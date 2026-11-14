// The window's Messages tab: the modem's text messages, newest first, with Delete and Refresh, and a
// form to send one. SmsController holds the state and runs the service; every decision that is a pure
// function of values lives in SmsModel.swift. Nothing here logs or stores message text or numbers.
import AppKit
import Combine
import Foundation
import SwiftUI

/// What is running on the service's queue; at most one call at a time.
enum SmsActivity: Equatable {
    case listing
    case deleting
    case sending
}

/// The Messages tab's state. It takes any SmsServing, so it can be driven by a fake; its logic uses no
/// SwiftUI or AppKit. Its methods are called on the main thread, and every service call runs on `queue`,
/// one at a time, with the result handed back to the main thread. The app has exactly one, owned by the
/// app delegate (StatusView.swift), so that quitting can wait for a running call.
final class SmsController: ObservableObject {
    @Published private(set) var messages: [SmsMessage] = []
    @Published private(set) var listedAt: Date? = nil        // the last listing that succeeded
    @Published private(set) var listFailure: String? = nil   // the last listing's failure; nil after a success
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
    @Published var text = "" { // not saved anywhere
        // After a success, starting a new message clears the result line.
        didSet {
            if clearResultOnTyping, !text.isEmpty {
                clearResultOnTyping = false
                setResult("", failure: false)
            }
        }
    }

    private let service: SmsServing
    private let queue: DispatchQueue
    private var timer: Timer?
    private var tabShown = false
    private var windowVisible = true
    private var confirmingDelete = false     // the delete confirmation is open: timer ticks skip
    private var clearResultOnTyping = false
    private var stopping = false             // the app is quitting: nothing new starts
    private var whenFinished: (() -> Void)?  // the reply to a quit that waits for the running call

    static let refreshInterval: TimeInterval = 15

    init(service: SmsServing = SmsService(),
         queue: DispatchQueue = DispatchQueue(label: "io.rmnetdriver.RMNet.sms", qos: .userInitiated)) {
        self.service = service
        self.queue = queue
    }

    deinit { timer?.invalidate() }

    var listed: Bool { listedAt != nil }
    var selectedMessage: SmsMessage? { messages.first { $0.key == selection } }
    var sendEnabled: Bool { running == nil && !stopping && canSend(number: to, text: text) }
    var deleteEnabled: Bool { running == nil && !stopping && selectedMessage != nil }
    var refreshEnabled: Bool { running == nil && !stopping }

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

    private func tick() {
        guard !confirmingDelete else { return }
        refresh()
    }

    // MARK: Quitting

    /// Asked when the app is about to end. With no call running it returns false and the app may end now.
    /// Otherwise nothing new starts, `reply` is called once the running call has finished (a send is
    /// never cut short), and it returns true.
    func quitWhenFinished(_ reply: @escaping () -> Void) -> Bool {
        stopping = true
        updateTimer()
        guard let now = running else { return false }
        whenFinished = reply
        setResult(now == .sending ? "RMNet quits when the message has been sent."
                                  : "RMNet quits when the current request to the modem has finished.",
                  failure: false)
        return true
    }

    // Called by each finish after `running` is cleared; true when a quit was waiting (it is answered).
    private func answeredQuit() -> Bool {
        guard let reply = whenFinished else { return false }
        whenFinished = nil
        reply()
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

    private func finishListing(_ outcome: Result<[SmsMessage], SmsFailure>) {
        running = nil
        switch outcome {
        case .success(let found):
            messages = found
            listedAt = Date()
            listFailure = nil
            unread = unreadMarks(listed: found, kept: unread)
            if let s = selection, !found.contains(where: { $0.key == s }) { selection = nil }
            if let s = selection { unread.remove(s) }
        case .failure(let failure):
            listFailure = failure.message
        }
        _ = answeredQuit()
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
        switch outcome {
        case .success(let count):
            selection = nil
            setResult("Deleted \(count) stored part(s).", failure: false)
            clearResultOnTyping = true
        case .failure(let failure):
            setResult(failure.message, failure: true)
        }
        if answeredQuit() { return }
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
        switch outcome {
        case .success(let parts):
            text = ""
            setResult("Sent to \(number) in \(parts) part(s).", failure: false)
            clearResultOnTyping = true
        case .failure(let failure):
            setResult(failure.message, failure: true)
        }
        if answeredQuit() { return }
        if active { refresh() }
    }

    private func setResult(_ line: String, failure: Bool) {
        result = line
        resultIsFailure = failure
        if !line.isEmpty { clearResultOnTyping = false }
    }
}

// MARK: - The view

extension SmsMessage: Identifiable {
    var id: SmsMessageKey { key }
}

/// One message in the list. Its text becomes selectable (to copy a code) once the row is selected, so a
/// click on the text of another row still selects that row.
struct SmsRow: View {
    let message: SmsMessage
    let unread: Bool
    let selected: Bool
    let listedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if unread {
                    Text("unread")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                }
                Text(verbatim: rowTitle(message, now: listedAt))
                    .fontWeight(unread ? .bold : .regular)
            }
            let note = rowNote(message)
            if !note.isEmpty {
                Text(verbatim: note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !message.text.isEmpty {
                if selected {
                    Text(verbatim: message.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(verbatim: message.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct SmsView: View {
    // The process's one controller, owned by the app delegate.
    @ObservedObject var controller: SmsController
    @State private var confirming: SmsMessage? = nil  // the message the delete confirmation is about

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                // The list's own line: when it was listed, or why the last listing failed.
                Text(verbatim: listLine(updated: controller.listedAt, failure: controller.listFailure))
                    .foregroundStyle(controller.listFailure == nil ? Color.secondary : Color.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Refresh") { controller.refresh() }
                    .disabled(!controller.refreshEnabled)
                Button("Delete…") { confirming = controller.selectedMessage }
                    .disabled(!controller.deleteEnabled)
            }
            if controller.messages.isEmpty {
                Text(verbatim: listPlaceholder(listed: controller.listed, failed: controller.listFailure != nil))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
            } else {
                let listedAt = controller.listedAt ?? Date()
                List(controller.messages, selection: $controller.selection) { m in
                    SmsRow(message: m, unread: controller.unread.contains(m.key),
                           selected: controller.selection == m.key, listedAt: listedAt)
                }
                .frame(minHeight: 120)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("To")
                    TextField("Number, with + and the country code", text: $controller.to)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                let badNumber = numberNote(controller.to)
                if !badNumber.isEmpty {
                    Text(verbatim: badNumber)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                // Plain text with no automatic substitutions (PlainTextEditor.swift); it scrolls inside its
                // frame, so a long text is never clipped.
                PlainTextEditor(text: $controller.text, editable: controller.running != .sending)
                    .frame(minHeight: 48, idealHeight: 64, maxHeight: 96)
                HStack {
                    Text(verbatim: composeNote(controller.text))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Send") { controller.send() }
                        .disabled(!controller.sendEnabled)
                }
            }
            .disabled(controller.running == .sending)
            if !controller.result.isEmpty {
                // The last send's or delete's result; only the next send or delete replaces it.
                Text(verbatim: controller.result)
                    .foregroundStyle(controller.resultIsFailure ? Color.red : Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 420)
        .onChange(of: confirming != nil) { _, open in controller.setConfirmingDelete(open) }
        .confirmationDialog(confirming.map { deleteQuestion($0).title } ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible,
                            presenting: confirming) { m in
            Button("Delete", role: .destructive) { controller.delete(m) }
            Button("Cancel", role: .cancel) {}
        } message: { m in
            Text(verbatim: deleteQuestion(m).message)
        }
    }
}
