// The menu bar item's state: an icon saying whether the modem's connection is up and, for its panel, the
// Driver tab's headline, the driver's addresses and a few lines about the network. Foundation only, so
// `make app-test` builds it without AppKit or SwiftUI (tests/app/MenuBarStatusTests.swift); the item and
// its panel are in MenuBarView.swift.
//
// The icon, the headline and the addresses come from the I/O registry (the driver's RMNet* properties and
// the modem on USB), read every 5 s (`poll`), and from the system's listing of the driver, asked only when it
// is needed: while the panel is open (for its headline), and while the registry shows no driver (to tell no
// driver from waiting for approval) at once and then every 12th poll, about once a minute. With the driver
// attached the headline comes from the registry until the listing answers. Never from the AT port. The
// network lines come from the modem's spare AT port, read once when the panel opens (`panelOpened`) and not
// again until 10 s after the last read finished, on the queue the window's tabs use, so that the app never
// opens the port twice at once. Nothing read is logged or stored.
import Foundation

/// The driver's RMNet* registry properties, as strings (readDriverProperties in Registry.swift).
typealias DriverProperties = [String: String]

/// What the item shows in the menu bar.
enum MenuBarIcon: Equatable {
    case up                   // the driver is attached and its link is up (RMNetState up or refreshing)
    case down                 // the driver is attached and its link is not up
    case noDriver             // no driver in the registry (not installed, not loaded, or no modem)
    case waitingForApproval   // no driver in the registry, and the system's listing waits for approval

    var symbolName: String {
        self == .up ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
    }

    var accessibilityLabel: String {
        switch self {
        case .up: return "RMNet: connected"
        case .down: return "RMNet: not connected"
        case .noDriver: return "RMNet: no driver"
        case .waitingForApproval: return "RMNet: waiting for approval"
        }
    }
}

/// The icon: while the driver is attached, its link decides (the listing then cannot hide a connection that
/// is up, as during an update waiting for approval while the old build runs); without it, the listing says
/// whether an approval is awaited. `entries` nil: the system gave no listing.
func menuBarIcon(properties: DriverProperties?, entries: [ExtensionEntry]?) -> MenuBarIcon {
    guard let properties else {
        return entries?.contains(where: { $0.awaitingApproval }) == true ? .waitingForApproval : .noDriver
    }
    return upStates.contains(properties["RMNetState"] ?? "") ? .up : .down
}

/// The addresses as the driver gives them, without the IPv4 gateway ("10.62.238.140/29 gw 10.62.238.141" is
/// shown as "IPv4 10.62.238.140/29"); "none" and an empty value are left out.
func menuBarAddressLines(_ properties: DriverProperties) -> [String] {
    var lines: [String] = []
    for (key, name) in [("RMNetIPv4", "IPv4"), ("RMNetIPv6", "IPv6")] {
        guard let value = properties[key], !value.isEmpty, value != "none" else { continue }
        let address = value.components(separatedBy: " gw ")[0]
        if !address.isEmpty { lines.append("\(name) \(address)") }
    }
    return lines
}

/// The panel's network lines from a read: the technology with its band or bands ("5G SA, band n41"), the
/// operator as `RMNet network` gives it ("CHINA MOBILE, PLMN 46000"), and the signal once a leg ("RSRP
/// -86 dBm, SINR 10 dB"; on EN-DC "LTE: …" and "5G: …"). The band and operator are networkRows' own values.
func menuBarNetworkLines(_ info: NetworkInfo) -> [String] {
    let rows = networkRows(info)
    func row(_ label: String) -> String? { rows.first(where: { $0.label == label })?.value }

    var technology: String
    if info.radio == .airplane {
        technology = "Radio off (airplane mode)"
    } else {
        let label = technologyLabel(info)
        technology = label == "unknown" ? "Technology unknown" : label.prefix(1).uppercased() + label.dropFirst()
        if let band = row("Band") {
            technology += (band.contains(" + ") ? ", bands " : ", band ") + band
        }
    }
    var lines = [technology]
    if let op = row("Operator") { lines.append(op) }
    let legs = info.serving?.cells ?? []
    for leg in legs {
        let signal = menuBarSignal(leg)
        if signal.isEmpty { continue }
        lines.append(legs.count > 1 ? "\(leg.rat.hasPrefix("NR5G") ? "5G" : leg.rat): \(signal)" : signal)
    }
    return lines
}

/// RSRP (RSCP for WCDMA) and SINR, in `RMNet network`'s words.
private func menuBarSignal(_ leg: CellLeg) -> String {
    var parts: [String] = []
    if let v = leg.rsrp { parts.append("\(leg.rat == "WCDMA" ? "RSCP" : "RSRP") \(v) dBm") }
    if let v = leg.sinr { parts.append("SINR \(v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v)) dB") }
    return parts.joined(separator: ", ")
}

