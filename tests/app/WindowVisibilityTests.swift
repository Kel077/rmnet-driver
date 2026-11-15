// Tests for app/WindowVisibility.swift: what the window's modem tabs are told about the RMNet window
// (setWindowVisible), from that window's own notifications only; how the window is shown again; and when a
// quit shows it. The window and the app's other windows (the
// menu bar item's panel, the status item's own window) are plain objects posting on a private notification
// center; no AppKit, no window. Built with swiftc by `make app-test`.
// Stops at the first failure, prints which check failed and exits 1.
import Foundation

var checks = 0

func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if !ok {
        print("FAIL: \(name)")
        let d = detail()
        if !d.isEmpty { print("  \(d)") }
        exit(1)
    }
}

func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    check(got == want, name, "got \(got)\nwant \(want)")
}

let occlusionName = Notification.Name("test.occlusionChanged")
let closeName = Notification.Name("test.willClose")

/// A window as the tracker sees it: an object that posts, and its own occlusion state.
final class FakeWindow {
    var visible = false
    let center: NotificationCenter
    init(_ center: NotificationCenter) { self.center = center }
    func occlusionChanged(_ v: Bool) { visible = v; center.post(name: occlusionName, object: self) }
    func close() { center.post(name: closeName, object: self) }
}

/// A tracker on a private center, and every visibility it reported (what setWindowVisible would get).
final class Rig {
    let center = NotificationCenter()
    var reports: [Bool] = []
    var tracker: WindowVisibility!
    init() {
        tracker = WindowVisibility(center: center, occlusionChanged: occlusionName, willClose: closeName) { [unowned self] in
            self.reports.append($0)
        }
    }
    func window(visible: Bool = false) -> FakeWindow {
        let w = FakeWindow(center)
        w.visible = visible
        return w
    }
    func follow(_ w: FakeWindow?) { tracker.follow(w, visible: { [weak w] in w?.visible ?? false }) }
}

@main
struct WindowVisibilityTests {
    static func main() {
        followsItsOwnWindow()
        otherWindowsDoNotCount()
        closing()
        leavingAndSwitching()
        reopening()
        quitting()
        print("window visibility: \(checks) checks passed")
    }

    // The window's state is reported when it is followed, then each change of it, once each.
    static func followsItsOwnWindow() {
        let rig = Rig()
        let w = rig.window(visible: false)
        rig.follow(w)
        equal(rig.reports, [false], "follow: the state now (not on screen yet)")
        w.occlusionChanged(true)
        equal(rig.reports, [false, true], "occlusion: visible")
        w.occlusionChanged(true)
        equal(rig.reports, [false, true], "occlusion: the same state is not reported again")
        w.occlusionChanged(false)   // covered, hidden (Cmd-H) or minimized
        equal(rig.reports, [false, true, false], "occlusion: not visible")

        let shown = Rig()
        let v = shown.window(visible: true)
        shown.follow(v)
        equal(shown.reports, [true], "follow: a window already on screen")
    }

    // The menu bar item's panel and the status item's own window post the same notifications for themselves:
    // they never change what the RMNet window's tabs are told (NSApp.occlusionState would count them).
    static func otherWindowsDoNotCount() {
        let rig = Rig()
        let w = rig.window(visible: true)
        let panel = rig.window()
        let statusItemWindow = rig.window()
        rig.follow(w)
        w.occlusionChanged(false)
        equal(rig.reports, [true, false], "others: the window is hidden")
        panel.occlusionChanged(true)
        statusItemWindow.occlusionChanged(true)
        equal(rig.reports, [true, false], "others: the panel or the status item showing does not count")
        w.occlusionChanged(true)
        panel.occlusionChanged(false)
        panel.close()
        statusItemWindow.close()
        equal(rig.reports, [true, false, true], "others: the panel closing does not count")
        rig.center.post(name: occlusionName, object: nil)
        rig.center.post(name: closeName, object: nil)
        equal(rig.reports, [true, false, true], "others: a notification for no window does not count")
    }

