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

// What the window knows of the system's listing.
enum ListingState {
    case asking            // no answer yet since the window opened
    case known             // the last properties request answered with a listing
    case unknown(String)   // the last one failed, ended without a listing, or was not answered in 10 s
}

// Keeps the status and runs the requests. Every message about an install or a removal comes from
// the request's own answer, and says "installed" only when the listing, read again, agrees.
final class StatusController: ObservableObject {
    @Published private(set) var status = DriverStatus(entries: [], modem: .absent, attached: false, properties: [:])
    @Published private(set) var listing = ListingState.asking
    @Published private(set) var busy = false
    @Published private(set) var progress = ""

    let bundledVersion = bundledDriverVersion() ?? ""
    private let manager = ExtensionManager()
    private var entries: [ExtensionEntry] = []
    private var asking = false  // a properties request is in flight (at most 10 s)

    var known: Bool {
        if case .known = listing { return true }
        return false
    }

    // Reads the registry now, and asks the system for its entries unless a question is pending.
    func refresh() {
        status = readStatus(entries: entries)
        guard !asking else { return }
        asking = true
        manager.properties(timeout: 10) { [weak self] answer in
            guard let self = self else { return }
            self.asking = false
            switch answer {
            case .listed(let found):
                self.entries = found.map(ExtensionEntry.init)
                self.listing = .known
            case .notListed(.failed(let error)):
                self.listing = .unknown("The system did not list the driver: \(describe(error))")
            case .notListed(let outcome):
                self.listing = .unknown("The system finished without listing the driver (\(self.words(outcome))).")
            case .noAnswer:
                self.listing = .unknown("The system has not answered in 10 s.")
            }
            self.status = readStatus(entries: self.entries)
        }
    }

    var installButtonTitle: String { installTitle(status, bundledVersion: bundledVersion) }
    var installEnabled: Bool { !busy && known && canActivate(status) && !bundledVersion.isEmpty }
    var plan: RemovalPlan { removalPlan(status, bundledVersion: bundledVersion) }
    var removeEnabled: Bool { !busy && known && plan != .nothingListed }

    func install() {
        guard installEnabled else { return }
        let updating = !status.entries.isEmpty
        let version = bundledVersion
        busy = true
        progress = "Asking the system to install version \(version)…"
        manager.activate(
            replacing: { [weak self] old, new in self?.progress = "Replacing version \(old) with version \(new)…" },
            needsApproval: { [weak self] in
                self?.progress = "Waiting for approval in System Settings, General, Login Items & Extensions, Driver Extensions."
            },
            completion: { [weak self] outcome in
                guard let self = self else { return }
                guard case .completed = outcome else {
                    self.finish(self.answer(outcome, request: "installation of version \(version)"))
                    return
                }
                self.progress = "The system accepted version \(version); reading the listing again…"
                self.manager.properties(timeout: 10) { answer in
                    guard case .listed(let found) = answer else {
                        self.finish("The system accepted version \(version), but did not list the driver afterwards.")
                        return
                    }
                    let now = found.map(ExtensionEntry.init)
                    if now.count == 1, now[0].version == version, now[0].enabled {
                        self.finish(updating
                            ? "Version \(version) is installed. It loads when the modem is next plugged in or the Mac restarts; until then the old build may still be attached."
                            : "Version \(version) is installed.")
                    } else {
                        self.finish("The system accepted version \(version); it now lists \(describeListing(now)).")
                    }
                }
            })
    }

    func remove() {
        guard removeEnabled else { return }
        let version = bundledVersion
        busy = true
        manager.remove(
            status: status, bundledVersion: version,
            step: { [weak self] text in self?.progress = text },
            completion: { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .notSent(let why):
                    self.finish("Nothing was sent. " + why)
                case .activationEnded(.willCompleteAfterReboot):
                    self.finish("The system will install version \(version) after a restart; press Remove again then. Nothing was removed.")
                case .activationEnded(let outcome):
                    self.finish(self.answer(outcome, request: "installation of version \(version) that comes first")
                                + " Nothing was removed.")
                case .listingAfterActivation(let what):
                    self.finish("The system accepted version \(version) first, but then \(what), so the removal was not asked for. Nothing was removed.")
                case .deactivation(.completed):
                    self.finish("The system accepted the removal. The driver keeps the modem's network port until the modem is unplugged or the Mac restarts.")
                case .deactivation(let outcome):
                    self.finish(self.answer(outcome, request: "removal"))
                }
            })
    }

    private func finish(_ text: String) {
        progress = text
        busy = false
        refresh()
    }

    private func words(_ outcome: RequestOutcome) -> String {
        switch outcome {
        case .completed: return "completed"
        case .willCompleteAfterReboot: return "completes after a restart"
        case .other(let raw): return "result \(raw)"
        case .failed(let error): return describe(error)
        }
    }

    private func answer(_ outcome: RequestOutcome, request: String) -> String {
        switch outcome {
        case .completed: return "The system accepted the \(request)."
        case .willCompleteAfterReboot: return "The system will complete the \(request) when the Mac restarts."
        case .other(let raw): return "The system answered the \(request) with result \(raw)."
        case .failed(let error): return "The system refused the \(request): \(describe(error))"
        }
    }
}

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
                        .font(line.hasPrefix("AT+") ? .body.monospaced() : .body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Table(tableRows(status, bundledVersion: controller.bundledVersion)) {
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
