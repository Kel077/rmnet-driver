// The Messages tab's state and the calls it makes to the modem: one call at a time, the list's line and
// the result line kept apart, and quitting that waits for a running call. It takes any SmsServing, and
// the two AppKit calls it needs (the answer to the terminate question, the request for attention) are
// closures given by the app delegate, so it uses no AppKit or SwiftUI and is tested with a fake service
// (tests/app/SmsControllerTests.swift). Nothing here logs or stores message text or numbers.
import Combine
import Foundation

/// What is running on the service's queue; at most one call at a time.
enum SmsActivity: Equatable {
    case listing
    case deleting
    case sending
}

/// The line the window shows above its tabs while a quit waits for a call to the modem; "" otherwise.
/// Its own object, so the window can show it without observing the whole controller (typing a message
/// must not redraw the Driver tab).
final class SmsQuitNotice: ObservableObject {
    @Published fileprivate(set) var line = ""
}

/// The app has exactly one, owned by the app delegate (StatusView.swift), so that quitting can wait for a
/// running call. Its methods are called on the main thread; every service call runs on `queue`, one at a
/// time, with the result handed back to the main thread.
final class SmsController: ObservableObject {
    @Published private(set) var messages: [SmsMessage] = []
    @Published private(set) var listedAt: Date? = nil        // the last listing that succeeded
    @Published private(set) var listFailure: String? = nil   // the last listing's failure; nil after a success
    @Published private(set) var storeUsed: Int? = nil        // the store's use at the last successful listing
    @Published private(set) var storeTotal: Int? = nil
    @Published private(set) var unread: Set<SmsMessageKey> = []
    @Published private(set) var running: SmsActivity? = nil
    // The result of the last send or delete (or what runs now). A listing never writes here.
    @Published private(set) var result = ""
    @Published private(set) var resultIsFailure = false
    @Published var selection: SmsMessageKey? = nil {
        // Selecting a message is reading it: its unread mark goes.
        didSet { if let s = selection { unread.remove(s) } }
    }
    @Published var to = ""     // not saved anywhere
    @Published var text = "" { // not saved anywhere; always the committed text the field shows
        // After a success, starting a new message clears the result line.
        didSet {
            if clearResultOnTyping, !text.isEmpty {
                clearResultOnTyping = false
                setResult("", failure: false)
            }
        }
    }
    @Published var composing = false  // an input method has text in the field that is not committed yet

    let quitNotice = SmsQuitNotice()

    private let service: SmsServing
    private let queue: DispatchQueue
    private let replyToQuit: (Bool) -> Void      // NSApp.reply(toApplicationShouldTerminate:)
    private let requestAttention: () -> Void     // NSApp.requestUserAttention(.criticalRequest)
    private var timer: Timer?
    private var tabShown = false
    private var windowVisible = true
    private var confirmingDelete = false     // the delete confirmation is open: timer ticks skip
    private var clearResultOnTyping = false
    private var stopping = false             // the app is quitting: nothing new starts
    private var quitWaits = false            // a quit waits for the running call to finish

    static let refreshInterval: TimeInterval = 15

    init(service: SmsServing,
         queue: DispatchQueue = DispatchQueue(label: "io.rmnetdriver.RMNet.sms", qos: .userInitiated),
         replyToQuit: @escaping (Bool) -> Void,
         requestAttention: @escaping () -> Void) {
        self.service = service
        self.queue = queue
        self.replyToQuit = replyToQuit
        self.requestAttention = requestAttention
    }

    deinit { timer?.invalidate() }

    var listed: Bool { listedAt != nil }
    var selectedMessage: SmsMessage? { messages.first { $0.key == selection } }
    var sendEnabled: Bool { running == nil && !stopping && !composing && canSend(number: to, text: text) }
    var deleteEnabled: Bool { running == nil && !stopping && selectedMessage != nil }
    var refreshEnabled: Bool { running == nil && !stopping }
    /// The list's own line: when it was listed and how full the store is, or why the last listing failed.
    var listText: String { listLine(updated: listedAt, failure: listFailure, used: storeUsed, total: storeTotal) }
    /// The line under the message being written.
    var composeText: String { composeNote(text, composing: composing) }

    // MARK: When the modem is asked

    /// The Messages tab is the one shown (true) or not (false, also when the window closes).
    func setTabShown(_ shown: Bool) {
        tabShown = shown
        updateTimer()
    }

