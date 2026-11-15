// The menu bar item (a MenuBarExtra in RMNetApp, StatusView.swift): its icon, and the panel it opens with the
// Driver tab's headline, the addresses while the link is up, a few lines about the network read over the AT
// port when the panel opens, `Open RMNet` and `Quit RMNet`. MenuBarStatus (MenuBarStatus.swift) holds the
// state and decides when the port is read; this file only shows it.
import AppKit
import SwiftUI

extension MenuBarStatus {
    /// The app's one: the registry and the system's listing from launch and every 5 s, and the network read
    /// with ModemService on `queue`, the queue the window's tabs share for the AT port.
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
        status.start()
        return status
    }
}

/// The panel, about 280 pt wide.
struct MenuBarPanel: View {
    @ObservedObject var status: MenuBarStatus
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
            HStack {
                Button("Open RMNet") {
                    openWindow(id: "status")
                    NSApp.activate()
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
/// launch. Calls `hidden` when it is no longer on screen (it resigns key and goes, its occlusion state is
/// no longer visible, or the view leaves it), so that the model stops asking for the listing.
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
                onHidden()
                return
            }
            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didChangeOcclusionStateNotification] {
                tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.check()
                })
            }
            check()
        }

        private func check() {
            if let window, window.isVisible, window.occlusionState.contains(.visible) { onShown() } else { onHidden() }
        }

        private func stopObserving() {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            tokens = []
        }
    }
}