    // Closing the window is not visible, even before its occlusion state says so; shown again (the same
    // window reopened), it is visible again.
    static func closing() {
        let rig = Rig()
        let w = rig.window(visible: true)
        rig.follow(w)
        w.close()
        equal(rig.reports, [true, false], "close: not visible")
        w.occlusionChanged(false)
        equal(rig.reports, [true, false], "close: then occluded, nothing new")
        w.occlusionChanged(true)
        equal(rig.reports, [true, false, true], "close: the same window shown again")
    }

    // A Dock click, a second launch or `Open RMNet`: the RMNet window when it is open (deminiaturized first when
    // minimized), whether or not an openWindow action is kept; else the action; else AppKit's own handling.
    static func reopening() {
        for action in [true, false] {
            equal(windowReopen(windowFound: true, minimized: false, actionAvailable: action), .bringForward(deminiaturize: false),
                  "reopen: an open window is brought forward (action \(action))")
            equal(windowReopen(windowFound: true, minimized: true, actionAvailable: action), .bringForward(deminiaturize: true),
                  "reopen: a minimized window is deminiaturized first (action \(action))")
        }
        for minimized in [true, false] {
            equal(windowReopen(windowFound: false, minimized: minimized, actionAvailable: true), .openWithAction,
                  "reopen: no window, the kept action opens it (minimized \(minimized))")
            equal(windowReopen(windowFound: false, minimized: minimized, actionAvailable: false), .leaveToAppKit,
                  "reopen: no window and no action, AppKit's own handling (minimized \(minimized))")
        }
        check(WindowReopen.leaveToAppKit.handled == false, "reopen: AppKit's handling is not handled here")
        check(WindowReopen.openWithAction.handled && WindowReopen.bringForward(deminiaturize: false).handled,
              "reopen: the other two are")
    }

    // A quit that waits for a call to the modem shows the RMNet window when it cannot be seen (closed, minimized,
    // hidden or covered), so that its line says why RMNet has not quit yet; a quit that ends at once, or a window
    // in view, is left alone.
    static func quitting() {
        check(quitShowsWindow(waits: true, windowSeen: false), "quit: waits, the window not seen: shown")
        check(!quitShowsWindow(waits: true, windowSeen: true), "quit: waits, the window in view: left alone")
        check(!quitShowsWindow(waits: false, windowSeen: false), "quit: ends at once, the window closed: not opened")
        check(!quitShowsWindow(waits: false, windowSeen: true), "quit: ends at once, the window in view: left alone")
    }

    // Leaving the window (the view taken out of it) is not visible, and its later notifications are not
    // followed; following another window follows only that one; a tracker that is gone follows nothing.
    static func leavingAndSwitching() {
        let rig = Rig()
        let first = rig.window(visible: true)
        rig.follow(first)
        rig.follow(nil)
        equal(rig.reports, [true, false], "leave: not visible")
        first.occlusionChanged(true)
        first.occlusionChanged(false)
        equal(rig.reports, [true, false], "leave: the old window is not followed")

        let second = rig.window(visible: true)
        rig.follow(first)
        rig.follow(second)
        equal(rig.reports, [true, false, true], "switch: the second window's state")
        first.occlusionChanged(false)
        first.close()
        equal(rig.reports, [true, false, true], "switch: the first window is no longer followed")
        second.occlusionChanged(false)
        equal(rig.reports, [true, false, true, false], "switch: the second window is")

        var gone: Rig? = Rig()
        let w = gone!.window(visible: true)
        gone!.follow(w)
        let center = gone!.center
        gone!.tracker = nil   // the observer view went away
        center.post(name: occlusionName, object: w)
        center.post(name: closeName, object: w)
        equal(gone!.reports, [true], "gone: nothing reported after the tracker is gone")
        gone = nil
    }
}
