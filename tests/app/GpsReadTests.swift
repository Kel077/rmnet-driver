// Tests for app/GpsCommand.swift. readGps reads a pseudo-terminal the test makes itself: the reader opens
// the pty's slave as it would the NMEA port, and a background thread plays the modem on the master. runGps
// runs with a fake GNSS switch that records its calls, on that pty (or with a reading given to it), with
// real signals sent to this process during the read, and once with standard output a pipe whose reader has
// gone (as `RMNet gps | head -1`); AtGnssSwitch runs against a scripted AT port. Never
// opens a real port: neither the NMEA port nor the AT port. Built with swiftc by `make app-test`, with
// app/Nmea.swift and the AT port's files (app/AtPort.swift, app/ModemService.swift for AtCommanding,
// app/SmsService.swift for describe, and what they need); needs no Xcode project and no hardware. Stops
// at the first failure, prints which check failed and exits 1.
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

// The sentences of NmeaTests: a fix (RMC and GGA), and a receiver with no fix (four sentences).
let fixLines = [
    "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A",
    "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47",
]
let noFixLines = ["$GPRMC,,V,,,,,,,,,,N*53", "$GPGGA,,,,,,0,,,,,,,,*66", "$GPGSV,1,1,00*79", "$GPVTG,,T,,M,,N,,K,N*2C"]

// A pty pair. The test keeps a descriptor on the slave too, so that the tty stays open while the reader
// opens and closes it, and so that its settings and its input queue can be seen from here.
struct Pty {
    let master: Int32
    let slave: Int32
    let path: String

    init() {
        master = posix_openpt(O_RDWR | O_NOCTTY)
        check(master >= 0, "posix_openpt", String(cString: strerror(errno)))
        check(grantpt(master) == 0 && unlockpt(master) == 0, "grantpt and unlockpt", String(cString: strerror(errno)))
        guard let name = ptsname(master) else {
            check(false, "ptsname", String(cString: strerror(errno)))
            fatalError()
        }
        path = String(cString: name)
        slave = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        check(slave >= 0, "open the pty's slave", String(cString: strerror(errno)))
        // A tty as a new one is (canonical, no CLOCAL), so that the reader is seen to change it.
        var settings = termios()
        check(tcgetattr(slave, &settings) == 0, "tcgetattr on the slave")
        settings.c_lflag |= tcflag_t(ICANON)
        settings.c_cflag &= ~tcflag_t(CLOCAL)
        check(tcsetattr(slave, TCSANOW, &settings) == 0, "tcsetattr on the slave")
    }

    // True when the tty is raw (not canonical, no echo) with CLOCAL and CREAD: what the reader sets.
    var isRawWithClocal: Bool {
        var settings = termios()
        guard tcgetattr(slave, &settings) == 0 else { return false }
        return settings.c_lflag & tcflag_t(ICANON | ECHO) == 0
            && settings.c_cflag & tcflag_t(CLOCAL | CREAD) == tcflag_t(CLOCAL | CREAD)
    }

    // The bytes waiting in the tty's input queue, which the reader has not read yet. FIONREAD is
    // _IOR('f', 127, int), a macro Swift does not import.
    var unread: Int32 {
        let fionread: UInt = 0x4004_667F
        var count: Int32 = 0
        return ioctl(slave, fionread, &count) == 0 ? count : -1
    }

    func write(_ lines: [String]) -> Bool {
        let bytes = Array(lines.map { $0 + "\r\n" }.joined().utf8)
        return Foundation.write(master, bytes, bytes.count) == bytes.count
    }

    func closeAll() {
        close(master)
        close(slave)
    }
}

// Waits up to 2 s, in steps of 10 ms, for `condition`.
func waitFor(_ condition: () -> Bool) -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        usleep(10_000)
    }
    return condition()
}

// What the background thread saw, read by the main thread once readGps has returned.
final class Modem {
    var sawRaw = false
    var wrote = false
    var drained = false
}

// readGps on the pty's slave while `play` runs on a background thread; the result and its duration.
func readWhile(_ pty: Pty, seconds: Int, play: @escaping () -> Void) -> (GpsRead, Double) {
    Thread { play() }.start()
    let start = Date()
    let result = readGps(path: pty.path, seconds: seconds)
    return (result, Date().timeIntervalSince(start))
}

// MARK: - runGps with a fake GNSS switch

// Everything runGps did, in order: "call: <name>" for each call of the switch and of the reader, "out: "
// and "err: " for each line written to standard output and standard error. Locked: the signal handler
// writes from another thread.
final class Log {
    private let lock = NSLock()
    private var all: [String] = []

