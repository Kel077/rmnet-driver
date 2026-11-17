// The window's screens (its sidebar, StatusView.swift), what each one reads while it is shown and the window can
// be seen, the two polls the window starts and stops for them (the driver's status, the throughput), the status
// pill for a headline, and the driver's addresses as rows. Foundation only (with ModemController.swift's
// ModemTab), so `make app-test` tests it (tests/app/ShellModelTests.swift).
import Foundation

/// The window's screens, in the sidebar's order. The raw value is the key the selection is kept under across
/// launches (@SceneStorage), so it never changes.
enum Screen: String, CaseIterable, Identifiable {
    case overview, messages, network, simData, driver

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .messages: return "Messages"
        case .network: return "Network"
        case .simData: return "SIM & Data"
        case .driver: return "Driver"
        }
    }

    /// The SF Symbol in the sidebar.
    var symbol: String {
        switch self {
        case .overview: return "antenna.radiowaves.left.and.right"
        case .messages: return "message"
        case .network: return "cellularbars"
        case .simData: return "simcard"
        case .driver: return "puzzlepiece.extension"
        }
    }

    /// What ModemController reads while this screen is shown (setTabShown); nil: nothing.
    var modemTab: ModemTab? {
        switch self {
        case .overview: return .overview
        case .network: return .network
        case .simData: return .simAndApn
        case .messages, .driver: return nil
        }
    }

    /// SmsController lists the messages (setTabShown(true)).
    var listsMessages: Bool { self == .messages }
    /// The driver's status is polled every 2 s (StatusController.refresh: the registry and the system's listing).
    var readsDriverStatus: Bool { self == .overview || self == .driver }
    /// The driver's byte counters are sampled every second (ThroughputSampler; the registry only).
    var samplesThroughput: Bool { self == .overview || self == .network }
}

/// An action run at once when the poll starts, then every `interval` on the main run loop (in its common modes,
/// so it goes on while a menu or a sheet is open) until it stops. On the main thread only.
final class RepeatingPoll {
    let interval: TimeInterval
    private let action: () -> Void
    private var timer: Timer?

    init(every interval: TimeInterval, action: @escaping () -> Void) {
        self.interval = interval
        self.action = action
    }

    deinit { timer?.invalidate() }

    var isRunning: Bool { timer != nil }

    /// Starts it (the action runs now) or stops it; starting a running poll, or stopping a stopped one, does nothing.
    func run(_ on: Bool) {
        if on {
            guard timer == nil else { return }
            let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.action() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            action()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }
}

/// The window's polls that are not the modem's: the driver's status (the Overview and Driver screens) and the
/// throughput (the Overview and Network screens), each only while its screen is shown and the window can be seen.
/// The window tells it the screen shown (nil when its view goes) and whether it can be seen (WindowVisibility.swift).
/// A poll that goes on from one screen to the next is not started again. On the main thread only.
final class WindowPolls {
    let driverStatus: RepeatingPoll
    let throughput: RepeatingPoll
    private var screen: Screen? = nil
    private var windowVisible = true

    init(driverStatus: RepeatingPoll, throughput: RepeatingPoll) {
        self.driverStatus = driverStatus
        self.throughput = throughput
    }

    func setScreen(_ screen: Screen?) {
        self.screen = screen
        update()
    }

    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        update()
    }

    private func update() {
        let shown = windowVisible ? screen : nil
        driverStatus.run(shown?.readsDriverStatus ?? false)
        throughput.run(shown?.samplesThroughput ?? false)
    }
}

/// What a status pill shows (DesignKit.swift draws it): connected (green), connecting (yellow, pulsing), down or
/// not installed (gray), something to do (orange: waiting for approval, not in QMI mode), error (red: the system
/// gave no listing).
enum ConnectionState: Equatable {
    case connected, connecting, down, attention, error
}

/// The pill for a headline of StatusModel.swift (headline(), unknownHeadline, or "Asking the system…" before the
/// system answers), and its short words. A headline not known here is shown as it is, as something to do.
func connectionPill(_ headline: String) -> (state: ConnectionState, text: String) {
    switch headline {
    case "Connected": return (.connected, "Connected")
    case "Connecting": return (.connecting, "Connecting…")
    case "Link down": return (.down, "Not connected")
    case "Not installed": return (.down, "Not installed")
    case "Installed, modem not attached": return (.down, "Modem not attached")
    case "Asking the system…": return (.down, "Checking…")
    case "Waiting for approval in System Settings": return (.attention, "Waiting for approval")
    case "Modem is not in QMI mode": return (.attention, "Not in QMI mode")
    case "Needs attention": return (.attention, "Needs attention")
    case unknownHeadline: return (.error, "Status unknown")
    default: return (.attention, headline)
    }
}

/// The driver's addresses as label and value: the IPv4 address without its gateway ("10.62.238.140/29 gw
/// 10.62.238.141" is "10.62.238.140/29"), then the IPv6 address; "none", an empty value and a missing one are
/// left out (menuBarAddressLines' rule).
func addressRows(_ properties: [String: String]) -> [(label: String, value: String)] {
    var rows: [(label: String, value: String)] = []
    for (key, label) in [("RMNetIPv4", "IPv4"), ("RMNetIPv6", "IPv6")] {
        guard let value = properties[key], !value.isEmpty, value != "none" else { continue }
        let address = value.components(separatedBy: " gw ")[0]
        if !address.isEmpty { rows.append((label: label, value: address)) }
    }
    return rows
}
