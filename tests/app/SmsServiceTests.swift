// Tests for app/SmsService.swift's sending, against a scripted port: a message stored (AT+CMGW) and sent from the store
// (AT+CMSS), its status checked (AT+CMGR) and written again as sent when the modem left it unsent; a part refused or
// with no answer (not sent, or not known: the wording that warns of a second delivery is kept), the parts already
// stored deleted again when a later one cannot be stored; Retry (resend); and the direct send (AT+CMGS) when the
// modem would store where it does not list. Built with swiftc by `make app-test` from app/AtPort.swift,
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

/// Answers each line in the order scripted; a line sent out of order, or after the script, is a problem.
final class ScriptedPort: SmsPort {
    private var script: [(line: String, answer: Result<[String], AtError>)]
    private(set) var lines: [String] = []
    private(set) var payloads: [String] = []
    private(set) var problems: [String] = []
    private(set) var closed = false

    init(_ script: [(String, Result<[String], AtError>)]) {
        self.script = script.map { (line: $0.0, answer: $0.1) }
    }

    private func answer(_ line: String) -> Result<[String], AtError> {
        lines.append(line)
        guard !script.isEmpty else {
            problems.append("unscripted \(line)")
            return .failure(.modem("ERROR"))
        }
        let next = script.removeFirst()
        // A line ending in "*" matches any line that starts with what comes before it (an AT+CMGW length).
        let matches = next.line.hasSuffix("*") ? line.hasPrefix(String(next.line.dropLast())) : line == next.line
        if !matches { problems.append("sent \(line), expected \(next.line)") }
        return next.answer
    }

    func command(_ line: String, timeout: TimeInterval) -> Result<[String], AtError> { answer(line) }

    func send(_ line: String, afterPrompt payload: String, timeout: TimeInterval) -> Result<[String], AtError> {
        payloads.append(payload)
        return answer(line)
    }

    func close() { closed = true }

    var leftover: Int { script.count }
}

let ok: Result<[String], AtError> = .success([])
let pduMode: (String, Result<[String], AtError>) = ("AT+CMGF?", .success(["+CMGF: 0"]))
let sameStorage: (String, Result<[String], AtError>) = ("AT+CPMS?", .success(["+CPMS: \"ME\",3,255,\"ME\",3,255,\"ME\",3,255"]))
let number = "+15555550100"

func service(_ port: ScriptedPort) -> SmsService { SmsService(open: { .success(port) }) }

func finished(_ port: ScriptedPort, _ name: String) {
    check(port.problems.isEmpty, "\(name): lines in order", port.problems.joined(separator: "; "))
    check(port.leftover == 0, "\(name): every scripted line sent", "\(port.leftover) left")
    check(port.closed, "\(name): the port closed")
}

func failureMessage<T>(_ r: Result<T, SmsFailure>, _ name: String) -> String {
    guard case .failure(let f) = r else {
        check(false, "\(name): fails")
        return ""
    }
    return f.message
}

/// What AT+CMGR answers for a stored entry of `status`.
func readBack(_ status: Int, _ hex: String) -> Result<[String], AtError> {
    .success(["+CMGR: \(status),,\(hex.count / 2 - 1)", hex])
}

@main
struct SmsServiceTests {
    static func main() {
        storedSend()
        markedSent()
        partsAndFailures()
        directSend()
        retry()
        print("sms service: \(checks) checks passed")
    }