    func call(_ name: String) { add("call: " + name) }
    func out(_ line: String) { add("out: " + line) }
    func err(_ line: String) { add("err: " + line) }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return all
    }

    func count(_ line: String) -> Int { lines.filter { $0 == line }.count }

    private func add(_ line: String) {
        lock.lock()
        all.append(line)
        lock.unlock()
    }
}

// A GNSS switch that answers as it is told and notes each call in the log.
final class FakeGnss: GnssSwitching {
    private let log: Log
    private let stateAnswer: Result<Bool, GnssFailure>
    private let onAnswer: Result<Void, GnssFailure>
    private let offAnswer: Result<Void, GnssFailure>

    init(_ log: Log, state: Result<Bool, GnssFailure>, on: Result<Void, GnssFailure> = .success(()),
         off: Result<Void, GnssFailure> = .success(())) {
        self.log = log
        stateAnswer = state
        onAnswer = on
        offAnswer = off
    }

    func state() -> Result<Bool, GnssFailure> {
        log.call("state")
        return stateAnswer
    }

    func switchOn() -> Result<Void, GnssFailure> {
        log.call("on")
        return onAnswer
    }

    func switchOff() -> Result<Void, GnssFailure> {
        log.call("off")
        return offAnswer
    }
}

// What the signal handler handed on, in place of ending the process.
final class Caught {
    private let lock = NSLock()
    private var all: [Int32] = []

    func add(_ sig: Int32) {
        lock.lock()
        all.append(sig)
        lock.unlock()
    }

    var signals: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return all
    }
}

let busy = GnssFailure(reason: "another program is using the modem's spare AT port")
let noAnswer = GnssFailure(reason: "the modem did not answer in time")
let refused = GnssFailure(reason: "the modem refused the command (+CME ERROR: 503)")
// AT+QGPS=1 without an answer in time: the modem may have switched GNSS on all the same.
let lostAnswer = GnssFailure(reason: "the modem did not answer in time", mayBeOn: true)
let hint = "; GNSS may be off (RMNet at AT+QGPS? shows it, RMNet at AT+QGPS=1 switches it on, "
    + "RMNet at AT+QGPSEND switches it off)"
let firstFix = "; a first fix can take minutes: try RMNet gps 120, or --keep-on"
let fixOutput = ["out: gps: fix 48.117300, 11.516667", "out:   altitude 545.4 m, 8 satellites used, 12:35:19 UTC"]

// runGps on `path` with the fake, writing to `log`; the reader is readGps, noted in the log as "read", or
// `reading` when given. No signal is watched unless `signals` are given; then a caught signal is handed to
// `caught` instead of ending the process.
func run(_ log: Log, _ gnss: GnssSwitching, path: String, seconds: Int, keepOn: Bool = false,
         reading: GpsRead? = nil, signals: [Int32] = [], caught: Caught = Caught()) -> Int32 {
    runGps(seconds: seconds, keepOn: keepOn, gnss: gnss, path: path,
           read: { path, seconds in
               log.call("read")
               return reading ?? readGps(path: path, seconds: seconds)
           },
           signals: signals, afterSignal: { caught.add($0) },
           output: { log.out($0) }, errorOutput: { log.err($0) })
}

func expectLog(_ log: Log, _ want: [String], _ name: String) {
    check(log.lines == want, name, "want \(want)\n  got  \(log.lines)")
}

// A report with the fix of fixLines.
func fixReport() -> GpsReport {
    var report = GpsReport()
    for line in fixLines { if let s = Nmea.parse(line) { report.add(s) } }
    return report
}

// MARK: - AtGnssSwitch against a scripted port

// A port that gives one answer and records what was sent.
final class OnePort: AtCommanding {
    private let answer: Result<[String], AtError>
    private(set) var sent: [(line: String, timeout: TimeInterval)] = []
    private(set) var closed = false

    init(_ answer: Result<[String], AtError>) { self.answer = answer }

    func command(_ line: String, timeout: TimeInterval) -> Result<[String], AtError> {
        sent.append((line: line, timeout: timeout))
        return closed ? .failure(.io(Int32(bitPattern: 0xE000_02CD))) : answer
    }

    func close() { closed = true }
}

// An AtGnssSwitch whose opens give `port` (or fail with `openFailure`), counted.
final class Opener {
    let port: OnePort
    let openFailure: AtError?
    private(set) var opens = 0

    init(_ answer: Result<[String], AtError>, openFailure: AtError? = nil) {
        port = OnePort(answer)
        self.openFailure = openFailure
    }

    var gnss: AtGnssSwitch {
        AtGnssSwitch(open: {
            self.opens += 1
            if let failure = self.openFailure { return .failure(failure) }
            return .success(self.port)
        })
    }

