// The window's Driver screen: the driver's status, refreshed every 2 seconds while it is shown and the window can
// be seen (the window's poll, WindowPolls in ShellModel.swift), and the buttons that install, update and remove it.
// StatusController (StatusView.swift; the app delegate's driverStatus) holds the status and runs the requests; the
// headline, the advice and the table come from StatusModel.swift.
import SwiftUI

extension TableRow: Identifiable {
    var id: String { name }
}

struct StatusView: View {
    // The process's one controller, owned by the app delegate and shared with the Overview.
    @ObservedObject var controller: StatusController
    @State private var confirmingRemove = false

    private var headlineText: String {
        switch controller.listing {
        case .asking: return "Asking the system…"
        case .known: return headline(controller.status)
        case .unknown: return unknownHeadline
        }
    }

    // The confirmation's text: what disappears, the password, and the install-first step if any.
    private var removeMessage: String {
        var text = "The Mac's network port for the modem will disappear. macOS will ask for an administrator password."
        if controller.plan == .activateThenDeactivate {
            let listed = controller.status.entries.map { $0.version }.joined(separator: ", ")
            text += " First this app installs version \(controller.bundledVersion) in place of version \(listed), so that it can remove it."
        }
        return text
    }

    var body: some View {
        let status = controller.status
        VStack(alignment: .leading, spacing: 10) {
            Text(headlineText)
                .font(.largeTitle)
            if case .unknown(let why) = controller.listing {
                Text(why)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if controller.known {
                ForEach(advice(status, bundledVersion: controller.bundledVersion), id: \.self) { line in
                    Text(line)
                        .font(line.hasPrefix("AT+") || line == usbModeQmiCommand || atFallbackCommands.contains(line)
                              ? .body.monospaced() : .body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Table(tableRows(status, bundledVersion: controller.bundledVersion, listingKnown: controller.known)) {
                TableColumn("Name", value: \.name)
                TableColumn("Value") { row in Text(row.value).textSelection(.enabled) }
            }
            if !controller.progress.isEmpty {
                Text(controller.progress)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(controller.installButtonTitle) { controller.install() }
                    .disabled(!controller.installEnabled)
                Button("Remove…") {
                    // With nothing it can send, Remove only says which app can.
                    if controller.plan == .cannot { controller.remove() } else { confirmingRemove = true }
                }
                .disabled(!controller.removeEnabled)
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 420)
        .confirmationDialog("Remove the RMNet driver?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { controller.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeMessage)
        }
    }
}
