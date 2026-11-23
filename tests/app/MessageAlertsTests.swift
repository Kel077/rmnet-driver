// Tests for app/MessageAlerts.swift, app/ModemPulse.swift and the background check of app/SmsController.swift: when the
// store's count lists the messages (the first, a count that went up, not one that went down), the baseline and its one
// summary at start, which messages are new (once each, also when a part comes later), what a notification says (with
// and without the text), the background turn (one read for all, commands once each, a busy port skipped for all,
// nothing opened when nothing is wanted), and the controller's part (every other turn, not while the Messages screen
// lists, not with notifications off, a busy turn skipped, a count that went up listed on the background service, the
// alerts it gives). Built with swiftc by `make app-test`; no AppKit, no modem. Every number and text is made up.
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

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func message(_ indices: [Int], from sender: String = "+15555550100", at seconds: TimeInterval?, unread: Bool = true,
             text: String = "Made-up text", missing: Int = 0) -> SmsMessage {
    SmsMessage(indices: indices, unread: unread, sender: sender, timestamp: seconds.map { t0.addingTimeInterval($0) },
               text: text, missingParts: missing, readable: true)
}

/// A service whose listing is set by the test and answers at once.
final class ListingService: SmsServing {
    var listing: Result<SmsListing, SmsFailure> = .success(SmsListing(messages: [], used: 0, total: 50))
    var lists = 0
    func list() -> Result<SmsListing, SmsFailure> {
        lists += 1
        return listing
    }
    func delete(indices: [Int]) -> Result<Int, SmsFailure> { .success(indices.count) }
    func send(to number: String, text: String) -> Result<Int, SmsFailure> { .success(1) }
}

func store(_ used: Int) -> Result<[String: PulseAnswer], ModemFailure> {
    .success(["AT+CPMS?": .lines(["+CPMS: \"ME\",\(used),50,\"ME\",\(used),50,\"ME\",\(used),50"])])
}

@main
struct MessageAlertsTests {
    static func main() {
        watchCounts()
        watchListings()
        content()
        pulse()
        controller()
        print("message alerts: \(checks) checks passed")
    }

    // When a count lists the messages.
    static func watchCounts() {
        var w = NewMessageWatch()
        check(w.storeCount(3), "count: before the first listing, list")
        check(!w.storeCount(nil), "count: not read, nothing")
        _ = w.listed([message([0], at: 0, unread: false)], used: 3)
        check(!w.storeCount(3), "count: the same, nothing")
        check(w.storeCount(4), "count: up, list")
        check(!w.storeCount(2), "count: down, nothing")
        equal(w.baseline, 2, "count: down is the baseline")
        check(w.storeCount(3), "count: up from the lower baseline, list")
    }

    // The first listing is the baseline (one summary of the unread); later only what is new and unread, once.
    static func watchListings() {
        var w = NewMessageWatch()
        let old1 = message([0], at: 0, unread: true)
        let old2 = message([1], from: "Carrier", at: 10, unread: true)
        let read = message([2], at: 20, unread: false)
        equal(w.listed([old2, old1, read], used: 3), [.summary(unread: 2)], "first: one summary of the two unread")
        check(w.started && w.baseline == 3, "first: the baseline")

        var quiet = NewMessageWatch()
        equal(quiet.listed([read], used: 1), [], "first: no unread, no summary")

        let new1 = message([3], at: 100)
        let new2 = message([4], from: "+15555550199", at: 200)
        equal(w.listed([new2, new1, old2, old1, read], used: 5), [.message(new1), .message(new2)],
              "later: the new unread ones, oldest first")
        equal(w.listed([new2, new1, old2, old1, read], used: 5), [], "later: the same listing again, nothing")

        // A message whose parts come at different times: one alert, when it first shows.
        let partial = message([5], at: 300, text: "First half[...]", missing: 1)
        equal(w.listed([partial], used: 6), [.message(partial)], "parts: the first part")
        let whole = message([5, 6], at: 300, text: "First half and the rest")
        equal(w.listed([whole], used: 7), [], "parts: the rest of the same message, no second alert")

        // A new message listed read (read elsewhere) is not announced; one with no time is known by its indices.
        equal(w.listed([message([7], at: 400, unread: false)], used: 8), [], "a new message already read: nothing")
        let noTime = message([8], at: nil)
        equal(w.listed([noTime], used: 9), [.message(noTime)], "no time: announced")
        equal(w.listed([noTime], used: 9), [], "no time: once")
    }

