// What the Network and SIM & Data screens share (NetworkView.swift, SimDataView.swift): the profile the driver
// dials, the words of the read line, the Put Back command, and the confirmations' words and their modifier.
import SwiftUI

/// The profile the driver dials: its RMNetProfile registry property; nil when it is not attached.
func driverProfileNumber() -> Int? {
    readDriverProperties()?["RMNetProfile"].flatMap { Int($0) }
}

// MARK: - Shared pieces

private let readTimeFormat: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm:ss"
    return f
}()

/// The screen's read line: "Updated HH:mm:ss." after a read that succeeded; after one that failed, its
/// sentence, and when values from an earlier read are on screen, that they may be out of date; before
/// the first read, `reading`.
func readStatusLine(at: Date?, failure: String?, valuesShown: Bool, reading: String) -> String {
    let time = at.map { readTimeFormat.string(from: $0) }
    switch (failure, time) {
    case (nil, nil): return reading
    case (nil, let t?): return "Updated \(t)."
    case (let f?, let t?) where valuesShown: return "\(f) The values below may be out of date; they were read at \(t)."
    case (let f?, _): return valuesShown ? "\(f) The values below may be out of date." : f
    }
}

/// What Put Back does, as a command for a terminal (the controller's `undoCommand`), since Put Back is
/// lost when the app quits; selectable, and never the password.
struct PutBackCommand: View {
    let command: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Put Back is lost when RMNet quits. The same in a terminal:")
                .foregroundStyle(.secondary)
            Text(verbatim: command)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A confirmation's words, taken when it opens (so a read that lands while it is open does not change
/// what the owner is asked), and the change it confirms.
struct Question<Action> {
    let action: Action
    let title: String
    let message: String
    let confirm: String   // the confirm button's title
    var destructive = false
    var cancelIsDefault = false   // Return cancels: the confirm button is never the default (the PIN, ruling R20)
}

/// Shows `question` as a confirmation. The screen calls `setConfirming(true)` when it opens one. Confirming
/// calls `perform` first and then `setConfirming(false)`, so the change starts at once rather than after
/// the read that may be due (ruling R12); the confirm button is never turned off. Confirmed, cancelled or
/// dismissed, `closed` runs (the SIM & Data screen clears the PIN and the last-attempt checkbox there).
struct Confirmation<Action>: ViewModifier {
    @Binding var question: Question<Action>?
    let controller: ModemController
    let perform: (Action) -> Void
    let closed: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(question?.title ?? "",
                                isPresented: Binding(get: { question != nil }, set: { if !$0 { question = nil } }),
                                titleVisibility: .visible,
                                presenting: question) { q in
                Button(q.confirm, role: q.destructive ? .destructive : nil) {
                    perform(q.action)
                    closed()
                    controller.setConfirming(false)
                }
                Button("Cancel", role: .cancel) {
                    closed()
                    controller.setConfirming(false)
                }
                .keyboardShortcut(q.cancelIsDefault ? KeyboardShortcut.defaultAction : nil)
            } message: { q in
                Text(verbatim: q.message)
            }
            // However it closed (also without a button): the PIN cleared and the last-attempt checkbox
            // unticked, and the controller reads again.
            .onChange(of: question == nil) { _, isClosed in
                if isClosed {
                    closed()
                    controller.setConfirming(false)
                }
            }
    }
}
