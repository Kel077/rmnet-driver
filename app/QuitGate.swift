// The one answer to the app's quit question from the controllers that may each wait for a call to the modem
// to finish: the modem tabs' (ModemController.swift) and the Messages tab's (SmsController.swift). Both
// share one queue to the AT port, so a call of one can wait behind a call of the other; the gate asks both
// at once, and the app ends only when every call it waited for has finished and succeeded (ruling R18). It
// uses no AppKit: the app delegate (StatusView.swift) gives it NSApp's reply as a closure, so it is tested
// on its own and with both controllers (tests/app/QuitGateTests.swift). Also the lines that say, while a quit
// waits, what it waits for (quitNoticeLines).
import Foundation

/// The lines the RMNet window (above its tabs) and the menu bar item's panel (above its buttons) show while a
/// quit waits: the Messages tab's controller's quit line, then the modem tabs', each only while it is set, and
/// a line both give (`RMNet quits when the current request to the modem has finished.`) once.
func quitNoticeLines(messages: String, modem: String) -> [String] {
    var lines: [String] = []
    for line in [messages, modem] where !line.isEmpty && !lines.contains(line) { lines.append(line) }
    return lines
}

/// The app has exactly one, owned by the app delegate. Called on the main thread only.
final class QuitGate {
    /// A controller as the gate sees it: its quitWhenFinished() (true: it waits for a running call, and
    /// answers later through the gate's `replied`), and its resumeAfterCancelledQuit().
    struct Member {
        let quitWhenFinished: () -> Bool
        let resume: () -> Void
    }

    private let members: [Member]
    private let reply: (Bool) -> Void        // NSApp.reply(toApplicationShouldTerminate:)
    private var pending: Set<Int> = []       // the members whose answer the quit still waits for
    private var waiting = false              // a quit waits for its answer

    init(_ members: [Member], reply: @escaping (Bool) -> Void) {
        self.members = members
        self.reply = reply
    }

    /// The quit question (applicationShouldTerminate). Asks every member at once; each stops starting
    /// anything new. False: none has a call running, so the app may end now. True: the answer is given
    /// later, once, through `reply`. A question after a cancelled one starts afresh.
    func ask() -> Bool {
        pending = Set(members.indices.filter { members[$0].quitWhenFinished() })
        waiting = !pending.isEmpty
        return waiting
    }

    /// Member `index`'s answer (its replyToQuit): true when the call it waited for succeeded. When every
    /// member that waited has said true, the answer is true. The first false answers false at once and
    /// resumes every other member, waiting or not, since the question stopped them all; the one that said
    /// false has resumed itself. Answers after the quit's answer was given, or from a member the quit did
    /// not wait for, are ignored.
    func replied(_ index: Int, _ succeeded: Bool) {
        guard waiting, pending.contains(index) else { return }
        guard succeeded else {
            waiting = false
            pending = []
            for i in members.indices where i != index { members[i].resume() }
            reply(false)
            return
        }
        pending.remove(index)
        if pending.isEmpty {
            waiting = false
            reply(true)
        }
    }
}
