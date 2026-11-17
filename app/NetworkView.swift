// The window's Network tab: what the modem says about the network, the radio (Radio Off…, Radio On), the network
// mode (Change…, Put Back) and the bands each RAT may use (Change…, a sheet of checkboxes; Reset; Reset all).
// ModemController (ModemController.swift) holds the state, reads the shown tab and runs one call at a time; the
// rows, questions and sentences come from ModemNetwork.swift. Radio Off…, the mode's Change… and Put Back… ask
// first, with words taken when their confirmation opens (ModemViewParts.swift); a RAT's Change… opens the bands
// sheet, which is its question. Radio On, Reset and Reset all ask nothing (for the bands, the line beside Reset
// all warns instead).
import SwiftUI

private enum NetworkAction { case radioOff, changeMode, putBack }

/// The radio's state as the Network tab's control shows it.
private func radioStateWords(_ radio: RadioState) -> String {
    switch radio {
    case .on: return "on"
    case .airplane: return "off (airplane mode)"
    case .minimum: return "minimum functionality"
    case .other(let n): return "AT+CFUN \(n)"
    }
}

/// The bands sheet open for one RAT, with its bands as read when it opened.
private struct BandsEdit: Identifiable {
    let opened: BandSet
    var id: BandRat { opened.rat }
}

struct NetworkTab: View {
    // The process's one controller, owned by the app delegate.
    @ObservedObject var controller: ModemController
    @State private var question: Question<NetworkAction>? = nil
    @State private var editing: BandsEdit? = nil

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
        VStack(alignment: .leading, spacing: 10) {
            ReadStatus(text: readStatusLine(at: controller.infoAt, failure: controller.infoFailure,
                                      valuesShown: controller.info != nil, reading: "Reading the network…"),
                       failed: controller.infoFailure != nil, controller: controller)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let info = controller.info {
                        RowsGrid(rows: networkRows(info))
                        Divider()
                    }
                    radioControl
                    modeControl
                    Divider()
                    bandsControl
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 14)  // room for the scroll bar
            }
            ResultLine(controller: controller)
        }
        .padding()
        .frame(minWidth: 480, minHeight: 420)
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

    /// One row per RAT (its summary as `RMNet bands` prints it, Change… and Reset), then Reset all; while the
    /// bands are unknown, `Bands: not read yet` or why the read failed.
    @ViewBuilder private var bandsControl: some View {
        if let sets = controller.bands {
            Text("Bands")
                .font(.headline)
            if let failure = controller.bandsFailure {
                Text(verbatim: "\(failure) The bands below may be out of date.")
                    .foregroundStyle(Color.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(sets, id: \.rat) { set in
                    GridRow {
                        Text(verbatim: set.rat.name)
                            .foregroundStyle(.secondary)
                        Text(verbatim: bandsSummary(set))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Change…") { openBands(set) }
                            .disabled(!controller.bandsChangeEnabled)
                            .accessibilityLabel(Text(verbatim: "Change the \(set.rat.name) bands…"))
                        Button("Reset") { controller.resetBands(set.rat) }
                            .disabled(!controller.bandsResetEnabled(set.rat))
                            .accessibilityLabel(Text(verbatim: "Reset the \(set.rat.name) bands"))
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Reset allows every supported band again, at once; the modem may re-select a cell and drop "
                     + "the connection for a few seconds.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Reset all") { controller.resetAllBands() }
                    .disabled(!controller.resetAllBandsEnabled)
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("Bands:")
                    .font(.headline)
                Text(verbatim: controller.bandsFailure ?? "not read yet")
                    .foregroundStyle(controller.bandsFailure == nil ? Color.secondary : Color.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
    }

    private func openBands(_ set: BandSet) {
        guard controller.bandsChangeEnabled else { return }
        editing = BandsEdit(opened: set)
        controller.setConfirming(true)
    }

    @ViewBuilder private var radioControl: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Radio")
                .font(.headline)
            if let radio = controller.info?.radio {
                Text(verbatim: radioStateWords(radio))
                Spacer()
                if radio == .on {
                    Button("Radio Off…") {
                        let q = radioOffQuestion()
                        ask(Question(action: .radioOff, title: q.title, message: q.message, confirm: "Switch Off",
                                     destructive: true))
                    }
                    .disabled(!controller.refreshEnabled)
                } else {
                    Button("Radio On") { controller.setRadio(on: true) }
                        .disabled(!controller.refreshEnabled)
                }
            } else {
                Text("not read")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    @ViewBuilder private var modeControl: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Network mode")
                .font(.headline)
            if controller.pickedMode != nil {
                Picker("Network mode", selection: pickedChoice) {
                    ForEach(modeChoices, id: \.self) { mode in
                        Text(verbatim: modeWords(mode)).tag(Optional(mode))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!controller.refreshEnabled)
                Spacer()
                Button("Change…") {
                    guard let picked = controller.pickedMode else { return }
                    let q = modeQuestion(from: controller.info?.mode, to: picked)
                    ask(Question(action: .changeMode, title: q.title, message: q.message, confirm: "Change"))
                }
                .disabled(!controller.modeChangeEnabled)
            } else {
                Text("not read")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        if case .mode(let before)? = controller.undo {
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

/// The sheet Change… opens for one RAT: a checkbox for each band it supports (`B3` for LTE, `n41` for 5G),
/// ticked for those it may use as read when the sheet opened; Select all and Clear; the warning; Apply (the
/// default button), off with nothing ticked or with the bands allowed now (the controller's
/// bandsApplyEnabled), and Cancel. Apply calls `apply` with the bands ticked, sorted; the tab then closes the
/// sheet.
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
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: "\(opened.rat.name) bands")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(rows, id: \.self) { row in
                    GridRow {
                        ForEach(row, id: \.self) { band in
                            Toggle(isOn: tick(band)) {
                                Text(verbatim: bandLabel(opened.rat, band))
                                    .monospacedDigit()
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            HStack {
                Button("Select all") { ticked = Set(opened.supported) }
                    .disabled(ticked == Set(opened.supported))
                Button("Clear") { ticked = [] }
                    .disabled(ticked.isEmpty)
            }
            Text("The modem may re-select a cell and drop the connection for a few seconds.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply(ticked.sorted()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!controller.bandsApplyEnabled(opened.rat, Array(ticked)))
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
