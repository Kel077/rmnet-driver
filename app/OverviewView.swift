// The window's Overview: the connection at a glance. A hero card (the state in large type, the technology, the
// bars and their word, the operator, the bands, and the addresses while connected); the live throughput (the
// current rates over the last two minutes, and the data since the driver started); the signal (the RSRP over the
// last ten minutes, shaded by quality); then three small cards: the SIM as the SIM & Data screen last read it,
// the unread messages, and the driver, with a call to action when it needs one. With the driver not installed,
// the whole Overview is an empty state whose action installs it.
//
// It reads nothing itself: the shell's polls refresh the driver's status every 2 s and sample the throughput every
// second while it is shown (WindowPolls, ShellModel.swift), ModemController reads the network every 5 s (never the
// bands or the SIM), and the messages are listed only on the Messages screen. Each card observes the object it draws
// and the layout follows the driver's status; only the throughput card observes the sampler, so its turn every
// second redraws that card alone.
import AppKit
import SwiftUI

/// What the shell gives the Overview: the shared controllers, the throughput sampler and a way to show another
/// screen. The root observes none of them.
struct OverviewView: View {
    let driverStatus: StatusController
    let modem: ModemController
    let messages: SmsController
    let throughput: ThroughputSampler
    let navigate: (Screen) -> Void
    /// Install or Update was pressed here: the request's progress line stays shown (in the driver card or the empty
    /// state) after it finishes, until the Overview goes.
    @State private var driverRequested = false

    var body: some View {
        OverviewContent(driverStatus: driverStatus, modem: modem, messages: messages, throughput: throughput,
                        navigate: navigate, driverRequested: $driverRequested)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        driverStatus.refresh()
                        modem.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Read the driver's status and the network again")
                }
            }
    }
}

/// The empty state while the driver is not installed, else the cards.
private struct OverviewContent: View {
    @ObservedObject var driverStatus: StatusController
    let modem: ModemController
    let messages: SmsController
    let throughput: ThroughputSampler
    let navigate: (Screen) -> Void
    @Binding var driverRequested: Bool

