// The RMNet app's one window: on its Driver tab the driver's status, refreshed every 2 seconds, and the
// buttons that install, update and remove it; on its Messages tab the modem's text messages (SmsView.swift);
// on its Network and SIM & APN tabs the modem's network, settings and SIM (ModemView.swift).
// Started by main.swift when the app gets no command-line verb.
import AppKit
import Combine
import SwiftUI

struct RMNetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("RMNet", id: "status") {
            RMNetWindow(messages: appDelegate.messages, quitNotice: appDelegate.messages.quitNotice,
                        modem: appDelegate.modem, modemQuitNotice: appDelegate.modem.quitNotice)
        }
        .defaultSize(width: 520, height: 480)
    }
}

enum WindowTab: Hashable {
    case driver
    case messages
    case network
    case simAndApn
}

// The window's tabs: Driver (the status below), Messages (SmsView.swift), Network and SIM & APN
// (ModemView.swift). The tab shown is tracked by the selection; the Messages tab and the modem tabs ask the
// modem only while one of theirs is shown and the window can be seen. The controllers are not observed
// here, so typing a message does not redraw the Driver tab; only their small quit notices are: while a
// quit waits for a call to the modem, a line above the tabs says so.
struct RMNetWindow: View {
    let messages: SmsController
    @ObservedObject var quitNotice: SmsQuitNotice
    let modem: ModemController
    @ObservedObject var modemQuitNotice: ModemQuitNotice
    @State private var tab = WindowTab.driver

    var body: some View {
        VStack(spacing: 0) {
            if !quitNotice.line.isEmpty {
                Text(verbatim: quitNotice.line)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top])
            }
            if !modemQuitNotice.line.isEmpty {
                Text(verbatim: modemQuitNotice.line)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top])
            }
            TabView(selection: $tab) {
                StatusView()
                    .tabItem { Text("Driver") }
                    .tag(WindowTab.driver)
                SmsView(controller: messages)
                    .tabItem { Text("Messages") }
                    .tag(WindowTab.messages)
                NetworkTab(controller: modem)
                    .tabItem { Text("Network") }
                    .tag(WindowTab.network)
                SimApnTab(controller: modem)
                    .tabItem { Text("SIM & APN") }
                    .tag(WindowTab.simAndApn)
            }
        }
        .onAppear { messages.setTabShown(tab == .messages) }
        .onChange(of: tab) { _, shown in messages.setTabShown(shown == .messages) }
        .onDisappear { messages.setTabShown(false) }
        .onAppear { modem.setTabShown(modemTab(tab)) }
        .onChange(of: tab) { _, shown in modem.setTabShown(modemTab(shown)) }
        .onDisappear { modem.setTabShown(nil) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeOcclusionStateNotification)) { _ in
            messages.setWindowVisible(NSApp.occlusionState.contains(.visible))
            modem.setWindowVisible(NSApp.occlusionState.contains(.visible))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // The one serial queue to the modem's AT port, shared by both controllers, so that the window never
    // opens the port twice at once.
    private let modemQueue = DispatchQueue(label: "io.rmnetdriver.RMNet.modem", qos: .userInitiated)

    // The process's one SmsController (its queue to the modem is the shared one): the window shows it, and
    // quitting waits for its running call. It lives as long as the app, so a window reopened from the Dock
    // shows the same messages and result line. Its answer to a quit goes through `quitGate`.
    private(set) lazy var messages: SmsController = SmsController(
        service: SmsService(),
        queue: modemQueue,
        replyToQuit: { [unowned self] succeeded in self.quitGate.replied(AppDelegate.messagesMember, succeeded) },
        requestAttention: { _ = NSApp.requestUserAttention(.criticalRequest) })

    // The process's one ModemController, for the Network and SIM & APN tabs, kept the same way.
    private(set) lazy var modem: ModemController = ModemController(
        service: ModemService(),
        queue: modemQueue,
        driverProfile: driverProfileNumber,
        replyToQuit: { [unowned self] succeeded in self.quitGate.replied(AppDelegate.modemMember, succeeded) },
        requestAttention: { _ = NSApp.requestUserAttention(.criticalRequest) })

    // Both controllers are asked at once when the app is to quit, since a call of one can wait behind a call
    // of the other on the shared queue: the app ends when every call the quit waited for has succeeded, and
    // the first that did not cancels the quit and resumes the other controller (QuitGate.swift).
    private static let modemMember = 0, messagesMember = 1
    private lazy var quitGate: QuitGate = QuitGate(
        [QuitGate.Member(quitWhenFinished: { [unowned self] in self.modem.quitWhenFinished() },
                         resume: { [unowned self] in self.modem.resumeAfterCancelledQuit() }),
         QuitGate.Member(quitWhenFinished: { [unowned self] in self.messages.quitWhenFinished() },
                         resume: { [unowned self] in self.messages.resumeAfterCancelledQuit() })],
        reply: { NSApp.reply(toApplicationShouldTerminate: $0) })

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Every way of quitting (Cmd-Q, the Dock's Quit, closing the last window, logout) comes here. With a
    // call to the modem running, the app ends only when it has finished; a send is never cut short. A send,
    // delete or change that does not succeed cancels the quit, so that its result can be read.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitGate.ask() ? .terminateLater : .terminateNow
    }
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

    // Install and remove check their button again at the press: the listing may have changed since the
    // window drew it (a refresh every 2 s, the confirmation open meanwhile). If nothing is sent, the
    // progress line says why.
    func install() {
        guard installEnabled else {
            progress = notSentText(action: installButtonTitle, busy: busy, known: known)
            return
        }
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
                    if installConfirmed(now, version: version) {
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
        guard removeEnabled else {
            progress = notSentText(action: "Remove", busy: busy, known: known)
            return
        }
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
                        .font(line.hasPrefix("AT+") || line == usbModeQmiCommand ? .body.monospaced() : .body)
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
