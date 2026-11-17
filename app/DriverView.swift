// The window's Driver tab: the driver's status, refreshed every 2 seconds, and the buttons that install, update
// and remove it. StatusController (StatusView.swift) holds the status and runs the requests; the headline, the
// advice and the table come from StatusModel.swift.
import Combine
import SwiftUI

extension TableRow: Identifiable {
    var id: String { name }
}

struct StatusView: View {
    @StateObject private var controller = StatusController()
    @State private var confirmingRemove = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

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
        .onAppear { controller.refresh() }
        .onReceive(timer) { _ in controller.refresh() }
        .confirmationDialog("Remove the RMNet driver?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { controller.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeMessage)
        }
    }
}