    var body: some View {
        if driverStatus.connectionHeadline == "Not installed" {
            NotInstalledState(driverStatus: driverStatus, navigate: navigate, driverRequested: $driverRequested)
        } else {
            ScrollView {
                OverviewCards(driverStatus: driverStatus, modem: modem, messages: messages, throughput: throughput,
                              navigate: navigate, driverRequested: $driverRequested)
                    .padding(Spacing.xl)
                    .frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Layout

/// The cards in a column. From 600 pt wide (the window's default size): the throughput and the signal side by
/// side, then the SIM, the messages and the driver in a row; narrower (down to the window's minimum): one card a
/// row, then the SIM and the messages side by side above the driver. A driver card with advice lines (not in QMI
/// mode: nothing below works until that is done) takes the whole width right under the hero.
private struct OverviewCards: View {
    @ObservedObject var driverStatus: StatusController
    let modem: ModemController
    let messages: SmsController
    let throughput: ThroughputSampler
    let navigate: (Screen) -> Void
    @Binding var driverRequested: Bool
    @State private var width: CGFloat = 0

    var body: some View {
        let wide = width >= 600
        let summary = driverSummary(driverStatus)
        let driver = DriverCard(summary: summary, controller: driverStatus, navigate: navigate,
                                driverRequested: $driverRequested)
        let driverFirst = !summary.lines.isEmpty
        VStack(alignment: .leading, spacing: Spacing.l) {
            OverviewHero(driverStatus: driverStatus, modem: modem, wide: wide)
            if driverFirst {
                driver
            }
            CardRow(across: wide) {
                ThroughputCard(throughput: throughput)
                SignalCard(modem: modem)
            }
            if wide && !driverFirst {
                CardRow {
                    SimCard(modem: modem, navigate: navigate)
                    MessagesCard(messages: messages, navigate: navigate)
                    driver
                }
            } else {
                CardRow {
                    SimCard(modem: modem, navigate: navigate)
                    MessagesCard(messages: messages, navigate: navigate)
                }
                if !driverFirst {
                    driver
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// Cards side by side at the height of the tallest (each card's content takes the height it is given), or one
/// above the other.
private struct CardRow<Content: View>: View {
    var across = true
    @ViewBuilder var content: Content

    var body: some View {
        let layout = across ? AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.l))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.l))
        layout { content }
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Hero

/// The hero: the state in large type (Connected only while the driver's link is up); under it the technology badge,
/// the bars with their word, the operator and the bands as chips (primary first, then the aggregated carriers); the
/// addresses while connected, beside them or below. An operator or bands not known are left out; an unknown signal
/// (nothing read, or no RSRP) is outlined bars and "Signal not known", never "No signal". Washed with the state's
/// colour.
private struct OverviewHero: View {
    @ObservedObject var driverStatus: StatusController
    @ObservedObject var modem: ModemController
    var wide = true

    var body: some View {
        let pill = connectionPill(driverStatus.connectionHeadline)
        let info = modem.info
        let level = info.flatMap(signalLevel)   // nil: not known (outlined bars, "Signal not known")
        let operatorName = info.flatMap { $0.networkName ?? $0.operatorName }
        let bands = info.flatMap(bandText)
        let addresses = pill.state == .connected ? addressRows(driverStatus.status.properties) : []
        let beside = wide && !addresses.isEmpty
        let layout = beside ? AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.l))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.l))
        layout {
            VStack(alignment: .leading, spacing: Spacing.m) {
                StatusPill(state: pill.state, text: pill.text, prominent: true)
                // The signal, then the network on the same line, or on a line of its own when they do not fit.
                let signal = HStack(alignment: .center, spacing: Spacing.s) {
                    if let tech = info.flatMap(techBadgeText) {
                        TechBadge(text: tech)
                    }
                    SignalBars(level: level, height: 14)
                    Text(verbatim: level.map(signalWord) ?? "Signal not known")
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
                let network = HStack(alignment: .center, spacing: Spacing.m) {
                    if let operatorName {
                        Text(verbatim: operatorName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .accessibilityLabel(Text("Operator"))
                            .accessibilityValue(Text(verbatim: operatorName))
                    }
                    if operatorName != nil && bands != nil {
                        HeroDivider()
                    }
                    if let bands {
                        BandChips(bands: bands)
                            .fixedSize()
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: Spacing.m) {
                        signal
                        if operatorName != nil || bands != nil {
                            HeroDivider()
                            network
                        }
                    }
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        signal
                        network
                    }
                }
                if let failure = modem.infoFailure {
                    Label {
                        Text(verbatim: failure + (modem.infoAt.map { " Shown " + asOfText($0) + "." } ?? ""))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !addresses.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Addresses")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(addresses, id: \.label) { row in
                        KeyValueRow(label: row.label, value: row.value, copyable: true)
                    }
                }
                .frame(width: beside ? 250 : nil)
                .frame(maxWidth: beside ? nil : .infinity, alignment: .leading)
            }
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            ZStack {
                CardBackground()
                shape.fill(LinearGradient(colors: [pill.state.tint.opacity(0.14), pill.state.tint.opacity(0.02)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
    }
}

/// A short upright rule between the hero's signal, operator and bands.
private struct HeroDivider: View {
    var body: some View {
        Divider()
            .frame(height: 14)
    }
}

/// The bands in use (bandText: "n41 + n78"), one chip each, primary first: carrier aggregation as a row of chips.
private struct BandChips: View {
    let bands: String

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(Array(bands.components(separatedBy: " + ").enumerated()), id: \.offset) { _, band in
                Text(verbatim: band)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(bands.contains(" + ") ? "Bands" : "Band"))
        .accessibilityValue(Text(verbatim: bands))
    }
}

// MARK: - Throughput and signal

/// The chart's height in the throughput card, and the sparkline's in the signal card, so the two cards match.
private let chartHeight: CGFloat = 100

/// The current download and upload rates over the last two minutes of them, and the data since the driver started.
/// Without the driver's counters (it is not attached) the chart's place says so.
private struct ThroughputCard: View {
    @ObservedObject var throughput: ThroughputSampler

    var body: some View {
        Card("Throughput", symbol: "arrow.up.arrow.down", accessory: { CardNote(text: "Last 2 minutes") }) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                ThroughputRates(current: throughput.current)
                if throughput.sessionRx == nil {
                    ChartPlaceholder(text: "No data from the driver", height: chartHeight)
                } else {
                    ThroughputChart(points: throughput.points, height: chartHeight)
                }
                Spacer(minLength: 0)
                Divider()
                SessionTotals(rx: throughput.sessionRx, tx: throughput.sessionTx)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// The bytes the driver has counted since it started, down and up; "—" when not known.
private struct SessionTotals: View {
    let rx: UInt64?
    let tx: UInt64?

    var body: some View {
        let label = Text("Since the driver started")
            .font(.caption)
            .foregroundStyle(.secondary)
        let totals = HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            total("arrow.down", rx, .blue)
            total("arrow.up", tx, .teal)
        }
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                label
                Spacer(minLength: Spacing.m)
                totals
            }
            .lineLimit(1)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                label
                totals
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Data since the driver started"))
        .accessibilityValue(Text(verbatim: "\(byteText(rx)) down, \(byteText(tx)) up"))
    }

    private func total(_ symbol: String, _ bytes: UInt64?, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(verbatim: byteText(bytes))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
        .fixedSize()
    }
}

/// A byte count in words ("1.83 GB", ByteCountFormatter's file style); "—" when not known.
private func byteText(_ bytes: UInt64?) -> String {
    bytes.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—"
}

/// The serving leg's RSRP (RSCP for 3G) now, its quality word, and a sparkline of it over the last ten minutes of
/// network reads, shaded by quality, with a key to the shading; in the sparkline's place, signalPlaceholder's words
/// while it has under two values.
private struct SignalCard: View {
    @ObservedObject var modem: ModemController

    var body: some View {
        let leg = modem.info?.serving.flatMap { servingLeg($0.cells) }
        let history = servingSignalHistory(modem.signalHistory, until: modem.infoAt)
        let rat = leg?.rat ?? history.rat
        let title = SignalMetric.rsrp.title(rat: rat)
        let value = leg?.rsrp
        let quality = metricQuality(.rsrp, value.map(Double.init), rat: rat)
        Card("Signal", symbol: "waveform.path.ecg", accessory: { CardNote(text: "Last 10 minutes") }) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Text(verbatim: value.map { String($0) } ?? "—")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    if value != nil {
                        Text(verbatim: SignalMetric.rsrp.unit)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, Spacing.xs)
                    Spacer(minLength: Spacing.s)
                    if let quality {
                        Text(verbatim: signalWord(quality))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(signalTint(quality))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: title))
                .accessibilityValue(Text(verbatim: value.map {
                    "\($0) \(SignalMetric.rsrp.unit)" + (quality.map { ", " + signalWord($0).lowercased() } ?? "")
                } ?? "not known"))
                if history.values.count >= 2 {
                    Sparkline(values: history.values, zones: qualityZones(.rsrp, rat: history.rat),
                              label: "\(SignalMetric.rsrp.title(rat: history.rat)) over the last 10 minutes",
                              unit: SignalMetric.rsrp.unit, height: chartHeight)
                } else {
                    ChartPlaceholder(text: signalPlaceholder(modem.info, history), height: chartHeight)
                }
                Spacer(minLength: 0)
                Divider()
                ZoneKey(rat: history.rat)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// What the sparkline's shading means: each quality zone's colour (as the gauges draw it) and word, best first.
private struct ZoneKey: View {
    let rat: String

    var body: some View {
        HStack(spacing: Spacing.m) {
            ForEach(qualityZones(.rsrp, rat: rat).reversed(), id: \.level) { zone in
                HStack(spacing: Spacing.xs) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(zoneFill(zone.level).opacity(3))
                        .frame(width: 10, height: 10)
                    Text(verbatim: signalWord(zone.level))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The sparkline's place while it has under two values: "No signal" when the last read says there is none (the
/// radio off, or no serving leg: a read with no leg adds nothing to the history), "No signal data" after two reads
/// without a value, else "Collecting…".
private func signalPlaceholder(_ info: NetworkInfo?, _ history: (values: [Double], rat: String, reads: Int))
    -> String {
    if let info, info.serving.flatMap({ servingLeg($0.cells) }) == nil, signalLevel(info) == 0 { return "No signal" }
    if history.values.isEmpty && history.reads >= 2 { return "No signal data" }
    return "Collecting…"
}

/// The signal history's reads of the last `window` seconds back from `until` (the last network read that succeeded;
/// the newest sample's time when nil), with a leg: one value a read, the RSRP (RSCP) of the leg that stands for the
/// connection (as servingLeg: the NR leg when it has an RSRP, else the LTE leg, else the read's first), oldest
/// first, only on the newest read's scale (RSCP for 3G, else RSRP); the newest read's leg ("NR", "LTE", "WCDMA";
/// "LTE" with none); and how many reads there were.
private func servingSignalHistory(_ samples: [SignalSample], until: Date? = nil, window: TimeInterval = 600)
    -> (values: [Double], rat: String, reads: Int) {
    guard let latest = samples.last?.at else { return ([], "LTE", 0) }
    let from = max(until ?? latest, latest).addingTimeInterval(-window)
    var reads: [[SignalSample]] = []
    for sample in samples where sample.at >= from {
        if let last = reads.last?.last, last.at == sample.at {
            reads[reads.count - 1].append(sample)
        } else {
            reads.append([sample])
        }
    }
    let serving = reads.compactMap { read in
        read.first(where: { $0.leg == "NR" && $0.rsrp != nil }) ?? read.first(where: { $0.leg == "LTE" }) ?? read.first
    }
    let rat = serving.last?.leg ?? "LTE"
    let values = serving.filter { ($0.leg == "WCDMA") == (rat == "WCDMA") }.compactMap { $0.rsrp.map(Double.init) }
    return (values, rat, reads.count)
}

// MARK: - Small cards

/// The SIM as the SIM & Data screen last read it (the Overview never reads it): ready; PIN required (orange, Unlock…
/// opens SIM & Data, where the unlock is); another state in its words; or not read yet.
private struct SimCard: View {
    @ObservedObject var modem: ModemController
    let navigate: (Screen) -> Void

    var body: some View {
        let summary = simSummary(modem.sim)
        SmallCard(title: "SIM", symbol: "simcard", state: summary.state, stateSymbol: summary.symbol,
                  tint: summary.tint, attention: summary.attention,
                  note: modem.sim == nil ? nil : modem.settingsAt.map(sentenceAsOf)) {
            if let action = summary.action {
                CardButton(title: action, prominent: summary.attention) { navigate(.simData) }
            }
        }
    }
}

/// The SIM card's state, its symbol and colour (nil: secondary), whether it needs attention, and its button.
private func simSummary(_ sim: SimInfo?) -> (state: String, symbol: String, tint: Color?, attention: Bool,
                                             action: String?) {
    guard let sim else { return ("Not checked yet", "questionmark.circle", nil, false, "Open SIM & Data") }
    switch sim.state {
    case .ready: return ("Ready", "checkmark.circle.fill", .green, false, nil)
    case .pin: return ("PIN required", "lock.fill", .orange, true, "Unlock…")
    case .puk, .notInserted, .failure:
        return (capitalized(simStateWords(sim.state)), "exclamationmark.triangle.fill", .orange, true,
                "Open SIM & Data")
    case .pin2, .puk2, .busy, .other:
        return (capitalized(simStateWords(sim.state)), "info.circle", nil, false, "Open SIM & Data")
    }
}

/// The unread messages at the Messages screen's last listing (the Overview never lists them), and Open.
private struct MessagesCard: View {
    @ObservedObject var messages: SmsController
    let navigate: (Screen) -> Void

    var body: some View {
        let unread = messages.unread.count
        let state: (text: String, symbol: String, tint: Color?) =
            !messages.listed ? ("Not checked yet", "questionmark.circle", nil)
            : unread > 0 ? ("\(unread) unread", "envelope.badge.fill", .blue)
            : messages.messages.isEmpty ? ("No messages", "tray", nil)
            : ("All read", "checkmark.circle", nil)
        SmallCard(title: "Messages", symbol: "message", state: state.text, stateSymbol: state.symbol, tint: state.tint,
                  attention: false, note: messages.listedAt.map(sentenceAsOf)) {
            CardButton(title: "Open", prominent: false) { navigate(.messages) }
        }
    }
}

/// The driver's version and state; when it needs attention, orange with its call to action: Install, Open System
/// Settings, the not-in-QMI-mode advice with Details, Update. Install and Update are the Driver screen's own
/// (StatusController.install, no confirmation there either); their progress line shows here.
private struct DriverCard: View {
    let summary: DriverSummary
    @ObservedObject var controller: StatusController
    let navigate: (Screen) -> Void
    @Binding var driverRequested: Bool

    var body: some View {
        SmallCard(title: "Driver", symbol: "puzzlepiece.extension", state: summary.state,
                  stateSymbol: summary.symbol, tint: summary.tint, attention: summary.attention, note: summary.version,
                  lines: summary.lines) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if let action = summary.action {
                    CardButton(title: title(action), prominent: summary.attention) { perform(action) }
                        .disabled(isInstall(action) && !controller.installEnabled)
                }
                if controller.busy || (driverRequested && !controller.progress.isEmpty) {
                    DriverProgress(busy: controller.busy, text: controller.progress)
                }
            }
        }
    }

    private func title(_ action: DriverSummary.Action) -> String {
        switch action {
        case .install: return controller.installButtonTitle
        case .update: return "Update"
        case .openSystemSettings: return "Open System Settings"
        case .details: return "Details"
        }
    }

    private func isInstall(_ action: DriverSummary.Action) -> Bool {
        action == .install || action == .update
    }

    private func perform(_ action: DriverSummary.Action) {
        switch action {
        case .install, .update:
            driverRequested = true
            controller.install()
        case .openSystemSettings:
            openDriverExtensionsSettings()
        case .details:
            navigate(.driver)
        }
    }
}

/// What the driver card shows: the driver's state in words, its symbol and colour, whether it needs attention, the
/// version line, the advice lines shown with it (StatusModel.swift's, unchanged), and its call to action.
private struct DriverSummary {
    enum Action { case install, update, openSystemSettings, details }

    var state: String
    var symbol: String
    var tint: Color?
    var attention = false
    var version: String
    var lines: [String] = []
    var action: Action? = nil
}

/// The driver card for the status (its headline is the hero's, connectionHeadline): checking; status unknown
/// (Details); not installed (Install; the Overview shows its empty state then, so the card only for completeness);
/// waiting for approval (Open System Settings); not in QMI mode (the advice's first sentence and its commands,
/// Details); needs attention (Details); an update bundled (Update); else running (attached) or enabled.
private func driverSummary(_ c: StatusController) -> DriverSummary {
    let status = c.status
    let listed = c.known ? status.entries.first(where: { !$0.uninstalling }) ?? status.entries.first : nil
    let version = "Version " + (listed?.version ?? "—")
    let attention = "exclamationmark.triangle.fill"
    switch c.connectionHeadline {
    case "Asking the system…":
        return DriverSummary(state: "Checking…", symbol: "circle.dotted", tint: nil, version: version)
    case unknownHeadline:
        return DriverSummary(state: "Status unknown", symbol: "questionmark.circle", tint: .red, version: version,
                             action: .details)
    case "Not installed":
        return DriverSummary(state: "Not installed", symbol: attention, tint: .orange, attention: true,
                             version: version, action: .install)
    case "Waiting for approval in System Settings":
        return DriverSummary(state: "Waiting for approval", symbol: "hand.raised.fill", tint: .orange, attention: true,
                             version: version, action: .openSystemSettings)
    case "Modem is not in QMI mode":
        return DriverSummary(state: "Not in QMI mode", symbol: attention, tint: .orange, attention: true,
                             version: version, lines: qmiModeAdvice(advice(status, bundledVersion: c.bundledVersion)),
                             action: .details)
    case "Needs attention":
        return DriverSummary(state: "Needs attention", symbol: attention, tint: .orange, attention: true,
                             version: version, action: .details)
    default:
        if let listed, c.known, !c.bundledVersion.isEmpty, canActivate(status), c.installButtonTitle == "Update" {
            return DriverSummary(state: "Update available", symbol: "arrow.down.circle.fill", tint: .orange,
                                 attention: true, version: "Version \(listed.version) → \(c.bundledVersion)",
                                 action: .update)
        }
        return DriverSummary(state: status.attached ? "Running" : "Enabled", symbol: "checkmark.circle.fill",
                             tint: .green, version: version)
    }
}

/// The advice's not-in-QMI-mode sentence and the commands right after it: for the RM520N-GL `RMNet usbmode set
/// qmi` (its fallback is on the Driver screen), for another model its two AT commands. Lines as the Driver screen
/// shows them; a command is in a fixed-width font (isCommandLine).
private func qmiModeAdvice(_ lines: [String]) -> [String] {
    guard let first = lines.first else { return [] }
    return [first] + lines.dropFirst().prefix(while: isCommandLine)
}

/// The Driver screen's rule for the advice lines it shows in a fixed-width font.
private func isCommandLine(_ line: String) -> Bool {
    line.hasPrefix("AT+") || line == usbModeQmiCommand || atFallbackCommands.contains(line)
}

/// System Settings, General, Login Items & Extensions, at its extensions.
private func openDriverExtensionsSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Small card pieces

/// A small card: its title, its state in large type with a symbol in the state's colour, a note under it (the time
/// of the read, the version), lines of advice, and its buttons at the bottom. Orange-washed when it needs
/// attention.
private struct SmallCard<Actions: View>: View {
    let title: String
    let symbol: String
    let state: String
    let stateSymbol: String
    let tint: Color?
    let attention: Bool
    var note: String? = nil
    var lines: [String] = []
    @ViewBuilder var actions: Actions

    var body: some View {
        Card(title, symbol: symbol) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Label {
                        Text(verbatim: state)
                            .foregroundStyle(tint ?? .secondary)
                    } icon: {
                        Image(systemName: stateSymbol)
                            .foregroundStyle(tint ?? .secondary)
                    }
                    .font(.title2.weight(.semibold))
                    if let note {
                        Text(verbatim: note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .accessibilityElement(children: .combine)
                ForEach(lines, id: \.self) { line in
                    Text(verbatim: line)
                        .font(isCommandLine(line) ? .callout.monospaced() : .callout)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                actions
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay {
            if attention {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                ZStack {
                    shape.fill(Color.orange.opacity(0.06))
                    shape.strokeBorder(Color.orange.opacity(0.55), lineWidth: 1)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

/// A small card's button: prominent and orange for a call to action.
private struct CardButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        if prominent {
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
        } else {
            Button(title, action: action)
                .buttonStyle(.bordered)
        }
    }
}

/// Install's or Update's progress line (StatusController's words, unchanged), with a spinner while it runs.
private struct DriverProgress: View {
    let busy: Bool
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            if busy {
                ProgressView()
                    .controlSize(.small)
            }
            Text(verbatim: text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

/// A card's quiet note at the end of its title row ("Last 2 minutes").
private struct CardNote: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// "As of 14:02:11": asOfText as a line of its own.
private func sentenceAsOf(_ date: Date) -> String {
    capitalized(asOfText(date))
}

/// The text with its first letter upper case ("not inserted" is "Not inserted").
private func capitalized(_ text: String) -> String {
    text.prefix(1).uppercased() + text.dropFirst()
}

// MARK: - Not installed

/// The whole Overview while the driver is not installed: an empty state whose action installs it (the Driver
/// screen's Install, StatusController.install), and the request's progress line under it. No action while a request
/// runs; Details (the Driver screen, which says why) while Install is off for another reason, such as an app that
/// carries no driver.
private struct NotInstalledState: View {
    @ObservedObject var driverStatus: StatusController
    let navigate: (Screen) -> Void
    @Binding var driverRequested: Bool

    var body: some View {
        let action: (title: String, perform: () -> Void)? =
            driverStatus.installEnabled ? (title: driverStatus.installButtonTitle, perform: install)
            : driverStatus.busy ? nil
            : (title: "Details", perform: { navigate(.driver) })
        VStack(spacing: Spacing.l) {
            EmptyState(symbol: "puzzlepiece.extension", title: "Driver not installed",
                       message: "Install the driver to connect to the modem.", action: action)
            if driverStatus.busy || (driverRequested && !driverStatus.progress.isEmpty) {
                DriverProgress(busy: driverStatus.busy, text: driverStatus.progress)
                    .frame(maxWidth: 440)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func install() {
        driverRequested = true
        driverStatus.install()
    }
}
