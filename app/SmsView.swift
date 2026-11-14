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

/// The Messages tab's state. It takes any SmsServing, so it can be driven by a fake; it uses no SwiftUI
/// or AppKit. Its methods are called on the main thread, and every service call runs on `queue`, one at
/// a time, with the result handed back to the main thread.
final class SmsController: ObservableObject {
    @Published private(set) var messages: [SmsMessage] = []
    @Published private(set) var listed = false              // a listing has succeeded at least once
    @Published private(set) var stale = false               // the last listing failed; the list is older
    @Published private(set) var unread: Set<SmsMessageKey> = []
    @Published private(set) var running: SmsActivity? = nil
    @Published private(set) var status = ""                 // the last result, failure or what runs now
    @Published private(set) var statusIsFailure = false
    @Published var selection: SmsMessageKey? = nil {
        // Selecting a message is reading it: its unread mark goes.
        didSet { if let s = selection { unread.remove(s) } }
    }
    @Published var to = ""     // not saved anywhere
    @Published var text = ""   // not saved anywhere

    private let service: SmsServing
    private let queue: DispatchQueue
    private var timer: Timer?
    private var tabShown = false
    private var windowVisible = true
    private var statusFromListing = false   // the status line holds a listing's failure

    static let refreshInterval: TimeInterval = 15

    init(service: SmsServing = SmsService(),
         queue: DispatchQueue = DispatchQueue(label: "io.rmnetdriver.RMNet.sms", qos: .userInitiated)) {
        self.service = service
        self.queue = queue
    }

    deinit { timer?.invalidate() }

    var selectedMessage: SmsMessage? { messages.first { $0.key == selection } }
    var sendEnabled: Bool { running == nil && canSend(number: to, text: text) }
    var deleteEnabled: Bool { running == nil && selectedMessage != nil }
    var refreshEnabled: Bool { running == nil }

    // MARK: When the modem is asked

    /// The tab is shown (true) or another tab is (false).
    func setTabShown(_ shown: Bool) {
        tabShown = shown
        updateTimer()
    }

    /// The window can be seen (true) or is minimized, hidden or covered (false).
    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        updateTimer()
    }

    private var active: Bool { tabShown && windowVisible }

    // Lists at once when the tab becomes active, then every 15 s; stops when it is not.
    private func updateTimer() {
        if active {
            guard timer == nil else { return }
            let t = Timer(timeInterval: SmsController.refreshInterval, repeats: true) { [weak self] _ in
                self?.refresh()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            refresh()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: The three calls

    /// Lists the messages, unless a call is already running (a timer tick then skips its turn).
    func refresh() {
        guard running == nil else { return }
        running = .listing
        let service = self.service
        queue.async {
            let result = service.list()
            DispatchQueue.main.async { self.finishListing(result) }
        }
    }

    private func finishListing(_ result: Result<[SmsMessage], SmsFailure>) {
        running = nil
        switch result {
        case .success(let found):
            messages = found
            listed = true
            stale = false
            unread = unreadMarks(listed: found, kept: unread)
            if let s = selection, !found.contains(where: { $0.key == s }) { selection = nil }
            if let s = selection { unread.remove(s) }
            if statusFromListing { setStatus("", failure: false) }
        case .failure(let failure):
            stale = listed
            setStatus(failure.message, failure: true)
            statusFromListing = true
        }
    }

    /// Deletes every stored part of `message`, if it is still listed and nothing else runs.
    func delete(_ message: SmsMessage) {
        // A refresh may have started while the confirmation was open.
        guard running == nil else {
            setStatus("The modem was busy with another request. Nothing was deleted; press Delete again.", failure: true)
            return
        }
        guard messages.contains(where: { $0.key == message.key }) else {
            setStatus("That message is no longer listed. Nothing was deleted.", failure: true)
            return
        }
        running = .deleting
        setStatus("Deleting \(message.indices.count) stored part(s)…", failure: false)
        let service = self.service
        let indices = message.indices
        queue.async {
            let result = service.delete(indices: indices)
            DispatchQueue.main.async { self.finishDelete(result) }
        }
    }

    private func finishDelete(_ result: Result<Int, SmsFailure>) {
        running = nil
        switch result {
        case .success(let count):
            selection = nil
            setStatus("Deleted \(count) stored part(s).", failure: false)
        case .failure(let failure):
            setStatus(failure.message, failure: true)
        }
        if active { refresh() }
    }

    /// Sends the text to the number once; never retried.
    func send() {
        guard sendEnabled else { return }
        let number = to, body = text
        let parts = partCount(body)
        running = .sending
        setStatus("Sending \(parts) part(s) to \(number). This can take up to a minute per part.", failure: false)
        let service = self.service
        queue.async {
            let result = service.send(to: number, text: body)
            DispatchQueue.main.async { self.finishSend(result, number: number) }
        }
    }

    private func finishSend(_ result: Result<Int, SmsFailure>, number: String) {
        running = nil
        switch result {
        case .success(let parts):
            text = ""
            setStatus("Sent to \(number) in \(parts) part(s).", failure: false)
        case .failure(let failure):
            setStatus(failure.message, failure: true)
        }
        if active { refresh() }
    }

    private func setStatus(_ line: String, failure: Bool) {
        status = line
        statusIsFailure = failure
        statusFromListing = false
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if unread {
                    Text("unread")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                }
                Text(verbatim: rowTitle(message, now: Date()))
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
    // Owned by the window (RMNetWindow), so the list and its unread marks survive a switch of tabs.
    @ObservedObject var controller: SmsController
    @State private var confirming: SmsMessage? = nil  // the message the delete confirmation is about

    private var emptyText: String {
        if controller.listed { return "No messages on the modem." }
        if controller.statusIsFailure, controller.running == nil { return "The messages could not be read." }
        return "Reading the messages…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                Button("Refresh") { controller.refresh() }
                    .disabled(!controller.refreshEnabled)
                Button("Delete…") { confirming = controller.selectedMessage }
                    .disabled(!controller.deleteEnabled)
            }
            if controller.stale {
                Text("The last listing failed; the list below may be out of date.")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if controller.messages.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
            } else {
                List(controller.messages, selection: $controller.selection) { m in
                    SmsRow(message: m, unread: controller.unread.contains(m.key), selected: controller.selection == m.key)
                }
                .frame(minHeight: 120)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("To")
                    TextField("Number, with + and the country code", text: $controller.to)
                        .textFieldStyle(.roundedBorder)
                }
                let badNumber = numberNote(controller.to)
                if !badNumber.isEmpty {
                    Text(verbatim: badNumber)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                // TextEditor scrolls inside its frame, so a long text is never clipped.
                TextEditor(text: $controller.text)
                    .font(.body)
                    .frame(minHeight: 48, idealHeight: 64, maxHeight: 96)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
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
            if !controller.status.isEmpty {
                Text(verbatim: controller.status)
                    .foregroundStyle(controller.statusIsFailure ? Color.red : Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 420)
        // The modem is asked only while this tab is shown and the window can be seen.
        .onAppear {
            controller.setWindowVisible(true)
            controller.setTabShown(true)
        }
        .onDisappear { controller.setTabShown(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeOcclusionStateNotification)) { _ in
            controller.setWindowVisible(NSApp.occlusionState.contains(.visible))
        }
        .confirmationDialog(confirming.map { deleteQuestion($0).title } ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { m in
            Button("Delete", role: .destructive) { controller.delete(m) }
            Button("Cancel", role: .cancel) {}
        } message: { m in
            Text(verbatim: deleteQuestion(m).message)
        }
    }
}