    // What a notification says.
    static func content() {
        let m = message([0], from: "+15555550100", at: 0, text: "Your code is 000000.\nIt expires soon.\nThird line.")
        let shown = alertContent(.message(m), showText: true)
        check(shown.title == "+15555550100" && shown.body == "Your code is 000000.\nIt expires soon.",
              "content: the sender and the first two lines", "\(shown)")
        equal(alertContent(.message(m), showText: false).body, "New message", "content: without the text")
        equal(alertContent(.message(message([0], from: "", at: 0)), showText: true).title, "Unknown sender", "content: no sender")
        let long = message([0], at: 0, text: String(repeating: "x", count: 300))
        equal(alertContent(.message(long), showText: true).body.count, 160, "content: at most 160 characters")
        let partial = message([0], at: 0, text: "Half", missing: 1)
        equal(alertContent(.message(partial), showText: true).body, "Half (1 part missing)", "content: a part missing")
        check(alertContent(.summary(unread: 1), showText: true) == ("RMNet", "1 unread message on the modem."),
              "content: the summary, one")
        equal(alertContent(.summary(unread: 3), showText: false).body, "3 unread messages on the modem.", "content: three")
        equal(unreadLine(0), "", "unread line: none")
        equal(unreadLine(1), "1 unread message", "unread line: one")
        equal(unreadLine(2), "2 unread messages", "unread line: two")
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

    // The controller's part.
    static func controller() {
        let screen = ListingService()
        let background = ListingService()
        var notify = true
        var alerts: [MessageAlert] = []
        let c = SmsController(service: screen, queue: DispatchQueue(label: "sms.test"), replyToQuit: { _ in },
                              requestAttention: {}, backgroundService: background, notifyEnabled: { notify },
                              alert: { alerts.append($0) })
        equal(c.pulseCommands(turn: 1), ["AT+CPMS?"], "controller: the first turn reads the count")
        equal(c.pulseCommands(turn: 2), [], "controller: every other turn")
        notify = false
        equal(c.pulseCommands(turn: 3), [], "controller: notifications off, no read")
        notify = true

        // The first count lists (the baseline): the unread already there, one summary.
        let old = message([0], at: 0)
        background.listing = .success(SmsListing(messages: [old, message([1], at: 5, unread: false)], used: 2, total: 50))
        c.pulseAnswers(store(2))
        pump(until: { c.listed }, "controller: the baseline listing")
        equal(background.lists, 1, "controller: listed on the background service")
        equal(screen.lists, 0, "controller: not on the screen's")
        equal(alerts, [.summary(unread: 1)], "controller: one summary at start")
        equal(c.unreadNotice.count, 1, "controller: the unread count for the menu bar")

        // The same count: nothing. A busy turn: nothing.
        c.pulseAnswers(store(2))
        c.pulseAnswers(.failure(ModemFailure(message: "The modem's AT port is busy.")))
        settle()
        equal(background.lists, 1, "controller: same count or busy, no listing")

        // Up: listed, the new one announced.
        let fresh = message([2], at: 100)
        background.listing = .success(SmsListing(messages: [fresh, old, message([1], at: 5, unread: false)], used: 3, total: 50))
        c.pulseAnswers(store(3))
        pump(until: { background.lists == 2 }, "controller: the count went up")
        pump(until: { alerts.count == 2 }, "controller: the alert")
        equal(alerts.last, .message(fresh), "controller: the new message announced")
        equal(c.unreadNotice.count, 2, "controller: two unread")

        // A background listing that fails is not shown, and is tried again (the count still differs).
        background.listing = .failure(SmsFailure(message: "The modem's AT port is busy."))
        c.pulseAnswers(store(4))
        pump(until: { background.lists == 3 }, "controller: a failed background listing")
        settle()
        check(c.listFailure == nil, "controller: a background failure is not shown")
        let later = message([3], at: 200)
        background.listing = .success(SmsListing(messages: [later, fresh, old], used: 4, total: 50))
        c.pulseAnswers(store(4))
        pump(until: { alerts.count == 3 }, "controller: tried again")
        equal(alerts.last, .message(later), "controller: announced on the retry")

        // Notifications off: listings still learn what is there, so turning them on does not announce old messages.
        notify = false
        screen.listing = .success(SmsListing(messages: [message([4], at: 300), later, fresh, old], used: 5, total: 50))
        c.refresh()
        pump(until: { screen.lists == 1 && c.running == nil }, "controller: a screen listing")
        notify = true
        background.listing = screen.listing
        c.pulseAnswers(store(6))
        pump(until: { background.lists == 4 }, "controller: listed again")
        settle()
        equal(alerts.count, 3, "controller: a message seen while notifications were off is not announced later")

        // The Messages screen shown and seen: it lists by itself, so no count read; its new messages are not announced.
        c.setWindowVisible(true)
        c.setTabShown(true)
        pump(until: { c.running == nil && screen.lists >= 2 }, "controller: the screen's listing")
        equal(c.pulseCommands(turn: 5), [], "controller: the screen lists, no count read")
        screen.listing = .success(SmsListing(messages: [message([5], at: 400), message([4], at: 300), later, fresh, old],
                                             used: 6, total: 50))
        c.refresh()
        pump(until: { c.running == nil && screen.lists >= 3 }, "controller: a listing while shown")
        equal(alerts.count, 3, "controller: no alert for a message the screen shows")
        c.setTabShown(false)

        // A notification's message selected, found by sender and time.
        c.select(SmsIdentity(later))
        equal(c.selection, later.key, "controller: the notification's message selected")
    }
}
