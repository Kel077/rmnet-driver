// The window's Messages screen: the modem's text messages, newest first, as a list (sender, a one-line preview, how
// long ago, an unread dot) beside a reading pane (sender, time, the full text), with the store's use in the list's
// footer; Refresh, Delete… and New Message in the toolbar, and a sheet to write and send a message. SmsController
// (SmsController.swift) holds the state and runs the service; every decision that is a pure function of values lives in
// SmsModel.swift. Nothing here logs or stores message text or numbers.
import SwiftUI

extension SmsMessage: Identifiable {
    var id: SmsMessageKey { key }
}

struct SmsView: View {
    // The process's one controller, owned by the app delegate.
    @ObservedObject var controller: SmsController
    @State private var confirming: SmsMessage? = nil  // the message the delete confirmation is about
    @State private var writing = false                // the New Message sheet is open

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { controller.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Refresh")
                        .disabled(!controller.refreshEnabled)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { confirming = controller.selectedMessage } label: { Label("Delete…", systemImage: "trash") }
                        .help("Delete…")
                        .disabled(!controller.deleteEnabled)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { writing = true } label: { Label("New Message", systemImage: "square.and.pencil") }
                        .help("New Message")
                }
            }
            // The last send's or delete's result; only the next send or delete replaces it.
            .resultBanner(controller.result, isFailure: controller.resultIsFailure,
                          inProgress: controller.running == .sending || controller.running == .deleting)
            .sheet(isPresented: $writing) { ComposeSheet(controller: controller) }
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

    @ViewBuilder private var content: some View {
        if controller.messages.isEmpty {
            emptyState
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let failure = controller.listFailure {
                        StaleListNotice(text: listLine(updated: controller.listedAt, failure: failure))
                    }
                    // Ages are counted from a clock that turns every 15 s, so they stay right between listings.
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        List(controller.messages, selection: $controller.selection) { m in
                            MessageRow(message: m, unread: controller.unread.contains(m.key), now: context.date)
                        }
                        .listStyle(.inset)
                    }
                    ListFooter(controller: controller)
                }
                .frame(minWidth: 230, idealWidth: 280, maxWidth: 320)
                Divider()
                ReadingPane(message: controller.selectedMessage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// No rows: the modem is not attached, the listing failed, there are no messages, or the first listing runs.
    @ViewBuilder private var emptyState: some View {
        if let failure = controller.listFailure {
            if failure == describe(.modemNotAttached) {
                EmptyState(symbol: "cable.connector.slash", title: "Modem not attached", message: failure)
            } else {
                EmptyState(symbol: "exclamationmark.triangle", title: "The messages could not be read", message: failure)
            }
        } else if controller.listed {
            EmptyState(symbol: "tray", title: "No messages",
                       message: listLine(updated: controller.listedAt, failure: nil),
                       action: (title: "New Message", perform: { writing = true }))
        } else {
            EmptyState(symbol: "message", title: "Reading the messages…")
        }
    }
}

// MARK: - The list

/// The sender as a title: the number or name the modem gave, "Unknown sender" when it gave none.
private func senderTitle(_ m: SmsMessage) -> String {
    m.sender.isEmpty ? "Unknown sender" : m.sender
}

/// The first letter of a model line in upper case, so it reads as a sentence on its own ("1 part missing").
private func sentence(_ s: String) -> String {
    s.prefix(1).uppercased() + s.dropFirst()
}

/// How long ago a message arrived, against `now` ("Now", "5 min. ago", "Yesterday", "4 days ago", "Last mo."); a time
/// after `now` (the service centre's clock ahead of the Mac's) counts as now; "—" with no time.
private func messageAge(_ time: Date?, now: Date) -> String {
    guard let time else { return "—" }
    return sentence(ageFormatter.localizedString(for: min(time, now), relativeTo: now))
}

private let ageFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.unitsStyle = .short
    f.dateTimeStyle = .named
    return f
}()

/// The message's time in full ("Monday 16 November 2026 at 14:05"); "—" with no time.
private func messageTime(_ time: Date?) -> String {
    time.map { timeFormatter.string(from: $0) } ?? "—"
}

private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEEE d MMMM yyyy 'at' HH:mm"
    return f
}()

/// One message in the list: the unread dot, the sender, how long ago, and the text's first line; a note when the
/// message is not readable or has parts missing.
private struct MessageRow: View {
    let message: SmsMessage
    let unread: Bool
    let now: Date

