// Tests for app/SmsService.swift, against a scripted port that acts as AtPort does after a failure (after no answer or an
// I/O error it is closed: a command sent on it then is a problem). Sending: a message stored (AT+CMGW) and sent from the
// store (AT+CMSS, 120 s), its status checked (AT+CMGR) and, when the modem left it unsent, deleted and written again as
// sent; what became of each part (sent, still listed unsent, not known); a part refused or with no answer (the wording
// that warns of a second delivery is kept), the parts already stored deleted again when a later one cannot be stored
// (and said when that fails); the direct send (AT+CMGS) when the modem would store where it does not list, and a new
// port when AT+CPMS? got no answer. The window's Retry and delete: checked first against the module, the SIM, the
// storages and each listed part (another storage, an index that holds another message after a delete elsewhere, another
// SIM, another module, a send confirmed late), and never with a command that makes an unread message read. The listing's
// place, and the background count (AT+CMGL=1, 2, 3 only). Built with swiftc by `make app-test` from app/AtPort.swift,
// app/SmsModel.swift, app/SmsService.swift and this file; no port is opened. Every number and text is made up.
// Stops at the first failure, prints which check failed and exits 1.
import Foundation

var checks = 0

func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if !ok {
        print("FAIL: \(name)")
        let d = detail()
        if !d.isEmpty { print("  \(d)") }
        exit(1)
    }
}

func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    check(got == want, name, "got \(got)\nwant \(want)")
}

/// Answers each line in the order scripted; a line sent out of order, after the script, or after an answer that closes
/// a real port (no answer in time, an I/O error) is a problem.
final class ScriptedPort: SmsPort {
    private var script: [(line: String, answer: Result<[String], AtError>)]
    private(set) var lines: [String] = []
    private(set) var payloads: [String] = []
    private(set) var timeouts: [String: TimeInterval] = [:]
    private(set) var problems: [String] = []
    private(set) var closed = false
    private var dead = false
    let deviceSerial: String?

    init(_ script: [(String, Result<[String], AtError>)], device: String? = "TESTMODULE1") {
        self.script = script.map { (line: $0.0, answer: $0.1) }
        deviceSerial = device
    }

    private func answer(_ line: String, _ timeout: TimeInterval) -> Result<[String], AtError> {
        lines.append(line)
        timeouts[line] = timeout
        if dead { problems.append("\(line) sent on a closed port") }
        guard !script.isEmpty else {
            problems.append("unscripted \(line)")
            return .failure(.modem("ERROR"))
        }
        let next = script.removeFirst()
        // A line ending in "*" matches any line that starts with what comes before it (an AT+CMGW length).
        let matches = next.line.hasSuffix("*") ? line.hasPrefix(String(next.line.dropLast())) : line == next.line
        if !matches { problems.append("sent \(line), expected \(next.line)") }
        if case .failure(let error) = next.answer, error == .timeout || { if case .io = error { return true }; return false }() {
            dead = true
        }
        return next.answer
    }

    func command(_ line: String, timeout: TimeInterval) -> Result<[String], AtError> { answer(line, timeout) }

    func send(_ line: String, afterPrompt payload: String, timeout: TimeInterval) -> Result<[String], AtError> {
        payloads.append(payload)
        return answer(line, timeout)
    }

    func close() { closed = true }

    var leftover: Int { script.count }
}

typealias Step = (String, Result<[String], AtError>)

let ok: Result<[String], AtError> = .success([])
let pduMode: Step = ("AT+CMGF?", .success(["+CMGF: 0"]))
let sameStorage: Step = ("AT+CPMS?", .success(["+CPMS: \"ME\",3,255,\"ME\",3,255,\"ME\",3,255"]))
let imsi = "310150123456789"
let simRead: Step = ("AT+CIMI", .success([imsi]))
let number = "+12025550100"
let place = SmsPlace(device: "TESTMODULE1", sim: imsi, listsFrom: "ME", writesTo: "ME")

func service(_ port: ScriptedPort) -> SmsService { SmsService(open: { .success(port) }) }

/// A service that opens `ports` in turn.
func service(_ ports: [ScriptedPort]) -> SmsService {
    var left = ports
    return SmsService(open: { left.isEmpty ? .failure(.busy) : .success(left.removeFirst()) })
}

