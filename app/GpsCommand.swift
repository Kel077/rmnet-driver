// The gps verb: reads the NMEA sentences of the modem's GNSS receiver from its NMEA interface (USB
// interface 1), which the driver presents as a serial device, and prints the position. It only reads:
// nothing is written to the port, so no modem setting changes (GNSS is switched on and off on the
// owner's console), and nothing is logged. The position goes to standard output only.
import Foundation

let nmeaPortPath = "/dev/cu.RM520N-GL-NMEA"

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

// Reads the NMEA port for `seconds` (readGps), then prints what it gave and returns the exit code: 1
// when the port is missing or cannot be opened or set up, otherwise gpsOutcome's code.
func runGps(seconds: Int) -> Int32 {
    switch readGps(path: nmeaPortPath, seconds: seconds) {
    case .notFound:
        print("gps: \(nmeaPortPath) not found (the driver is not attached to the modem's NMEA interface)")
        return 1
    case .cannotOpen(let reason):
        print("gps: cannot open \(nmeaPortPath): \(reason)")
        return 1
    case .cannotSetUp(let reason):
        print("gps: cannot set up \(nmeaPortPath): \(reason)")
        return 1
    case .read(let report, let end):
        let outcome = gpsOutcome(report, seconds: seconds, end: end)
        for line in outcome.lines { print(line) }
        return outcome.code
    }
}
