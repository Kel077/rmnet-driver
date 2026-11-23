// Switching SIM slots by itself. The RM520N-GL uses one of its two SIM slots at a time (AT+QUIMSLOT, ModemSettings.swift),
// and nothing on this board tells it that a SIM was moved to the other slot: its SIM detection is off. So when a modem
// attaches and the slot in use has no usable SIM, RMNet switches to the other slot; if that one has none either, it
// switches back. At most one try for each attach, so it never switches back and forth.
//
// What counts as "no usable SIM": AT+CPIN? answering `+CME ERROR: 10` (SIM not inserted) or `+CME ERROR: 13` (SIM
// failure), as 3GPP TS 27.007 numbers them (simUnusable), for 25 s without a break, and only while AT+CFUN? says the
// radio is on (1): in minimum functionality (0) the modem powers the SIM down and answers so for a SIM that is there,
// and right after an attach a SIM can answer `+CME ERROR: 14` (busy) or 10 for a few seconds while it starts. A SIM
// that answers READY or asks for its PIN or PUK is there: nothing is done.
//
// SimSlotWatch is the decision, a value tested by tests/app/SimSlotWatchTests.swift; SimSlotWatcher runs it in the app:
// it reads the SIM in the app's background turn (ModemPulse.swift) while it watches, and switches with the modem
// screens' controller (ModemController.changeSimSlot), on the queue they share. Only the app does this; neither the
// command line nor the driver switches by itself.
import Combine
import Foundation

struct SimSlotWatch: Equatable {
    enum Phase: Equatable {
        case idle                                                // no modem, or this attach is settled
        case watching                                            // a modem attached; no verdict yet
        case unusable(since: Date, slot: Int, state: SimState)   // the slot in use has had no usable SIM since then
        case switching(from: Int, to: Int, reason: SimState)     // trying the other slot
        case switchingBack(original: Int, tried: Int, reason: SimState, triedState: SimState?)
    }

    enum Action: Equatable { case none, switchSlot(Int) }

    /// How long the slot in use must have no usable SIM before the other slot is tried.
    static let patience: TimeInterval = 25

    private(set) var phase: Phase = .idle

    /// The watcher wants the SIM read: a modem attached and no verdict yet.
    var wantsReads: Bool {
        switch phase {
        case .watching, .unusable: return true
        default: return false
        }
    }

    /// A modem came onto USB (or was there when the app started): watch it afresh.
    mutating func attached() { phase = .watching }

    /// The modem left USB, or the slot was switched in the window: nothing more for this attach.
    mutating func stop() { phase = .idle }

    /// A read of the SIM (AT+CPIN?), the radio (AT+CFUN?) and the slot (AT+QUIMSLOT?) at `at`. With `enabled` off
    /// (Settings) it keeps watching but never switches.
    mutating func read(sim: SimState?, radio: RadioState?, slot: Int?, at: Date, enabled: Bool) -> Action {
        guard wantsReads else { return .none }
        guard let sim, let slot, let radio else { return .none }      // a part not read: no verdict either way
        guard radio == .on else {
            phase = .watching                                       // the SIM may be powered down: start again
            return .none
        }
        if simUnusable(sim) {
            if case .unusable(let since, let s, _) = phase, s == slot {
                guard enabled, at.timeIntervalSince(since) >= SimSlotWatch.patience else { return .none }
                let other = otherSimSlot(slot)
                phase = .switching(from: slot, to: other, reason: sim)
                return .switchSlot(other)
            }
            phase = .unusable(since: at, slot: slot, state: sim)
            return .none
        }
        switch sim {
        case .busy:
            phase = .watching                                       // still starting: start again
        case .ready, .pin, .puk, .pin2, .puk2:
            phase = .idle                                           // a SIM is there
        case .notInserted, .failure, .other:
            break                                                   // another answer: no verdict
        }
        return .none
    }

    /// The switch asked for did not start (another change ran): try the other slot again after the patience (the
    /// try did not happen), or, switching back, switch back on the next turn (retryAction).
    mutating func notStarted() {
        if case .switching = phase { phase = .watching }
    }

    /// The switch back that did not start, asked again.
    var retryAction: Action {
        if case .switchingBack(let original, _, _, _) = phase { return .switchSlot(original) }
        return .none
    }