    // One open, `line` sent once with `timeout`, and the port closed.
    func sentOnce(_ line: String, _ timeout: TimeInterval) -> Bool {
        opens == 1 && port.sent.count == 1 && port.sent[0].line == line && port.sent[0].timeout == timeout && port.closed
    }
}

func expectSwitch<T: Equatable>(_ got: Result<T, GnssFailure>, _ want: Result<T, GnssFailure>, _ name: String) {
    check(got == want, "AtGnssSwitch: \(name)", "want \(want), got \(got)")
}

func runGnssTests() {
    let off = Opener(.success(["+QGPS: 0"]))
    expectSwitch(off.gnss.state(), .success(false), "+QGPS: 0 is off")
    check(off.sentOnce("AT+QGPS?", 3), "AtGnssSwitch: state sends AT+QGPS? once (3 s) on its own port, then closes it",
          "opens \(off.opens), sent \(off.port.sent), closed \(off.port.closed)")
    expectSwitch(Opener(.success(["+QGPS: 1"])).gnss.state(), .success(true), "+QGPS: 1 is on")
    expectSwitch(Opener(.success([])).gnss.state(), .failure(GnssFailure(reason: "the modem did not say whether GNSS is on")),
                 "an answer without +QGPS")
    expectSwitch(Opener(.failure(.modem("+CME ERROR: 3"))).gnss.state(),
                 .failure(GnssFailure(reason: "the modem refused the command (+CME ERROR: 3)")), "state refused")
    let held = Opener(.success(["+QGPS: 0"]), openFailure: .busy)
    expectSwitch(held.gnss.state(), .failure(busy), "the port held by another program")
    check(held.opens == 1 && held.port.sent.isEmpty, "AtGnssSwitch: nothing sent when the open fails")

    let on = Opener(.success([]))
    expectSwitch(on.gnss.switchOn().map { true }, .success(true), "AT+QGPS=1 answered OK")
    check(on.sentOnce("AT+QGPS=1", 5), "AtGnssSwitch: switchOn sends AT+QGPS=1 once (5 s), then closes the port",
          "opens \(on.opens), sent \(on.port.sent), closed \(on.port.closed)")
    expectSwitch(Opener(.failure(.modem("+CME ERROR: 504"))).gnss.switchOn().map { true }, .success(true),
                 "+CME ERROR: 504 (a session is running) is on")
    expectSwitch(Opener(.failure(.modem("+CME ERROR: 503"))).gnss.switchOn().map { true }, .failure(refused),
                 "switch on refused: GNSS is not on")
    // AT+QGPS=1 sent and its answer lost (no answer in time, an I/O error): GNSS may be on.
    let late = Opener(.failure(.timeout))
    expectSwitch(late.gnss.switchOn().map { true }, .failure(lostAnswer), "switch on: no answer, so GNSS may be on")
    check(late.port.closed, "AtGnssSwitch: the port is closed after a timeout too")
    let ioError = AtError.io(Int32(bitPattern: 0xE000_02ED))
    expectSwitch(Opener(.failure(ioError)).gnss.switchOn().map { true },
                 .failure(GnssFailure(reason: gnssReason(ioError), mayBeOn: true)),
                 "switch on: an I/O error after the port opened, so GNSS may be on")
    // Nothing sent (the port not opened), or the modem's own refusal: GNSS is not on.
    let notOpened = Opener(.success([]), openFailure: ioError)
    expectSwitch(notOpened.gnss.switchOn().map { true }, .failure(GnssFailure(reason: gnssReason(ioError))),
                 "switch on: an I/O error opening the port sent nothing, so GNSS is not on")
    check(notOpened.port.sent.isEmpty, "AtGnssSwitch: switch on sent nothing when the open failed")
    expectSwitch(Opener(.success([]), openFailure: .busy).gnss.switchOn().map { true }, .failure(busy),
                 "switch on: the port held by another program, so GNSS is not on")
    expectSwitch(Opener(.success([]), openFailure: .timeout).gnss.switchOn().map { true }, .failure(noAnswer),
                 "switch on: a timeout opening the port sent nothing, so GNSS is not on")

    let offAgain = Opener(.success([]))
    expectSwitch(offAgain.gnss.switchOff().map { true }, .success(true), "AT+QGPSEND answered OK")
    check(offAgain.sentOnce("AT+QGPSEND", 5), "AtGnssSwitch: switchOff sends AT+QGPSEND once (5 s), then closes the port",
          "opens \(offAgain.opens), sent \(offAgain.port.sent), closed \(offAgain.port.closed)")
    expectSwitch(Opener(.failure(.modem("+CME ERROR: 505"))).gnss.switchOff().map { true }, .success(true),
                 "+CME ERROR: 505 (no session) is off")
    expectSwitch(Opener(.failure(.modem("+CME ERROR: 504"))).gnss.switchOff().map { true },
                 .failure(GnssFailure(reason: "the modem refused the command (+CME ERROR: 504)")), "switch off refused")
    expectSwitch(Opener(.success([]), openFailure: .modemNotAttached).gnss.switchOff().map { true },
                 .failure(GnssFailure(reason: "the RM520N-GL (USB 2c7c:0801) is not attached")), "switch off: no modem")
    expectSwitch(Opener(.failure(.timeout)).gnss.switchOff().map { true }, .failure(noAnswer),
                 "switch off: no answer (mayBeOn is for switch on only)")
    expectSwitch(Opener(.failure(.timeout)).gnss.state(), .failure(noAnswer), "state: no answer")
    let ioReason = gnssReason(.io(Int32(bitPattern: 0xE000_02ED)))
    check(ioReason == "an I/O error occurred on the modem's spare AT port (code 0xe00002ed)", "gnssReason: an I/O error",
          ioReason)
}