func finished(_ port: ScriptedPort, _ name: String) {
    check(port.problems.isEmpty, "\(name): lines in order", port.problems.joined(separator: "; "))
    check(port.leftover == 0, "\(name): every scripted line sent", "\(port.leftover) left")
    check(port.closed, "\(name): the port closed")
}

func failure<T>(_ r: Result<T, SmsFailure>, _ name: String) -> SmsFailure {
    guard case .failure(let f) = r else {
        check(false, "\(name): fails")
        return SmsFailure(message: "")
    }
    return f
}

func failureMessage<T>(_ r: Result<T, SmsFailure>, _ name: String) -> String { failure(r, name).message }

/// What AT+CMGR answers for a stored entry of `status`.
func readBack(_ status: Int, _ hex: String) -> Result<[String], AtError> {
    .success(["+CMGR: \(status),,\(hex.count / 2 - 1)", hex])
}

/// What AT+CMGL=<stat> answers for `entries`.
func listed(_ entries: [StoredPdu]) -> Result<[String], AtError> {
    .success(entries.flatMap { ["+CMGL: \($0.index),\($0.status.rawValue),,\($0.hex.count / 2 - 1)", $0.hex] })
}

func submit(_ text: String, to: String = number) -> SubmitPdu {
    guard case .success(let pdus) = encodeSubmit(to: to, text: text, reference: 0), let first = pdus.first else {
        check(false, "the PDU encodes")
        return SubmitPdu(hex: "00", tpduLength: 0)
    }
    return first
}

/// A received entry's made-up PDU (only its identity matters here).
func received(_ index: Int, _ status: SmsStatus = .read, _ tag: Int = 0) -> StoredPdu {
    StoredPdu(index: index, status: status, hex: String(format: "0004%02X%04X", tag, index))
}

func stored(_ index: Int, _ status: SmsStatus, _ pdu: SubmitPdu) -> StoredPdu {
    StoredPdu(index: index, status: status, hex: pdu.hex)
}

let commandsThatRead = ["AT+CMGL=0", "AT+CMGL=4", "AT+CMGR"]

func readsNoUnread(_ port: ScriptedPort, _ name: String) {
    check(!port.lines.contains { l in commandsThatRead.contains { l.hasPrefix($0) } },
          "\(name): no command that makes an unread message read", "\(port.lines)")
}

@main
struct SmsServiceTests {
    static func main() {
        signatures()
        storedSend()
        markedSent()
        partsAndFailures()
        directSend()
        listingPlace()
        retry()
        deleting()
        counting()
        print("sms service: \(checks) checks passed")
    }

    // A stored part's identity: its PDU without the service centre field and, sent, without the message reference.
    static func signatures() {
        let p = submit("Made-up text")
        var sentCopy = Array(p.hex)
        sentCopy.replaceSubrange(4..<6, with: Array("7F"))      // TP-MR, set by the modem when it sends
        equal(pduSignature(String(sentCopy)), pduSignature(p.hex), "signature: the message reference left out")
        equal(pduSignature("07912120550501F0" + p.hex.dropFirst(2)), pduSignature(p.hex),
              "signature: the service centre field left out")
        check(pduSignature(submit("Other made-up text").hex) != pduSignature(p.hex), "signature: another text differs")
        equal(pduSignature("zz"), "ZZ", "signature: not a PDU, itself")
        equal(StoredPart(index: 3, hex: p.hex), StoredPart(index: 3, hex: String(sentCopy)), "stored part: the same")
        check(StoredPart(index: 4, hex: p.hex) != StoredPart(index: 3, hex: p.hex), "stored part: another index")
    }