    /// What came of a switch: the action that follows (the switch back), and the line to show, if any.
    mutating func switched(_ outcome: Result<SimSlotChange, ModemFailure>) -> (action: Action, line: String?) {
        switch phase {
        case .switching(let from, let to, let reason):
            switch outcome {
            case .failure:
                phase = .idle
                return (.none, "\(reasonWords(reason, slot: from)); could not switch to SIM \(to).")
            case .success(let c) where !c.changed:
                phase = .idle                                       // switched elsewhere meanwhile
                return (.none, nil)
            case .success(let c):
                if let sim = c.sim, simUnusable(sim) {
                    phase = .switchingBack(original: from, tried: to, reason: reason, triedState: sim)
                    return (.switchSlot(from), nil)
                }
                phase = .idle
                return (.none, "Switched to SIM \(to): \(reasonWords(reason, slot: from).lowercasedFirst).")
            }
        case .switchingBack(let original, let tried, let reason, let triedState):
            phase = .idle
            switch outcome {
            case .failure:
                return (.none, "\(reasonWords(triedState ?? .notInserted, slot: tried)) either; could not switch back to SIM \(original).")
            case .success:
                let neither = reason == .notInserted && (triedState ?? .notInserted) == .notInserted
                return (.none, neither ? "No SIM in either slot." : "No usable SIM in either slot.")
            }
        default:
            return (.none, nil)
        }
    }
}

/// "No SIM in slot 1", "SIM failure in slot 1".
private func reasonWords(_ state: SimState, slot: Int) -> String {
    state == .failure ? "SIM failure in slot \(slot)" : "No SIM in slot \(slot)"
}

private extension String {
    /// "No SIM in slot 1" → "no SIM in slot 1"; "SIM failure…" stays.
    var lowercasedFirst: String {
        hasPrefix("SIM") ? self : prefix(1).lowercased() + dropFirst()
    }
}

/// Runs SimSlotWatch in the app: told when a modem comes onto USB or leaves it (the menu bar item's registry polls),
/// it asks for the SIM in the background turn while it watches, and switches with `switchSlot` (the modem screens'
/// controller: one change at a time, the quit waits for it). Its line says what it last did, for the SIM card.
final class SimSlotWatcher: ObservableObject {
    @Published private(set) var line: String? = nil
    @Published private(set) var lineAt: Date? = nil
    @Published private(set) var phase: SimSlotWatch.Phase = .idle

    static let commands = ["AT+CPIN?", "AT+CFUN?", "AT+QUIMSLOT?"]

    private var watch = SimSlotWatch() {
        didSet { if phase != watch.phase { phase = watch.phase } }
    }
    private var present = false
    private var switchRunning = false
    private let enabled: () -> Bool
    private let switchSlot: (Int, @escaping (Result<SimSlotChange, ModemFailure>) -> Void) -> Bool
    private let now: () -> Date

    /// `enabled`: Settings' Switch SIM slots automatically. `switchSlot`: starts a switch (false: it did not start)
    /// and calls back with its outcome on the main thread.
    init(enabled: @escaping () -> Bool,
         switchSlot: @escaping (Int, @escaping (Result<SimSlotChange, ModemFailure>) -> Void) -> Bool,
         now: @escaping () -> Date = { Date() }) {
        self.enabled = enabled
        self.switchSlot = switchSlot
        self.now = now
    }

    /// The slot it is about to try: the slot in use has no usable SIM, and switching by itself is on.
    var aboutToTry: (empty: Int, other: Int)? {
        guard case .unusable(_, let slot, _) = phase, enabled() else { return nil }
        return (slot, otherSimSlot(slot))
    }

    /// The modem is on USB (true) or not: a modem that appears is watched afresh, one that goes is forgotten.
    func modemPresent(_ isPresent: Bool) {
        if isPresent && !present { watch.attached() }
        if !isPresent && present { watch.stop() }
        present = isPresent
    }

    /// The slot was switched in the window: nothing more is done for this attach.
    func switchedByHand() {
        if !switchRunning { watch.stop() }
    }

    /// The commands for this background turn: the SIM, the radio and the slot while it watches; none otherwise. A switch
    /// back that could not start is asked again first.
    func pulseCommands() -> [String] {
        if !switchRunning, case .switchSlot(let slot) = watch.retryAction { start(slot) }
        return watch.wantsReads && !switchRunning ? SimSlotWatcher.commands : []
    }

    /// The turn's answers (keyed by command), or why the port could not be used (the turn is skipped).
    func pulseAnswers(_ answers: Result<[String: PulseAnswer], ModemFailure>) {
        guard case .success(let a) = answers else { return }
        let sim = a["AT+CPIN?"].flatMap(simState)
        let radio = a["AT+CFUN?"].flatMap { parseRadio($0.lines) }
        let slot = a["AT+QUIMSLOT?"].flatMap { parseSimSlot($0.lines) }
        if case .switchSlot(let other) = watch.read(sim: sim, radio: radio, slot: slot, at: now(), enabled: enabled()) {
            start(other)
        }
    }

    private func start(_ slot: Int) {
        switchRunning = true
        let started = switchSlot(slot) { [weak self] outcome in
            guard let self else { return }
            self.switchRunning = false
            let next = self.watch.switched(outcome)
            if let line = next.line {
                self.line = line
                self.lineAt = self.now()
            }
            if case .switchSlot(let back) = next.action { self.start(back) }
        }
        if !started {
            switchRunning = false
            watch.notStarted()
        }
    }
}
