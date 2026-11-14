// The RMNet app's one window: the driver's status, refreshed every 2 seconds, and the buttons that
// install, update and remove it. Started by main.swift when the app gets no command-line verb.
import AppKit
import Combine
import SwiftUI

struct RMNetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("RMNet", id: "status") {
            StatusView()
        }
        .defaultSize(width: 480, height: 420)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// Keeps the status and runs the requests. Every message about an install or a removal comes from
// the request's own answer.
final class StatusController: ObservableObject {
    @Published private(set) var status = DriverStatus(entries: [], modem: .absent, attached: false, properties: [:])
    @Published private(set) var listed = false        // a properties request has answered
    @Published private(set) var listingError: String?  // the last properties request failed
    @Published private(set) var busy = false
    @Published private(set) var progress = ""

    let bundledVersion = bundledDriverVersion() ?? ""
    private let manager = ExtensionManager()
    private var entries: [ExtensionEntry] = []
    private var asking = false  // a properties request is in flight

    // Reads the registry now, and asks the system for its entries unless a question is pending.
    func refresh() {
        status = readStatus(entries: entries)
        guard !asking else { return }
        asking = true
        manager.properties { [weak self] result in
            guard let self = self else { return }
            self.asking = false
            switch result {
            case .success(let found):
                self.entries = found.map(ExtensionEntry.init)
                self.listed = true
                self.listingError = nil
            case .failure(let error):
                self.listingError = describe(error)
            }
            self.status = readStatus(entries: self.entries)
        }
    }

    var installTitle: String { status.entries.isEmpty ? "Install" : "Update" }

    func install() {
        let updating = !status.entries.isEmpty
        busy = true
        progress = "Asking the system to install version \(bundledVersion)…"
        manager.activate(
            replacing: { [weak self] old, new in self?.progress = "Replacing version \(old) with version \(new)…" },
            needsApproval: { [weak self] in
                self?.progress = "Waiting for approval in System Settings, General, Login Items & Extensions, Driver Extensions."
            },
            completion: { [weak self] outcome in
                guard let self = self else { return }
                switch outcome {
                case .completed:
                    self.progress = updating
                        ? "The system installed version \(self.bundledVersion). It loads when the modem is next plugged in or the Mac restarts; until then the old build may still be attached."
                        : "The system installed version \(self.bundledVersion)."
                default:
                    self.progress = self.answer(outcome, request: "installation")
                }
                self.busy = false
                self.refresh()
            })
    }

    func remove() {
        busy = true
        manager.remove(
            status: status, bundledVersion: bundledVersion,
            step: { [weak self] text in self?.progress = text },
            completion: { [weak self] outcome in
                guard let self = self else { return }
                self.progress = outcome.isCompleted
                    ? "The system removed the driver."
                    : self.answer(outcome, request: "removal")
                self.busy = false
                self.refresh()
            })
    }

    private func answer(_ outcome: RequestOutcome, request: String) -> String {
        switch outcome {
        case .completed: return "The system completed the \(request)."
        case .willCompleteAfterReboot: return "The system will complete the \(request) when the Mac restarts."
        case .other(let raw): return "The system finished the \(request) with result \(raw)."
        case .failed(let error): return "The system refused the \(request): \(describe(error))"
        }
    }
}

extension RequestOutcome {
    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
}

extension TableRow: Identifiable {
    var id: String { name }
}

struct StatusView: View {
    @StateObject private var controller = StatusController()
    @State private var confirmingRemove = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        let status = controller.status
        VStack(alignment: .leading, spacing: 10) {
            Text(controller.listed ? headline(status) : "Asking the system…")
                .font(.largeTitle)
            if let error = controller.listingError {
                Text("The system did not list the driver: \(error)")
                    .foregroundStyle(.red)
            }
            ForEach(advice(status, bundledVersion: controller.bundledVersion), id: \.self) { line in
                Text(line)
                    .font(line.hasPrefix("AT+") ? .body.monospaced() : .body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Table(tableRows(status, bundledVersion: controller.bundledVersion)) {
                TableColumn("Name", value: \.name)
                TableColumn("Value") { row in Text(row.value).textSelection(.enabled) }
            }
            if !controller.progress.isEmpty {
                Text(controller.progress)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(controller.installTitle) { controller.install() }
                    .disabled(controller.busy || !controller.listed || controller.bundledVersion.isEmpty)
                Button("Remove…") { confirmingRemove = true }
                    .disabled(controller.busy || status.entries.isEmpty)
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
            Text("The Mac's network port for the modem will disappear. macOS will ask for an administrator password.")
        }
    }
}
