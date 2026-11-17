// What the Network and SIM & Data screens share (NetworkView.swift, SimDataView.swift): the profile the driver
// dials, the read line with Refresh, the result line, label and value rows, the Put Back command, and the
// confirmations' words and their modifier.
import SwiftUI

/// The profile the driver dials: its RMNetProfile registry property; nil when it is not attached.
func driverProfileNumber() -> Int? {
    readDriverProperties()?["RMNetProfile"].flatMap { Int($0) }
}

/// The modem tab a window tab is; nil for the Driver and Messages tabs.
func modemTab(_ tab: WindowTab) -> ModemTab? {
    switch tab {
    case .network: return .network
    case .simAndApn: return .simAndApn
    case .driver, .messages: return nil
    }
}

// MARK: - Shared pieces

private let readTimeFormat: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm:ss"
    return f
}()

/// The tab's first line: "Updated HH:mm:ss." after a read that succeeded; after one that failed, its
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

/// The read line (orange after a failed read) and Refresh.
struct ReadStatus: View {
    let text: String
    let failed: Bool
    @ObservedObject var controller: ModemController

    var body: some View {
        HStack(alignment: .top) {
            Text(verbatim: text)
                .foregroundStyle(failed ? Color.orange : Color.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Refresh") { controller.refresh() }
                .disabled(!controller.refreshEnabled)
        }
    }
}

/// The result of the last change (or what runs or waits now), red on failure. A read never changes it.
struct ResultLine: View {
    @ObservedObject var controller: ModemController

    var body: some View {
        if !controller.result.isEmpty {
            Text(verbatim: controller.result)
                .foregroundStyle(controller.resultIsFailure ? Color.red : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Label and value in two columns; the values can be selected.
struct RowsGrid: View {
    let rows: [(label: String, value: String)]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(verbatim: row.label)
                        .foregroundStyle(.secondary)
                    Text(verbatim: row.value)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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

/// Shows `question` as a confirmation. The tab calls `setConfirming(true)` when it opens one. Confirming
/// calls `perform` first and then `setConfirming(false)`, so the change starts at once rather than after
/// the read that may be due (ruling R12); the confirm button is never turned off. Confirmed, cancelled or
/// dismissed, `closed` runs (the SIM & APN tab clears the PIN and the last-attempt checkbox there).
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
