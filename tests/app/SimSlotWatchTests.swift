// Tests for app/SimSlotWatch.swift and app/AppSettings.swift: when the other SIM slot is tried (no usable SIM in the slot
// in use for 25 s, the radio on), when not (a SIM there, busy, the radio off, the setting off, no modem), what follows a
// switch (staying, or switching back once), the lines it leaves, never switching back and forth within one attach, a
// switch that did not start, and the watcher's commands, answers and attaches; then the settings' defaults and keeping.
// Built with swiftc by `make app-test` from app/ModemNetwork.swift, app/ModemSettings.swift, app/SimSlotWatch.swift,
// app/AppSettings.swift and this file; no AppKit, no modem.
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

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

/// A switch to `to` that read `sim` in the new slot.
func switched(_ from: Int, _ to: Int, _ sim: SimState?) -> Result<SimSlotChange, ModemFailure> {
    .success(SimSlotChange(before: from, after: to, sim: sim))
}

@main
struct SimSlotWatchTests {
    static func main() {
        waiting()
        notWhen()
        afterTheSwitch()
        backAndForth()
        notStarted()
        watcher()
        settings()
        print("SIM slot watch: \(checks) checks passed")
    }

    // No usable SIM for 25 s with the radio on: the other slot.
    static func waiting() {
        var w = SimSlotWatch()
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true), .none, "idle: no modem, nothing")
        check(!w.wantsReads, "idle: no reads wanted")
        w.attached()
        check(w.wantsReads, "attached: reads wanted")
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true), .none, "first empty read")
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(15), enabled: true), .none, "15 s: not yet")
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(24.9), enabled: true), .none, "24.9 s: not yet")
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(25), enabled: true), .switchSlot(2), "25 s: slot 2")
        equal(w.phase, .switching(from: 1, to: 2, reason: .notInserted), "switching")
        check(!w.wantsReads, "switching: no reads")

        // SIM failure (CME 13) counts too, from slot 2 to slot 1.
        var f = SimSlotWatch()
        f.attached()
        _ = f.read(sim: .failure, radio: .on, slot: 2, at: at(0), enabled: true)
        equal(f.read(sim: .failure, radio: .on, slot: 2, at: at(30), enabled: true), .switchSlot(1), "SIM failure: slot 1")
    }

    // A SIM there, busy, the radio off, a part not read, the setting off: no switch (or the wait starts again).
    static func notWhen() {
        var w = SimSlotWatch()
        w.attached()
        _ = w.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = w.read(sim: .busy, radio: .on, slot: 1, at: at(10), enabled: true)
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(26), enabled: true), .none, "busy started the wait again")
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(51), enabled: true), .switchSlot(2), "25 s after busy")

        var r = SimSlotWatch()
        r.attached()
        _ = r.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = r.read(sim: .failure, radio: .minimum, slot: 1, at: at(20), enabled: true)
        equal(r.read(sim: .notInserted, radio: .on, slot: 1, at: at(30), enabled: true), .none,
              "minimum functionality (the SIM powered down) started the wait again")
        _ = r.read(sim: .notInserted, radio: .airplane, slot: 1, at: at(60), enabled: true)
        equal(r.phase, .watching, "airplane mode: no verdict")

        var ready = SimSlotWatch()
        ready.attached()
        _ = ready.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = ready.read(sim: .ready, radio: .on, slot: 1, at: at(5), enabled: true)
        equal(ready.phase, .idle, "ready: settled")
        equal(ready.read(sim: .notInserted, radio: .on, slot: 1, at: at(60), enabled: true), .none, "settled: nothing more")
        var pin = SimSlotWatch()
        pin.attached()
        _ = pin.read(sim: .pin, radio: .on, slot: 1, at: at(0), enabled: true)
        equal(pin.phase, .idle, "asking for its PIN: a SIM is there")

        var unread = SimSlotWatch()
        unread.attached()
        _ = unread.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        equal(unread.read(sim: .notInserted, radio: nil, slot: 1, at: at(30), enabled: true), .none, "radio not read")
        equal(unread.read(sim: .notInserted, radio: .on, slot: nil, at: at(31), enabled: true), .none, "slot not read")
        equal(unread.read(sim: nil, radio: .on, slot: 1, at: at(32), enabled: true), .none, "SIM not read")
        equal(unread.read(sim: .other("+CME ERROR: 3"), radio: .on, slot: 1, at: at(33), enabled: true), .none,
              "another answer: no verdict")
        equal(unread.read(sim: .notInserted, radio: .on, slot: 1, at: at(34), enabled: true), .switchSlot(2),
              "the wait kept across reads with no verdict")

        var off = SimSlotWatch()
        off.attached()
        _ = off.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: false)
        equal(off.read(sim: .notInserted, radio: .on, slot: 1, at: at(60), enabled: false), .none, "setting off: no switch")
        equal(off.read(sim: .notInserted, radio: .on, slot: 1, at: at(61), enabled: true), .switchSlot(2),
              "setting turned on: switches at the next read")

        // Another slot reported (switched elsewhere) starts the wait again.
        var moved = SimSlotWatch()
        moved.attached()
        _ = moved.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        equal(moved.read(sim: .notInserted, radio: .on, slot: 2, at: at(30), enabled: true), .none, "slot changed: wait again")
    }

    // The new slot has a SIM: stay, with a line. Neither has: switch back once, with a line.
    static func afterTheSwitch() {
        var w = SimSlotWatch()
        w.attached()
        _ = w.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = w.read(sim: .notInserted, radio: .on, slot: 1, at: at(25), enabled: true)
        let ok = w.switched(switched(1, 2, .ready))
        equal(ok.action, .none, "ready in slot 2: stays")
        equal(ok.line, "Switched to SIM 2: no SIM in slot 1.", "ready in slot 2: the line")
        equal(w.phase, .idle, "ready in slot 2: settled")

        var p = SimSlotWatch()
        p.attached()
        _ = p.read(sim: .failure, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = p.read(sim: .failure, radio: .on, slot: 1, at: at(25), enabled: true)
        equal(p.switched(switched(1, 2, .pin)).line, "Switched to SIM 2: SIM failure in slot 1.", "a PIN in slot 2: stays")

        var n = SimSlotWatch()
        n.attached()
        _ = n.read(sim: .notInserted, radio: .on, slot: 2, at: at(0), enabled: true)
        _ = n.read(sim: .notInserted, radio: .on, slot: 2, at: at(25), enabled: true)
        let back = n.switched(switched(2, 1, .notInserted))
        equal(back.action, .switchSlot(2), "nothing in slot 1 either: back to slot 2")
        equal(back.line, nil, "no line before the switch back")
        let done = n.switched(switched(1, 2, .notInserted))
        equal(done.action, .none, "back: no more switches")
        equal(done.line, "No SIM in either slot.", "back: the line")
        equal(n.phase, .idle, "back: settled")

        var u = SimSlotWatch()
        u.attached()
        _ = u.read(sim: .failure, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = u.read(sim: .failure, radio: .on, slot: 1, at: at(25), enabled: true)
        _ = u.switched(switched(1, 2, .notInserted))
        equal(u.switched(switched(2, 1, .failure)).line, "No usable SIM in either slot.", "a failure and none: the line")

        var e = SimSlotWatch()
        e.attached()
        _ = e.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = e.read(sim: .notInserted, radio: .on, slot: 1, at: at(25), enabled: true)
        let failed = e.switched(.failure(ModemFailure(message: "The SIM slot was not changed. ERROR")))
        equal(failed.line, "No SIM in slot 1; could not switch to SIM 2.", "the switch failed: the line")
        equal(e.phase, .idle, "the switch failed: no second try")

        var b = SimSlotWatch()
        b.attached()
        _ = b.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = b.read(sim: .notInserted, radio: .on, slot: 1, at: at(25), enabled: true)
        _ = b.switched(switched(1, 2, .notInserted))
        equal(b.switched(.failure(ModemFailure(message: "busy"))).line,
              "No SIM in slot 2 either; could not switch back to SIM 1.", "the switch back failed: the line")

        var s = SimSlotWatch()
        s.attached()
        _ = s.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = s.read(sim: .notInserted, radio: .on, slot: 1, at: at(25), enabled: true)
        let same = s.switched(.success(SimSlotChange(before: 2, after: 2)))
        check(same.action == .none && same.line == nil && s.phase == .idle, "switched elsewhere meanwhile: nothing")
    }

    // Within one attach: one try, one switch back, then nothing, whatever the reads say; a new attach watches again.
    static func backAndForth() {
        var w = SimSlotWatch()
        w.attached()
        var switches = 0
        var slot = 1
        var time: TimeInterval = 0
        for _ in 0..<40 {
            if case .switchSlot(let to) = w.read(sim: .notInserted, radio: .on, slot: slot, at: at(time), enabled: true) {
                switches += 1
                var next = w.switched(switched(slot, to, .notInserted))
                slot = to
                while case .switchSlot(let back) = next.action {
                    switches += 1
                    next = w.switched(switched(slot, back, .notInserted))
                    slot = back
                }
            }
            time += 15
        }
        equal(switches, 2, "ten minutes of empty slots: one try and one switch back")
        equal(slot, 1, "back on the slot it started on")
        w.attached()
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(1000), enabled: true), .none, "a new attach: wait again")
        equal(w.read(sim: .notInserted, radio: .on, slot: 1, at: at(1025), enabled: true), .switchSlot(2),
              "a new attach: one try again")
    }

    // A switch that did not start: the try did not happen (watch again); a switch back is asked again.
    static func notStarted() {
        var w = SimSlotWatch()
        w.attached()
        _ = w.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = w.read(sim: .notInserted, radio: .on, slot: 1, at: at(25), enabled: true)
        w.notStarted()
        equal(w.phase, .watching, "the try did not start: watching again")
        equal(w.retryAction, .none, "no retry of a try")

        var b = SimSlotWatch()
        b.attached()
        _ = b.read(sim: .notInserted, radio: .on, slot: 1, at: at(0), enabled: true)
        _ = b.read(sim: .notInserted, radio: .on, slot: 1, at: at(25), enabled: true)
        _ = b.switched(switched(1, 2, .notInserted))
        b.notStarted()
        equal(b.retryAction, .switchSlot(1), "the switch back did not start: asked again")
        b.stop()
        equal(b.retryAction, .none, "stopped: nothing")
    }

    // The watcher: its commands while it watches, the answers turned into a switch, the attaches, a switch by hand.
    static func watcher() {
        var clock = at(0)
        var enabled = true
        var asked: [Int] = []
        var pending: [(Result<SimSlotChange, ModemFailure>) -> Void] = []
        var accept = true
        let w = SimSlotWatcher(enabled: { enabled }, switchSlot: { slot, done in
            guard accept else { return false }
            asked.append(slot)
            pending.append(done)
            return true
        }, now: { clock })
        func answers(_ cpin: PulseAnswer, cfun: String = "+CFUN: 1", slot: Int = 1) -> Result<[String: PulseAnswer], ModemFailure> {
            .success(["AT+CPIN?": cpin, "AT+CFUN?": .lines([cfun]), "AT+QUIMSLOT?": .lines(["+QUIMSLOT: \(slot)"])])
        }
        let empty = PulseAnswer.refused("+CME ERROR: 10")

        equal(w.pulseCommands(), [], "watcher: no modem, no commands")
        w.modemPresent(true)
        equal(w.pulseCommands(), SimSlotWatcher.commands, "watcher: attached, the three reads")
        w.pulseAnswers(answers(empty))
        clock = at(30)
        w.pulseAnswers(.failure(ModemFailure(message: "The modem's AT port is busy.")))
        check(asked.isEmpty, "watcher: a busy turn decides nothing")
        w.pulseAnswers(answers(empty))
        equal(asked, [2], "watcher: switches to slot 2")
        equal(w.pulseCommands(), [], "watcher: no reads while it switches")
        pending.removeFirst()(switched(1, 2, .ready))
        equal(w.line, "Switched to SIM 2: no SIM in slot 1.", "watcher: the line")
        equal(w.lineAt, at(30), "watcher: when")
        equal(w.pulseCommands(), [], "watcher: settled, no reads")

        // Still present: no new watch. Gone and back: a new one.
        w.modemPresent(true)
        equal(w.pulseCommands(), [], "watcher: still present, nothing new")
        w.modemPresent(false)
        w.modemPresent(true)
        equal(w.pulseCommands(), SimSlotWatcher.commands, "watcher: attached again, reads again")

        // Neither slot: the switch back follows by itself.
        asked = []
        clock = at(100)
        w.pulseAnswers(answers(empty))
        clock = at(130)
        w.pulseAnswers(answers(empty))
        equal(asked, [2], "watcher: tries slot 2")
        pending.removeFirst()(switched(1, 2, .notInserted))
        equal(asked, [2, 1], "watcher: and back to slot 1")
        pending.removeFirst()(switched(2, 1, .notInserted))
        equal(w.line, "No SIM in either slot.", "watcher: neither slot")

        // A switch back that could not start is asked again on the next turn.
        w.modemPresent(false)
        w.modemPresent(true)
        asked = []
        clock = at(200)
        w.pulseAnswers(answers(empty))
        clock = at(230)
        w.pulseAnswers(answers(empty))
        accept = false
        pending.removeFirst()(switched(1, 2, .notInserted))
        equal(asked, [2], "watcher: the switch back did not start")
        accept = true
        _ = w.pulseCommands()
        equal(asked, [2, 1], "watcher: the switch back asked again on the next turn")
        pending.removeFirst()(switched(2, 1, .notInserted))

        // A switch by hand stops the watch; the setting off never switches.
        w.modemPresent(false)
        w.modemPresent(true)
        w.switchedByHand()
        equal(w.pulseCommands(), [], "watcher: switched by hand, nothing more")
        w.modemPresent(false)
        w.modemPresent(true)
        enabled = false
        asked = []
        clock = at(300)
        w.pulseAnswers(answers(empty))
        clock = at(400)
        w.pulseAnswers(answers(empty))
        check(asked.isEmpty, "watcher: the setting off, no switch")
    }

    // The settings: on by default, kept, read back.
    static func settings() {
        let suite = "io.rmnetdriver.RMNet.tests.settings.\(getpid())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: defaults)
        check(s.simAutoSwitch && s.notifyMessages && s.notificationShowsText, "settings: on by default")
        s.simAutoSwitch = false
        s.notificationShowsText = false
        equal(defaults.object(forKey: "simAutoSwitch") as? Bool, false, "settings: kept under simAutoSwitch")
        equal(defaults.object(forKey: "notificationShowsText") as? Bool, false, "settings: kept under notificationShowsText")
        let again = AppSettings(defaults: defaults)
        check(!again.simAutoSwitch && again.notifyMessages && !again.notificationShowsText, "settings: read back")
        defaults.set("yes", forKey: "notifyNewMessages")
        check(AppSettings(defaults: defaults).notifyMessages, "settings: a value not a Bool is on")
    }
}
