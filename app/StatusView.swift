// The RMNet app's one window: a sidebar of screens (ShellModel.swift's Screen) with the connection at its foot,
// and the screen chosen: the Overview (OverviewView.swift), the modem's text messages (SmsView.swift), its network
// and its SIM and data profile (NetworkView.swift, SimDataView.swift), and the driver, which this app installs,
// updates and removes (DriverView.swift). And its menu bar item (MenuBarView.swift), which stays when the window
// is closed. Started by main.swift when the app gets no command-line verb.
import AppKit
import Combine
import SwiftUI

struct RMNetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("RMNet", id: "status") {
            RMNetWindow(messages: appDelegate.messages, quitNotice: appDelegate.messages.quitNotice,
                        modem: appDelegate.modem, modemQuitNotice: appDelegate.modem.quitNotice,
                        driverStatus: appDelegate.driverStatus, throughput: appDelegate.throughput,
                        menuBar: appDelegate.menuBar, polls: appDelegate.windowPolls)
        }
        .defaultSize(width: 920, height: 640)
        .windowResizability(.contentMinSize)
        // The App observes nothing: the item's label and its panel observe the menu bar model (kept by the app
        // delegate), so a change of the icon redraws only the label.
        MenuBarExtra {
            MenuBarPanel(status: appDelegate.menuBar, quitNotice: appDelegate.messages.quitNotice,
                         modemQuitNotice: appDelegate.modem.quitNotice,
                         showWindow: { open in _ = AppDelegate.showStatusWindow(using: open) })
                .background(OpenWindowKeeper())
        } label: {
            MenuBarLabel(status: appDelegate.menuBar)
        }
        .menuBarExtraStyle(.window)
    }
}

// The window: a NavigationSplitView whose sidebar lists the screens (the Messages row with the unread count) above
// the connection pill, and whose detail is the screen chosen, under the quit notices. The screen chosen is kept
// across launches (@SceneStorage). What the modem, the messages and the two polls read follows the screen shown
// (Screen's modemTab, listsMessages, readsDriverStatus, samplesThroughput) and only while this window itself can be
// seen (WindowVisibility.swift: not NSApp.occlusionState, which the menu bar item's windows would keep visible).
// The controllers are not observed here, so typing a message does not redraw the window; only their small quit
// notices are: while a quit waits for a call to the modem, a line above the screen says so (quitNoticeLines, as
// the menu bar's panel). Each screen puts its own actions in the toolbar (ToolbarItem placement .primaryAction)
// and its result line in the banner slot at its bottom (DesignKit's resultBanner); the window sets the title.
struct RMNetWindow: View {
    let messages: SmsController
    @ObservedObject var quitNotice: SmsQuitNotice
    let modem: ModemController
    @ObservedObject var modemQuitNotice: ModemQuitNotice
    let driverStatus: StatusController
    let throughput: ThroughputSampler
    let menuBar: MenuBarStatus
    let polls: WindowPolls
    @SceneStorage("screen") private var screen = Screen.overview

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { screen }, set: { if let chosen = $0 { screen = chosen } })) {
                ForEach(Screen.allCases) { item in
                    SidebarRow(screen: item, messages: messages)
                        .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarConnection(menuBar: menuBar, modem: modem)
                    .padding(Spacing.m)
            }
        } detail: {
            VStack(spacing: 0) {
                QuitNotice(lines: quitNoticeLines(messages: quitNotice.line, modem: modemQuitNotice.line))
                detail(screen)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(screen.title)
        }
        // The window's minimum is 760 × 520 with its toolbar (about 52 pt): this frame is below the toolbar.
        .frame(minWidth: 760, minHeight: 468)
        .onAppear { show(screen) }
        .onChange(of: screen) { _, shown in show(shown) }
        .onDisappear {
            messages.setTabShown(false)
            modem.setTabShown(nil)
            // The controller outlives the window: a confirmation or the bands sheet that closed with it must not
            // keep its reads paused when the window opens again.
            modem.setConfirming(false)
            polls.setScreen(nil)
        }
        .background(WindowVisibilityObserver { visible in
            messages.setWindowVisible(visible)
            modem.setWindowVisible(visible)
            polls.setWindowVisible(visible)
        })
        .background(OpenWindowKeeper())
    }

    /// Tells the controllers and the polls what the screen shown reads.
    private func show(_ shown: Screen) {
        messages.setTabShown(shown.listsMessages)
        modem.setTabShown(shown.modemTab)
        polls.setScreen(shown)
    }

    @ViewBuilder private func detail(_ shown: Screen) -> some View {
        switch shown {
        case .overview:
            OverviewView(driverStatus: driverStatus, modem: modem, messages: messages, throughput: throughput,
                         navigate: { screen = $0 })
        case .messages:
            SmsView(controller: messages)
        case .network:
            NetworkTab(controller: modem, throughput: throughput)
        case .simData:
            SimApnTab(controller: modem)
        case .driver:
            StatusView(controller: driverStatus)
        }
    }
}

/// A screen in the sidebar: its symbol and title; the Messages row with the unread messages' count as a badge
/// (only that row observes the messages' controller).
private struct SidebarRow: View {
    let screen: Screen
    let messages: SmsController