    /// The window can be seen (true) or is minimized, hidden or covered (false).
    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        updateTimer()
    }

    /// While the delete confirmation is open the 15 s refresh skips its turns.
    func setConfirmingDelete(_ open: Bool) {
        confirmingDelete = open
    }

    private var active: Bool { tabShown && windowVisible && !stopping }

    // Lists at once when the tab becomes active, then every 15 s; stops when it is not.
    private func updateTimer() {
        if active {
            guard timer == nil else { return }
            let t = Timer(timeInterval: SmsController.refreshInterval, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            refresh()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// One turn of the 15 s refresh.
    func tick() {
        guard !confirmingDelete else { return }
        refresh()
    }

    // MARK: Quitting

    /// Asked when the app is about to end. With no call running it returns false and the app may end now.
    /// Otherwise nothing new starts, it returns true, and once the running call has finished `replyToQuit`
    /// is called once (a send is never cut short): with true after a listing or a send or delete that
    /// succeeded; with false (the quit is cancelled, and the app asks for attention) after a send or
    /// delete that did not, so that the owner sees its result line.
    func quitWhenFinished() -> Bool {
        stopping = true
        updateTimer()
        guard let now = running else { return false }
        quitWaits = true
        quitNotice.line = quitWaitLine(now)
        return true
    }

    /// The quit was cancelled elsewhere (the modem tabs' call failed): working again, the tab listed at once
    /// if it is shown. A quit of this controller that still waited is cancelled too and never answered.
    func resumeAfterCancelledQuit() {
        stopping = false
        quitWaits = false
        quitNotice.line = ""
        updateTimer()
    }

    // Called by each finish after `running` is cleared; true when a quit was waiting (it is answered).
    private func answeredQuit(succeeded: Bool) -> Bool {
        guard quitWaits else { return false }
        quitWaits = false
        quitNotice.line = ""
        if succeeded {
            replyToQuit(true)
            return true
        }
        stopping = false
        replyToQuit(false)
        requestAttention()
        updateTimer()  // the app goes on: the tab lists again if it is shown
        return true
    }

    // MARK: The three calls

    /// Lists the messages, unless a call is already running (a timer tick then skips its turn).
    func refresh() {
        guard running == nil, !stopping else { return }
        running = .listing
        let service = self.service
        queue.async {
            let result = service.list()
            DispatchQueue.main.async { self.finishListing(result) }
        }
    }

    private func finishListing(_ outcome: Result<SmsListing, SmsFailure>) {
        running = nil
        switch outcome {
        case .success(let listing):
            let found = listing.messages
            messages = found
            listedAt = Date()
            listFailure = nil
            storeUsed = listing.used
            storeTotal = listing.total
            unread = unreadMarks(listed: found, kept: unread)
            if let s = selection, !found.contains(where: { $0.key == s }) { selection = nil }
            if let s = selection { unread.remove(s) }
        case .failure(let failure):
            listFailure = failure.message
        }
        _ = answeredQuit(succeeded: true)
    }

    /// Deletes every stored part of `message`, if it is still listed and nothing else runs.
    func delete(_ message: SmsMessage) {
        guard !stopping else { return }
        // A refresh may have started just before the confirmation opened.
        guard running == nil else {
            setResult("The modem was busy with another request. Nothing was deleted; press Delete again.", failure: true)
            return
        }
        guard messages.contains(where: { $0.key == message.key }) else {
            setResult("That message is no longer listed. Nothing was deleted.", failure: true)
            return
        }
        running = .deleting
        setResult("Deleting \(message.indices.count) stored part(s)…", failure: false)
        let service = self.service
        let indices = message.indices
        queue.async {
            let result = service.delete(indices: indices)
            DispatchQueue.main.async { self.finishDelete(result) }
        }
    }

    private func finishDelete(_ outcome: Result<Int, SmsFailure>) {
        running = nil
        let succeeded: Bool
        switch outcome {
        case .success(let count):
            selection = nil
            setResult("Deleted \(count) stored part(s).", failure: false)
            clearResultOnTyping = true
            succeeded = true
        case .failure(let failure):
            setResult(failure.message, failure: true)
            succeeded = false
        }
        if answeredQuit(succeeded: succeeded) { return }
        if active { refresh() }
    }

    /// Sends the text to the number once; never retried.
    func send() {
        guard sendEnabled else { return }
        let number = to, body = text
        let parts = partCount(body)
        running = .sending
        setResult("Sending \(parts) part(s) to \(number). This can take up to a minute per part.", failure: false)
        let service = self.service
        queue.async {
            let result = service.send(to: number, text: body)
            DispatchQueue.main.async { self.finishSend(result, number: number) }
        }
    }

    private func finishSend(_ outcome: Result<Int, SmsFailure>, number: String) {
        running = nil
        let succeeded: Bool
        switch outcome {
        case .success(let parts):
            text = ""
            setResult("Sent to \(number) in \(parts) part(s).", failure: false)
            clearResultOnTyping = true
            succeeded = true
        case .failure(let failure):
            setResult(failure.message, failure: true)
            succeeded = false
        }
        if answeredQuit(succeeded: succeeded) { return }
        if active { refresh() }
    }

    private func setResult(_ line: String, failure: Bool) {
        result = line
        resultIsFailure = failure
        if !line.isEmpty { clearResultOnTyping = false }
    }
}

private func quitWaitLine(_ activity: SmsActivity) -> String {
    switch activity {
    case .sending: return "RMNet quits when the message being sent has finished."
    case .deleting: return "RMNet quits when the message being deleted has finished."
    case .listing: return "RMNet quits when the current request to the modem has finished."
    }
}
