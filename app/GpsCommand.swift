// The gps verb: reads the NMEA sentences of the modem's GNSS receiver from its NMEA interface (USB
// interface 1), which the driver presents as a serial device, and prints the position. Nothing is
// written to the NMEA port. GNSS itself is switched over the modem's spare AT port (USB interface 3,
// AtPort): on when it is off, and off again afterwards on every way out, Ctrl-C included, unless
// --keep-on. Nothing is logged; the position goes to standard output only.
import Foundation

let nmeaPortPath = "/dev/cu.RM520N-GL-NMEA"

// MARK: - Switching GNSS

// Why GNSS could not be checked or switched, in words that fit in a line's parentheses. `mayBeOn` (switchOn
// only): the port was open and the command may have reached the modem, but its answer was lost (no answer in
// time, an I/O error), so the modem may have switched GNSS on all the same.
struct GnssFailure: Error, Equatable {
    let reason: String
    var mayBeOn = false
}

// The modem's GNSS receiver: whether it is on, and switching it on and off. Each call blocks until done.
protocol GnssSwitching {
    func state() -> Result<Bool, GnssFailure>      // true: on
    func switchOn() -> Result<Void, GnssFailure>
    func switchOff() -> Result<Void, GnssFailure>
}

// describe's sentence for an AT port failure as a clause: its first letter lower-cased and its final
// period dropped ("the modem did not answer in time").
func gnssReason(_ error: AtError) -> String {
    var sentence = describe(error)
    if sentence.hasSuffix(".") { sentence.removeLast() }
    return sentence.prefix(1).lowercased() + sentence.dropFirst()
}

// GNSS over the modem's spare AT port. Each call opens a port (AtPort.open waits up to 2 s while another
// program holds it), sends one command and closes the port, also on failure. The timeouts are the modem
// service's: 3 s for the read, 5 s for each switch.
final class AtGnssSwitch: GnssSwitching {
    private static let readTimeout: TimeInterval = 3
    private static let switchTimeout: TimeInterval = 5
    private let open: () -> Result<AtCommanding, AtError>

    init(open: @escaping () -> Result<AtCommanding, AtError> = { AtPort.open().map { $0 as AtCommanding } }) {
        self.open = open
    }

    // What one command gave: the port could not be opened (nothing was sent), or the command's own result.
    private enum Outcome {
        case notOpened(AtError)
        case sent(Result<[String], AtError>)
    }

    private func command(_ line: String, timeout: TimeInterval) -> Outcome {
        switch open() {
        case .failure(let error):
            return .notOpened(error)
        case .success(let port):
            defer { port.close() }
            return .sent(port.command(line, timeout: timeout))
        }
    }

    // AT+QGPS?: "+QGPS: 1" is on, "+QGPS: 0" off.
    func state() -> Result<Bool, GnssFailure> {
        switch command("AT+QGPS?", timeout: AtGnssSwitch.readTimeout) {
        case .sent(.success(let lines)):
            guard let on = parseGnssState(lines) else {
                return .failure(GnssFailure(reason: "the modem did not say whether GNSS is on"))
            }
            return .success(on)
        case .notOpened(let error), .sent(.failure(let error)):
            return .failure(GnssFailure(reason: gnssReason(error)))
        }
    }

    // AT+QGPS=1. Its error 504 (a GNSS session is already running) means GNSS is on. No answer in time, or an
    // I/O error once the port was open, leaves it unknown whether the modem took the command: GNSS may be on.
    func switchOn() -> Result<Void, GnssFailure> {
        switch command("AT+QGPS=1", timeout: AtGnssSwitch.switchTimeout) {
        case .sent(.success), .sent(.failure(.modem("+CME ERROR: 504"))):
            return .success(())
        case .sent(.failure(let error)):
            var mayBeOn = error == .timeout
            if case .io = error { mayBeOn = true }
            return .failure(GnssFailure(reason: gnssReason(error), mayBeOn: mayBeOn))
        case .notOpened(let error):
            return .failure(GnssFailure(reason: gnssReason(error)))
        }
    }

    // AT+QGPSEND. Its error 505 (no GNSS session is running) means GNSS is off.
    func switchOff() -> Result<Void, GnssFailure> {
        switch command("AT+QGPSEND", timeout: AtGnssSwitch.switchTimeout) {
        case .sent(.success), .sent(.failure(.modem("+CME ERROR: 505"))):
            return .success(())
        case .notOpened(let error), .sent(.failure(let error)):
            return .failure(GnssFailure(reason: gnssReason(error)))
        }
    }
}

// The GNSS side of one gps run: begin() switches GNSS on when it is off, and end() is the one way back,
// called both at the run's normal end and by the signal handler. Both hold one lock, so a signal during
// begin() waits for it (and then switches GNSS off if it was switched on), and the way back runs once.
// The lines go to `errorOutput`.
final class GnssSession {
    private let gnss: GnssSwitching
    private let keepOn: Bool
    private let errorOutput: (String) -> Void
    private let lock = NSLock()
    private var switchedOn = false   // this run switched GNSS on
    private var mayBeOn = false      // this run's switch on lost its answer, so GNSS may be on
    private var ended = false