/// What the panel's window just did, as its observer (MenuBarView.swift) sees it: the observer's view moved
/// into it or out of it, it became or resigned key, or its occlusion state changed.
enum MenuBarPanelEvent { case attached, detached, becameKey, resignedKey, occlusionChanged }

/// What the observer then tells the model: the panel is shown (panelOpened) or hidden (panelClosed).
enum MenuBarPanelSignal: Equatable { case shown, hidden }

/// Shown only while the window is on screen (visible, with its occlusion state visible), and never on
/// resigning key: the panel resigns key as it closes (a click outside it, `Open RMNet` making the RMNet window
/// key) while it may still be on screen, and no read may start then; its order-out changes the occlusion state,
/// which says hidden. Hidden when it is off screen or the view left it; nil: nothing to tell.
func menuBarPanelSignal(_ event: MenuBarPanelEvent, onScreen: Bool) -> MenuBarPanelSignal? {
    switch event {
    case .detached: return .hidden
    case .resignedKey: return onScreen ? nil : .hidden
    case .becameKey: return onScreen ? .shown : nil
    case .attached, .occlusionChanged: return onScreen ? .shown : .hidden
    }
}

let menuBarReadingLine = "Reading the modem…"
let menuBarBusyNote = "The modem's AT port is busy; open the panel again in a moment."

/// The note after a read that failed, and whether the modem is gone (its last lines then mean nothing). A
/// busy port and a modem not attached are told apart by the service's own sentence for a port that did not
/// open (ModemService.networkInfo gives describe(error) for it, and nothing else).
func menuBarNetworkNote(_ failure: ModemFailure) -> (note: String, modemGone: Bool) {
    switch failure.message {
    case describe(AtError.busy): return (menuBarBusyNote, false)
    case describe(AtError.modemNotAttached): return (failure.message, true)
    default: return ("The network could not be read. \(failure.message)", false)
    }
}

private let asOfFormat: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm:ss"
    return f
}()

/// "as of HH:mm:ss", in the Mac's time zone.
func asOfText(_ date: Date) -> String {
    "as of \(asOfFormat.string(from: date))"
}

/// The Driver tab's words before the system first answers (StatusView.swift).
private let askingHeadline = "Asking the system…"

/// headline() of StatusModel.swift, by another name: inside MenuBarStatus `headline` is the property.
private func driverHeadline(_ status: DriverStatus) -> String {
    headline(status)
}

/// The panel's headline: with the system's last fresh answer (`entries`, nil: none yet, or no listing), the
/// Driver tab's; with the driver attached and no such answer, the Driver tab's headline for an attached driver
/// whose one listed entry is enabled (`Connected`, `Connecting` or `Link down`, from RMNetState), so that the
/// panel never says `Asking the system…` while the driver runs; with no driver, `Asking the system…` until the
/// system answers, `Unknown` while it gives no listing.
func menuBarHeadline(driver: DriverProperties?, modem: ModemState, model: QuectelModel?, answered: Bool,
                     entries: [ExtensionEntry]?) -> String {
    if answered, let entries {
        return driverHeadline(DriverStatus(entries: entries, modem: modem, modemModel: model, attached: driver != nil,
                                           properties: driver ?? [:]))
    }
    if let driver {
        let running = ExtensionEntry(version: "", enabled: true, awaitingApproval: false, uninstalling: false)
        return driverHeadline(DriverStatus(entries: [running], modem: modem, modemModel: model, attached: true,
                                           properties: driver))
    }
    return answered ? unknownHeadline : askingHeadline
}

/// The app has one, kept by the app delegate (StatusView.swift; MenuBarView.swift makes it). Its methods are
/// called on the main thread; the network read runs on `queue` and its result comes back to the main thread.
final class MenuBarStatus: ObservableObject {
    @Published private(set) var icon = MenuBarIcon.noDriver
    @Published private(set) var headline = askingHeadline
    @Published private(set) var addressLines: [String] = []     // only while the link is up
    @Published private(set) var networkLines: [String] = []     // from the last read that succeeded
    @Published private(set) var networkAt: Date? = nil          // when that read finished
    @Published private(set) var networkNote: String? = nil      // why the last read failed; nil after a success
    @Published private(set) var reading = false                 // a network read runs

    static let pollInterval: TimeInterval = 5
    static let pollTolerance: TimeInterval = 1   // the system may fire a poll up to 1 s late, to save power
    static let listingEvery = 12                 // polls between listing questions while no driver is attached
    static let networkSpacing: TimeInterval = 10

