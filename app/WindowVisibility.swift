// Whether the RMNet window can be seen, for its Messages and modem tabs, which read the AT port only while
// it can (their controllers' setWindowVisible). It follows that one window's own notifications: its occlusion
// state changing, and its closing. The app's other windows (the menu bar item's panel, the status item's own
// window) post the same notifications for themselves and are not followed: NSApp.occlusionState, which counts
// every window of the app, would keep the tabs reading the port while the RMNet window is covered, hidden
// (Cmd-H), minimized or closed but the panel is open or the status item counts as visible.
//
// Foundation only, so `make app-test` tests it without AppKit (tests/app/WindowVisibilityTests.swift): the
// window is any object, and the notification names and its occlusion state are given by the window's view
// (StatusView.swift).
import Foundation

/// The app has one per RMNet window, made by the view inside it. Notifications are taken on the thread
/// that posts them (AppKit posts these on the main thread).
final class WindowVisibility {
    private let center: NotificationCenter
    private let occlusionChanged: Notification.Name
    private let willClose: Notification.Name
    private let report: (Bool) -> Void
    private var tokens: [NSObjectProtocol] = []
    private var reported: Bool?

    /// `report` gets each change: true when some part of the window can be seen, false otherwise (also when
    /// it closes, or the view leaves it). The first state is always reported.
    init(center: NotificationCenter = .default, occlusionChanged: Notification.Name, willClose: Notification.Name,
         report: @escaping (Bool) -> Void) {
        self.center = center
        self.occlusionChanged = occlusionChanged
        self.willClose = willClose
        self.report = report
    }

    deinit { stopFollowing() }

    /// Follows `window` from now on, and no other (nil: none, which is not visible), and reports its state
    /// now. `visible` reads its occlusion state. A closed window shown again is visible again.
    func follow(_ window: AnyObject?, visible: @escaping () -> Bool) {
        stopFollowing()
        guard let window else {
            set(false)
            return
        }
        tokens.append(center.addObserver(forName: occlusionChanged, object: window, queue: nil) { [weak self] _ in
            self?.set(visible())
        })
        tokens.append(center.addObserver(forName: willClose, object: window, queue: nil) { [weak self] _ in
            self?.set(false)
        })
        set(visible())
    }

    private func stopFollowing() {
        for token in tokens { center.removeObserver(token) }
        tokens = []
    }

    private func set(_ visible: Bool) {
        guard visible != reported else { return }
        reported = visible
        report(visible)
    }
}