    init(gnss: GnssSwitching, keepOn: Bool, errorOutput: @escaping (String) -> Void) {
        self.gnss = gnss
        self.keepOn = keepOn
        self.errorOutput = errorOutput
    }

    // Asks whether GNSS is on and, when it is off, switches it on; when it was on already, says so and
    // leaves it on. Gives what is known: .alreadyOn, .switchedOn, or .notKnownOn when its state could not be
    // read or switching it on failed. After end() it asks and switches nothing (.notKnownOn).
    func begin() -> GnssKnown {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return .notKnownOn }
        switch gnss.state() {
        case .failure(let failure):
            errorOutput(GnssLine.checkFailed(failure.reason))
            return .notKnownOn
        case .success(true):
            errorOutput(GnssLine.alreadyOn)
            return .alreadyOn
        case .success(false):
            switch gnss.switchOn() {
            case .success:
                switchedOn = true
                errorOutput(GnssLine.switchedOn)
                return .switchedOn
            case .failure(let failure):
                mayBeOn = failure.mayBeOn
                errorOutput(GnssLine.switchOnFailed(failure.reason))
                return .notKnownOn
            }
        }
    }

    // The way back, the first time only: if this run switched GNSS on, or may have (a switch on that lost its
    // answer), switches it off again; with --keep-on it sends nothing and says that GNSS is left on, or may be
    // on. Otherwise nothing.
    func end() {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return }
        ended = true
        guard switchedOn || mayBeOn else { return }
        if keepOn {
            errorOutput(switchedOn ? GnssLine.leftOn : GnssLine.mayBeOn)
            return
        }
        switch gnss.switchOff() {
        case .success: errorOutput(GnssLine.switchedOff)
        case .failure(let failure): errorOutput(GnssLine.switchOffFailed(failure.reason))
        }
    }
}

// While it runs, `signals` neither end the process nor interrupt a wait: each is ignored, and `handler`
// runs for it on a global queue (a dispatch source, which sees a signal also while it is ignored and
// whichever thread blocks it). A signal the process already ignored when the watch began (SIGINT in a
// background job of a script, SIGHUP under nohup) stays ignored and is not watched. stop() ends the watch
// and gives each signal back its earlier action.
final class SignalWatch {
    private var sources: [DispatchSourceSignal] = []
    private var earlier: [(signal: Int32, action: sig_t?)] = []

    init(_ signals: [Int32], handler: @escaping (Int32) -> Void) {
        for sig in signals {
            let action = signal(sig, SIG_IGN)
            guard !SignalWatch.isIgnore(action) else { continue }
            earlier.append((signal: sig, action: action))
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            source.setEventHandler { handler(sig) }
            source.resume()
            sources.append(source)
        }
    }

    // Whether `action` is SIG_IGN (C function pointers cannot be compared in Swift; their bits can).
    static func isIgnore(_ action: sig_t?) -> Bool {
        guard let action else { return false }  // SIG_DFL
        return unsafeBitCast(action, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self)
    }

    func stop() {
        for source in sources { source.cancel() }
        for (sig, action) in earlier { signal(sig, action) }
    }
}

// Ends the process by `sig` as if it had not been caught (Ctrl-C still ends the verb as interrupted): the
// default action again, the signal unblocked on this thread (a dispatch queue's thread blocks signals),
// and raised on it. Standard output is flushed first.
func dieBySignal(_ sig: Int32) {
    fflush(stdout)
    signal(sig, SIG_DFL)
    var set = sigset_t()
    sigemptyset(&set)
    sigaddset(&set, sig)
    pthread_sigmask(SIG_UNBLOCK, &set, nil)
    raise(sig)
    exit(128 + sig)  // not reached
}

// MARK: - Reading the NMEA port

// What reading a port gave: no such path, a port that could not be opened or set up (with strerror's
// text), or the report and how the reading ended.
enum GpsRead { case notFound, cannotOpen(String), cannotSetUp(String), read(GpsReport, GpsEnd) }

