// The gps verb: reads the NMEA sentences of the modem's GNSS receiver from its NMEA interface (USB
// interface 1), which the driver presents as a serial device, and prints the position. It only reads:
// nothing is written to the port, so no modem setting changes (GNSS is switched on and off on the
// owner's console), and nothing is logged. The position goes to standard output only.
import Foundation

let nmeaPortPath = "/dev/cu.RM520N-GL-NMEA"

// Reads until `seconds` after the start or, once the sentences give a fix, for at most one more second
// (the rest of that second's sentences), then prints gpsOutcome's lines and returns its exit code.
// Runs on the calling thread.
func runGps(seconds: Int) -> Int32 {
    guard FileManager.default.fileExists(atPath: nmeaPortPath) else {
        print("gps: \(nmeaPortPath) not found (the driver is not attached to the modem's NMEA interface)")
        return 1
    }
    // O_NONBLOCK: the open does not wait for a carrier, and reads never block (poll waits instead).
    let fd = open(nmeaPortPath, O_RDONLY | O_NOCTTY | O_NONBLOCK)
    guard fd >= 0 else {
        print("gps: cannot open \(nmeaPortPath): \(String(cString: strerror(errno)))")
        return 1
    }
    // Raw, so that the line discipline neither changes the bytes nor echoes them back to the port. A
    // failure is not fatal: the parser copes with cooked input (CRs made LFs, empty lines), though the
    // line discipline then echoes the sentences back to the port if the port's settings say so.
    var settings = termios()
    if tcgetattr(fd, &settings) == 0 {
        cfmakeraw(&settings)
        _ = tcsetattr(fd, TCSANOW, &settings)
    }

    var report = GpsReport()
    var lines = NmeaLineBuffer()
    var chunk = [UInt8](repeating: 0, count: 4096)
    let second: UInt64 = 1_000_000_000
    var deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(seconds, 0)) * second
    var sawFix = false
    while true {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { break }
        var request = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let milliseconds = min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max))
        let ready = poll(&request, 1, Int32(milliseconds))
        if ready < 0 && errno == EINTR { continue }
        if ready < 0 { break }
        if ready == 0 { continue }
        // Without POLLIN the port reports only a hang-up or an error: the port went away.
        guard request.revents & Int16(POLLIN) != 0 else { break }
        let count = read(fd, &chunk, chunk.count)
        if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
        guard count > 0 else { break }  // a read error or the end of the file: the port went away
        for line in lines.append(Array(chunk[..<count])) {
            if let sentence = Nmea.parse(line) { report.add(sentence) }
        }
        if report.hasFix && !sawFix {
            sawFix = true
            deadline = min(deadline, DispatchTime.now().uptimeNanoseconds + second)
        }
    }
    close(fd)

    let outcome = gpsOutcome(report, seconds: seconds)
    for line in outcome.lines { print(line) }
    return outcome.code
}