    var body: some View {
        if screen == .messages {
            MessagesRow(screen: screen, messages: messages)
        } else {
            Label(screen.title, systemImage: screen.symbol)
        }
    }
}

private struct MessagesRow: View {
    let screen: Screen
    @ObservedObject var messages: SmsController

    var body: some View {
        Label(screen.title, systemImage: screen.symbol)
            .badge(messages.unread.count)
    }
}

/// The connection at the sidebar's foot: the state's dot and words, from the menu bar item's model (read from the
/// registry every 5 s whatever the screen); while the link is up, the technology, the band and the bars from the
/// modem's last network read, if it is less than a minute old (the Overview and the Network screen read it).
private struct SidebarConnection: View {
    @ObservedObject var menuBar: MenuBarStatus
    @ObservedObject var modem: ModemController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let pill = connectionPill(menuBar.headline)
            let fresh = modem.infoAt.map { context.date.timeIntervalSince($0) < 60 } ?? false
            let info = menuBar.icon == .up && fresh ? modem.info : nil
            let tech = info.flatMap(techBadgeText)
            HStack(spacing: Spacing.s) {
                Image(systemName: "circle.fill")
                    .imageScale(.small)
                    .font(.caption)
                    .foregroundStyle(pill.state.tint)
                    .symbolEffect(.pulse, options: .repeating, isActive: pill.state == .connecting)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: pill.text)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let tech {
                        Text(verbatim: [tech, info.flatMap(bandText)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Spacing.xs)
                if let info {
                    SignalBars(level: signalLevel(info), height: 12)
                }
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))
            .accessibilityElement(children: .combine)
        }
    }
}

/// Reports whether the window this view is in can be seen: its own occlusion state, and not visible once it
/// closes or the view leaves it (WindowVisibility.swift). The app's other windows do not count. Each report is
/// delivered on a later turn of the main queue, in order: the first comes while SwiftUI inserts the view
/// (viewDidMoveToWindow), when the controllers' published values must not change. Also marks the window as the
/// RMNet window (AppDelegate.statusWindow) while it is open, so a reopen can find it.
private struct WindowVisibilityObserver: NSViewRepresentable {
    let report: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView(report: report) }
    func updateNSView(_ view: ObserverView, context: Context) {}

    final class ObserverView: NSView {
        private let visibility: WindowVisibility
        private var closeToken: NSObjectProtocol?

        init(report: @escaping (Bool) -> Void) {
            visibility = WindowVisibility(occlusionChanged: NSWindow.didChangeOcclusionStateNotification,
                                          willClose: NSWindow.willCloseNotification,
                                          report: { visible in DispatchQueue.main.async { report(visible) } })
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        deinit { stopMarking() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            visibility.follow(window, visible: { [weak window] in
                guard let window else { return false }
                return window.isVisible && window.occlusionState.contains(.visible)
            })
            stopMarking()
            guard let window else { return }
            AppDelegate.statusWindow = window
            closeToken = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                queue: .main) { [weak window] _ in
                if AppDelegate.statusWindow === window { AppDelegate.statusWindow = nil }
            }
        }

        private func stopMarking() {
            if let closeToken { NotificationCenter.default.removeObserver(closeToken) }
            closeToken = nil
        }
    }
}

