// Tests for app/MessageAlerts.swift, app/ModemPulse.swift and the background check of app/SmsController.swift: when the
// store's count is followed by a count of the unread entries (the first, a count that changed, every tenth while it
// stays), the baseline and its one summary at start, what counts as new (more unread, or more received while some are
// unread; never RMNet's own sends), what a notification says (never a sender or text), the permission (asked once,
// refused: dropped and asked again later), the background turn (one read for all, commands once each, a busy port
// skipped for all, nothing opened when nothing is wanted), and the controller's part (every other turn, not while the
// Messages screen lists, not with notifications off nor when they were turned off during a count, a busy turn skipped,
// the count on the background service and never a listing, the alerts it gives); the controller's replies (one draft a
// conversation, to that conversation's number), Retry and delete with the listed parts. Built with swiftc by
// `make app-test`; no AppKit, no modem. Every number and text is made up.
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

/// Runs the main run loop until `condition` holds (or fails the check after 2 s).
func pump(until condition: () -> Bool, _ name: String) {
    let deadline = Date().addingTimeInterval(2)
    while !condition() {
        if Date() > deadline { check(false, "timed out waiting: \(name)") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
}

func settle() {
    let end = Date().addingTimeInterval(0.1)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
}

let t0 = Date(timeIntervalSince1970: 1_700_000_000)

func count(_ used: Int, received: Int, unread: Int) -> SmsStoreCount {
    SmsStoreCount(used: used, received: received, unread: unread)
}

/// A made-up stored PDU for index `i` (only its identity matters here).
func pdu(_ i: Int, _ status: SmsStatus) -> StoredPdu { StoredPdu(index: i, status: status, hex: String(format: "00%04X", i)) }

/// A listing of `messages`, each part listed with the status its message has.
func listingOf(_ messages: [SmsMessage], used: Int, place: SmsPlace = SmsPlace(sim: "310150123456789")) -> SmsListing {
    let parts = messages.flatMap { m in
        m.indices.map { i -> StoredPdu in
            switch m.box {
            case .received: return pdu(i, m.unread ? .unread : .read)
            case .sent: return pdu(i, .sent)
            case .unsent: return pdu(i, m.unsentIndices.contains(i) ? .unsent : .sent)
            }
        }
    }
    return SmsListing(messages: messages, used: used, total: 50, parts: parts, place: place)
}

/// A service whose answers are set by the test and come at once (a count can be held until `release`).
final class FakeSms: SmsServing {
    var listing: Result<SmsListing, SmsFailure> = .success(SmsListing(messages: [], used: 0, total: 50))
    var counted: Result<SmsStoreCount, SmsFailure> = .success(SmsStoreCount(used: 0, received: 0, unread: 0))
    var lists = 0
    var counts = 0
    var holdCount = false
    private let gate = DispatchSemaphore(value: 0)
    var sends: [(number: String, text: String)] = []
    var resends: [(parts: [StoredPdu], place: SmsPlace)] = []
    var deletes: [(parts: [StoredPdu], place: SmsPlace)] = []
    var sendIndex = 9
    var resendResult: Result<SmsSent, SmsFailure>? = nil

    func list() -> Result<SmsListing, SmsFailure> {
        lists += 1
        return listing
    }
    func countUnread() -> Result<SmsStoreCount, SmsFailure> {
        counts += 1
        if holdCount { gate.wait() }
        return counted
    }
    func release() { gate.signal() }
    func delete(indices: [Int]) -> Result<Int, SmsFailure> { .failure(SmsFailure(message: "not the window's")) }
    func delete(_ parts: [StoredPdu], listedFrom place: SmsPlace) -> Result<Int, SmsFailure> {
        deletes.append((parts, place))
        return .success(parts.count)
    }
    func send(to number: String, text: String) -> Result<SmsSent, SmsFailure> {
        sends.append((number, text))
        let part = StoredPart(index: sendIndex, hex: String(format: "00%04X", sendIndex))
        return .success(SmsSent(parts: 1, indices: [sendIndex], record: SmsSendRecord(sent: [part])))
    }
    func resend(_ parts: [StoredPdu], listedFrom place: SmsPlace) -> Result<SmsSent, SmsFailure> {
        resends.append((parts, place))
        if let resendResult { return resendResult }
        let record = SmsSendRecord(sent: parts.map(StoredPart.init))
        return .success(SmsSent(parts: parts.count, indices: parts.map { $0.index }, record: record))
    }
}

func store(_ used: Int) -> Result<[String: PulseAnswer], ModemFailure> {
    .success(["AT+CPMS?": .lines(["+CPMS: \"ME\",\(used),50,\"ME\",\(used),50,\"ME\",\(used),50"])])
}

@main
struct MessageAlertsTests {
    static func main() {
        watchCounts()
        watchAlerts()
        content()
        permission()
        pulse()
        controller()
        turnedOffDuringCount()
        ownMessages()
        print("message alerts: \(checks) checks passed")
    }

    // When the store's count is followed by a count of the unread.
    static func watchCounts() {
        var w = NewMessageWatch()
        check(w.storeCount(3), "count: before the first count, count")
        check(!w.storeCount(nil), "count: not read, nothing")
        _ = w.counted(count(3, received: 3, unread: 0))
        check(!w.storeCount(3), "count: the same, nothing")
        check(w.storeCount(4), "count: up, count")
        check(w.storeCount(2), "count: down, count (a delete and a new message may both have come)")
        _ = w.counted(count(3, received: 3, unread: 0))
        for n in 1..<NewMessageWatch.recountEvery { check(!w.storeCount(3), "count: the same, read \(n), nothing") }
        check(w.storeCount(3), "count: the tenth read of the same count, count anyway")
        _ = w.counted(count(3, received: 3, unread: 0))
        check(!w.storeCount(3), "count: after a count, the reads start again")
    }

    // The baseline's summary; later, more unread or more received (with some unread) is new; RMNet's own sends never.
    static func watchAlerts() {
        var w = NewMessageWatch()
        equal(w.counted(count(3, received: 3, unread: 2)), .summary(unread: 2), "first: one summary of the two unread")
        check(w.started, "first: the baseline")
        var quiet = NewMessageWatch()
        equal(quiet.counted(count(1, received: 1, unread: 0)), nil, "first: none unread, no summary")

        equal(w.counted(count(3, received: 3, unread: 2)), nil, "the same again: nothing")
        equal(w.counted(count(4, received: 4, unread: 3)), .arrived(1), "one more unread: new")
        equal(w.counted(count(6, received: 6, unread: 5)), .arrived(2), "two parts (one long message, maybe): new")
        equal(w.counted(count(7, received: 6, unread: 5)), nil, "a send stored (sent or unsent): not new")
        equal(w.counted(count(9, received: 6, unread: 5)), nil, "`RMNet sms send` twice: not new")
        // Read elsewhere (`RMNet sms list`): fewer unread, nothing; then one more received while it is unread: new.
        equal(w.counted(count(9, received: 6, unread: 0)), nil, "read elsewhere: nothing")
        equal(w.counted(count(10, received: 7, unread: 1)), .arrived(1), "one received after those were read: new")
        equal(w.counted(count(11, received: 8, unread: 0)), nil, "received and read elsewhere before the count: nothing")
        // A read one deleted elsewhere and a new one received between two counts: the store's count the same, new.
        equal(w.counted(count(11, received: 8, unread: 1)), .arrived(1), "one deleted, one received: new")
        equal(w.counted(count(10, received: 7, unread: 1)), nil, "a read one deleted: nothing")

        // The Messages screen listed: none unread on the modem, then one comes in.
        w.listedByWindow(used: 10, received: 7)
        equal(w.unread, 0, "listed: none unread")
        check(!w.storeCount(10), "listed: the store's count known")
        equal(w.counted(count(11, received: 8, unread: 1)), .arrived(1), "listed, then one more: new")
        var fresh = NewMessageWatch()
        fresh.listedByWindow(used: 2, received: 2)
        equal(fresh.counted(count(2, received: 2, unread: 0)), nil, "listed before any count: no summary after")
    }

    // What a notification says: never who sent it or what it says.
    static func content() {
        check(alertContent(.summary(unread: 1)) == ("RMNet", "1 unread message on the modem."), "content: the summary, one")
        equal(alertContent(.summary(unread: 3)).body, "Unread messages on the modem.", "content: the summary, more")
        check(alertContent(.arrived(1)) == ("RMNet", "New message on the modem."), "content: one new")
        equal(alertContent(.arrived(2)).body, "New messages on the modem.", "content: more new")
        equal(unreadLine(0), "", "unread line: none")
        equal(unreadLine(1), "1 unread message", "unread line: one")
        equal(unreadLine(2), "2 unread messages", "unread line: two")
        equal(unreadLine(0, onModem: 1), "1 unread message", "unread line: one on the modem")
        equal(unreadLine(0, onModem: 3), "Unread messages", "unread line: parts on the modem")
        equal(unreadLine(2, onModem: 1), "2+ unread messages", "unread line: marked and on the modem")
    }

    // The permission: asked once, the posts meanwhile wait; refused by the system: dropped, and asked again (without a
    // prompt) on the next post; allowed later in System Settings: posted.
    static func permission() {
        var asks: [(Bool) -> Void] = []
        var checksAsked: [(Bool) -> Void] = []
        var added: [String] = []
        let gate = NotificationGate<String>(ask: { asks.append($0) }, check: { checksAsked.append($0) },
                                            add: { added.append($0) })
        gate.post("a")
        gate.post("b")
        equal(asks.count, 1, "permission: asked once")
        equal(gate.permission, .asking, "permission: asking")
        asks[0](false)
        equal(gate.permission, .refused, "permission: refused by the system")
        equal(added, [], "permission: refused, nothing posted")
        equal(gate.dropped, 2, "permission: refused, the waiting ones dropped")
        gate.post("c")
        equal(asks.count, 1, "permission: not prompted again")
        equal(checksAsked.count, 1, "permission: the system's setting checked again")
        checksAsked[0](false)
        equal(added, [], "permission: still refused, nothing posted")
        equal(gate.dropped, 3, "permission: dropped again")
        gate.post("d")
        checksAsked[1](true)
        equal(added, ["d"], "permission: allowed in System Settings since, posted")
        gate.post("e")
        equal(added, ["d", "e"], "permission: allowed, posted at once")
        equal(checksAsked.count, 2, "permission: allowed, not checked again")

        var granted: [(Bool) -> Void] = []
        var posted: [String] = []
        let yes = NotificationGate<String>(ask: { granted.append($0) }, check: { _ in }, add: { posted.append($0) })
        yes.post("x")
        granted[0](true)
        equal(posted, ["x"], "permission: allowed at the prompt, the waiting one posted")
    }

    // The background turn.
    static func pulse() {
        var reads: [[String]] = []
        var answer: Result<[PulseAnswer], ModemFailure> = .success([])
        let p = ModemPulse(queue: DispatchQueue(label: "pulse.test"), read: { commands in
            reads.append(commands)
            switch answer {
            case .success: return .success(commands.map { .lines(["answer to \($0)"]) })
            case .failure(let f): return .failure(f)
            }
        })
        var gotA: [Result<[String: PulseAnswer], ModemFailure>] = []
        var gotB: [Result<[String: PulseAnswer], ModemFailure>] = []
        var wantA: [String] = ["AT+CFUN?", "AT+QENG=\"servingcell\""]
        var wantB: [String] = ["AT+CPMS?", "AT+CFUN?"]
        var turnsSeen: [Int] = []
        p.add(ModemPulse.Rider(commands: { turn in turnsSeen.append(turn); return wantA }, deliver: { gotA.append($0) }))
        p.add(ModemPulse.Rider(commands: { _ in wantB }, deliver: { gotB.append($0) }))

        p.turn()
        pump(until: { gotA.count == 1 && gotB.count == 1 }, "pulse: the first turn")
        equal(reads, [["AT+CFUN?", "AT+QENG=\"servingcell\"", "AT+CPMS?"]], "pulse: one read, each command once")
        equal(turnsSeen, [1], "pulse: the first turn is 1")
        if case .success(let a) = gotA[0] {
            equal(Set(a.keys), ["AT+CFUN?", "AT+QENG=\"servingcell\""], "pulse: A gets its own answers")
        } else { check(false, "pulse: A's answers") }
        if case .success(let b) = gotB[0] {
            equal(b["AT+CPMS?"], .lines(["answer to AT+CPMS?"]), "pulse: B gets its own answers")
            equal(Set(b.keys), ["AT+CPMS?", "AT+CFUN?"], "pulse: a shared command for both")
        } else { check(false, "pulse: B's answers") }

        // A busy port: the turn skipped for both, as a failure each.
        answer = .failure(ModemFailure(message: "The modem's AT port is busy."))
        p.turn()
        pump(until: { gotA.count == 2 && gotB.count == 2 }, "pulse: the busy turn")
        check({ if case .failure = gotA[1], case .failure = gotB[1] { return true }; return false }(),
              "pulse: busy reaches both as a failure")

        // Nothing wanted: nothing opened; only those who want something get answers.
        wantA = []
        wantB = []
        p.turn()
        settle()
        equal(reads.count, 2, "pulse: nothing wanted, no read")
        answer = .success([])
        wantB = ["AT+CPMS?"]
        p.turn()
        pump(until: { gotB.count == 3 }, "pulse: B alone")
        equal(gotA.count, 2, "pulse: A wanted nothing, gets nothing")
        equal(reads.last, ["AT+CPMS?"], "pulse: B's command alone")
        equal(p.turns, 4, "pulse: turns counted")
    }

    // The controller's part: counts, never lists, in the background.
    static func controller() {
        let screen = FakeSms()
        let background = FakeSms()
        var notify = true
        var alerts: [MessageAlert] = []
        let c = SmsController(service: screen, queue: DispatchQueue(label: "sms.test"), replyToQuit: { _ in },
                              requestAttention: {}, backgroundService: background, notifyEnabled: { notify },
                              alert: { alerts.append($0) })
        equal(c.pulseCommands(turn: 1), ["AT+CPMS?"], "controller: the first turn reads the count")
        equal(c.pulseCommands(turn: 2), [], "controller: every other turn")
        notify = false
        equal(c.pulseCommands(turn: 3), [], "controller: notifications off, no read")
        c.pulseAnswers(store(2))
        settle()
        equal(background.counts, 0, "controller: notifications off, an answer that comes anyway counts nothing")
        notify = true

        // The first count (the baseline): the unread already there, one summary; nothing listed.
        background.counted = .success(count(2, received: 2, unread: 1))
        c.pulseAnswers(store(2))
        pump(until: { background.counts == 1 && c.running == nil }, "controller: the baseline count")
        equal(alerts, [.summary(unread: 1)], "controller: one summary at start")
        equal(background.lists + screen.lists, 0, "controller: nothing listed (no unread message read)")
        equal(c.unreadNotice.onModem, 1, "controller: the unread on the modem for the menu bar")

        // The same count: nothing. A busy turn: nothing.
        c.pulseAnswers(store(2))
        c.pulseAnswers(.failure(ModemFailure(message: "The modem's AT port is busy.")))
        settle()
        equal(background.counts, 1, "controller: same count or busy, no count")

        // Up: counted, announced.
        background.counted = .success(count(3, received: 3, unread: 2))
        c.pulseAnswers(store(3))
        pump(until: { alerts.count == 2 }, "controller: the alert")
        equal(alerts.last, .arrived(1), "controller: the new message announced")
        equal(c.unreadNotice.onModem, 2, "controller: two unread on the modem")

        // A count that fails is tried again (the store's count still differs from the last count's).
        background.counted = .failure(SmsFailure(message: "The modem's AT port is busy."))
        c.pulseAnswers(store(4))
        pump(until: { background.counts == 3 && c.running == nil }, "controller: a failed count")
        check(c.listFailure == nil, "controller: a background failure is not shown")
        background.counted = .success(count(4, received: 4, unread: 3))
        c.pulseAnswers(store(4))
        pump(until: { alerts.count == 3 }, "controller: tried again")
        equal(alerts.last, .arrived(1), "controller: announced on the retry")

        // Turned off: the count starts again when turned on (a summary of what is unread then, nothing older).
        notify = false
        _ = c.pulseCommands(turn: 5)
        equal(c.unreadNotice.onModem, 0, "controller: off, nothing on the modem shown")
        notify = true
        background.counted = .success(count(5, received: 5, unread: 4))
        c.pulseAnswers(store(5))
        pump(until: { alerts.count == 4 }, "controller: turned on again")
        equal(alerts.last, .summary(unread: 4), "controller: turned on again, a summary")

        // The Messages screen lists (making them read on the modem): none unread on the modem; then one comes in.
        screen.listing = .success(listingOf([SmsMessage(indices: [0], unread: true, sender: "+12025550101",
                                                        timestamp: t0, text: "Made-up", missingParts: 0, readable: true)],
                                            used: 5))
        c.refresh()
        pump(until: { screen.lists == 1 && c.running == nil }, "controller: a screen listing")
        equal(c.unreadNotice.onModem, 0, "controller: listed, none left unread on the modem")
        equal(c.unreadNotice.count, 1, "controller: the window's mark")
        background.counted = .success(count(6, received: 6, unread: 1))
        c.pulseAnswers(store(6))
        pump(until: { alerts.count == 5 }, "controller: one after the listing")
        equal(alerts.last, .arrived(1), "controller: new after the listing")

        // The Messages screen shown and seen: it lists by itself, so no count read.
        c.setWindowVisible(true)
        c.setTabShown(true)
        pump(until: { c.running == nil && screen.lists >= 2 }, "controller: the screen's listing")
        equal(c.pulseCommands(turn: 7), [], "controller: the screen lists, no count read")
        c.setTabShown(false)
    }

    // Notifications turned off while a count runs: its result posts nothing; a count that ends while the Messages screen
    // has come up posts nothing either (the screen shows them).
    static func turnedOffDuringCount() {
        let background = FakeSms()
        var notify = true
        var alerts: [MessageAlert] = []
        let c = SmsController(service: FakeSms(), queue: DispatchQueue(label: "sms.off"), replyToQuit: { _ in },
                              requestAttention: {}, backgroundService: background, notifyEnabled: { notify },
                              alert: { alerts.append($0) })
        background.counted = .success(count(1, received: 1, unread: 0))
        c.pulseAnswers(store(1))
        pump(until: { background.counts == 1 && c.running == nil }, "off: the baseline")
        background.holdCount = true
        background.counted = .success(count(2, received: 2, unread: 1))
        c.pulseAnswers(store(2))
        pump(until: { c.running == .counting }, "off: a count runs")
        notify = false
        background.release()
        pump(until: { c.running == nil }, "off: the count ends")
        settle()
        equal(alerts, [], "off: turned off during the count, nothing posted")
        equal(c.unreadNotice.onModem, 0, "off: nothing shown on the menu bar")

        notify = true
        _ = c.pulseCommands(turn: 1)
        background.holdCount = false
        background.counted = .success(count(2, received: 2, unread: 1))
        c.pulseAnswers(store(2))
        pump(until: { alerts.count == 1 }, "off: on again, the baseline")
        background.holdCount = true
        background.counted = .success(count(3, received: 3, unread: 2))
        c.pulseAnswers(store(3))
        pump(until: { c.running == .counting }, "shown: a count runs")
        c.setWindowVisible(true)
        c.setTabShown(true)       // its listing waits: the count runs
        background.release()
        pump(until: { c.running == nil }, "shown: the count ends")
        equal(alerts.count, 1, "shown: the screen came up during the count, nothing posted")
        c.setTabShown(false)
    }

    /// Replies (one draft a conversation, each to its own number), a Retry and deletes with the listed parts and
    /// place; the messages RMNet sends never announced.
    static func ownMessages() {
        let screen = FakeSms()
        var alerts: [MessageAlert] = []
        let c = SmsController(service: screen, queue: DispatchQueue(label: "sms.own"), replyToQuit: { _ in },
                              requestAttention: {}, backgroundService: screen, notifyEnabled: { true },
                              alert: { alerts.append($0) })
        // An hour ago: a reply sent now comes after it. Two numbers that end in the same ten digits, and the first one
        // in its national form: a US SIM (MCC 310), so that is the same conversation as its international form.
        let first = SmsMessage(indices: [0], unread: true, sender: "+12025550100", timestamp: Date().addingTimeInterval(-3600),
                               text: "Made-up question", missingParts: 0, readable: true)
        let abroad = SmsMessage(indices: [1], unread: true, sender: "+442025550100",
                                timestamp: Date().addingTimeInterval(-1800), text: "Made-up hello", missingParts: 0,
                                readable: true)
        let national = SmsMessage(indices: [2], unread: false, sender: "2025550100", timestamp: nil, text: "Made-up",
                                  missingParts: 0, readable: true, box: .sent)
        let place = SmsPlace(device: "TESTMODULE1", sim: "310150123456789", listsFrom: "ME", writesTo: "ME")
        screen.listing = .success(listingOf([first, abroad, national], used: 3, place: place))
        c.refresh()
        pump(until: { c.listed && c.running == nil }, "own: listed")
        equal(Set(c.conversations.map { $0.id }), ["+12025550100", "+442025550100"],
              "own: one conversation a number, the national form with its international one")
        equal(c.conversations.first { $0.id == "+12025550100" }?.messages.count, 2, "own: the national form joined")

        // One draft a conversation.
        c.selectedConversation = "+12025550100"
        equal(c.unreadNotice.count, 1, "own: shown is read (the other one is still unread)")
        equal(c.shownConversation?.number, "+12025550100", "own: the number in its international form")
        check(!c.replyEnabled, "own: no reply text, no send")
        c.replyText = "Made-up answer"
        c.selectedConversation = "+442025550100"
        equal(c.replyText, "", "own: another conversation, its own (empty) draft")
        c.replyText = "Made-up reply abroad"
        c.selectedConversation = "+12025550100"
        equal(c.replyText, "Made-up answer", "own: back, the first draft")

        // A reply: sent to that conversation's number; its part gets the time; only its draft cleared.
        c.sendReply()
        pump(until: { c.running == nil && !screen.sends.isEmpty }, "own: the reply sent")
        check(screen.sends.first?.number == "+12025550100" && screen.sends.first?.text == "Made-up answer",
              "own: to the conversation's number")
        equal(c.replyText, "", "own: the reply cleared")
        equal(c.replyDrafts["+442025550100"], "Made-up reply abroad", "own: the other draft kept")
        equal(c.result, "Sent to +12025550100 in 1 part(s).", "own: the result line")

        // Listed with the sent one: it has the time RMNet sent it; never announced.
        let mine = SmsMessage(indices: [9], unread: false, sender: "+12025550100", timestamp: nil, text: "Made-up answer",
                              missingParts: 0, readable: true, box: .sent)
        screen.listing = .success(listingOf([first, abroad, national, mine], used: 4, place: place))
        c.refresh()
        pump(until: { c.messages.count == 4 && c.running == nil }, "own: listed with the sent one")
        check(c.sentAt[9] != nil, "own: the sent part's time kept")
        equal(c.conversations.first { $0.id == "+12025550100" }?.messages.last, mine, "own: the reply last")
        // The same index later holds another sent message (deleted and written again elsewhere): no time from before.
        let other = SmsMessage(indices: [9], unread: false, sender: "+12025550100", timestamp: nil, text: "Other",
                               missingParts: 0, readable: true, box: .sent)
        var reused = listingOf([first, abroad, national], used: 4, place: place)
        reused = SmsListing(messages: reused.messages + [other], used: 4, total: 50,
                            parts: reused.parts + [StoredPdu(index: 9, status: .sent, hex: "00FFFF")], place: place)
        screen.listing = .success(reused)
        c.refresh()
        pump(until: { c.messages.contains(other) && c.running == nil }, "own: index 9 reused")
        check(c.sentAt[9] == nil, "own: a reused index does not take the old time")

        // An unsent one: Retry sends its listed unsent parts, with the listing's place.
        let unsent = SmsMessage(indices: [10, 11], unread: false, sender: "+12025550100", timestamp: nil, text: "Long",
                                missingParts: 0, readable: true, box: .unsent, unsentIndices: [11])
        screen.listing = .success(listingOf([first, abroad, national, mine, unsent], used: 6, place: place))
        c.refresh()
        pump(until: { c.messages.count == 5 && c.running == nil }, "own: listed with the unsent one")
        c.retry(unsent)
        pump(until: { c.running == nil && !screen.resends.isEmpty }, "own: retried")
        equal(screen.resends.first?.parts.map { $0.index }, [11], "own: only the unsent part again")
        equal(screen.resends.first?.place, place, "own: with where it was listed")
        check(c.sentAt[11] != nil, "own: the retried part's time kept")

        // A Retry whose part was not answered: Not confirmed; one the modem confirmed but lists unsent: not offered.
        screen.resendResult = .failure(SmsFailure(message: "Made-up failure.",
                                                  record: SmsSendRecord(unknown: [StoredPart(pdu(11, .unsent))])))
        c.retry(unsent)
        pump(until: { c.running == nil && screen.resends.count == 2 }, "own: retried, no answer")
        check(c.unconfirmed.contains(11), "own: no answer, Not confirmed")
        equal(sentStatusWords(unsent, sentAt: c.sentAt, unconfirmed: c.unconfirmed, time: { _ in "" }), "Not confirmed",
              "own: the words")
        screen.resendResult = .success(SmsSent(parts: 1, indices: [11],
                                               record: SmsSendRecord(sent: [StoredPart(pdu(11, .unsent))],
                                                                     stillUnsent: [StoredPart(pdu(11, .unsent))])))
        c.retry(unsent)
        pump(until: { c.running == nil && screen.resends.count == 3 }, "own: retried, confirmed")
        let listsBefore = screen.lists
        c.refresh()
        pump(until: { c.running == nil && screen.lists == listsBefore + 1 }, "own: listed after")
        let shown = c.messages.first { $0.indices == [10, 11] }
        equal(shown?.box, .sent, "own: confirmed though listed unsent: shown as sent")
        equal(shown?.unsentIndices, [], "own: not offered for Retry")
        check(!c.unconfirmed.contains(11), "own: no longer Not confirmed")

        // The New Message sheet: its conversation shown after the send (the national form, as its international one).
        c.to = "2025550199"
        c.text = "Made-up new message"
        screen.sendIndex = 12
        c.send()
        pump(until: { c.running == nil && screen.sends.count == 2 }, "own: a new message sent")
        equal(c.selectedConversation, "+12025550199", "own: its conversation shown")
        equal(c.text, "", "own: the sheet's text cleared")

        // Deleting a conversation: every listed part of every message in it, with the place; never the other number's.
        guard let conversation = c.conversations.first(where: { $0.id == "+12025550100" }) else {
            check(false, "own: the conversation")
            return
        }
        c.selectedConversation = "+12025550100"
        c.deleteConversation(conversation)
        pump(until: { c.running == nil && !screen.deletes.isEmpty }, "own: the conversation deleted")
        equal(screen.deletes.first.map { Set($0.parts.map { $0.index }) }, Set([0, 2, 9, 10, 11]), "own: every stored part")
        equal(screen.deletes.first?.place, place, "own: with where it was listed")
        check(c.selectedConversation == nil, "own: nothing shown after")
        equal(alerts, [], "own: nothing RMNet sent was announced")
    }
}
