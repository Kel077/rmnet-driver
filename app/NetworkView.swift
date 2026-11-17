// The window's Network screen, as cards: the connection (technology, registration, operator, PLMN, mode), the signal
// (a gauge for each metric of each serving leg, then the last ten minutes of RSRP and SINR as charts), the throughput
// (the driver's counters, sampled every second while the screen is shown), the cell (its numbers, and the carriers as
// band chips sized by their bandwidth), the radio and the network mode (the radio's switch; the mode's picker with
// Change… and Put Back) and the bands each RAT may use (chips; Change…, a sheet of band chips; Reset; Reset all).
// Refresh is in the toolbar, the result of the last change in the banner at the bottom, and when the values were read
// (or why the last read failed) above the cards.
// ModemController (ModemController.swift) holds the state, reads the shown screen and runs one call at a time; the
// rows' words, questions and sentences come from ModemNetwork.swift, ModemSettings.swift and the controller. Switching
// the radio off, the mode's Change… and Put Back… ask first, with words taken when their confirmation opens
// (ModemViewParts.swift); a RAT's Change… opens the bands sheet, which is its question. Switching the radio on, Reset
// and Reset all ask nothing (for the bands, the line beside Reset all warns instead). What the cards show is worked
// out by NetworkCards, at the end of this file: Foundation only, tested by tests/app/NetworkViewTests.swift.
import SwiftUI

private enum NetworkAction { case radioOff, changeMode, putBack }

/// The radio's state beside its switch.
private func radioStateWords(_ radio: RadioState) -> String {
    switch radio {
    case .on: return "On"
    case .airplane: return "Off (airplane mode)"
    case .minimum: return "Minimum functionality"
    case .other(let n): return "AT+CFUN \(n)"
    }
}

/// The bands sheet open for one RAT, with its bands as read when it opened.
private struct BandsEdit: Identifiable {
    let opened: BandSet
    var id: BandRat { opened.rat }
}

/// The widest the cards (and the read line above them) get; the same as the Overview's.
private let contentWidth: CGFloat = 760

struct NetworkTab: View {
    // The process's one controller, owned by the app delegate.
    @ObservedObject var controller: ModemController
    // The throughput, sampled every second while this screen is shown; not observed here (ThroughputCard observes
    // it, so that the rest of the screen does not redraw every second).
    let throughput: ThroughputSampler
    @State private var question: Question<NetworkAction>? = nil
    @State private var editing: BandsEdit? = nil
    // Counts the clicks on the radio's switch. Each click makes the switch anew from the modem's state as read, so
    // the switch never shows the click: it moves when a read (after the change, or after Switch Off) says so.
    @State private var radioClicks = 0

    /// The picker's modes: the window's choices, then the modem's mode (or the pick) if it is another mode;
    /// the same RATs in another order (the modem's `NR5G:LTE`) are the choice already there (sameMode).
    private var modeChoices: [String] {
        var choices = networkModeChoices
        for mode in [controller.info?.mode, controller.pickedMode].compactMap({ $0 })
        where !choices.contains(where: { sameMode($0, mode) }) {
            choices.append(mode)
        }
        return choices
    }

    /// The picker's selection: the choice of the same mode as the pick (`LTE:NR5G` for the modem's
    /// `NR5G:LTE`). Picking sets the controller's pick; Put Back still sends the modem's own string (R8).
    private var pickedChoice: Binding<String?> {
        Binding(get: { controller.pickedMode.map { p in modeChoices.first(where: { sameMode($0, p) }) ?? p } },
                set: { controller.pickedMode = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            readStatus
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    connectionCard
                    signalCard
                    ThroughputCard(throughput: throughput)
                    cellCard
                    radioAndModeCard
                    bandsCard
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.xs)
                .padding(.bottom, Spacing.xl)
                .frame(maxWidth: contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    controller.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Read the network and the bands again")
                .disabled(!controller.refreshEnabled)
            }
        }
        .resultBanner(controller.result, isFailure: controller.resultIsFailure,
                      inProgress: controller.running != nil && controller.running != .reading)
        .modifier(Confirmation(question: $question, controller: controller, perform: perform, closed: {}))
        // Reads pause while the sheet is open, as for a confirmation; however it closes, they go on.
        .sheet(item: $editing, onDismiss: { controller.setConfirming(false) }) { edit in
            BandsSheet(controller: controller, opened: edit.opened,
                       apply: { chosen in
                           controller.changeBands(edit.opened.rat, to: chosen)
                           editing = nil
                           controller.setConfirming(false)
                       },
                       cancel: {
                           editing = nil
                           controller.setConfirming(false)
                       })
        }
    }

