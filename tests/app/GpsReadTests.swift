// Tests for readGps (app/GpsCommand.swift) against a pseudo-terminal the test makes itself: the reader
// opens the pty's slave as it would the NMEA port, and a background thread plays the modem on the
// master. Never opens a real port. Built with swiftc by `make app-test`, with app/Nmea.swift; needs no
// Xcode project and no hardware. Stops at the first failure, prints which check failed and exits 1.
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

        print("gpsread-test: \(checks) checks passed")
    }
}
