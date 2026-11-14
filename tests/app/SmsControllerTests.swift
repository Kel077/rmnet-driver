// Tests for app/SmsController.swift: the controller driven by a fake SmsServing whose calls block until
// the test releases them, with the main run loop pumped so that results come back as in the app. Built
// with swiftc by `make app-test` from app/SmsModel.swift, app/SmsController.swift and this file; needs no
// AppKit, no window and no modem.
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

// MARK: - The fake service

enum Call: Equatable {
    case list
    case delete([Int])
    case send(String, String)
}

/// Records each call, then blocks it (on the controller's queue) until the test releases it with a result.
final class FakeService: SmsServing {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var log: [Call] = []
    private var listResults: [Result<SmsListing, SmsFailure>] = []
    private var deleteResults: [Result<Int, SmsFailure>] = []
    private var sendResults: [Result<Int, SmsFailure>] = []
    private var inside = 0   // calls entered and not yet returned
    private var mostInside = 0

    var calls: [Call] { locked { log } }
    var blocked: Int { locked { inside } }
    var mostAtOnce: Int { locked { mostInside } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func enter(_ call: Call) {
        locked {
            log.append(call)
            inside += 1
            mostInside = max(mostInside, inside)
        }
        gate.wait()
        locked { inside -= 1 }
    }

    func list() -> Result<SmsListing, SmsFailure> {
        enter(.list)
        return locked { listResults.removeFirst() }
    }

    func delete(indices: [Int]) -> Result<Int, SmsFailure> {
        enter(.delete(indices))
        return locked { deleteResults.removeFirst() }
    }

    func send(to number: String, text: String) -> Result<Int, SmsFailure> {
        enter(.send(number, text))
        return locked { sendResults.removeFirst() }
    }

    func releaseList(_ result: Result<SmsListing, SmsFailure>) { locked { listResults.append(result) }; gate.signal() }
    func releaseDelete(_ result: Result<Int, SmsFailure>) { locked { deleteResults.append(result) }; gate.signal() }
    func releaseSend(_ result: Result<Int, SmsFailure>) { locked { sendResults.append(result) }; gate.signal() }
}

// MARK: - Helpers

/// Runs the main run loop until `condition` holds (or fails the check after 2 s).
func pump(until condition: () -> Bool, _ name: String) {
    let deadline = Date().addingTimeInterval(2)
    while !condition() {
        if Date() > deadline { check(false, "timed out waiting: \(name)") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
}

/// Runs the main run loop for a while, so that anything wrongly started would show.
func settle() {
    let end = Date().addingTimeInterval(0.1)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
}

/// A controller with a fake service, and what it answered to quits and how often it asked for attention.
final class Rig {
    let fake = FakeService()
    var replies: [Bool] = []
    var attention = 0
    lazy var controller = SmsController(service: fake,
                                        replyToQuit: { [unowned self] in self.replies.append($0) },
                                        requestAttention: { [unowned self] in self.attention += 1 })

    /// The controller ready to send: a valid number and a text.
    func ready(_ text: String = "hello") {
        controller.to = "+27831234567"
        controller.text = text
    }

    /// Starts a send and waits until the fake has it.
    func startSend() {
        let before = fake.calls.count
        controller.send()
        pump(until: { fake.calls.count == before + 1 && fake.blocked == 1 }, "the send reaches the service")
    }

    /// Lists once (the given result) and waits for it to come back.
    func list(_ result: Result<SmsListing, SmsFailure>) {
        let before = fake.calls.count
        controller.refresh()
        pump(until: { fake.calls.count == before + 1 && fake.blocked == 1 }, "the listing reaches the service")
        fake.releaseList(result)
        pump(until: { controller.running == nil }, "the listing comes back")
    }
}

func message(_ indices: [Int], sender: String = "+27838890001", text: String = "hi") -> SmsMessage {
    SmsMessage(indices: indices, unread: false, sender: sender, timestamp: Date(timeIntervalSince1970: 1794657609),
               text: text, missingParts: 0, readable: true)
}

func listing(_ messages: [SmsMessage], used: Int? = nil, total: Int? = nil) -> Result<SmsListing, SmsFailure> {
    .success(SmsListing(messages: messages, used: used, total: total))
}

let notKnown = SmsFailure(message: "The message failed. The modem did not answer in time. It is not known whether it was "
                          + "sent. It may have been delivered; sending it again may deliver it twice.")
let refused = SmsFailure(message: "The message was refused. The modem refused the command (+CMS ERROR: 350). Nothing was sent.")
let listFailed = SmsFailure(message: "Another program is using the modem's spare AT port.")
let deleteFailed = SmsFailure(message: "Stored part 3 could not be deleted. The modem refused the command (ERROR). "
                              + "0 of 2 stored part(s) were deleted before it.")

// MARK: - The checks

@main
struct SmsControllerTests {
    static func main() {
        oneCallAtATime()
        twoLines()
        deleting()
        quitting()
        composingAndStore()
        print("smsui-test: \(checks) checks passed")
    }

    // A second send while one runs does nothing; a tick or a refresh during a send does nothing.
    static func oneCallAtATime() {
        let rig = Rig()
        let c = rig.controller
        rig.ready()
        check(c.sendEnabled, "send: enabled with a number and a text")
        rig.startSend()
        check(c.running == .sending, "send: running is .sending")
        check(!c.sendEnabled && !c.refreshEnabled && !c.deleteEnabled, "send: nothing else is enabled while it runs")
        c.send()
        c.tick()
        c.refresh()
        settle()
        check(rig.fake.calls == [.send("+27831234567", "hello")], "send: a second send, a tick and a refresh while a send runs do nothing",
              "\(rig.fake.calls)")
        rig.fake.releaseSend(.success(1))
        pump(until: { c.running == nil }, "the send comes back")
        check(rig.fake.mostAtOnce == 1, "send: never two calls in the service at once")
        check(c.result == "Sent to +27831234567 in 1 part(s)." && !c.resultIsFailure, "send: success sentence", c.result)
        check(c.text == "", "send: the text is cleared after a success")

        // A tick while a listing runs also does nothing.
        let rig2 = Rig()
        rig2.controller.refresh()
        pump(until: { rig2.fake.blocked == 1 }, "a listing starts")
        rig2.controller.tick()
        rig2.controller.refresh()
        settle()
        check(rig2.fake.calls == [.list], "list: a tick and a refresh during a listing do nothing", "\(rig2.fake.calls)")
        rig2.fake.releaseList(listing([]))
        pump(until: { rig2.controller.running == nil }, "the listing comes back")
    }

    // The result line (a send's or delete's) and the list line are kept apart: a listing that fails after a
    // send or delete leaves the result line alone. Typing clears a success's line, not a failure's.
    static func twoLines() {
        // 1. A send that succeeds, then a listing that fails.
        do {
            let rig = Rig()
            let c = rig.controller
            c.setTabShown(true)  // active: the tab lists after a send
            pump(until: { rig.fake.blocked == 1 }, "the first listing starts")
            rig.fake.releaseList(listing([]))
            pump(until: { c.running == nil }, "the first listing comes back")
            rig.ready()
            rig.startSend()
            rig.fake.releaseSend(.success(1))
            pump(until: { rig.fake.calls.count == 3 && rig.fake.blocked == 1 }, "the listing after the send starts")
            check(rig.fake.calls.last == .list, "lines: a send that succeeds is followed by a listing")
            rig.fake.releaseList(.failure(listFailed))
            pump(until: { c.running == nil }, "the failed listing comes back")
            check(c.result == "Sent to +27831234567 in 1 part(s)." && !c.resultIsFailure,
                  "lines: a failed listing after a successful send keeps the send's sentence", c.result)
            check(c.listFailure == listFailed.message && c.listText.hasPrefix(listFailed.message),
                  "lines: the listing's failure is on the list line", c.listText)
            c.setTabShown(false)
        }
        // 2. A send that fails (not known), then a listing that fails.
        do {
            let rig = Rig()
            let c = rig.controller
            c.setTabShown(true)
            pump(until: { rig.fake.blocked == 1 }, "the first listing starts")
            rig.fake.releaseList(listing([]))
            pump(until: { c.running == nil }, "the first listing comes back")
            rig.ready()
            rig.startSend()
            rig.fake.releaseSend(.failure(notKnown))
            pump(until: { rig.fake.calls.count == 3 && rig.fake.blocked == 1 }, "the listing after the send starts")
            rig.fake.releaseList(.failure(listFailed))
            pump(until: { c.running == nil }, "the failed listing comes back")
            check(c.result == notKnown.message && c.resultIsFailure,
                  "lines: a failed listing after a failed send keeps the send's failure", c.result)
            check(c.text == "hello", "lines: the text is kept after a failed send")
            c.setTabShown(false)
        }
        // 3. A delete that succeeds, then a listing that fails.
        do {
            let rig = Rig()
            let c = rig.controller
            let m = message([3, 4])
            c.setTabShown(true)
            pump(until: { rig.fake.blocked == 1 }, "the first listing starts")
            rig.fake.releaseList(listing([m]))
            pump(until: { c.running == nil }, "the first listing comes back")
            c.delete(m)
            pump(until: { rig.fake.blocked == 1 }, "the delete reaches the service")
            rig.fake.releaseDelete(.success(2))
            pump(until: { rig.fake.calls.count == 3 && rig.fake.blocked == 1 }, "the listing after the delete starts")
            rig.fake.releaseList(.failure(listFailed))
            pump(until: { c.running == nil }, "the failed listing comes back")
            check(c.result == "Deleted 2 stored part(s)." && !c.resultIsFailure,
                  "lines: a failed listing after a delete keeps the delete's sentence", c.result)
            c.setTabShown(false)
        }
        // Typing after a success clears the result line; after a failure it does not.
        do {
            let rig = Rig()
            let c = rig.controller
            rig.ready()
            rig.startSend()
            rig.fake.releaseSend(.success(1))
            pump(until: { c.running == nil }, "the send comes back")
            c.text = "n"
            check(c.result == "", "lines: typing after a successful send clears the result line", c.result)
        }
        do {
            let rig = Rig()
            let c = rig.controller
            rig.ready()
            rig.startSend()
            rig.fake.releaseSend(.failure(refused))
            pump(until: { c.running == nil }, "the send comes back")
            c.text = "hello again"
            check(c.result == refused.message && c.resultIsFailure,
                  "lines: typing after a failed send keeps the failure on the result line", c.result)
        }
    }

    // Delete passes the message's whole indices, and refuses a message that is no longer listed.
    static func deleting() {
        let rig = Rig()
        let c = rig.controller
        let m = message([3, 4, 7])
        rig.list(listing([m]))
        c.delete(m)
        pump(until: { rig.fake.blocked == 1 }, "the delete reaches the service")
        check(rig.fake.calls.last == .delete([3, 4, 7]), "delete: the message's whole indices are passed", "\(rig.fake.calls)")
        check(c.result == "Deleting 3 stored part(s)…", "delete: the running sentence", c.result)
        rig.fake.releaseDelete(.success(3))
        pump(until: { c.running == nil }, "the delete comes back")
        check(c.result == "Deleted 3 stored part(s)." && c.selection == nil, "delete: the success sentence", c.result)

        let gone = message([9], sender: "+27830000000")
        let before = rig.fake.calls
        c.delete(gone)
        settle()
        check(rig.fake.calls == before, "delete: a message no longer listed is not deleted", "\(rig.fake.calls)")
        check(c.result == "That message is no longer listed. Nothing was deleted." && c.resultIsFailure,
              "delete: the refusal sentence", c.result)

        // A delete while another call runs is refused (a refresh began just before the confirmation).
        c.refresh()
        pump(until: { rig.fake.blocked == 1 }, "a listing starts")
        c.delete(m)
        check(c.result == "The modem was busy with another request. Nothing was deleted; press Delete again.",
              "delete: refused while a listing runs", c.result)
        rig.fake.releaseList(listing([m]))
        pump(until: { c.running == nil }, "the listing comes back")
        check(rig.fake.calls.filter({ if case .delete = $0 { return true } else { return false } }).count == 1,
              "delete: the refused delete did not reach the service", "\(rig.fake.calls)")
    }

    // Quitting: at once with nothing running; after a running call, true exactly once when it was a
    // listing or a send or delete that succeeded, false exactly once (and attention) when a send or delete
    // did not succeed. No listing starts after a quit began.
    static func quitting() {
        // Nothing running.
        do {
            let rig = Rig()
            check(rig.controller.quitWhenFinished() == false, "quit: nothing running answers at once (terminate now)")
            settle()
            check(rig.replies.isEmpty && rig.attention == 0, "quit: nothing running needs no later reply", "\(rig.replies)")
        }

        // Each kind of call, and how it ends.
        enum Ending { case list, sendOK, sendFailed, sendNotKnown, deleteOK, deleteFailed }
        let cases: [(Ending, Bool, String)] = [
            (.list, true, "RMNet quits when the current request to the modem has finished."),
            (.sendOK, true, "RMNet quits when the message being sent has finished."),
            (.deleteOK, true, "RMNet quits when the message being deleted has finished."),
            (.sendFailed, false, "RMNet quits when the message being sent has finished."),
            (.sendNotKnown, false, "RMNet quits when the message being sent has finished."),
            (.deleteFailed, false, "RMNet quits when the message being deleted has finished."),
        ]
        for (ending, goesAhead, notice) in cases {
            let name = "quit during \(ending)"
            let rig = Rig()
            let c = rig.controller
            let m = message([3, 4])
            c.setTabShown(true)  // active: without the quit, a listing would follow a send or delete
            pump(until: { rig.fake.blocked == 1 }, "the first listing starts")
            if ending != .list {
                rig.fake.releaseList(listing([m]))
                pump(until: { c.running == nil }, "the first listing comes back")
                switch ending {
                case .deleteOK, .deleteFailed:
                    c.delete(m)
                    pump(until: { rig.fake.blocked == 1 }, "the delete reaches the service")
                default:
                    rig.ready()
                    rig.startSend()
                }
            }
            let callsBefore = rig.fake.calls.count
            check(c.quitWhenFinished() == true, "\(name): the quit waits (terminate later)")
            check(c.quitNotice.line == notice, "\(name): the window's quit line", c.quitNotice.line)
            check(rig.replies.isEmpty, "\(name): no reply while the call runs", "\(rig.replies)")
            c.tick()
            c.refresh()
            switch ending {
            case .list: rig.fake.releaseList(listing([m]))
            case .sendOK: rig.fake.releaseSend(.success(1))
            case .sendFailed: rig.fake.releaseSend(.failure(refused))
            case .sendNotKnown: rig.fake.releaseSend(.failure(notKnown))
            case .deleteOK: rig.fake.releaseDelete(.success(2))
            case .deleteFailed: rig.fake.releaseDelete(.failure(deleteFailed))
            }
            pump(until: { !rig.replies.isEmpty }, "\(name): the reply")
            settle()
            check(rig.replies == [goesAhead], "\(name): replies \(goesAhead) exactly once", "\(rig.replies)")
            check(c.quitNotice.line == "", "\(name): the quit line goes when the call has finished", c.quitNotice.line)
            if goesAhead {
                check(rig.attention == 0, "\(name): no request for attention")
                check(rig.fake.calls.count == callsBefore, "\(name): no listing starts after the quit began",
                      "\(rig.fake.calls)")
                c.tick()
                c.refresh()
                settle()
                check(rig.fake.calls.count == callsBefore && !c.refreshEnabled && !c.sendEnabled,
                      "\(name): nothing starts while the app ends", "\(rig.fake.calls)")
            } else {
                check(rig.attention == 1, "\(name): asks for attention once", "\(rig.attention)")
                let want: String
                switch ending {
                case .sendFailed: want = refused.message
                case .sendNotKnown: want = notKnown.message
                default: want = deleteFailed.message
                }
                check(c.result == want && c.resultIsFailure, "\(name): the result line keeps the sentence", c.result)
                // The quit is cancelled: the app goes on, and the shown tab lists again.
                pump(until: { rig.fake.calls.count == callsBefore + 1 && rig.fake.blocked == 1 }, "\(name): the tab lists again")
                rig.fake.releaseList(listing([m]))
                pump(until: { c.running == nil }, "\(name): that listing comes back")
                check(c.result == want, "\(name): the listing after the cancelled quit leaves the result line", c.result)
                check(c.refreshEnabled, "\(name): the controller works again after the cancelled quit")
                settle()
                check(rig.replies == [false] && rig.attention == 1, "\(name): still exactly one reply", "\(rig.replies)")
            }
            c.setTabShown(false)
        }
    }

    // Send waits while an input method composes; the store's warning reaches the list line.
    static func composingAndStore() {
        let rig = Rig()
        let c = rig.controller
        rig.ready()
        check(c.sendEnabled, "composing: send enabled before")
        c.composing = true
        check(!c.sendEnabled, "composing: sendEnabled is false while composing")
        check(c.composeText == "Finish the input being composed (the underlined text) before sending.",
              "composing: the line under the text says so", c.composeText)
        c.send()
        settle()
        check(rig.fake.calls.isEmpty, "composing: send() does nothing while composing", "\(rig.fake.calls)")
        c.composing = false
        check(c.sendEnabled && c.composeText == "1 part, GSM alphabet", "composing: enabled again when finished", c.composeText)

        rig.list(listing([message([1])], used: 22, total: 255))
        check(c.listText.hasSuffix(" 22 of 255 stored parts."), "store: the use reaches the list line", c.listText)
        rig.list(listing([message([1])], used: 230, total: 255))
        check(c.listText.hasSuffix(" 230 of 255 stored parts. The modem's message store is nearly full (230 of 255). "
                                   + "Delete old messages, or new ones will not arrive."),
              "store: the warning reaches the list line", c.listText)
        rig.list(listing([message([1])], used: nil, total: nil))
        check(!c.listText.contains("stored parts"), "store: unknown use is not shown", c.listText)
    }
}