    var body: some View {
        let note = rowNote(message)
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Circle()
                .fill(unread ? Color.blue : Color.clear)
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .accessibilityLabel(Text(unread ? "Unread" : ""))
                .accessibilityHidden(!unread)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(verbatim: senderTitle(message))
                        .font(.body.weight(unread ? .bold : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: Spacing.xs)
                    Text(verbatim: messageAge(message.timestamp, now: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .help(messageTime(message.timestamp))
                }
                Group {
                    if message.text.isEmpty {
                        Text(verbatim: note.isEmpty ? "No text" : sentence(note)).italic()
                    } else {
                        // One line: the text's line breaks become spaces.
                        Text(verbatim: message.text.split(whereSeparator: \.isNewline).joined(separator: " "))
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if !message.text.isEmpty && !note.isEmpty {
                    Text(verbatim: sentence(note))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

/// Above the list when the last listing failed and the list shown is an older one.
private struct StaleListNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.m)
        .background(Color.orange.opacity(0.12), ignoresSafeAreaEdges: [])  // not up under the toolbar
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The list's footer: the store's use as a gauge (not shown when it is not known), the warning when it is nearly full,
/// and when the list was read.
private struct ListFooter: View {
    @ObservedObject var controller: SmsController

    var body: some View {
        let warning = storeWarning(used: controller.storeUsed, total: controller.storeTotal)
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let used = controller.storeUsed, let total = controller.storeTotal, total > 0 {
                CapacityGauge(used: used, total: total, label: "Message store")
                    .font(.caption)
            }
            if !warning.isEmpty {
                Text(verbatim: warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if controller.listFailure == nil && controller.listed {
                Text(verbatim: listLine(updated: controller.listedAt, failure: nil))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - The reading pane

/// The selected message: who sent it and when, a note when it is not readable or incomplete, and its full text
/// (selectable, to copy a code).
private struct ReadingPane: View {
    let message: SmsMessage?

    var body: some View {
        if let m = message {
            let note = rowNote(m)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    HStack(alignment: .center, spacing: Spacing.m) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: senderTitle(m))
                                .font(.title2.weight(.semibold))
                                .textSelection(.enabled)
                            Text(verbatim: messageTime(m.timestamp))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    if !note.isEmpty {
                        Label(sentence(note), systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    if !m.text.isEmpty {
                        Text(verbatim: m.text)
                            .font(.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.fill.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .padding(Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyState(symbol: "text.bubble", title: "No message selected")
        }
    }
}

// MARK: - The New Message sheet

/// To, the text (plain, with no automatic substitutions: PlainTextEditor.swift) and its part counter, Cancel and Send.
/// The number and the text live in the controller, so closing the sheet keeps them. While a send runs nothing can be
/// changed or closed and the sheet shows what runs; after a failure the sheet stays open with the failure in it; after
/// a success it closes, and the screen's banner shows the result. Send is the default button (Return) only while the
/// controller allows sending and the To field is not being edited, so Return in To never sends; in the text, Return is
/// a new line. While an input method composes, Send waits (the controller's sendEnabled and composeText).
private struct ComposeSheet: View {
    @ObservedObject var controller: SmsController
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editingNumber: Bool
    @State private var sentHere = false  // a send was started from this sheet: its failure is shown here

    var body: some View {
        let sending = controller.running == .sending
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("New Message")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text("To")
                    .foregroundStyle(.secondary)
                TextField("To", text: $controller.to, prompt: Text("Number, with + and the country code"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($editingNumber)
                    .disabled(sending)
            }
            let badNumber = numberNote(controller.to)
            if !badNumber.isEmpty {
                Text(verbatim: badNumber)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            // It scrolls inside its frame, so a long text is never clipped. Its square bezel is drawn over with the
            // rounded edge of the To field.
            let edge = RoundedRectangle(cornerRadius: 6, style: .continuous)
            PlainTextEditor(text: $controller.text, composing: $controller.composing, editable: !sending)
                .frame(minHeight: 100, idealHeight: 140, maxHeight: 240)
                .clipShape(edge)
                .overlay(edge.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
                .accessibilityLabel(Text("Message"))
            Text(verbatim: controller.composeText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if sending {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    ProgressView()
                        .controlSize(.small)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text(verbatim: controller.result)
                        .font(.callout)
                }
            } else if sentHere && controller.resultIsFailure && !controller.result.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel(Text("Failed"))
                    Text(verbatim: controller.result)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(sending)
                Button("Send") {
                    sentHere = true
                    controller.send()
                }
                .keyboardShortcut(controller.sendEnabled && !editingNumber ? .defaultAction : nil)
                .disabled(!controller.sendEnabled)
            }
            .padding(.top, Spacing.xs)
        }
        .padding(Spacing.xl - 4)
        .frame(width: 460)
        .interactiveDismissDisabled(sending)
        .onChange(of: controller.running) { was, now in
            // A send started here has finished: on success the sheet closes (the banner shows the result). The
            // controller lists again as the send finishes, so what follows it may be a listing rather than nothing.
            if was == .sending, now != .sending, sentHere, !controller.resultIsFailure { dismiss() }
        }
    }
}