/// Keeps SwiftUI's way of opening the window (`openWindow(id: "status")`) in AppDelegate.openStatusWindow, for
/// a Dock click or a second launch while the window is closed. In the window and in the menu bar item's panel;
/// it reads nothing.
private struct OpenWindowKeeper: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                let open = openWindow
                AppDelegate.openStatusWindow = { open(id: "status") }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // The one serial queue to the modem's AT port, shared by both controllers and the menu bar item, so that
    // the app never opens the port twice at once.
    static let modemQueue = DispatchQueue(label: "io.rmnetdriver.RMNet.modem", qos: .userInitiated)

    // The process's one SmsController (its queue to the modem is the shared one): the window shows it, and
    // quitting waits for its running call. It lives as long as the app, so a window reopened from the Dock
    // shows the same messages and result line. Its answer to a quit goes through `quitGate`.
    private(set) lazy var messages: SmsController = SmsController(
        service: SmsService(),
        queue: AppDelegate.modemQueue,
        replyToQuit: { [unowned self] succeeded in self.quitGate.replied(AppDelegate.messagesMember, succeeded) },
        requestAttention: { _ = NSApp.requestUserAttention(.criticalRequest) })

    // The process's one ModemController, for the Network and SIM & APN tabs, kept the same way.
    private(set) lazy var modem: ModemController = ModemController(
        service: ModemService(),
        queue: AppDelegate.modemQueue,
        driverProfile: driverProfileNumber,
        replyToQuit: { [unowned self] succeeded in self.quitGate.replied(AppDelegate.modemMember, succeeded) },
        requestAttention: { _ = NSApp.requestUserAttention(.criticalRequest) })

    // The menu bar item's state, polled from launch (applicationDidFinishLaunching) for as long as the app runs.
    // Kept here rather than in the App, so that only the item's label and panel observe it.
    private(set) lazy var menuBar: MenuBarStatus = MenuBarStatus.forApp(queue: AppDelegate.modemQueue)

    // The driver's status, shared by the Overview and the Driver screen, and the throughput, shared by the Overview
    // and the Network screen; each polled by `windowPolls` only while one of its screens is shown and the window
    // can be seen: the status every 2 s (the registry and the system's listing), the driver's byte counters every
    // second (the registry only). Neither reads the AT port.
    private(set) lazy var driverStatus = StatusController()
    private(set) lazy var throughput = ThroughputSampler(read: { driverByteCounters(readDriverProperties()) })
    private(set) lazy var windowPolls = WindowPolls(
        driverStatus: RepeatingPoll(every: 2) { [unowned self] in self.driverStatus.refresh() },
        throughput: RepeatingPoll(every: 1) { [unowned self] in self.throughput.sample() })

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar.start()
    }

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

    // RMNet stays in the menu bar when its window is closed; `Open RMNet` in the item's panel opens it again.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // SwiftUI's way of opening the window, kept by the window and the panel when they appear (OpenWindowKeeper);
    // nil until one of them has. On the main thread only.
    static var openStatusWindow: (() -> Void)?

    // The RMNet window while it is open: marked by its view when the view moves into it, cleared when it closes
    // (WindowVisibilityObserver). On the main thread only.
    static weak var statusWindow: NSWindow?

    // Shows the RMNet window (windowReopen in WindowVisibility.swift): the window itself when it is open, found
    // among the app's windows, deminiaturized if minimized, made key and ordered front; else `open`, SwiftUI's
    // openWindow; then the app is made active. False when there is neither, and nothing was done.
    static func showStatusWindow(using open: (() -> Void)?) -> Bool {
        let window = statusWindow.flatMap { marked in NSApp.windows.first(where: { $0 === marked }) }
        let way = windowReopen(windowFound: window != nil, minimized: window?.isMiniaturized == true,
                               actionAvailable: open != nil)
        switch way {
        case .bringForward(let deminiaturize):
            if deminiaturize { window?.deminiaturize(nil) }
            window?.makeKeyAndOrderFront(nil)
        case .openWithAction:
            open?()
        case .leaveToAppKit:
            return false
        }
        NSApp.activate()
        return way.handled
    }

    // A click on the Dock icon, or `open /Applications/RMNet.app` while RMNet runs: shows the window as `Open
    // RMNet` does. `hasVisibleWindows` is not trusted: the menu bar item's own windows can count as visible while
    // the RMNet window is closed. False: shown here. True (no open window and no openWindow kept, which should
    // not happen, since the window opens at launch): AppKit's and SwiftUI's own handling.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !AppDelegate.showStatusWindow(using: AppDelegate.openStatusWindow)
    }

    // Every way of quitting (Cmd-Q, the Dock's Quit, `Quit RMNet` in the menu bar item's panel, logout) comes
    // here. With a call to the modem running, the app ends only when it has finished; a send is never cut
    // short. A send, delete or change that does not succeed cancels the quit, so that its result can be read.
    // While it waits, the window shows why above its tabs (and the panel above its buttons); so a quit that
    // waits opens the window, or brings it forward, when it cannot be seen (quitShowsWindow).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let waits = quitGate.ask()
        if quitShowsWindow(waits: waits, windowSeen: AppDelegate.statusWindowSeen) {
            _ = AppDelegate.showStatusWindow(using: AppDelegate.openStatusWindow)
        }
        return waits ? .terminateLater : .terminateNow
    }

    // The RMNet window is open and some of it can be seen (not minimized, hidden or covered).
    private static var statusWindowSeen: Bool {
        guard let window = statusWindow.flatMap({ marked in NSApp.windows.first(where: { $0 === marked }) }) else {
            return false
        }
        return window.isVisible && window.occlusionState.contains(.visible)
    }
}

// What the window knows of the system's listing.
enum ListingState {
    case asking            // no answer yet since the window opened
    case known             // the last properties request answered with a listing
    case unknown(String)   // the last one failed, ended without a listing, or was not answered in 10 s
}

// Keeps the status and runs the requests. Every message about an install or a removal comes from
// the request's own answer, and says "installed" only when the listing, read again, agrees. The app has one
// (AppDelegate.driverStatus), refreshed by the window's poll (WindowPolls) every 2 s while the Overview or the
// Driver screen is shown and the window can be seen.
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

extension StatusController {
    /// The connection's headline for the Overview, as the menu bar's panel decides it (menuBarHeadline): with the
    /// system's listing, the Driver screen's headline; with the driver attached and no listing (not answered yet,
    /// or none given), the headline for its state (Connected only while its link is up); with neither, `Asking the
    /// system…` until the system answers, `Unknown` while it gives no listing.
    var connectionHeadline: String {
        let answered: Bool
        if case .asking = listing { answered = false } else { answered = true }
        return menuBarHeadline(driver: status.attached ? status.properties : nil, modem: status.modem,
                               model: status.modemModel, answered: answered, entries: known ? status.entries : nil)
    }
}