    // One part: stored unsent, sent from the store (120 s), read back as sent.
    static func storedSend() {
        let pdu = submit("Made-up text")
        let port = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=\(pdu.tpduLength),2", .success(["+CMGW: 5"])),
                                 ("AT+CMSS=5", .success(["+CMSS: 12"])), ("AT+CMGR=5", readBack(3, pdu.hex))])
        let result = service(port).send(to: number, text: "Made-up text")
        equal(try? result.get(), SmsSent(parts: 1, indices: [5], record: SmsSendRecord(sent: [StoredPart(index: 5, hex: pdu.hex)])),
              "stored send: sent, stored at 5")
        equal(port.payloads, [pdu.hex], "stored send: the PDU written once")
        equal(port.timeouts["AT+CMSS=5"], 120, "stored send: AT+CMSS waits 120 s, as the manual says")
        finished(port, "stored send")

        // A bad number never opens the port.
        var opened = false
        let s = SmsService(open: { opened = true; return .failure(.busy) })
        check(failureMessage(s.send(to: "12", text: "x"), "bad number").hasPrefix("The number is not valid"), "bad number")
        check(!opened, "bad number: no port")
        // A busy port: nothing sent.
        equal(failureMessage(s.send(to: number, text: "x"), "busy"),
              "Another program is using the modem's spare AT port. Nothing was sent.", "busy: nothing sent")
    }

    // A part the modem left unsent after its AT+CMSS: deleted, then written again as sent (the delete frees the place).
    static func markedSent() {
        let pdu = submit("Made-up text")
        let part = StoredPart(index: 5, hex: pdu.hex)
        let port = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=*", .success(["+CMGW: 5"])),
                                 ("AT+CMSS=5", .success(["+CMSS: 12"])), ("AT+CMGR=5", readBack(2, pdu.hex)),
                                 ("AT+CMGD=5", ok), ("AT+CMGW=\(pdu.tpduLength),3", .success(["+CMGW: 6"]))])
        equal(try? service(port).send(to: number, text: "Made-up text").get(),
              SmsSent(parts: 1, indices: [6], record: SmsSendRecord(sent: [StoredPart(index: 6, hex: pdu.hex)])),
              "marked sent: the copy written as sent")
        equal(port.payloads, [pdu.hex, pdu.hex], "marked sent: the same PDU written again")
        finished(port, "marked sent")

        // The delete refused: still listed unsent, though sent (never offered for Retry).
        let kept = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=*", .success(["+CMGW: 5"])),
                                 ("AT+CMSS=5", .success(["+CMSS: 12"])), ("AT+CMGR=5", readBack(2, pdu.hex)),
                                 ("AT+CMGD=5", .failure(.modem("+CMS ERROR: 321")))])
        equal((try? service(kept).send(to: number, text: "Made-up text").get())?.record,
              SmsSendRecord(sent: [part], stillUnsent: [part]), "marked sent: not deleted, still unsent but sent")
        finished(kept, "not deleted")

        // The copy not written (after the delete): sent, no longer stored; nothing offered for Retry.
        let lost = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=*", .success(["+CMGW: 5"])),
                                 ("AT+CMSS=5", .success(["+CMSS: 12"])), ("AT+CMGR=5", readBack(2, pdu.hex)),
                                 ("AT+CMGD=5", ok), ("AT+CMGW=*", .failure(.modem("+CMS ERROR: 322")))])
        let r = try? service(lost).send(to: number, text: "Made-up text").get()
        check(r?.parts == 1 && r?.record == SmsSendRecord(), "marked sent: the copy not written, the send stands", "\(String(describing: r))")
        finished(lost, "copy not written")

        // The status not read: the send stands; kept as still unsent (if it is listed so, it is not offered for Retry).
        let quiet = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=*", .success(["+CMGW: 5"])),
                                  ("AT+CMSS=5", .success(["+CMSS: 12"])), ("AT+CMGR=5", .failure(.modem("+CMS ERROR: 321")))])
        equal(try? service(quiet).send(to: number, text: "Made-up text").get(),
              SmsSent(parts: 1, indices: [5], record: SmsSendRecord(sent: [part], stillUnsent: [part])),
              "marked sent: the status not read, the send stands")
        finished(quiet, "status not read")
    }

    // Two parts: every part stored first; a send refused, a send with no answer, a part that cannot be stored.
    static func partsAndFailures() {
        let long = String(repeating: "made-up ", count: 25)
        let refused = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=*", .success(["+CMGW: 5"])),
                                    ("AT+CMGW=*", .success(["+CMGW: 6"])), ("AT+CMSS=5", .success(["+CMSS: 12"])),
                                    ("AT+CMGR=5", .success(["+CMGR: 3,,140", "00"])),
                                    ("AT+CMSS=6", .failure(.modem("+CMS ERROR: 500")))])
        let f = failure(service(refused).send(to: number, text: long), "part 2 refused")
        equal(f.message,
              "Part 2 of 2 was refused. The modem refused the command (+CMS ERROR: 500). 1 of 2 parts were sent; the "
              + "message is incomplete at the receiver. It is kept on the modem as Not sent: Retry sends it, Delete removes it.",
              "part 2 refused: the sentence")
        equal(f.record, SmsSendRecord(sent: [StoredPart(index: 5, hex: "00")]), "part 2 refused: part 1 sent, part 2 not")
        check(refused.lines.filter { $0.hasPrefix("AT+CMGW") }.count == 2, "both parts stored before the first send")
        finished(refused, "part 2 refused")

        // No answer: not known; the port is not used again; the part is recorded as not known.
        let pdu = submit("Made-up")
        let unknown = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=*", .success(["+CMGW: 5"])),
                                    ("AT+CMSS=5", .failure(.timeout))])
        let u = failure(service(unknown).send(to: number, text: "Made-up"), "no answer")
        check(u.message.contains("It is not known whether it was sent.")
                && u.message.contains("sending it again may deliver it twice")
                && u.message.hasSuffix("It is kept on the modem as Not sent: Retry sends it, Delete removes it."),
              "no answer: not known, kept as not sent", u.message)
        equal(u.record, SmsSendRecord(unknown: [StoredPart(index: 5, hex: pdu.hex)]), "no answer: recorded as not known")
        finished(unknown, "no answer")

        let noLine = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=*", .success(["+CMGW: 5"])), ("AT+CMSS=5", ok)])
        let n = failure(service(noLine).send(to: number, text: "Made-up"), "no +CMSS")
        check(n.message.contains("The modem did not confirm it with a +CMSS line."), "OK without +CMSS: not known")
        equal(n.record.unknown.map { $0.index }, [5], "OK without +CMSS: recorded as not known")
        finished(noLine, "no +CMSS")

        // Part 2 cannot be stored (the store is full): part 1 deleted again, nothing sent.
        let full = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=*", .success(["+CMGW: 5"])),
                                 ("AT+CMGW=*", .failure(.modem("+CMS ERROR: 322"))), ("AT+CMGD=5", ok)])
        equal(failureMessage(service(full).send(to: number, text: long), "store full"),
              "Part 2 of 2 could not be stored on the modem. The modem refused the command (+CMS ERROR: 322). Nothing was sent.",
              "store full: the sentence")
        check(!full.lines.contains { $0.hasPrefix("AT+CMSS") }, "store full: nothing sent")
        finished(full, "store full")

        // Part 1 could not be deleted again: said so.
        let stuck = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=*", .success(["+CMGW: 5"])),
                                  ("AT+CMGW=*", .failure(.modem("+CMS ERROR: 322"))),
                                  ("AT+CMGD=5", .failure(.modem("+CMS ERROR: 321")))])
        check(failureMessage(service(stuck).send(to: number, text: long), "not deleted again")
                .hasSuffix("Nothing was sent. Parts already stored are listed as Not sent."),
              "store full, part 1 not deleted: said so")
        finished(stuck, "not deleted again")

        // Part 2's write got no answer: the port is closed, so part 1 is not deleted (and is said to be listed).
        let lost = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=*", .success(["+CMGW: 5"])), ("AT+CMGW=*", .failure(.timeout))])
        check(failureMessage(service(lost).send(to: number, text: long), "write no answer")
                .hasSuffix("Nothing was sent. Parts already stored are listed as Not sent."),
              "write with no answer: nothing more on the port, part 1 listed")
        finished(lost, "write no answer")

        // No +CMGW line: not known where it went; nothing sent, nothing deleted.
        let noIndex = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=*", ok)])
        equal(failureMessage(service(noIndex).send(to: number, text: "Made-up"), "no index"),
              "The message could not be stored on the modem. The modem did not say where it stored it (no +CMGW line). "
              + "Nothing was sent.", "no index: the sentence")
        finished(noIndex, "no index")
    }

    // The modem lists one storage and writes to another (or AT+CPMS? is refused or gives no names): sent directly, not
    // stored. AT+CPMS? with no answer: a new port, once (the first one is closed).
    static func directSend() {
        let mixed = ScriptedPort([pduMode, ("AT+CPMS?", .success(["+CPMS: \"SM\",0,50,\"ME\",3,255,\"ME\",3,255"])),
                                  ("AT+CMGS=*", .success(["+CMGS: 7"]))])
        equal(try? service(mixed).send(to: number, text: "Made-up").get(), SmsSent(parts: 1, indices: [], stored: false),
              "storages differ: sent directly")
        equal(mixed.timeouts.first { $0.key.hasPrefix("AT+CMGS=") }?.value, 120, "direct: AT+CMGS waits 120 s")
        finished(mixed, "storages differ")

        let refusedRead = ScriptedPort([pduMode, ("AT+CPMS?", .failure(.modem("ERROR"))), ("AT+CMGS=*", .success(["+CMGS: 7"]))])
        equal((try? service(refusedRead).send(to: number, text: "Made-up").get())?.stored, false,
              "storages refused: sent directly on the same port")
        finished(refusedRead, "storages refused")

        let pdu = submit("Made-up")
        let first = ScriptedPort([pduMode, ("AT+CPMS?", .failure(.timeout))])
        let second = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=*", .success(["+CMGW: 5"])),
                                   ("AT+CMSS=5", .success(["+CMSS: 12"])), ("AT+CMGR=5", readBack(3, pdu.hex))])
        equal((try? service([first, second]).send(to: number, text: "Made-up").get())?.indices, [5],
              "storages not answered: stored and sent on a new port")
        finished(first, "the closed port")
        finished(second, "the new port")

        let again1 = ScriptedPort([pduMode, ("AT+CPMS?", .failure(.timeout))])
        let again2 = ScriptedPort([pduMode, ("AT+CPMS?", .failure(.timeout))])
        equal(failureMessage(service([again1, again2]).send(to: number, text: "Made-up"), "storages twice"),
              "Where the modem stores messages could not be read. The modem did not answer in time. Nothing was sent.",
              "storages not answered twice: nothing sent")
        finished(again1, "twice, first")
        finished(again2, "twice, second")

        let unnamed = ScriptedPort([pduMode, ("AT+CPMS?", .success(["+CPMS: 3,255,3,255,3,255"])),
                                    ("AT+CMGS=*", .failure(.modem("+CMS ERROR: 500")))])
        equal(failureMessage(service(unnamed).send(to: number, text: "Made-up"), "direct refused"),
              "The message was refused. The modem refused the command (+CMS ERROR: 500). Nothing was sent.",
              "direct: a refusal, as before")
        finished(unnamed, "no names")
    }

    // The listing: every part, and where they were listed (module, SIM, storages).
    static func listingPlace() {
        let r = received(0, .unread)
        let port = ScriptedPort([pduMode, ("AT+CMGL=4", listed([r])), sameStorage, simRead])
        guard case .success(let l) = service(port).list() else { return check(false, "listing: succeeds") }
        equal(l.parts, [r], "listing: the parts")
        equal(l.place, place, "listing: module, SIM and storages")
        equal(l.used, 3, "listing: the store's use")
        finished(port, "listing")

        let noSim = ScriptedPort([pduMode, ("AT+CMGL=4", listed([])), sameStorage, ("AT+CIMI", .failure(.modem("+CME ERROR: 10")))])
        let n = try? service(noSim).list().get()
        check(n?.place.sim == nil && n?.place.complete == true, "listing: no SIM is a place too")
        finished(noSim, "listing without a SIM")

        let stuck = ScriptedPort([pduMode, ("AT+CMGL=4", listed([r])), ("AT+CPMS?", .failure(.timeout))])
        let s = try? service(stuck).list().get()
        check(s?.messages.count == 1 && s?.place.complete == false, "listing: storages not read, the place not complete")
        finished(stuck, "listing, storages not read")
    }

    // Retry: checked first (module, SIM, storages, each part still unsent as listed); then sent again.
    static func retry() {
        let a = submit("Made-up part one"), b = submit("Made-up part two")
        let parts = [stored(3, .unsent, a), stored(4, .unsent, b)]
        let check1: [Step] = [pduMode, sameStorage, simRead, ("AT+CMGL=2", listed(parts))]
        let port = ScriptedPort(check1 + [("AT+CMSS=3", .success(["+CMSS: 20"])), ("AT+CMGR=3", readBack(3, a.hex)),
                                          ("AT+CMSS=4", .success(["+CMSS: 21"])), ("AT+CMGR=4", readBack(3, b.hex))])
        equal((try? service(port).resend(parts, listedFrom: place).get())?.indices, [3, 4], "retry: both sent")
        finished(port, "retry")

        let refused = ScriptedPort([pduMode, sameStorage, simRead, ("AT+CMGL=2", listed([parts[0]])),
                                    ("AT+CMSS=3", .failure(.modem("+CMS ERROR: 500")))])
        check(failureMessage(service(refused).resend([parts[0]], listedFrom: place), "retry refused")
                .hasPrefix("The message was refused."), "retry: refused")
        finished(refused, "retry refused")

        // An index that holds another message now (deleted elsewhere, and another written there): nothing sent.
        let other = stored(3, .unsent, submit("Another made-up message"))
        let reused = ScriptedPort([pduMode, sameStorage, simRead, ("AT+CMGL=2", listed([other, parts[1]]))])
        let r = failure(service(reused).resend(parts, listedFrom: place), "reused index")
        check(r.listingChanged && r.message == "The messages on the modem changed since they were listed: stored part 3 "
              + "is not the one listed. Nothing was sent.", "retry: an index reused, nothing sent", r.message)
        readsNoUnread(reused, "retry, reused")
        finished(reused, "reused index")

        // Sent late (no answer at the time; the modem sent it): no longer unsent, nothing sent again.
        let late = ScriptedPort([pduMode, sameStorage, simRead, ("AT+CMGL=2", listed([parts[1]]))])
        check(failure(service(late).resend(parts, listedFrom: place), "late").listingChanged,
              "retry: a part confirmed late is not sent again")
        finished(late, "late confirmation")

        // Another SIM: nothing sent.
        let sim = ScriptedPort([pduMode, sameStorage, ("AT+CIMI", .success(["310150987654321"]))])
        let s = failure(service(sim).resend(parts, listedFrom: place), "another SIM")
        check(s.listingChanged && s.message.contains("another SIM is in use"), "retry: another SIM, nothing sent", s.message)
        finished(sim, "another SIM")

        // Another module: nothing sent, not even read.
        let module = ScriptedPort([pduMode], device: "TESTMODULE2")
        check(failure(service(module).resend(parts, listedFrom: place), "another module").listingChanged,
              "retry: another module, nothing sent")
        finished(module, "another module")

        // Listed from one storage, sending from another (<mem1> is not <mem2>): AT+CMSS would send another entry.
        let split = SmsPlace(device: "TESTMODULE1", sim: imsi, listsFrom: "SM", writesTo: "ME")
        let mixed = ScriptedPort([pduMode, ("AT+CPMS?", .success(["+CPMS: \"SM\",3,50,\"ME\",3,255,\"ME\",3,255"])), simRead])
        let m = failure(service(mixed).resend(parts, listedFrom: split), "mem1 not mem2")
        check(!m.listingChanged && m.message.hasPrefix("The modem sends from another storage than the one it lists"),
              "retry: <mem1> not <mem2>, nothing sent", m.message)
        finished(mixed, "mem1 not mem2")
        // The storage changed since the listing.
        let moved = ScriptedPort([pduMode, ("AT+CPMS?", .success(["+CPMS: \"SM\",3,50,\"SM\",3,50,\"SM\",3,50"])), simRead])
        check(failure(service(moved).resend(parts, listedFrom: place), "moved").listingChanged,
              "retry: another storage than listed, nothing sent")
        finished(moved, "storage changed")

        // Not known where they were listed: nothing read beyond the format.
        let unknown = ScriptedPort([pduMode])
        check(failure(service(unknown).resend(parts, listedFrom: SmsPlace(complete: false)), "unknown place").listingChanged,
              "retry: the listing's place not known, list again")
        finished(unknown, "unknown place")

        var opened = false
        let none = SmsService(open: { opened = true; return .failure(.busy) })
        equal(failureMessage(none.resend([], listedFrom: place), "nothing to retry"),
              "There is nothing stored to send. Nothing was sent.", "retry: nothing")
        equal(failureMessage(none.resend([received(1)], listedFrom: place), "a received part"),
              "There is nothing stored to send. Nothing was sent.", "retry: a received part is not sent")
        check(!opened, "retry: nothing, no port")
    }

    // The window's delete: checked first; a received part is looked for among the read ones only (listing made it read);
    // never with a command that makes an unread message read.
    static func deleting() {
        let mine = submit("Made-up reply")
        let r = received(0, .unread), s = stored(9, .sent, mine), u = stored(11, .unsent, submit("Made-up unsent"))
        let port = ScriptedPort([pduMode, sameStorage, simRead, ("AT+CMGL=1", listed([received(0)])),
                                 ("AT+CMGL=2", listed([u])), ("AT+CMGL=3", listed([s])),
                                 ("AT+CMGD=0", ok), ("AT+CMGD=9", ok), ("AT+CMGD=11", ok)])
        equal(try? service(port).delete([r, s, u], listedFrom: place).get(), 3, "delete: checked, then deleted")
        readsNoUnread(port, "delete")
        finished(port, "delete")

        // Index 0 holds another message now: nothing deleted.
        let reused = ScriptedPort([pduMode, sameStorage, simRead, ("AT+CMGL=1", listed([received(0, .read, 7)]))])
        let f = failure(service(reused).delete([r], listedFrom: place), "reused")
        check(f.listingChanged && f.message.hasSuffix("Nothing was deleted."), "delete: an index reused, nothing deleted")
        finished(reused, "delete, reused")

        // Index 0 holds a new unread message (not among the read ones): nothing deleted, nothing read.
        let fresh = ScriptedPort([pduMode, sameStorage, simRead, ("AT+CMGL=1", listed([]))])
        check(failure(service(fresh).delete([r], listedFrom: place), "fresh").listingChanged,
              "delete: a new unread message at the index, nothing deleted")
        readsNoUnread(fresh, "delete, fresh")
        finished(fresh, "delete, fresh")

        // An unsent part sent late (listed sent now): it is the same message, deleted.
        let late = ScriptedPort([pduMode, sameStorage, simRead, ("AT+CMGL=2", listed([])),
                                 ("AT+CMGL=3", listed([stored(11, .sent, submit("Made-up unsent"))])), ("AT+CMGD=11", ok)])
        equal(try? service(late).delete([u], listedFrom: place).get(), 1, "delete: sent late, still deleted")
        finished(late, "delete, late")

        // The SIM taken out since the listing.
        let sim = ScriptedPort([pduMode, sameStorage, ("AT+CIMI", .failure(.modem("+CME ERROR: 10")))])
        check(failure(service(sim).delete([r], listedFrom: place), "no SIM").listingChanged, "delete: the SIM changed")
        finished(sim, "delete, SIM")

        // The check could not be read: nothing deleted, not a changed listing.
        let quiet = ScriptedPort([pduMode, ("AT+CPMS?", .failure(.timeout))])
        let q = failure(service(quiet).delete([r], listedFrom: place), "quiet")
        check(!q.listingChanged && q.message.hasSuffix("Nothing was deleted."), "delete: not checked, nothing deleted")
        finished(quiet, "delete, quiet")
    }

    // The background count: the store's entries less the read, unsent and sent ones; never a command that reads an
    // unread one.
    static func counting() {
        let port = ScriptedPort([pduMode, sameStorage, ("AT+CMGL=1", listed([received(0), received(1)])),
                                 ("AT+CMGL=2", listed([stored(2, .unsent, submit("x"))])), ("AT+CMGL=3", listed([])),
                                 sameStorage])
        equal(try? service(port).countUnread().get(), SmsStoreCount(used: 3, received: 2, unread: 0), "count: none unread")
        readsNoUnread(port, "count")
        finished(port, "count")

        let one = ScriptedPort([pduMode, sameStorage, ("AT+CMGL=1", listed([received(0)])), ("AT+CMGL=2", listed([])),
                                ("AT+CMGL=3", listed([stored(2, .sent, submit("x"))])), sameStorage])
        equal(try? service(one).countUnread().get(), SmsStoreCount(used: 3, received: 2, unread: 1), "count: one unread")
        finished(one, "count one")

        let moving = ScriptedPort([pduMode, sameStorage, ("AT+CMGL=1", listed([])), ("AT+CMGL=2", listed([])),
                                   ("AT+CMGL=3", listed([])), ("AT+CPMS?", .success(["+CPMS: \"ME\",4,255,\"ME\",4,255,\"ME\",4,255"]))])
        equal(failureMessage(service(moving).countUnread(), "moving"), "The message store changed while it was counted.",
              "count: the store changed meanwhile, tried later")
        finished(moving, "count moving")

        let text = ScriptedPort([("AT+CMGF?", .success(["+CMGF: 1"])), ("AT+CMGF=0", ok), sameStorage,
                                 ("AT+CMGL=1", listed([])), ("AT+CMGL=2", listed([])), ("AT+CMGL=3", listed([])), sameStorage])
        equal((try? service(text).countUnread().get())?.unread, 3, "count: text mode switched to PDU mode first")
        finished(text, "count text mode")
    }
}