    // MARK: The read line

    /// When the values were read, or why the last read failed (and that the values may be out of date): above the
    /// cards, so it stays in view while they scroll. Not fixedSize: this part of the window does not scroll.
    private var readStatus: some View {
        let failed = controller.infoFailure != nil
        return Label {
            Text(verbatim: readStatusLine(at: controller.infoAt, failure: controller.infoFailure,
                                          valuesShown: controller.info != nil, reading: "Reading the network…"))
                .textSelection(.enabled)
        } icon: {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "clock")
                .foregroundStyle(failed ? Color.orange : Color.secondary)
        }
        .font(.callout)
        .foregroundStyle(failed ? Color.primary : Color.secondary)
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.m)
        .padding(.bottom, Spacing.s)
        .frame(maxWidth: contentWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    // MARK: Connection

    private var connectionCard: some View {
        let info = controller.info
        return Card("Connection", symbol: "antenna.radiowaves.left.and.right", accessory: {
            if let info {
                if let tech = techBadgeText(info) {
                    TechBadge(text: tech)
                } else if let words = NetworkCards.technologyWithoutBadge(info) {
                    Text(verbatim: words)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(NetworkCards.connectionRows(info), id: \.label) { row in
                    KeyValueRow(label: row.label, value: row.value)
                }
            }
        }
    }

    // MARK: Signal

    /// The connection's bars and word in the title row; a gauge for each metric of each serving leg (EN-DC: a column
    /// for LTE and one for NR); then RSRP and SINR over the last ten minutes.
    private var signalCard: some View {
        let info = controller.info
        let legs = NetworkCards.shownLegs(info)
        let level = info.flatMap(signalLevel)   // nil: not known
        return Card("Signal", symbol: "cellularbars", accessory: {
            if info != nil {
                HStack(spacing: Spacing.s) {
                    SignalBars(level: level)
                    Text(verbatim: level.map(signalWord) ?? "Not known")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }) {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if let reason = NetworkCards.noLegReason(info) {
                    ChartPlaceholder(text: reason, height: 64)
                } else if legs.count > 1 {
                    HStack(alignment: .top, spacing: Spacing.xl) {
                        ForEach(Array(legs.enumerated()), id: \.offset) { _, leg in
                            LegGauges(leg: leg)
                        }
                    }
                } else {
                    GaugeRow(leg: legs.first)
                }
                HStack(alignment: .top, spacing: Spacing.l) {
                    historyChart(.rsrp)
                    historyChart(.sinr)
                }
            }
        }
    }

    private func historyChart(_ metric: SignalMetric) -> some View {
        let rat = controller.signalHistory.last?.leg ?? "LTE"
        return VStack(alignment: .leading, spacing: Spacing.s) {
            Text(verbatim: "\(metric.title(rat: rat)), last 10 minutes")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)   // the chart's own label says it
            SignalHistoryChart(samples: controller.signalHistory, metric: metric, height: 120)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Cell

    /// The serving legs' numbers (EN-DC: a column for LTE and one for NR), then the carriers as chips.
    private var cellCard: some View {
        let info = controller.info
        let carriers = info.map(NetworkCards.carrierChips) ?? []
        return Card("Cell", symbol: "dot.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if let reason = NetworkCards.noLegReason(info) {
                    ChartPlaceholder(text: reason, height: 44)
                } else {
                    CellGrid(legs: NetworkCards.shownLegs(info))
                }
                if !carriers.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("Carriers")
                            .foregroundStyle(.secondary)
                        FlowLayout(spacing: Spacing.s) {
                            ForEach(Array(carriers.enumerated()), id: \.offset) { _, chip in
                                CarrierChipView(chip: chip)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Radio and mode

    private var radioAndModeCard: some View {
        Card("Radio & mode", symbol: "switch.2") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .center, spacing: Spacing.m) {
                    Text("Radio")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Spacing.s)
                    Text(verbatim: controller.info?.radio.map(radioStateWords) ?? "—")
                    radioSwitch
                }
                HStack(alignment: .center, spacing: Spacing.m) {
                    Text("Network mode")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Spacing.s)
                    if controller.pickedMode != nil {
                        Picker("Network mode", selection: pickedChoice) {
                            ForEach(modeChoices, id: \.self) { mode in
                                Text(verbatim: NetworkCards.capitalizedFirst(modeWords(mode))).tag(Optional(mode))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(!controller.refreshEnabled)
                        Button("Change…") {
                            guard let picked = controller.pickedMode else { return }
                            let q = modeQuestion(from: controller.info?.mode, to: picked)
                            ask(Question(action: .changeMode, title: q.title, message: q.message, confirm: "Change"))
                        }
                        .disabled(!controller.modeChangeEnabled)
                    } else {
                        Text(verbatim: "—")
                    }
                }
                if case .mode(let before)? = controller.undo {
                    Divider()
                    HStack {
                        Spacer()
                        Button("Put Back to \(modeWords(before))…") {
                            let from = controller.info?.mode.map { "The modem changes from \(modeWords($0)) back to \(modeWords(before)) at once" }
                                ?? "The current mode could not be read. The modem changes back to \(modeWords(before)) at once"
                            ask(Question(action: .putBack, title: "Put the network mode back to \(modeWords(before))?",
                                         message: "\(from); the connection can drop while it finds a network. "
                                            + "The modem keeps this setting, also after a restart.",
                                         confirm: "Put Back"))
                        }
                        .disabled(!controller.refreshEnabled)
                    }
                    if let command = controller.undoCommand { PutBackCommand(command: command) }
                }
            }
        }
    }

    /// On while the modem says the radio is on. Switching it off asks first (the confirmation of Radio Off…);
    /// switching it on runs Radio On. Either way it shows the modem's state, not the click (radioClicks), and it is
    /// off while a change runs or waits, a confirmation or the sheet is open, or the radio has not been read.
    private var radioSwitch: some View {
        Toggle("Radio", isOn: Binding(get: { controller.info?.radio == .on }, set: { on in
            radioClicks += 1
            if on {
                controller.setRadio(on: true)
            } else {
                let q = radioOffQuestion()
                ask(Question(action: .radioOff, title: q.title, message: q.message, confirm: "Switch Off",
                             destructive: true))
            }
        }))
        .toggleStyle(.switch)
        .labelsHidden()
        .id(radioClicks)
        .disabled(!controller.refreshEnabled || controller.info?.radio == nil)
    }

    // MARK: Bands

    /// A row a RAT (its count, Change… and Reset, and its bands as chips unless it allows them all), then Reset all
    /// with its warning; while the bands are unknown, that they were not read yet or why the read failed.
    private var bandsCard: some View {
        Card("Bands", symbol: "square.grid.3x3") {
            if let sets = controller.bands {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    if let failure = controller.bandsFailure {
                        warning("\(failure) The bands below may be out of date.")
                    }
                    ForEach(Array(sets.enumerated()), id: \.element.rat) { i, set in
                        if i > 0 { Divider() }
                        bandsRow(set)
                    }
                    Divider()
                    HStack(alignment: .center, spacing: Spacing.m) {
                        Text("Reset allows every supported band again, at once; the modem may re-select a cell and drop "
                             + "the connection for a few seconds.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Spacing.m)
                        Button("Reset all") { controller.resetAllBands() }
                            .disabled(!controller.resetAllBandsEnabled)
                    }
                }
            } else if let failure = controller.bandsFailure {
                warning(failure)
            } else {
                Text("Not read yet.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func bandsRow(_ set: BandSet) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                Text(verbatim: set.rat.name)
                    .font(.headline)
                    .frame(minWidth: 64, alignment: .leading)
                Text(verbatim: NetworkCards.bandsCount(set))
                    .foregroundStyle(.secondary)
                Spacer(minLength: Spacing.s)
                Button("Change…") { openBands(set) }
                    .disabled(!controller.bandsChangeEnabled)
                    .accessibilityLabel(Text(verbatim: "Change the \(set.rat.name) bands…"))
                Button("Reset") { controller.resetBands(set.rat) }
                    .disabled(!controller.bandsResetEnabled(set.rat))
                    .accessibilityLabel(Text(verbatim: "Reset the \(set.rat.name) bands"))
            }
            if !NetworkCards.bandsAllAllowed(set) {
                FlowLayout(spacing: 5) {
                    ForEach(NetworkCards.bandChips(set), id: \.band) { chip in
                        BandChipView(label: chip.label, allowed: chip.allowed)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(set.rat.name) bands"))
                .accessibilityValue(Text(verbatim: bandsSummary(set)))
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(verbatim: text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .font(.callout)
    }

    private func openBands(_ set: BandSet) {
        guard controller.bandsChangeEnabled else { return }
        editing = BandsEdit(opened: set)
        controller.setConfirming(true)
    }

    private func ask(_ q: Question<NetworkAction>) {
        question = q
        controller.setConfirming(true)
    }

    private func perform(_ action: NetworkAction) {
        switch action {
        case .radioOff: controller.setRadio(on: false)
        case .changeMode: controller.changeMode()
        case .putBack: controller.putBack()
        }
    }
}

// MARK: - The cards' parts

/// The throughput card: the current rates in large type over the last two minutes as a chart. It observes the sampler
/// (every second) so that only it redraws.
private struct ThroughputCard: View {
    @ObservedObject var throughput: ThroughputSampler

    var body: some View {
        Card("Throughput", symbol: "arrow.up.arrow.down") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                ThroughputRates(current: throughput.current)
                ThroughputChart(points: throughput.points, height: 180)
            }
        }
    }
}

/// The one serving leg's gauges side by side; before anything is read, the three of them "—".
private struct GaugeRow: View {
    let leg: CellLeg?

    var body: some View {
        let rat = leg?.rat ?? "LTE"
        HStack(alignment: .top, spacing: Spacing.xl) {
            ForEach(NetworkCards.legMetrics(rat), id: \.self) { metric in
                MetricGauge(metric, value: leg.flatMap { NetworkCards.legValue($0, metric) }, rat: rat)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// One of EN-DC's legs: its name and band over its gauges, one under the other.
private struct LegGauges: View {
    let leg: CellLeg

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(verbatim: NetworkCards.legTitle(leg))
                    .font(.headline)
                if let band = leg.band {
                    Text(verbatim: band)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(NetworkCards.legMetrics(leg.rat), id: \.self) { metric in
                MetricGauge(metric, value: NetworkCards.legValue(leg, metric), rat: leg.rat)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: NetworkCards.legTitle(leg)))
    }
}

/// The cell's numbers: a label column, then a value column a leg (named above them when there are two).
private struct CellGrid: View {
    let legs: [CellLeg]

    var body: some View {
        let named = legs.count > 1
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.xl, verticalSpacing: Spacing.s) {
            if named {
                GridRow {
                    Color.clear
                        .gridCellUnsizedAxes([.horizontal, .vertical])
                    ForEach(Array(legs.enumerated()), id: \.offset) { _, leg in
                        Text(verbatim: NetworkCards.legTitle(leg))
                            .font(.headline)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            ForEach(NetworkCards.cellRows(legs), id: \.label) { row in
                GridRow {
                    Text(verbatim: row.label)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityHidden(true)
                    ForEach(Array(row.values.enumerated()), id: \.offset) { i, value in
                        Text(verbatim: value)
                            .monospacedDigit()
                            .textSelection(.enabled)
                            .gridColumnAlignment(.trailing)
                            .accessibilityLabel(Text(verbatim: named ? "\(NetworkCards.legTitle(legs[i])) \(row.label)"
                                                                     : row.label))
                            .accessibilityValue(Text(verbatim: value))
                    }
                }
            }
        }
    }
}

/// A carrier: its band over its bandwidth, as wide as the bandwidth (NetworkCards.carrierChipWidth), 5G blue and LTE
/// teal (as the technology badge); the primary carrier's fill is stronger.
private struct CarrierChipView: View {
    let chip: NetworkCards.CarrierChip

    var body: some View {
        let tint = techTint(chip.band.hasPrefix("n") ? "5G" : chip.band.hasPrefix("B") ? "LTE" : "")
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: chip.band)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
            Text(verbatim: chip.bandwidthMHz.map(NetworkCards.bandwidthText) ?? "—")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .lineLimit(1)
        .padding(.horizontal, Spacing.s + 2)
        .padding(.vertical, Spacing.xs + 1)
        .frame(width: NetworkCards.carrierChipWidth(chip.bandwidthMHz), alignment: .leading)
        .background(shape.fill(tint.opacity(chip.primary ? 0.24 : 0.12)))
        .overlay(shape.strokeBorder(tint.opacity(chip.primary ? 0.7 : 0.4), lineWidth: chip.primary ? 1 : 0.5))
        .help(chip.primary ? "Primary carrier" : "Carrier")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Carrier \(chip.band)"))
        .accessibilityValue(Text(verbatim: [chip.primary ? "primary" : nil,
                                            chip.bandwidthMHz.map(NetworkCards.bandwidthText)]
            .compactMap { $0 }.joined(separator: ", ")))
    }
}

/// A band in a RAT's row: filled when the RAT may use it, outlined when not. Blue, not the accent colour: the
/// system's accent can be yellow, under which the white label could not be read.
private struct BandChipView: View {
    let label: String
    let allowed: Bool

    var body: some View {
        let shape = Capsule()
        Text(verbatim: label)
            .font(.caption.weight(allowed ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(allowed ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            .frame(minWidth: 28)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background { if allowed { shape.fill(Color.blue) } }
            .overlay { if !allowed { shape.strokeBorder(.tertiary, lineWidth: 1) } }
    }
}

/// Its views left to right, as many to a line as fit, then on the next line.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, let limit, x + size.width > limit {
                x = 0
                y += line + spacing
                line = 0
            }
            x += size.width
            widest = max(widest, x)
            x += spacing
            line = max(line, size.height)
        }
        return CGSize(width: limit ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += line + spacing
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: - The bands sheet

/// The sheet Change… opens for one RAT: a chip for each band it supports (`B3` for LTE, `n41` for 5G), on for those
/// it may use as read when the sheet opened, and how many are on; Select all and Clear; the warning; Apply (the
/// default button), off with nothing on or with the bands allowed now (the controller's bandsApplyEnabled), and
/// Cancel. Apply calls `apply` with the bands on, sorted; the screen then closes the sheet.
struct BandsSheet: View {
    @ObservedObject var controller: ModemController
    let opened: BandSet
    let apply: ([Int]) -> Void
    let cancel: () -> Void
    @State private var ticked: Set<Int>

    private static let columns = 7

    init(controller: ModemController, opened: BandSet, apply: @escaping ([Int]) -> Void, cancel: @escaping () -> Void) {
        self.controller = controller
        self.opened = opened
        self.apply = apply
        self.cancel = cancel
        _ticked = State(initialValue: Set(opened.allowed).intersection(opened.supported))
    }

    /// The supported bands, ascending, in rows of `columns`.
    private var rows: [[Int]] {
        let all = bandSorted(opened.supported)
        return stride(from: 0, to: all.count, by: BandsSheet.columns).map {
            Array(all[$0..<min($0 + BandsSheet.columns, all.count)])
        }
    }

    private func tick(_ band: Int) -> Binding<Bool> {
        Binding(get: { ticked.contains(band) },
                set: { on in if on { ticked.insert(band) } else { ticked.remove(band) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(opened.rat.name) bands")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: "\(ticked.count) of \(Set(opened.supported).count) selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: Spacing.s, verticalSpacing: Spacing.s) {
                ForEach(rows, id: \.self) { row in
                    GridRow {
                        ForEach(row, id: \.self) { band in
                            Toggle(isOn: tick(band)) {
                                Text(verbatim: bandLabel(opened.rat, band))
                            }
                            .toggleStyle(BandToggleStyle())
                        }
                    }
                }
            }
            HStack(spacing: Spacing.s) {
                Button("Select all") { ticked = Set(opened.supported) }
                    .disabled(ticked == Set(opened.supported))
                Button("Clear") { ticked = [] }
                    .disabled(ticked.isEmpty)
            }
            Label {
                Text("The modem may re-select a cell and drop the connection for a few seconds.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply(ticked.sorted()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!controller.bandsApplyEnabled(opened.rat, Array(ticked)))
            }
        }
        .padding(Spacing.xl)
        .frame(width: 520)
    }
}

/// A band in the sheet: a chip, filled (blue, as in the Bands card) while on; VoiceOver reads it as a checkbox.
private struct BandToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .font(.callout.weight(configuration.isOn ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(configuration.isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                .frame(width: 60, height: 26)   // seven a row fill the sheet's 472 pt
                .background { if configuration.isOn { shape.fill(Color.blue) } }
                .overlay { if !configuration.isOn { shape.strokeBorder(.tertiary, lineWidth: 1) } }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.checkbox)
        }
    }
}

// MARK: - What the cards show

/// The values the Network screen's cards show, worked out from a network read and the bands: Foundation only (with
/// ModemNetwork.swift's, ModemSettings.swift's and SignalQuality.swift's types), so that `make app-test` tests them
/// (tests/app/NetworkViewTests.swift). A value the modem did not report is "—".
enum NetworkCards {
    static let notReported = "—"

    /// The first letter in upper case, for a value shown on its own ("registered, home network (5GS)" reads
    /// "Registered, home network (5GS)"); the words are otherwise those given.
    static func capitalizedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// 100 → "100 MHz", 1.4 → "1.4 MHz".
    static func bandwidthText(_ mhz: Double) -> String {
        (mhz == mhz.rounded() && abs(mhz) < 1e15 ? String(Int(mhz)) : String(mhz)) + " MHz"
    }

    // MARK: Connection

    /// The Connection card's rows: the operator (with the network's own name after it when that differs), the
    /// registration, the PLMN (AT+QSPN's, else the first leg's MCC and MNC) and the network mode (with a 5G kind
    /// disabled), each in the words the network rows use (networkRows).
    static func connectionRows(_ info: NetworkInfo?) -> [(label: String, value: String)] {
        let mode = info.flatMap { i in networkRows(i).first(where: { $0.label == "Network mode" })?.value }
        return [
            (label: "Operator", value: info.flatMap(operatorText) ?? notReported),
            (label: "Registration", value: info?.registration.map { capitalizedFirst(registrationWords($0)) } ?? notReported),
            (label: "PLMN", value: info.flatMap(plmnText) ?? notReported),
            (label: "Network mode", value: mode.map(capitalizedFirst) ?? notReported),
        ]
    }

    /// AT+COPS?'s operator, with AT+QSPN's name in brackets when it differs (ignoring case); either alone.
    static func operatorText(_ info: NetworkInfo) -> String? {
        if let op = info.operatorName, let network = info.networkName, op.caseInsensitiveCompare(network) != .orderedSame {
            return "\(op) (\(network))"
        }
        return info.operatorName ?? info.networkName
    }

    /// AT+QSPN's PLMN, else the first leg's MCC and MNC together ("001" + "01").
    static func plmnText(_ info: NetworkInfo) -> String? {
        if let plmn = info.plmn { return plmn }
        guard let leg = info.serving?.cells.first, let mcc = leg.mcc, let mnc = leg.mnc else { return nil }
        return mcc + mnc
    }

    /// The technology in words where the badge has none to show ("Searching", "Limited service", "None (radio
    /// off)"); nil when the badge shows it or it is not known.
    static func technologyWithoutBadge(_ info: NetworkInfo) -> String? {
        guard techBadgeText(info) == nil else { return nil }
        let words = technologyLabel(info)
        return words == "unknown" ? nil : capitalizedFirst(words)
    }

    // MARK: Signal and cell

    /// The serving legs in the cards' order: LTE first (EN-DC's columns read LTE, then NR), the others as read.
    static func shownLegs(_ info: NetworkInfo?) -> [CellLeg] {
        let legs = info?.serving?.cells ?? []
        return legs.filter { $0.rat == "LTE" } + legs.filter { $0.rat != "LTE" }
    }

    /// A leg's name over its column: "NR" for either 5G leg (as the signal history names it), else its RAT.
    static func legTitle(_ leg: CellLeg) -> String {
        leg.rat.hasPrefix("NR5G") ? "NR" : leg.rat
    }

    /// The metrics a leg's RAT reports: WCDMA its RSCP only; the others RSRP, RSRQ and SINR.
    static func legMetrics(_ rat: String) -> [SignalMetric] {
        rat == "WCDMA" ? [.rsrp] : [.rsrp, .rsrq, .sinr]
    }

    static func legValue(_ leg: CellLeg, _ metric: SignalMetric) -> Double? {
        switch metric {
        case .rsrp: return leg.rsrp.map(Double.init)
        case .rsrq: return leg.rsrq.map(Double.init)
        case .sinr: return leg.sinr
        }
    }

    /// Why the Signal and Cell cards have no leg to show: the radio is off (airplane mode or minimum functionality),
    /// or the serving cell was read with no leg (searching, limited or no service). nil when there is a leg, or when
    /// nothing (or no serving cell) was read: the cards then show "—".
    static func noLegReason(_ info: NetworkInfo?) -> String? {
        guard let info else { return nil }
        if info.radio == .airplane || info.radio == .minimum { return "The radio is off." }
        guard let serving = info.serving, serving.cells.isEmpty else { return nil }
        return "No serving cell."
    }

    struct CellRow: Equatable {
        let label: String
        let values: [String]   // one a leg, in the order given; one "—" with no leg
    }

    /// The Cell card's rows, a value a leg: band (with the duplex), bandwidth, channel (ARFCN, EARFCN or UARFCN),
    /// PCI, cell ID and TAC; PSC and LAC for a WCDMA cell on its own. With no leg, one column of "—".
    static func cellRows(_ legs: [CellLeg]) -> [CellRow] {
        let shown: [CellLeg?] = legs.isEmpty ? [nil] : legs
        let wcdma = legs.count == 1 && legs[0].rat == "WCDMA"
        func row(_ label: String, _ value: (CellLeg) -> String?) -> CellRow {
            CellRow(label: label, values: shown.map { $0.flatMap(value) ?? notReported })
        }
        return [
            row("Band") { leg in leg.band.map { band in leg.duplex.map { "\(band) (\($0))" } ?? band } },
            row("Bandwidth") { $0.bandwidthMHz.map(bandwidthText) },
            row("Channel") { $0.channel.map { String($0) } },
            row(wcdma ? "PSC" : "PCI") { $0.pci.map { String($0) } },
            row("Cell ID") { $0.cellID },
            row(wcdma ? "LAC" : "TAC") { $0.tac },
        ]
    }

    struct CarrierChip: Equatable {
        let band: String
        let bandwidthMHz: Double?
        let primary: Bool
    }

    /// The carriers in use: AT+QCAINFO's (primary first), then any serving leg's band they do not list (as
    /// bandText). Each has the bandwidth of the serving leg on its band, when there is one (the modem reports none
    /// for another carrier); the first is the primary when AT+QCAINFO listed it.
    static func carrierChips(_ info: NetworkInfo) -> [CarrierChip] {
        let legs = info.serving?.cells ?? []
        var bands = info.carriers
        for leg in legs {
            if let band = leg.band, !bands.contains(band) { bands.append(band) }
        }
        return bands.enumerated().map { i, band in
            CarrierChip(band: band, bandwidthMHz: legs.first(where: { $0.band == band && $0.bandwidthMHz != nil })?.bandwidthMHz,
                        primary: i == 0 && !info.carriers.isEmpty)
        }
    }

    /// A carrier chip's width in points, by its bandwidth: 40 pt and 1.2 pt a MHz, at least 56 (room for the band and
    /// "1.4 MHz") and at most 220 (wider than 150 MHz all look the same); 56 when the bandwidth is not known.
    static func carrierChipWidth(_ mhz: Double?) -> CGFloat {
        guard let mhz, mhz > 0 else { return 56 }
        return min(220, max(56, 40 + 1.2 * CGFloat(mhz)))
    }

    // MARK: Bands

    struct BandChip: Equatable {
        let band: Int
        let label: String   // as the sheet labels it: B3, n41
        let allowed: Bool
    }

    /// A RAT's bands as chips, ascending: every band it supports, and any it allows that the modem does not list as
    /// supported; each marked allowed or not.
    static func bandChips(_ set: BandSet) -> [BandChip] {
        let allowed = Set(set.allowed)
        return bandSorted(set.supported + set.allowed).map {
            BandChip(band: $0, label: bandLabel(set.rat, $0), allowed: allowed.contains($0))
        }
    }

    /// The RAT allows every band it supports (and at least one): its row shows the count only.
    static func bandsAllAllowed(_ set: BandSet) -> Bool {
        !set.allowed.isEmpty && !bandsLocked(set)
    }

    /// "All 31 allowed" when the RAT allows every band it supports; else "2 of 28 allowed" (as sets, as
    /// bandsSummary counts them).
    static func bandsCount(_ set: BandSet) -> String {
        let supported = Set(set.supported).count
        if bandsAllAllowed(set) { return "All \(supported) allowed" }
        return "\(Set(set.allowed).count) of \(supported) allowed"
    }
}