    private let properties: () -> DriverProperties?
    private let modem: () -> (state: ModemState, model: QuectelModel?)
    private let listing: (@escaping ([ExtensionEntry]?) -> Void) -> Void
    private let network: () -> Result<NetworkInfo, ModemFailure>
    private let now: () -> Date
    private let queue: DispatchQueue
    private var timer: Timer?
    private var asking = false              // a listing question is pending
    private var panelOpen = false           // between panelOpened() and panelClosed()
    private var listingAnswered = false     // the system has answered since the listing was last dropped as stale
    private var entries: [ExtensionEntry]? = nil   // that answer; nil: none, or it gave no listing
    private var pollsSinceAsked = 0         // polls since the listing was last asked
    private var driver: DriverProperties? = nil
    private var usb: (state: ModemState, model: QuectelModel?) = (.absent, nil)
    private var lastReadFinished: Date? = nil

    /// `properties`: the driver's registry properties, nil when it is not attached. `modem`: the modem on USB.
    /// `listing`: asks the system for its entries for the driver and answers on the main thread, nil when it
    /// gave none. `network`: the read over the AT port; it blocks, and runs only on `queue`.
    init(properties: @escaping () -> DriverProperties?,
         modem: @escaping () -> (state: ModemState, model: QuectelModel?),
         listing: @escaping (@escaping ([ExtensionEntry]?) -> Void) -> Void,
         network: @escaping () -> Result<NetworkInfo, ModemFailure>,
         now: @escaping () -> Date = { Date() },
         queue: DispatchQueue) {
        self.properties = properties
        self.modem = modem
        self.listing = listing
        self.network = network
        self.now = now
        self.queue = queue
    }

    deinit { timer?.invalidate() }

    /// Polls now and every 5 s from then on (up to 1 s late), in the main run loop's common modes (so the icon
    /// also changes while a menu is open).
    func start() {
        guard timer == nil else { return }
        poll()
        let t = Timer(timeInterval: MenuBarStatus.pollInterval, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = MenuBarStatus.pollTolerance
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Reads the registry; asks the system for its listing too (its answer updates the icon and headline when
    /// it comes), unless a question is pending: on each poll while the panel is open, and while no driver is
    /// attached when there is no fresh answer (at launch, or once the driver has gone away) and then every 12th
    /// poll. With the driver attached and the panel closed the answer is not kept fresh, so it is stale and is
    /// dropped: a driver that goes away later shows no driver until a fresh answer says the system waits for
    /// approval. Never the AT port. On the main thread only.
    func poll() {
        dispatchPrecondition(condition: .onQueue(.main))
        driver = properties()
        usb = modem()
        pollsSinceAsked += 1
        if driver != nil && !panelOpen && !asking {
            listingAnswered = false
            entries = nil
        }
        update()
        let wanted = panelOpen
            || (driver == nil && (!listingAnswered || pollsSinceAsked >= MenuBarStatus.listingEvery))
        guard wanted, !asking else { return }
        asking = true
        pollsSinceAsked = 0
        listing { [weak self] answer in
            guard let self else { return }
            self.asking = false
            self.listingAnswered = true
            self.entries = answer
            self.update()
        }
    }

    /// The panel opened: polls (with the listing), then reads the network unless a read runs or one finished
    /// less than 10 s ago (a clock set back since does not count). On the main thread only.
    func panelOpened() {
        dispatchPrecondition(condition: .onQueue(.main))
        panelOpen = true
        poll()
        guard !reading else { return }
        if let last = lastReadFinished {
            let since = now().timeIntervalSince(last)
            if since >= 0 && since < MenuBarStatus.networkSpacing { return }
        }
        reading = true
        let network = self.network
        queue.async { [weak self] in
            let result = network()
            DispatchQueue.main.async { self?.finishRead(result) }
        }
    }

    /// The panel closed: from now on the listing is asked only while no driver is attached (every 12th poll).
    /// A read that runs finishes. On the main thread only.
    func panelClosed() {
        dispatchPrecondition(condition: .onQueue(.main))
        panelOpen = false
    }

    private func finishRead(_ result: Result<NetworkInfo, ModemFailure>) {
        let at = now()
        lastReadFinished = at
        switch result {
        case .success(let info):
            networkLines = menuBarNetworkLines(info)
            networkAt = at
            networkNote = nil
        case .failure(let failure):
            let (note, modemGone) = menuBarNetworkNote(failure)
            if modemGone {
                networkLines = []
                networkAt = nil
            }
            networkNote = note
        }
        reading = false
    }

    /// Sets what changed only, so that a poll that finds the same state redraws nothing.
    private func update() {
        let newIcon = menuBarIcon(properties: driver, entries: entries)
        let newHeadline = menuBarHeadline(driver: driver, modem: usb.state, model: usb.model, answered: listingAnswered,
                                          entries: entries)
        let newAddresses = newIcon == .up ? menuBarAddressLines(driver ?? [:]) : []
        if icon != newIcon { icon = newIcon }
        if headline != newHeadline { headline = newHeadline }
        if addressLines != newAddresses { addressLines = newAddresses }
    }
}
