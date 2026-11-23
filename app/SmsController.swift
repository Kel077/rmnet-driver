// The Messages screen's state and the calls it makes to the modem: one call at a time, the list's line and
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

/// The line the window shows above its screen while a quit waits for a call to the modem; "" otherwise.
/// Its own object, so the window can show it without observing the whole controller (typing a message
/// must not redraw the rest of the window).
final class SmsQuitNotice: ObservableObject {
    @Published fileprivate(set) var line = ""
}

/// How many messages are unread (the window's marks), for the menu bar item's panel; its own object for the same reason.
final class SmsUnreadNotice: ObservableObject {
    @Published fileprivate(set) var count = 0
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
    @Published private(set) var unread: Set<SmsMessageKey> = [] {
        didSet { if unreadNotice.count != unread.count { unreadNotice.count = unread.count } }
    }
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
    /// The conversation shown (conversationKey of its number). Showing it is reading it: its unread marks go.
    @Published var selectedConversation: String? = nil {
        didSet { markShownConversationRead() }
    }
    @Published var replyText = ""      // the conversation's reply, not saved anywhere
    @Published var replyComposing = false
    /// When this run of RMNet sent each stored part (index → time), so a sent message has a time: the modem keeps none
    /// for it. In memory only.
    @Published private(set) var sentAt: [Int: Date] = [:]

    let quitNotice = SmsQuitNotice()
    let unreadNotice = SmsUnreadNotice()

    private let service: SmsServing
    private let backgroundService: SmsServing    // the background listing's: a busy port fails at once
    private let notifyEnabled: () -> Bool        // Settings' Notify about new messages
    private let alert: (MessageAlert) -> Void    // posts a notification (MessageNotifier.swift)
    private var watch = NewMessageWatch()
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

    /// `backgroundService`: the background listing's service (nil: `service`). `notifyEnabled` and `alert`: whether
    /// to check for new messages in the background and announce them, and how (the tests' defaults: never).
    init(service: SmsServing,
         queue: DispatchQueue = DispatchQueue(label: "io.rmnetdriver.RMNet.sms", qos: .userInitiated),
         replyToQuit: @escaping (Bool) -> Void,
         requestAttention: @escaping () -> Void,
         backgroundService: SmsServing? = nil,
         notifyEnabled: @escaping () -> Bool = { false },
         alert: @escaping (MessageAlert) -> Void = { _ in }) {
        self.service = service
        self.queue = queue
        self.replyToQuit = replyToQuit
        self.requestAttention = requestAttention
        self.backgroundService = backgroundService ?? service
        self.notifyEnabled = notifyEnabled
        self.alert = alert
    }

    deinit { timer?.invalidate() }

    var listed: Bool { listedAt != nil }
    var selectedMessage: SmsMessage? { messages.first { $0.key == selection } }
    var sendEnabled: Bool { running == nil && !stopping && !composing && canSend(number: to, text: text) }
    /// The messages as conversations, the latest first (SmsConversations.swift).
    var conversations: [SmsConversation] { RMNetConversations.build(messages, unread: unread, sentAt: sentAt) }
    var shownConversation: SmsConversation? {
        guard let key = selectedConversation else { return nil }
        return conversations.first { $0.id == key }
    }
    /// The reply can go: a conversation with a number shown, a text, nothing running.
    var replyEnabled: Bool {
        guard running == nil, !stopping, !replyComposing, let number = shownConversation?.number else { return false }
        return canSend(number: number, text: replyText)
    }
    var replyNote: String { composeNote(replyText, composing: replyComposing) }
    var changeEnabled: Bool { running == nil && !stopping }
    var deleteEnabled: Bool { running == nil && !stopping && selectedMessage != nil }
    var refreshEnabled: Bool { running == nil && !stopping }
    /// The list's own line: when it was listed and how full the store is, or why the last listing failed.
    var listText: String { listLine(updated: listedAt, failure: listFailure, used: storeUsed, total: storeTotal) }
    /// The line under the message being written.
    var composeText: String { composeNote(text, composing: composing) }

    // MARK: When the modem is asked

    /// The Messages screen is the one shown (true) or not (false, also when the window closes).
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

    // Lists at once when the screen becomes active, then every 15 s; stops when it is not.
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

