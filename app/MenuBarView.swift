// The menu bar item (a MenuBarExtra in RMNetApp, StatusView.swift): its icon (MenuBarLabel), and the panel it
// opens with the Driver tab's headline, the addresses while the link is up, a few lines about the network read
// over the AT port when the panel opens, the window's quit lines while a quit waits, `Open RMNet` and `Quit
// RMNet`. MenuBarStatus (MenuBarStatus.swift) holds the state and decides when the port is read; this file only
// shows it.
import AppKit
import SwiftUI

extension MenuBarStatus {
    /// The app's one, on the registry, the system's listing (asked with a 10 s limit) and the network read with
    /// ModemService on `queue`, the queue the window's tabs share for the AT port. The app delegate starts its
    /// polls at launch (`start`).
    static func forApp(queue: DispatchQueue) -> MenuBarStatus {
        let manager = ExtensionManager()
        let service = ModemService()
        let status = MenuBarStatus(
            properties: { readDriverProperties() },
            modem: { readModemModel() },
            listing: { answer in
                manager.properties(timeout: 10) { reply in
                    if case .listed(let found) = reply { answer(found.map(ExtensionEntry.init)) } else { answer(nil) }
                }
            },
            network: { service.networkInfo() },
            queue: queue)
        return status
    }
}

/// The item's icon in the menu bar: the antenna, struck through unless the link is up; its title, the
/// accessibility label, is not drawn. The only view of the item that observes the model besides the panel.
struct MenuBarLabel: View {
    @ObservedObject var status: MenuBarStatus

    var body: some View {
        Label(status.icon.accessibilityLabel, systemImage: status.icon.symbolName)
            .labelStyle(.iconOnly)
    }
}

/// The panel, about 280 pt wide.
struct MenuBarPanel: View {
    @ObservedObject var status: MenuBarStatus
    // The controllers' quit lines (quitNoticeLines), shown above the buttons while a quit waits: `Quit RMNet`
    // pressed while a send or a change runs says why RMNet has not quit yet.
    @ObservedObject var quitNotice: SmsQuitNotice
    @ObservedObject var modemQuitNotice: ModemQuitNotice
    /// Shows the RMNet window, given the panel's own way of opening it (for when it is not open). The app
    /// passes AppDelegate.showStatusWindow, which brings an open window forward first.
    var showWindow: (_ open: @escaping () -> Void) -> Void = { open in
        open()
        NSApp.activate()
    }
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: status.icon.symbolName)
                    .foregroundStyle(status.icon == .up ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: status.headline)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !status.addressLines.isEmpty {
                Lines(status.addressLines)
                    .textSelection(.enabled)
            }
            if showsNetwork {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    Lines(status.networkLines)
                    if let at = status.networkAt {
                        Text(verbatim: asOfText(at))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if status.reading {
                        Text(verbatim: menuBarReadingLine)
                            .foregroundStyle(.secondary)
                    } else if let note = status.networkNote {
                        // A busy port is not a failure: the connection may well be up.
                        Text(verbatim: note)
                            .foregroundStyle(note == menuBarBusyNote ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider()
            let quitLines = quitNoticeLines(messages: quitNotice.line, modem: modemQuitNotice.line)
            if !quitLines.isEmpty {
                Lines(quitLines)
            }
            HStack {
                Button("Open RMNet") {
                    let open = openWindow
                    showWindow { open(id: "status") }
                }
                Spacer()
                // Through applicationShouldTerminate, so the quit gate still waits for a running send or change.
                Button("Quit RMNet") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(PanelShownObserver(shown: { status.panelOpened() }, hidden: { status.panelClosed() }))
    }

    private var showsNetwork: Bool {
        !status.networkLines.isEmpty || status.reading || status.networkNote != nil
    }
}

/// Lines of text one under the other, wrapped when long.
private struct Lines: View {
    let lines: [String]
    init(_ lines: [String]) { self.lines = lines }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Calls `shown` each time the panel's window comes on screen: when it becomes key (the menu bar panel does
/// when it opens) or becomes visible. Several calls for one opening are harmless: the model reads the port
/// at most once in 10 s. Nothing is called while the panel is not on screen, so the port is not read at
/// launch, and resigning key never calls it (menuBarPanelSignal), so no read starts as the panel closes.
/// Calls `hidden` when it is no longer on screen or the view leaves it, so that the model stops asking for
/// the listing. Whether the panel is on screen is read when the event comes; the call is made on a later turn
/// of the main queue, in order, since the first comes while SwiftUI inserts the view (viewDidMoveToWindow), when
/// the model's published values must not change.
private struct PanelShownObserver: NSViewRepresentable {
    let shown: () -> Void
    let hidden: () -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView(shown: shown, hidden: hidden) }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.onShown = shown
        view.onHidden = hidden
    }

    final class ObserverView: NSView {
        var onShown: () -> Void
        var onHidden: () -> Void   // not `hidden`: NSView has one
        private var tokens: [NSObjectProtocol] = []

        init(shown: @escaping () -> Void, hidden: @escaping () -> Void) {
            onShown = shown
            onHidden = hidden
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        deinit { stopObserving() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else {
                signal(.detached)
                return
            }
            let center = NotificationCenter.default
            let events: [(Notification.Name, MenuBarPanelEvent)] = [
                (NSWindow.didBecomeKeyNotification, .becameKey),
                (NSWindow.didResignKeyNotification, .resignedKey),
                (NSWindow.didChangeOcclusionStateNotification, .occlusionChanged),
            ]
            for (name, event) in events {
                tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.signal(event)
                })
            }
            signal(.attached)
        }

        private func signal(_ event: MenuBarPanelEvent) {
            let onScreen = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
            let call: () -> Void
            switch menuBarPanelSignal(event, onScreen: onScreen) {
            case .shown: call = onShown
            case .hidden: call = onHidden
            case nil: return
            }
            DispatchQueue.main.async { call() }
        }

        private func stopObserving() {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            tokens = []
        }
    }
}
