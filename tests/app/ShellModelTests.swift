// Tests for app/ShellModel.swift: the window's screens (their names, symbols, storage keys and what each one
// reads), the repeating polls the shell starts and stops (the driver's status on the Overview and Driver
// screens, the throughput on the Overview and Network screens, each only while the window can be seen), the
// status pill for every headline StatusModel.swift gives, and the addresses as the Overview lists them. Built
// with swiftc by `make app-test` from app/StatusModel.swift, app/ModemNetwork.swift, app/ModemSettings.swift,
// app/ModemController.swift, app/ShellModel.swift and this file; no AppKit, no window, no registry.
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

/// The poll's repeating timer (its private `timer`), found by reflection; nil when none runs.
func timer(of poll: RepeatingPoll) -> Timer? {
    Mirror(reflecting: poll).children.first(where: { $0.label == "timer" }).flatMap { $0.value as? Timer }
}

/// The timer is scheduled in the main run loop's common modes (so it turns while a menu or a sheet is open).
func scheduled(_ t: Timer?) -> Bool {
    guard let t else { return false }
    return CFRunLoopContainsTimer(CFRunLoopGetMain(), unsafeBitCast(t, to: CFRunLoopTimer.self), .commonModes)
}

@main
struct ShellModelTests {
    static func main() {
        screens()
        polls()
        windowPolls()
        pills()
        addresses()
        print("shell model: \(checks) checks passed")
    }

    static func screens() {
        let all = Screen.allCases
        equal(all, [.overview, .messages, .network, .simData, .driver], "screens: the sidebar's order")
        equal(all.map { $0.rawValue }, ["overview", "messages", "network", "simData", "driver"],
              "screens: the keys the selection is kept under")
        equal(all.map { $0.title }, ["Overview", "Messages", "Network", "SIM & Data", "Driver"], "screens: titles")
        equal(all.map { $0.symbol }, ["antenna.radiowaves.left.and.right", "message", "cellularbars", "simcard",
                                      "puzzlepiece.extension"], "screens: symbols")
        equal(all.map { $0.modemTab }, [.overview, nil, .network, .simAndApn, nil], "screens: what the modem reads")
        equal(all.map { $0.listsMessages }, [false, true, false, false, false], "screens: the messages are listed")
        equal(all.map { $0.readsDriverStatus }, [true, false, false, false, true], "screens: the driver's status")
        equal(all.map { $0.samplesThroughput }, [true, false, true, false, false], "screens: the throughput")
        check(Screen(rawValue: "status") == nil && Screen(rawValue: "simAndApn") == nil,
              "screens: an unknown key is no screen")
    }