    /// The quit was cancelled elsewhere (the modem screens' call failed): working again, the screen listed at once
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
        updateTimer()  // the app goes on: the screen lists again if it is shown
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
            apply(listing)
        case .failure(let failure):
            listFailure = failure.message
        }
        _ = answeredQuit(succeeded: true)
    }

    /// A listing that succeeded, the screen's or the background's: the messages, the store, the unread marks; then what
    /// is new in it, announced.
    private func apply(_ listing: SmsListing) {
        let found = listing.messages
        messages = found
        listedAt = Date()
        listFailure = nil
        storeUsed = listing.used
        storeTotal = listing.total
        unread = unreadMarks(listed: found, kept: unread)
        if let s = selection, !found.contains(where: { $0.key == s }) { selection = nil }
        if let s = selection { unread.remove(s) }
        if active { markShownConversationRead() }
        announce(watch.listed(found, used: listing.used))
    }

    /// Each alert as a notification, while Notify about new messages is on; a new message not while the Messages
    /// screen is shown and seen (it is in the list there).
    private func announce(_ alerts: [MessageAlert]) {
        guard notifyEnabled() else { return }
        for a in alerts {
            if case .message = a, active { continue }
            alert(a)
        }
    }

    // MARK: New messages in the background

    /// The background turn's part (ModemPulse.swift): AT+CPMS? every other turn (about every 30 s, from the first),
    /// while Notify about new messages is on, nothing runs, the app does not quit, and the Messages screen does not list
    /// by itself (shown and seen: it lists every 15 s).
    func pulseCommands(turn: Int) -> [String] {
        guard notifyEnabled(), !stopping, running == nil, !active, turn % 2 == 1 else { return [] }
        return ["AT+CPMS?"]
    }

    /// The count read (or why the port could not be used: the turn is skipped): a count that went up, or the first,
    /// lists the messages, on a port that does not wait either.
    func pulseAnswers(_ answers: Result<[String: PulseAnswer], ModemFailure>) {
        guard case .success(let a) = answers, let store = a["AT+CPMS?"] else { return }
        if watch.storeCount(parseStorage(store.lines)?.used) { listInBackground() }
    }

    /// As refresh, with the background service; a listing that fails is not shown (it is tried again on a later turn:
    /// the count it is compared with changes only with a listing).
    private func listInBackground() {
        guard running == nil, !stopping else { return }
        running = .listing
        let service = self.backgroundService
        queue.async {
            let result = service.list()
            DispatchQueue.main.async { self.finishBackgroundListing(result) }
        }
    }

    private func finishBackgroundListing(_ outcome: Result<SmsListing, SmsFailure>) {
        running = nil
        if case .success(let listing) = outcome { apply(listing) }
        _ = answeredQuit(succeeded: true)
    }

    /// Shows the message a notification was about, if it is still listed (its parts may have changed since).
    func select(_ identity: SmsIdentity) {
        if let m = messages.first(where: { SmsIdentity($0) == identity }) {
            selection = m.key
            selectedConversation = conversationKey(m.sender)
        }
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
    /// Sends the reply to the conversation shown, as `send` does; on success the reply is cleared.
    func sendReply() {
        guard replyEnabled, let number = shownConversation?.number else { return }
        startSend(to: number, body: replyText, reply: true)
    }

    /// Sends the stored parts of `message` that are not sent (Retry), once.
    func retry(_ message: SmsMessage) {
        guard running == nil, !stopping, !message.unsentIndices.isEmpty else { return }
        running = .sending
        setResult("Sending \(message.unsentIndices.count) stored part(s) to \(message.sender) again…", failure: false)
        let service = self.service
        let indices = message.unsentIndices
        queue.async {
            let result = service.resend(indices: indices)
            DispatchQueue.main.async { self.finishSend(result, number: message.sender, reply: nil) }
        }
    }

    /// Deletes every stored part of every message of `conversation`.
    func deleteConversation(_ conversation: SmsConversation) {
        guard !stopping else { return }
        guard running == nil else {
            setResult("The modem was busy with another request. Nothing was deleted; press Delete again.", failure: true)
            return
        }
        let indices = conversation.messages.flatMap { $0.indices }
        guard !indices.isEmpty else { return }
        running = .deleting
        setResult("Deleting \(indices.count) stored part(s)…", failure: false)
        let service = self.service
        queue.async {
            let result = service.delete(indices: indices)
            DispatchQueue.main.async {
                if case .success = result, self.selectedConversation == conversation.id { self.selectedConversation = nil }
                self.finishDelete(result)
            }
        }
    }

    private func markShownConversationRead() {
        guard let c = shownConversation else { return }
        for m in c.messages { unread.remove(m.key) }
    }

    /// Sends the New Message sheet's text to its number once; never retried.
    func send() {
        guard sendEnabled else { return }
        startSend(to: to, body: text, reply: false)
    }

    /// `reply`: true for the conversation's reply, false for the New Message sheet (whose conversation is then shown).
    private func startSend(to number: String, body: String, reply: Bool) {
        let parts = partCount(body)
        running = .sending
        setResult("Sending \(parts) part(s) to \(number). This can take up to a minute per part.", failure: false)
        let service = self.service
        queue.async {
            let result = service.send(to: number, text: body)
            DispatchQueue.main.async { self.finishSend(result, number: number, reply: reply) }
        }
    }

    /// `reply` nil: a Retry. The parts' stored indices get the time they were sent (sentAt).
    private func finishSend(_ outcome: Result<SmsSent, SmsFailure>, number: String, reply: Bool?) {
        running = nil
        let succeeded: Bool
        switch outcome {
        case .success(let sent):
            let now = Date()
            for index in sent.indices { sentAt[index] = now }
            switch reply {
            case true?: replyText = ""
            case false?:
                text = ""
                selectedConversation = conversationKey(number)
            case nil: break
            }
            setResult("Sent to \(number) in \(sent.parts) part(s)."
                      + (sent.stored ? "" : " It is not stored on the modem: it writes messages to another storage than "
                         + "the one it lists."), failure: false)
            clearResultOnTyping = reply == false
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
