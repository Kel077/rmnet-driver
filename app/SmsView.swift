// The window's Messages tab: the modem's text messages, newest first, with Delete and Refresh, and a
// form to send one. SmsController (SmsController.swift) holds the state and runs the service; every
// decision that is a pure function of values lives in SmsModel.swift. Nothing here logs or stores
// message text or numbers.
import SwiftUI

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
                // The list's own line: when it was listed and how full the store is, or why the last
                // listing failed.
                Text(verbatim: controller.listText)
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
                // frame, so a long text is never clipped. While an input method composes, Send waits.
                PlainTextEditor(text: $controller.text, composing: $controller.composing,
                                editable: controller.running != .sending)
                    .frame(minHeight: 48, idealHeight: 64, maxHeight: 96)
                HStack {
                    Text(verbatim: controller.composeText)
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