    // Started: the action at once, then every interval, in the main run loop's common modes; starting it again
    // does nothing; stopped: the timer is invalidated and the action no longer runs.
    static func polls() {
        var ran = 0
        let poll = RepeatingPoll(every: 2) { ran += 1 }
        check(!poll.isRunning && ran == 0 && timer(of: poll) == nil, "poll: nothing before it is started")
        equal(poll.interval, 2, "poll: its interval")
        poll.run(true)
        check(poll.isRunning && ran == 1, "poll: runs at once when started")
        check(timer(of: poll)?.timeInterval == 2 && scheduled(timer(of: poll)), "poll: then every 2 s, in the common modes")
        poll.run(true)
        check(ran == 1 && poll.isRunning, "poll: starting a running poll does not run it again")
        timer(of: poll)?.fire()
        equal(ran, 2, "poll: each turn runs it")
        let t = timer(of: poll)
        poll.run(false)
        check(!poll.isRunning && t?.isValid == false && timer(of: poll) == nil && ran == 2, "poll: stopped")
        poll.run(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        equal(ran, 2, "poll: nothing runs once stopped")
    }

    // The driver's status on the Overview and Driver screens, the throughput on the Overview and Network screens,
    // each only while the window can be seen; nothing with no screen. A poll that goes on from one screen to the
    // next is not started again.
    static func windowPolls() {
        var status = 0
        var throughput = 0
        let p = WindowPolls(driverStatus: RepeatingPoll(every: 2) { status += 1 },
                            throughput: RepeatingPoll(every: 1) { throughput += 1 })
        func running() -> [Bool] { [p.driverStatus.isRunning, p.throughput.isRunning] }
        equal(running(), [false, false], "window polls: nothing before a screen is shown")
        p.setWindowVisible(true)
        equal(running(), [false, false], "window polls: nothing with the window seen and no screen")
        p.setScreen(.overview)
        check(running() == [true, true] && status == 1 && throughput == 1, "window polls: the Overview runs both at once")
        p.setScreen(.driver)
        check(running() == [true, false] && status == 1, "window polls: the Driver screen keeps the status poll going")
        p.setScreen(.network)
        check(running() == [false, true] && throughput == 2, "window polls: the Network screen samples the throughput")
        p.setScreen(.messages)
        equal(running(), [false, false], "window polls: Messages runs neither")
        p.setScreen(.simData)
        equal(running(), [false, false], "window polls: SIM & Data runs neither")
        p.setScreen(.overview)
        check(running() == [true, true] && status == 2 && throughput == 3, "window polls: the Overview again")
        p.setScreen(.overview)
        check(status == 2 && throughput == 3, "window polls: the same screen again starts nothing")
        p.setWindowVisible(false)
        equal(running(), [false, false], "window polls: nothing while the window cannot be seen")
        p.setScreen(.driver)
        equal(running(), [false, false], "window polls: a screen shown while hidden runs nothing")
        p.setWindowVisible(true)
        check(running() == [true, false] && status == 3, "window polls: seen again, the screen's poll runs at once")
        p.setScreen(nil)
        equal(running(), [false, false], "window polls: nothing once the window's view goes")
        p.setWindowVisible(true)
        equal(running(), [false, false], "window polls: still nothing with no screen")
    }

    static func status(_ entries: [ExtensionEntry], attached: Bool = false, state: String? = nil,
                       modem: ModemState = .absent) -> DriverStatus {
        DriverStatus(entries: entries, modem: modem, attached: attached,
                     properties: state.map { ["RMNetState": $0] } ?? [:])
    }

    // Every headline headline() gives, and the two the window shows before or without the system's answer.
    static func pills() {
        let on = ExtensionEntry(version: "318.19.40", enabled: true, awaitingApproval: false, uninstalling: false)
        let waiting = ExtensionEntry(version: "318.19.40", enabled: false, awaitingApproval: true, uninstalling: false)
        let cases: [(DriverStatus, String, ConnectionState, String)] = [
            (status([]), "Not installed", .down, "Not installed"),
            (status([on, on]), "Needs attention", .attention, "Needs attention"),
            (status([waiting]), "Waiting for approval in System Settings", .attention, "Waiting for approval"),
            (status([on], attached: true, state: "up"), "Connected", .connected, "Connected"),
            (status([on], attached: true, state: "refreshing"), "Connected", .connected, "Connected"),
            (status([on], attached: true, state: "connecting"), "Connecting", .connecting, "Connecting…"),
            (status([on], attached: true), "Connecting", .connecting, "Connecting…"),
            (status([on], attached: true, state: "backoff"), "Link down", .down, "Not connected"),
            (status([on]), "Installed, modem not attached", .down, "Modem not attached"),
            (status([on], modem: .notQMI), "Modem is not in QMI mode", .attention, "Not in QMI mode"),
            (status([on], modem: .qmi(interface: 4)), "Connecting", .connecting, "Connecting…"),
        ]
        for (s, words, state, text) in cases {
            equal(headline(s), words, "pills: the headline \(words)")
            let pill = connectionPill(words)
            check(pill.state == state && pill.text == text, "pills: \(words)", "got \(pill)")
        }
        let asking = connectionPill("Asking the system…")
        check(asking.state == .down && asking.text == "Checking…", "pills: before the system answers", "got \(asking)")
        let unknown = connectionPill(unknownHeadline)
        check(unknown.state == .error && unknown.text == "Status unknown", "pills: with no listing", "got \(unknown)")
        let other = connectionPill("Something new")
        check(other.state == .attention && other.text == "Something new", "pills: a headline not known here, as given")
        check(ConnectionState.connected != .connecting, "pills: states differ")
    }

    // The driver's addresses as rows: the IPv4 address without its gateway, the IPv6 address; "none", an empty
    // value and a missing one left out.
    static func addresses() {
        func rows(_ p: [String: String]) -> [String] { addressRows(p).map { "\($0.label)=\($0.value)" } }
        equal(rows(["RMNetIPv4": "10.62.238.140/29 gw 10.62.238.141", "RMNetIPv6": "2001:db8::1/64"]),
              ["IPv4=10.62.238.140/29", "IPv6=2001:db8::1/64"], "addresses: both, without the gateway")
        equal(rows(["RMNetIPv4": "10.0.0.2/30", "RMNetIPv6": "none"]), ["IPv4=10.0.0.2/30"], "addresses: none is left out")
        equal(rows(["RMNetIPv4": "", "RMNetIPv6": "2001:db8::2/64"]), ["IPv6=2001:db8::2/64"], "addresses: empty is left out")
        equal(rows(["RMNetState": "up"]), [], "addresses: none listed")
    }
}