// Reads the NMEA sentences at `path` until `seconds` after the start or, once the sentences give a fix,
// for at most one more second (the rest of that second's sentences; the deadline is never extended),
// and stops at once if the port closes or a read fails. Never prints. Runs on the calling thread, and
// the descriptor is closed on every path.
func readGps(path: String, seconds: Int) -> GpsRead {
    guard FileManager.default.fileExists(atPath: path) else { return .notFound }
    // O_NONBLOCK: the open does not wait for a carrier, and reads never block (select waits instead).
    let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
    guard fd >= 0 else { return .cannotOpen(String(cString: strerror(errno))) }
    // Raw, so that the line discipline neither changes the bytes nor echoes them back to the modem, and
    // CLOCAL, so that a change of the carrier line cannot hang the port up. Both are required (a tty
    // left as it was could echo the sentences back to the modem), so a failure here ends the verb.
    var settings = termios()
    guard tcgetattr(fd, &settings) == 0 else {
        let reason = String(cString: strerror(errno))
        close(fd)
        return .cannotSetUp(reason)
    }
    cfmakeraw(&settings)
    settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
    guard tcsetattr(fd, TCSANOW, &settings) == 0 else {
        let reason = String(cString: strerror(errno))
        close(fd)
        return .cannotSetUp(reason)
    }

    var report = GpsReport()
    var lines = NmeaLineBuffer()
    var chunk = [UInt8](repeating: 0, count: 4096)
    let second: UInt64 = 1_000_000_000
    let start = DispatchTime.now().uptimeNanoseconds
    var deadline = start + UInt64(max(seconds, 0)) * second
    var sawFix = false
    let elapsed = { Int((DispatchTime.now().uptimeNanoseconds - start) / second) }
    let end: GpsEnd
    while true {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else {
            end = .deadline
            break
        }
        // select, not poll: macOS's poll(2) does not support devices (it answers POLLNVAL for them).
        // The timeout is what is left of the deadline, recomputed on every pass.
        let left = deadline - now
        var timeout = timeval(tv_sec: Int(left / second), tv_usec: Int32((left % second) / 1000))
        var readable = fd_set()
        __darwin_fd_set(fd, &readable)
        let ready = select(fd + 1, &readable, nil, nil, &timeout)
        if ready < 0 {
            if errno == EINTR { continue }
            end = .failed(elapsed: elapsed(), reason: String(cString: strerror(errno)))
            break
        }
        if ready == 0 { continue }  // the timeout: the loop's guard ends the reading
        let count = read(fd, &chunk, chunk.count)
        if count < 0 {
            if errno == EAGAIN || errno == EINTR { continue }
            end = .failed(elapsed: elapsed(), reason: String(cString: strerror(errno)))
            break
        }
        if count == 0 {  // the end of the file: the port hung up or went away
            end = .closed(elapsed: elapsed())
            break
        }
        for line in lines.append(Array(chunk[..<count])) {
            if let sentence = Nmea.parse(line) { report.add(sentence) }
        }
        if report.hasFix && !sawFix {
            sawFix = true
            deadline = min(deadline, DispatchTime.now().uptimeNanoseconds + second)
        }
    }
    close(fd)
    return .read(report, end)
}

// MARK: - The verb

// Without the NMEA port, prints that it is missing and asks nothing of GNSS. Otherwise: switches GNSS on
// when it is off (GnssSession.begin), reads the port for `seconds` (`read`, readGps), prints what it gave,
// and then takes the way back (GnssSession.end: GNSS off again if this run switched it on, unless
// `keepOn`). From before GNSS is asked until the way back, `signals` (Ctrl-C, SIGTERM, a hang-up) take the
// way back at once and are then handed to `afterSignal`, which ends the process by that signal. Returns
// the exit code: 1 when the port is missing or cannot be opened or set up, otherwise gpsOutcome's code;
// how GNSS was switched does not change it. The reading's lines go to `output`, the GNSS lines to
// `errorOutput`. Blocks: run it off the main thread.
//
// SIGPIPE is ignored from the start, for the rest of the process: with standard output (or standard error)
// a pipe whose reader has gone, as in `RMNet gps 2>&1 | head -1`, a write then fails with EPIPE instead of
// ending the process before the way back, and the flush at exit fails the same way.
func runGps(seconds: Int, keepOn: Bool, gnss: GnssSwitching = AtGnssSwitch(), path: String = nmeaPortPath,
            read: (String, Int) -> GpsRead = readGps(path:seconds:),
            signals: [Int32] = [SIGINT, SIGTERM, SIGHUP], afterSignal: @escaping (Int32) -> Void = dieBySignal,
            output: (String) -> Void = { print($0); fflush(stdout) },
            errorOutput: @escaping (String) -> Void = { fputs("\($0)\n", stderr) }) -> Int32 {
    signal(SIGPIPE, SIG_IGN)
    let notFound = "gps: \(path) not found (the driver is not attached to the modem's NMEA interface)"
    guard FileManager.default.fileExists(atPath: path) else {
        output(notFound)
        return 1
    }
    let session = GnssSession(gnss: gnss, keepOn: keepOn, errorOutput: errorOutput)
    let watch = SignalWatch(signals) { sig in
        session.end()
        afterSignal(sig)
    }
    defer { watch.stop() }
    let known = session.begin()

    let code: Int32
    switch read(path, seconds) {
    case .notFound:
        output(notFound)
        code = 1
    case .cannotOpen(let reason):
        output("gps: cannot open \(path): \(reason)")
        code = 1
    case .cannotSetUp(let reason):
        output("gps: cannot set up \(path): \(reason)")
        code = 1
    case .read(let report, let end):
        let outcome = gpsOutcome(report, seconds: seconds, end: end, gnss: known)
        for line in outcome.lines { output(line) }
        code = outcome.code
    }
    session.end()
    return code
}