@main
struct GpsReadTests {
    static func main() {
        // --- 1: a fix arrives at once and the port stays open: one more second, then the deadline --
        do {
            let pty = Pty()
            let modem = Modem()
            let (result, took) = readWhile(pty, seconds: 10) {
                modem.sawRaw = waitFor { pty.isRawWithClocal }
                modem.wrote = pty.write(fixLines)
            }
            check(modem.sawRaw, "fix: the reader made the tty raw with CLOCAL and CREAD before reading")
            check(modem.wrote, "fix: the master wrote the sentences")
            guard case .read(let report, let end) = result else {
                check(false, "fix: a reading", "got \(result)")
                return
            }
            check(report.hasFix && report.sentences == 2, "fix: RMC and GGA give a fix",
                  "got \(report.sentences) sentences, fix \(report.hasFix)")
            check(end == .deadline, "fix: ends at the deadline", "got \(end)")
            check(took < 3, "fix: returns within one second of the fix, not after 10 s", "took \(took) s")
            pty.closeAll()
        }

        // --- 2: nothing is written and the port stays open: the deadline after 1 s -----------------
        do {
            let pty = Pty()
            let (result, took) = readWhile(pty, seconds: 1) {}
            guard case .read(let report, let end) = result else {
                check(false, "silent: a reading", "got \(result)")
                return
            }
            check(report.sentences == 0, "silent: no sentences", "got \(report.sentences)")
            check(end == .deadline, "silent: ends at the deadline", "got \(end)")
            check(took >= 0.9 && took <= 2.5, "silent: about 1 s", "took \(took) s")
            check(pty.isRawWithClocal, "silent: the reader left the tty raw with CLOCAL and CREAD")
            pty.closeAll()
        }

        // --- 3: four sentences without a fix, then the master closes: the port closed --------------
        // On this Mac (Darwin 27) the slave reads end of file once the master has closed, so the end is
        // .closed; a pty slave elsewhere may see EIO (.failed) instead, which is accepted too.
        do {
            let pty = Pty()
            let modem = Modem()
            let (result, took) = readWhile(pty, seconds: 10) {
                modem.sawRaw = waitFor { pty.isRawWithClocal }
                modem.wrote = pty.write(noFixLines)
                // Closing the master flushes what the slave has not read, so wait until it is read.
                modem.drained = waitFor { pty.unread == 0 }
                close(pty.master)
            }
            check(modem.sawRaw && modem.wrote && modem.drained, "closed: the master wrote and the reader read",
                  "raw \(modem.sawRaw), wrote \(modem.wrote), read \(modem.drained)")
            guard case .read(let report, let end) = result else {
                check(false, "closed: a reading", "got \(result)")
                return
            }
            check(report.sentences == 4 && !report.hasFix, "closed: four sentences, no fix",
                  "got \(report.sentences) sentences, fix \(report.hasFix)")
            var closedOrFailed = end == .closed(elapsed: 0)
            if case .failed(elapsed: 0, _) = end { closedOrFailed = true }
            check(closedOrFailed, "closed: ends as closed (end of file) or failed (EIO) after 0 s", "got \(end)")
            check(took < 3, "closed: returns at once, not at the deadline", "took \(took) s")
            print("gpsread-test: after the master closed, the reading ended as \(end)")
            close(pty.slave)
        }

        // --- 4: no such path -----------------------------------------------------------------------
        let missing = NSTemporaryDirectory() + "gpsread-test-\(getpid())-missing"
        let notFound = readGps(path: missing, seconds: 1)
        var isNotFound = false
        if case .notFound = notFound { isNotFound = true }
        check(isNotFound, "missing: not found", "got \(notFound)")

        // --- 5: not a tty (/dev/null): the port cannot be set up -----------------------------------
        let notTty = readGps(path: "/dev/null", seconds: 1)
        var isCannotSetUp = false
        if case .cannotSetUp(let reason) = notTty, !reason.isEmpty { isCannotSetUp = true }
        check(isCannotSetUp, "not a tty: cannot set up", "got \(notTty)")

        // --- 6: a file that cannot be opened: cannot open ------------------------------------------
        let locked = NSTemporaryDirectory() + "gpsread-test-\(getpid())-locked"
        check(FileManager.default.createFile(atPath: locked, contents: Data(), attributes: [.posixPermissions: 0]),
              "unreadable: create the file")
        let unreadable = readGps(path: locked, seconds: 1)
        unlink(locked)
        var isCannotOpen = false
        if case .cannotOpen(let reason) = unreadable, reason == String(cString: strerror(EACCES)) { isCannotOpen = true }
        check(isCannotOpen, "unreadable: cannot open (permission denied)", "got \(unreadable)")

        // --- 7: runGps: GNSS off: on, the read (a fix), off ---------------------------------------
        do {
            let pty = Pty()
            let log = Log()
            Thread {
                if waitFor({ pty.isRawWithClocal }) { _ = pty.write(fixLines) }
            }.start()
            let code = run(log, FakeGnss(log, state: .success(false)), path: pty.path, seconds: 10)
            expectLog(log, ["call: state", "call: on", "err: " + GnssLine.switchedOn, "call: read"] + fixOutput
                      + ["call: off", "err: " + GnssLine.switchedOff], "runGps: off, so on, read, off")
            check(code == 0, "runGps: a fix exits 0", "got \(code)")
            pty.closeAll()
        }

        // --- 8: runGps: GNSS already on: says so, no switching; no hint after no sentences -----------
        do {
            let pty = Pty()
            let log = Log()
            let code = run(log, FakeGnss(log, state: .success(true)), path: pty.path, seconds: 1)
            expectLog(log, ["call: state", "err: " + GnssLine.alreadyOn, "call: read", "out: gps: no NMEA sentences in 1 s"],
                      "runGps: already on, so it says so at the start and switches neither on nor off")
            check(code == 1, "runGps: no sentences exits 1", "got \(code)")
            pty.closeAll()
        }

        // --- 8b: runGps: GNSS already on, sentences without a fix: no advice to wait ----------------
        do {
            let log = Log()
            var noFix = GpsReport()
            for line in noFixLines { if let s = Nmea.parse(line) { noFix.add(s) } }
            let code = run(log, FakeGnss(log, state: .success(true)), path: "/dev/null", seconds: 10,
                           reading: .read(noFix, .deadline))
            expectLog(log, ["call: state", "err: " + GnssLine.alreadyOn, "call: read",
                            "out: gps: no fix after 10 s (4 sentences, 0 satellites in view)"],
                      "runGps: already on, no fix: the line without the advice to wait")
            check(code == 1, "runGps: already on, no fix: exit 1", "got \(code)")
        }

        // --- 9: runGps --keep-on: on, the read, left on -------------------------------------------
        do {
            let pty = Pty()
            let log = Log()
            Thread {
                if waitFor({ pty.isRawWithClocal }) { _ = pty.write(noFixLines) }
            }.start()
            let code = run(log, FakeGnss(log, state: .success(false)), path: pty.path, seconds: 2, keepOn: true)
            expectLog(log, ["call: state", "call: on", "err: " + GnssLine.switchedOn, "call: read",
                            "out: gps: no fix after 2 s (4 sentences, 0 satellites in view)" + firstFix,
                            "err: " + GnssLine.leftOn],
                      "runGps --keep-on: no fix after 2 s with GNSS just on (wait longer), no off, and says GNSS is left on")
            check(code == 1, "runGps --keep-on: no fix exits 1", "got \(code)")
            pty.closeAll()
        }

        // --- 10: runGps: the state cannot be read: reads anyway, switches nothing, gives the hint ----
        do {
            let pty = Pty()
            let log = Log()
            let code = run(log, FakeGnss(log, state: .failure(busy)), path: pty.path, seconds: 1)
            expectLog(log, ["call: state", "err: " + GnssLine.checkFailed(busy.reason), "call: read",
                            "out: gps: no NMEA sentences in 1 s" + hint],
                      "runGps: state failed, so it reads anyway and says GNSS may be off")
            check(pty.isRawWithClocal, "runGps: state failed, and the port was read")
            check(code == 1, "runGps: state failed, no sentences: exit 1", "got \(code)")
            pty.closeAll()
        }

        // --- 11: runGps: switching on is refused: reads anyway, no off, gives the hint --------------
        do {
            let pty = Pty()
            let log = Log()
            let code = run(log, FakeGnss(log, state: .success(false), on: .failure(refused)), path: pty.path, seconds: 1)
            expectLog(log, ["call: state", "call: on", "err: " + GnssLine.switchOnFailed(refused.reason), "call: read",
                            "out: gps: no NMEA sentences in 1 s" + hint],
                      "runGps: switching on failed, so it reads anyway and never switches off")
            check(code == 1, "runGps: switching on failed: exit 1", "got \(code)")
            pty.closeAll()
        }

        // --- 11b: runGps: switching on lost its answer: GNSS may be on, so off at the end --------------
        do {
            let log = Log()
            let code = run(log, FakeGnss(log, state: .success(false), on: .failure(lostAnswer)), path: "/dev/null",
                           seconds: 1, reading: .read(GpsReport(), .deadline))
            expectLog(log, ["call: state", "call: on", "err: " + GnssLine.switchOnFailed(lostAnswer.reason), "call: read",
                            "out: gps: no NMEA sentences in 1 s" + hint, "call: off", "err: " + GnssLine.switchedOff],
                      "runGps: switching on lost its answer, so it reads anyway (with the hint) and switches off at the end")
            check(code == 1, "runGps: switching on lost its answer: exit 1", "got \(code)")
        }

        // --- 11c: the same, and switching off fails: says how to do it ----------------------------
        do {
            let log = Log()
            let code = run(log, FakeGnss(log, state: .success(false), on: .failure(lostAnswer), off: .failure(noAnswer)),
                           path: "/dev/null", seconds: 1, reading: .read(GpsReport(), .deadline))
            expectLog(log, ["call: state", "call: on", "err: " + GnssLine.switchOnFailed(lostAnswer.reason), "call: read",
                            "out: gps: no NMEA sentences in 1 s" + hint, "call: off",
                            "err: " + GnssLine.switchOffFailed(noAnswer.reason)],
                      "runGps: switching on lost its answer, then switching off failed, and it says so")
            check(code == 1, "runGps: lost answer, off failed: exit 1", "got \(code)")
        }

        // --- 11d: the same with --keep-on: no off; says GNSS may be on -------------------------------
        do {
            let log = Log()
            let code = run(log, FakeGnss(log, state: .success(false), on: .failure(lostAnswer)), path: "/dev/null",
                           seconds: 1, keepOn: true, reading: .read(GpsReport(), .deadline))
            expectLog(log, ["call: state", "call: on", "err: " + GnssLine.switchOnFailed(lostAnswer.reason), "call: read",
                            "out: gps: no NMEA sentences in 1 s" + hint, "err: " + GnssLine.mayBeOn],
                      "runGps --keep-on: switching on lost its answer, so no off, and it says GNSS may be on")
            check(code == 1, "runGps --keep-on: lost answer: exit 1", "got \(code)")
        }

        // --- 12: runGps: the port closes during the read: off all the same -----------------------
        do {
            let pty = Pty()
            let log = Log()
            Thread {
                guard waitFor({ pty.isRawWithClocal }), pty.write(noFixLines) else { return }
                _ = waitFor { pty.unread == 0 }
                close(pty.master)
            }.start()
            let code = run(log, FakeGnss(log, state: .success(false)), path: pty.path, seconds: 10)
            // As in 3: end of file on this Mac, EIO elsewhere.
            let ended = log.lines.count == 7 ? log.lines[4] : ""
            check(ended == "out: gps: the NMEA port closed after 0 s (4 sentences read)"
                  || ended.hasPrefix("out: gps: reading the NMEA port failed after 0 s: "),
                  "runGps: the port closed: says so", "got \(log.lines)")
            expectLog(log, ["call: state", "call: on", "err: " + GnssLine.switchedOn, "call: read", ended,
                            "call: off", "err: " + GnssLine.switchedOff], "runGps: the port closed, and GNSS is off again")
            check(code == 1, "runGps: the port closed: exit 1", "got \(code)")
            close(pty.slave)
        }

        // --- 13: runGps: a read fails: off all the same ------------------------------------------
        do {
            let log = Log()
            let failed = GpsRead.read(GpsReport(), .failed(elapsed: 3, reason: "Device not configured"))
            let code = run(log, FakeGnss(log, state: .success(false)), path: "/dev/null", seconds: 10, reading: failed)
            expectLog(log, ["call: state", "call: on", "err: " + GnssLine.switchedOn, "call: read",
                            "out: gps: reading the NMEA port failed after 3 s: Device not configured",
                            "call: off", "err: " + GnssLine.switchedOff], "runGps: a read failed, and GNSS is off again")
            check(code == 1, "runGps: a read failed: exit 1", "got \(code)")
        }

        // --- 14: runGps: the port cannot be set up: off all the same -----------------------------
        do {
            let log = Log()
            let code = run(log, FakeGnss(log, state: .success(false)), path: "/dev/null", seconds: 1)
            var notTtyReason = ""
            if case .cannotSetUp(let reason) = notTty { notTtyReason = reason }  // from 5
            let setUp = "out: gps: cannot set up /dev/null: " + notTtyReason
            expectLog(log, ["call: state", "call: on", "err: " + GnssLine.switchedOn, "call: read", setUp,
                            "call: off", "err: " + GnssLine.switchedOff], "runGps: the port cannot be set up, and GNSS is off again")
            check(code == 1, "runGps: cannot set up: exit 1", "got \(code)")
        }

        // --- 15: runGps: no port: GNSS is not touched -------------------------------------------
        do {
            let log = Log()
            let code = run(log, FakeGnss(log, state: .success(false)), path: missing, seconds: 1)
            expectLog(log, ["out: gps: \(missing) not found (the driver is not attached to the modem's NMEA interface)"],
                      "runGps: no port, so neither the state nor a switch is asked")
            check(code == 1, "runGps: no port: exit 1", "got \(code)")
        }

        // --- 16: runGps: switching off fails: says how to do it; the exit code is the reading's ----
        do {
            let log = Log()
            let code = run(log, FakeGnss(log, state: .success(false), off: .failure(noAnswer)), path: "/dev/null",
                           seconds: 10, reading: .read(fixReport(), .deadline))
            expectLog(log, ["call: state", "call: on", "err: " + GnssLine.switchedOn, "call: read"] + fixOutput
                      + ["call: off", "err: " + GnssLine.switchOffFailed(noAnswer.reason)],
                      "runGps: switching off failed, and it says so")
            check(code == 0, "runGps: a fix, then switching off failed: exit 0", "got \(code)")
        }

        // --- 17: runGps: SIGINT during the read: off at once, once --------------------------------
        // The signal is sent to this process (again every 50 ms, for up to 1 s, until the handler has run:
        // the watch is set up asynchronously); the handler hands it to `caught` instead of ending the process.
        // Each signal's action is the default first: a shell starts a background job with SIGINT ignored.
        for (sig, keepOn) in [(SIGINT, false), (SIGTERM, false), (SIGHUP, true)] {
            let name = "runGps: signal \(sig)\(keepOn ? " with --keep-on" : "")"
            let pty = Pty()
            let log = Log()
            let caught = Caught()
            let after = keepOn ? GnssLine.leftOn : GnssLine.switchedOff
            for s in [SIGINT, SIGTERM, SIGHUP] { signal(s, SIG_DFL) }
            Thread {
                guard waitFor({ pty.isRawWithClocal }) else { return }
                for _ in 0..<20 where caught.signals.isEmpty {
                    kill(getpid(), sig)
                    usleep(50_000)
                }
            }.start()
            let code = run(log, FakeGnss(log, state: .success(false)), path: pty.path, seconds: 2, keepOn: keepOn,
                           signals: [SIGINT, SIGTERM, SIGHUP], caught: caught)
            check(waitFor { !caught.signals.isEmpty } && caught.signals.allSatisfy { $0 == sig },
                  "\(name): the handler ran for it", "caught \(caught.signals)")
            let offs = keepOn ? [] : ["call: off"]
            expectLog(log, ["call: state", "call: on", "err: " + GnssLine.switchedOn, "call: read"] + offs
                      + ["err: " + after, "out: gps: no NMEA sentences in 2 s"],
                      "\(name): GNSS \(keepOn ? "left on" : "off") during the read, once, then the reading's own end")
            check(code == 1, "\(name): the reading's exit code", "got \(code)")
            // The watch is over: each signal's action is back to the default it was before.
            for s in [SIGINT, SIGTERM, SIGHUP] {
                check(signal(s, SIG_DFL) == nil, "\(name): signal \(s) is back to its default action")
            }
            pty.closeAll()
        }

        // --- 17b: runGps: a signal ignored before the run (nohup) stays ignored and is not watched ----
        do {
            let pty = Pty()
            let log = Log()
            let caught = Caught()
            signal(SIGINT, SIG_DFL)
            signal(SIGHUP, SIG_IGN)
            Thread {
                guard waitFor({ pty.isRawWithClocal }) else { return }
                for _ in 0..<5 {
                    kill(getpid(), SIGHUP)
                    usleep(50_000)
                }
            }.start()
            let code = run(log, FakeGnss(log, state: .success(false)), path: pty.path, seconds: 1,
                           signals: [SIGINT, SIGHUP], caught: caught)
            check(caught.signals.isEmpty, "runGps: an ignored SIGHUP is not handled", "caught \(caught.signals)")
            expectLog(log, ["call: state", "call: on", "err: " + GnssLine.switchedOn, "call: read",
                            "out: gps: no NMEA sentences in 1 s", "call: off", "err: " + GnssLine.switchedOff],
                      "runGps: an ignored SIGHUP changes nothing: off at the end as usual")
            check(code == 1, "runGps: an ignored SIGHUP: the reading's exit code", "got \(code)")
            check(SignalWatch.isIgnore(signal(SIGHUP, SIG_DFL)), "runGps: SIGHUP is still ignored after the run")
            check(signal(SIGINT, SIG_DFL) == nil, "runGps: SIGINT is back to its default action after the run")
            pty.closeAll()
        }

        // --- 18: GnssSession: the way back runs once, and nothing begins after it ------------------
        do {
            let log = Log()
            let session = GnssSession(gnss: FakeGnss(log, state: .success(false)), keepOn: false, errorOutput: { log.err($0) })
            check(session.begin() == .switchedOn, "GnssSession: switched on by this run")
            session.end()
            session.end()
            expectLog(log, ["call: state", "call: on", "err: " + GnssLine.switchedOn, "call: off", "err: " + GnssLine.switchedOff],
                      "GnssSession: end twice switches off once")
            let early = Log()
            let ended = GnssSession(gnss: FakeGnss(early, state: .success(false)), keepOn: false, errorOutput: { early.err($0) })
            ended.end()
            check(ended.begin() == .notKnownOn, "GnssSession: begin after end: GNSS not known on")
            expectLog(early, [], "GnssSession: begin after end asks nothing and switches nothing")
            let wasOn = Log()
            let already = GnssSession(gnss: FakeGnss(wasOn, state: .success(true)), keepOn: false, errorOutput: { wasOn.err($0) })
            check(already.begin() == .alreadyOn, "GnssSession: GNSS was on already")
            already.end()
            expectLog(wasOn, ["call: state", "err: " + GnssLine.alreadyOn],
                      "GnssSession: already on: says so, and the way back switches nothing")
        }

        // --- 19: runGps with standard output a pipe whose reader has gone (RMNet gps | head -1) --------
        // SIGPIPE has its default action first, which would end this process at the first write. runGps must
        // ignore it, so that its writes fail with EPIPE and GNSS is still switched off. Standard output is the
        // pipe only during the run; what stdio kept back of the failed writes is dropped before it is given back.
        do {
            var ends: [Int32] = [0, 0]
            check(pipe(&ends) == 0, "SIGPIPE: make a pipe", String(cString: strerror(errno)))
            close(ends[0])  // the reader has gone, as head after its first line
            signal(SIGPIPE, SIG_DFL)
            fflush(stdout)
            let saved = dup(STDOUT_FILENO)
            check(saved >= 0 && dup2(ends[1], STDOUT_FILENO) == STDOUT_FILENO, "SIGPIPE: standard output to the pipe",
                  String(cString: strerror(errno)))
            close(ends[1])
            let log = Log()
            // The default output (print, then fflush) and no signal watched.
            let code = runGps(seconds: 10, keepOn: false, gnss: FakeGnss(log, state: .success(false)), path: "/dev/null",
                              read: { _, _ in
                                  log.call("read")
                                  return .read(fixReport(), .deadline)
                              },
                              signals: [], afterSignal: { _ in }, errorOutput: { log.err($0) })
            let writesFailed = ferror(stdout) != 0
            let pipeIgnored = SignalWatch.isIgnore(signal(SIGPIPE, SIG_DFL))
            fpurge(stdout)
            clearerr(stdout)
            dup2(saved, STDOUT_FILENO)
            close(saved)
            check(writesFailed, "SIGPIPE: the writes to the closed pipe failed, and the process lived on")
            expectLog(log, ["call: state", "call: on", "err: " + GnssLine.switchedOn, "call: read", "call: off",
                            "err: " + GnssLine.switchedOff], "runGps: standard output closed, and GNSS is off again")
            check(code == 0, "runGps: standard output closed: the reading's exit code (a fix)", "got \(code)")
            check(pipeIgnored, "runGps: SIGPIPE is left ignored, so the flush at exit cannot end the process either")
        }

        // --- 20: AtGnssSwitch against a scripted port -----------------------------------------------
        runGnssTests()

        print("gpsread-test: \(checks) checks passed")
    }
}