    // One part: stored unsent, sent from the store, read back as sent.
    static func storedSend() {
        guard case .success(let pdus) = encodeSubmit(to: number, text: "Made-up text", reference: 0) else {
            check(false, "the PDU encodes")
            return
        }
        let port = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=\(pdus[0].tpduLength),2", .success(["+CMGW: 5"])),
                                 ("AT+CMSS=5", .success(["+CMSS: 12"])), ("AT+CMGR=5", readBack(3, pdus[0].hex))])
        let result = service(port).send(to: number, text: "Made-up text")
        equal(try? result.get(), SmsSent(parts: 1, indices: [5]), "stored send: sent, stored at 5")
        equal(port.payloads, [pdus[0].hex], "stored send: the PDU written once")
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

    // A part the modem left unsent after its AT+CMSS: written again as sent, the unsent copy deleted.
    static func markedSent() {
        guard case .success(let pdus) = encodeSubmit(to: number, text: "Made-up text", reference: 0) else { return }
        let port = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=*", .success(["+CMGW: 5"])),
                                 ("AT+CMSS=5", .success(["+CMSS: 12"])), ("AT+CMGR=5", readBack(2, pdus[0].hex)),
                                 ("AT+CMGW=\(pdus[0].tpduLength),3", .success(["+CMGW: 6"])), ("AT+CMGD=5", ok)])
        equal(try? service(port).send(to: number, text: "Made-up text").get(), SmsSent(parts: 1, indices: [6]),
              "marked sent: the copy written as sent")
        equal(port.payloads, [pdus[0].hex, pdus[0].hex], "marked sent: the same PDU written again")
        finished(port, "marked sent")

        // The status not read: left as it is, the send stands.
        let quiet = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=*", .success(["+CMGW: 5"])),
                                  ("AT+CMSS=5", .success(["+CMSS: 12"])), ("AT+CMGR=5", .failure(.modem("+CMS ERROR: 321")))])
        equal(try? service(quiet).send(to: number, text: "Made-up text").get(), SmsSent(parts: 1, indices: [5]),
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
        equal(failureMessage(service(refused).send(to: number, text: long), "part 2 refused"),
              "Part 2 of 2 was refused. The modem refused the command (+CMS ERROR: 500). 1 of 2 parts were sent; the "
              + "message is incomplete at the receiver. It is kept on the modem as Not sent: Retry sends it, Delete removes it.",
              "part 2 refused: the sentence")
        check(refused.lines.filter { $0.hasPrefix("AT+CMGW") }.count == 2, "both parts stored before the first send")
        finished(refused, "part 2 refused")

        let unknown = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=*", .success(["+CMGW: 5"])),
                                    ("AT+CMSS=5", .failure(.timeout))])
        let message = failureMessage(service(unknown).send(to: number, text: "Made-up"), "no answer")
        check(message.contains("It is not known whether it was sent.")
                && message.contains("sending it again may deliver it twice")
                && message.hasSuffix("It is kept on the modem as Not sent: Retry sends it, Delete removes it."),
              "no answer: not known, kept as not sent", message)
        finished(unknown, "no answer")

        let noLine = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=*", .success(["+CMGW: 5"])), ("AT+CMSS=5", ok)])
        check(failureMessage(service(noLine).send(to: number, text: "Made-up"), "no +CMSS")
                .contains("The modem did not confirm it with a +CMSS line."), "OK without +CMSS: not known")
        finished(noLine, "no +CMSS")

        // Part 2 cannot be stored (the store is full): part 1 deleted again, nothing sent.
        let full = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=*", .success(["+CMGW: 5"])),
                                 ("AT+CMGW=*", .failure(.modem("+CMS ERROR: 322"))), ("AT+CMGD=5", ok)])
        equal(failureMessage(service(full).send(to: number, text: long), "store full"),
              "Part 2 of 2 could not be stored on the modem. The modem refused the command (+CMS ERROR: 322). Nothing was sent.",
              "store full: the sentence")
        check(!full.lines.contains { $0.hasPrefix("AT+CMSS") }, "store full: nothing sent")
        finished(full, "store full")

        // No +CMGW line: not known where it went; nothing sent, nothing deleted.
        let noIndex = ScriptedPort([pduMode, sameStorage, ("AT+CMGW=*", ok)])
        equal(failureMessage(service(noIndex).send(to: number, text: "Made-up"), "no index"),
              "The message could not be stored on the modem. The modem did not say where it stored it (no +CMGW line). "
              + "Nothing was sent.", "no index: the sentence")
        finished(noIndex, "no index")
    }

    // The modem lists one storage and writes to another (or AT+CPMS? gives no names): sent directly, not stored.
    static func directSend() {
        let mixed = ScriptedPort([pduMode, ("AT+CPMS?", .success(["+CPMS: \"SM\",0,50,\"ME\",3,255,\"ME\",3,255"])),
                                  ("AT+CMGS=*", .success(["+CMGS: 7"]))])
        equal(try? service(mixed).send(to: number, text: "Made-up").get(), SmsSent(parts: 1, indices: [], stored: false),
              "storages differ: sent directly")
        finished(mixed, "storages differ")

        let unnamed = ScriptedPort([pduMode, ("AT+CPMS?", .failure(.timeout)), ("AT+CMGS=*", .success(["+CMGS: 7"]))])
        equal((try? service(unnamed).send(to: number, text: "Made-up").get())?.stored, false, "no names: sent directly")
        let refused = ScriptedPort([pduMode, ("AT+CPMS?", .success(["+CPMS: 3,255,3,255,3,255"])),
                                    ("AT+CMGS=*", .failure(.modem("+CMS ERROR: 500")))])
        equal(failureMessage(service(refused).send(to: number, text: "Made-up"), "direct refused"),
              "The message was refused. The modem refused the command (+CMS ERROR: 500). Nothing was sent.",
              "direct: a refusal, as before")
    }

    // Retry: the stored unsent parts sent again.
    static func retry() {
        let port = ScriptedPort([pduMode, ("AT+CMSS=3", .success(["+CMSS: 20"])), ("AT+CMGR=3", .success(["+CMGR: 3,,20", "00"])),
                                 ("AT+CMSS=4", .success(["+CMSS: 21"])), ("AT+CMGR=4", .success(["+CMGR: 3,,20", "00"]))])
        equal(try? service(port).resend(indices: [3, 4]).get(), SmsSent(parts: 2, indices: [3, 4]), "retry: both sent")
        finished(port, "retry")

        let refused = ScriptedPort([pduMode, ("AT+CMSS=3", .failure(.modem("+CMS ERROR: 500")))])
        check(failureMessage(service(refused).resend(indices: [3]), "retry refused")
                .hasPrefix("The message was refused."), "retry: refused")
        finished(refused, "retry refused")

        var opened = false
        let none = SmsService(open: { opened = true; return .failure(.busy) })
        equal(failureMessage(none.resend(indices: []), "nothing to retry"),
              "There is nothing stored to send. Nothing was sent.", "retry: nothing")
        check(!opened, "retry: nothing, no port")
    }
}
