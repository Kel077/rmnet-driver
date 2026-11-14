// Tests for app/Nmea.swift: sentence parsing, coordinates, the report the gps verb builds from the
// sentences, its outcome text (also after the port closed or failed), the line buffer and the verb's
// arguments. Built with swiftc by
// `make app-test`; needs no Xcode project and no hardware (nothing here opens the port).
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

// Coordinates are compared to within 1e-6 degrees.
func near(_ value: Double?, _ want: Double) -> Bool {
    guard let value = value else { return false }
    return abs(value - want) <= 1e-6
}

// The sentences of the brief, numbered as it numbers them; every checksum is correct.
let line1 = "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A"
let line2 = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47"
let line3 = "$GPRMC,,V,,,,,,,,,,N*53"
let line4 = "$GPGGA,,,,,,0,,,,,,,,*66"
let line5 = "$GPGSV,1,1,00*79"
let line6 = "$GPVTG,,T,,M,,N,,K,N*2C"
let line7 = "$GNRMC,021500.00,A,3330.1234,S,07040.5678,W,0.0,,151126,,,A,V*15"
let line8 = "$GPGSV,3,1,11,01,40,083,46,02,17,308,41,12,07,344,39,14,22,228,45*7C"
let line9 = "$GLGSV,1,1,03,65,30,100,20,66,40,200,25,67,50,300,*53"
let line10 = "$GPGGA,021500.00,3330.1234,S,07040.5678,W,0,,,,,,,,*72"

// "$" + body + "*" + the body's checksum, for sentences made up here.
func withChecksum(_ body: String) -> String {
    let sum = body.utf8.reduce(UInt8(0), ^)
    return "$" + body + "*" + String(format: "%02X", sum)
}

// A report from sentences that must all parse.
func report(_ lines: [String], into start: GpsReport = GpsReport()) -> GpsReport {
    var r = start
    for line in lines {
        guard let s = Nmea.parse(line) else {
            check(false, "parse of a test sentence", line)
            continue
        }
        r.add(s)
    }
    return r
}

// The outcome after asking for 10 s, the reading having ended as `end` says.
func expectOutcome(_ r: GpsReport, _ lines: [String], _ code: Int32, _ name: String, end: GpsEnd) {
    let got = gpsOutcome(r, seconds: 10, end: end)
    check(got.lines == lines && got.code == code, "outcome: \(name)",
          "want \(lines) \(code), got \(got.lines) \(got.code)")
}

// The ways the same bytes may arrive in reads.
func chunkings(_ bytes: [UInt8]) -> [(String, [[UInt8]])] {
    var splitInCRLF: [[UInt8]] = [[]]
    for b in bytes {
        splitInCRLF[splitInCRLF.count - 1].append(b)
        if b == 0x0D { splitInCRLF.append([]) }  // a read ends between CR and LF
    }
    return [
        ("whole", [bytes]),
        ("byte by byte", bytes.map { [$0] }),
        ("split inside CR LF", splitInCRLF),
    ]
}

// Feeds `bytes` in every chunking and expects exactly `want` from the calls together.
func expectLines(_ bytes: [UInt8], _ want: [String], _ name: String) {
    for (how, chunks) in chunkings(bytes) {
        var buffer = NmeaLineBuffer()
        var got: [String] = []
        for chunk in chunks { got += buffer.append(chunk) }
        check(got == want, "line buffer: \(name) (\(how))", "want \(want), got \(got)")
    }
}

@main
struct NmeaTests {
    static func main() {
        // --- parse ---------------------------------------------------------------------------------
        let first = Nmea.parse(line1)
        check(first?.talker == "GP" && first?.type == "RMC", "parse: talker and type",
              "got \(String(describing: first))")
        check(first?.fields.count == 11, "parse: 11 fields (the address is not one)",
              "got \(first?.fields.count ?? -1)")
        check(first?.fields.first == "123519", "parse: fields[0] is the time")
        check(Nmea.parse(String(line1.dropLast(2)) + "6a") == first, "parse: lower-case checksum")
        check(Nmea.parse(line1 + "\r") == first, "parse: trailing CR")
        check(Nmea.parse(line1 + "  \r\n ") == first, "parse: trailing spaces, CR and LF")

        check(Nmea.parse(String(line1.dropLast(2)) + "6B") == nil, "parse: wrong checksum")
        check(Nmea.parse(String(line1.dropLast(3))) == nil, "parse: no checksum")
        check(Nmea.parse(String(line1.dropFirst())) == nil, "parse: no $")
        check(Nmea.parse("!AIVDM,1,1,,A,1,0*00") == nil, "parse: ! sentence")
        check(Nmea.parse("$G*00") == nil, "parse: one-letter address")
        check(Nmea.parse("") == nil, "parse: empty line")
        check(Nmea.parse(" " + line1) == nil, "parse: a space before $")
        check(Nmea.parse(withChecksum("GP")) == nil, "parse: two-letter address, right checksum")
        check(Nmea.parse(withChecksum("GPABCDEFGHI,1")) == nil, "parse: 11-character address, right checksum")
        check(Nmea.parse(withChecksum("GP-RM,1")) == nil, "parse: address with a dash, right checksum")
        check(Nmea.parse(String(withChecksum("GPRMC,1").dropLast(1)) + "G") == nil, "parse: checksum not hex")
        let shortest = Nmea.parse(withChecksum("GPX"))
        check(shortest == NmeaSentence(talker: "GP", type: "X", fields: []), "parse: three-character address, no fields",
              "got \(String(describing: shortest))")

        // --- coordinate ----------------------------------------------------------------------------
        check(near(Nmea.coordinate("4807.038", "N"), 48.1173), "coordinate: 4807.038 N")
        check(near(Nmea.coordinate("01131.000", "E"), 11.516667), "coordinate: 01131.000 E")
        check(near(Nmea.coordinate("3330.1234", "S"), -33.502057), "coordinate: 3330.1234 S")
        check(near(Nmea.coordinate("07040.5678", "W"), -70.676130), "coordinate: 07040.5678 W")
        check(Nmea.coordinate("", "N") == nil, "coordinate: empty")
        check(Nmea.coordinate("4807.038", "X") == nil, "coordinate: hemisphere X")
        check(Nmea.coordinate("4807.038", "") == nil, "coordinate: no hemisphere")
        check(Nmea.coordinate("4860.000", "N") == nil, "coordinate: 60 minutes")
        check(Nmea.coordinate("9100.000", "N") == nil, "coordinate: 91 degrees north")
        check(Nmea.coordinate("18100.000", "E") == nil, "coordinate: 181 degrees east")
        check(Nmea.coordinate("48a7.038", "N") == nil, "coordinate: not a number")
        let zero = Nmea.coordinate("0000.000", "S")
        check(zero == 0 && zero?.sign == .plus, "coordinate: zero south is +0 (never printed as -0)")

        // --- report: a fix from RMC and GGA --------------------------------------------------------
        let fix = report([line1, line2])
        check(fix.sentences == 2, "report: two sentences", "got \(fix.sentences)")
        check(fix.hasFix, "report: RMC and GGA give a fix")
        check(near(fix.latitude, 48.1173) && near(fix.longitude, 11.516667), "report: position",
              "got \(String(describing: fix.latitude)) \(String(describing: fix.longitude))")
        check(fix.altitude == 545.4, "report: altitude", "got \(String(describing: fix.altitude))")
        check(fix.satellitesUsed == 8, "report: satellites used", "got \(String(describing: fix.satellitesUsed))")
        check(fix.time == "123519", "report: time", "got \(String(describing: fix.time))")
        expectOutcome(fix, ["gps: fix 48.117300, 11.516667", "  altitude 545.4 m, 8 satellites used, 12:35:19 UTC"], 0,
                      "fix with altitude, satellites and time", end: .deadline)
        check(!report([line3], into: fix).hasFix, "report: a later RMC with status V clears the position")
        check(!report([withChecksum("GPRMC,123519,V,4807.038,N,01131.000,E,,,230394,,")]).hasFix,
              "report: RMC with status V and coordinates is no fix")
        check(!report([withChecksum("GPGGA,123519,4807.038,N,01131.000,E,0,08,0.9,545.4,M,46.9,M,,")]).hasFix,
              "report: GGA with quality 0 and coordinates is no fix")
        let cleared = report([line4], into: fix)
        check(!cleared.hasFix && cleared.satellitesUsed == nil && cleared.altitude == nil,
              "report: a later GGA with quality 0 clears the position, satellites used and altitude")

        // --- report: a receiver with no fix --------------------------------------------------------
        let noFix = report([line3, line4, line5, line6])
        check(noFix.sentences == 4, "report: no fix, four sentences", "got \(noFix.sentences)")
        check(!noFix.hasFix && noFix.latitude == nil && noFix.longitude == nil, "report: no fix")
        check(noFix.satellitesInView == 0, "report: none in view", "got \(noFix.satellitesInView)")
        expectOutcome(noFix, ["gps: no fix after 10 s (4 sentences, 0 satellites in view)"], 1, "no fix", end: .deadline)

        // --- report: satellites in view, the latest per talker -------------------------------------
        let inView = report([line8, line9])
        check(inView.satellitesInView == 14, "report: 11 GPS and 3 GLONASS in view", "got \(inView.satellitesInView)")
        let again = report([line8], into: inView)
        check(again.satellitesInView == 14, "report: the latest per talker, not a running sum",
              "got \(again.satellitesInView)")

        // --- report: south and west, then a GGA without a fix --------------------------------------
        let southWest = report([line7])
        check(southWest.hasFix, "report: RMC alone gives a fix")
        check(near(southWest.latitude, -33.502057) && near(southWest.longitude, -70.676130), "report: south and west",
              "got \(String(describing: southWest.latitude)) \(String(describing: southWest.longitude))")
        check(southWest.time == "021500.00", "report: time with hundredths", "got \(String(describing: southWest.time))")
        check(southWest.altitude == nil && southWest.satellitesUsed == nil, "report: RMC gives no altitude or count")
        expectOutcome(southWest, ["gps: fix -33.502057, -70.676130", "  02:15:00 UTC"], 0, "fix with time only",
                      end: .deadline)
        let lost = report([line10], into: southWest)
        check(!lost.hasFix && lost.latitude == nil && lost.longitude == nil, "report: the latest (GGA, quality 0) decides")
        check(lost.sentences == 2, "report: both sentences count", "got \(lost.sentences)")

        // --- report: a coordinate that does not parse is no position -------------------------------
        let badLatitude = report([withChecksum("GPRMC,123519,A,4860.000,N,01131.000,E,,,230394,,")])
        check(!badLatitude.hasFix && badLatitude.latitude == nil && badLatitude.longitude == nil,
              "report: RMC with 60 minutes of latitude has no position")

        // --- outcome: nothing read -----------------------------------------------------------------
        expectOutcome(GpsReport(), ["gps: no NMEA sentences in 10 s; GNSS may be off (AT+QGPS? on the console shows it, "
                                    + "AT+QGPS=1 switches it on)"], 1, "no sentences", end: .deadline)

        // --- outcome: the port closed or failed: never reported as the receiver's state ------------
        expectOutcome(noFix, ["gps: the NMEA port closed after 0 s (4 sentences read)"], 1, "port closed, no fix",
                      end: .closed(elapsed: 0))
        expectOutcome(GpsReport(), ["gps: the NMEA port closed after 7 s (0 sentences read)"], 1,
                      "port closed, nothing read", end: .closed(elapsed: 7))
        expectOutcome(GpsReport(), ["gps: reading the NMEA port failed after 3 s: Device not configured"], 1,
                      "read failed, nothing read", end: .failed(elapsed: 3, reason: "Device not configured"))
        expectOutcome(noFix, ["gps: reading the NMEA port failed after 0 s: Input/output error"], 1,
                      "read failed, no fix", end: .failed(elapsed: 0, reason: "Input/output error"))
        let fixLines = ["gps: fix 48.117300, 11.516667", "  altitude 545.4 m, 8 satellites used, 12:35:19 UTC"]
        expectOutcome(fix, fixLines, 0, "a fix, then the port closed", end: .closed(elapsed: 2))
        expectOutcome(fix, fixLines, 0, "a fix, then a read failed",
                      end: .failed(elapsed: 1, reason: "Device not configured"))

        // --- line buffer ---------------------------------------------------------------------------
        expectLines(Array((line5 + "\r\n" + line6 + "\r\n").utf8), [line5, line6], "two lines with CR LF")
        expectLines(Array((line5 + "\n").utf8), [line5], "a line ending in bare LF")
        expectLines(Array((line5 + "\r\n\r\n\n" + line6 + "\r\n").utf8), [line5, line6], "empty lines are skipped")
        expectLines(Array((line5 + "\r\n" + line6).utf8), [line5], "a partial line is kept back")
        expectLines([UInt8](repeating: 0x41, count: 600) + Array(("\n" + line5 + "\r\n").utf8), [line5],
                    "a line of 600 bytes is dropped up to its LF")
        expectLines([UInt8](repeating: 0x41, count: 512) + Array(("\r\n" + line5 + "\r\n").utf8),
                    [String(repeating: "A", count: 512), line5], "a line of 512 bytes is kept")
        expectLines([UInt8](repeating: 0x41, count: 513) + Array(("\r\n" + line5 + "\r\n").utf8), [line5],
                    "a line of 513 bytes is dropped")
        expectLines([UInt8](repeating: 0x41, count: 513) + Array(("\n" + line5 + "\n").utf8), [line5],
                    "a line of 513 bytes ending in bare LF is dropped")
        var lossy = NmeaLineBuffer()
        check(lossy.append([0xFF, 0xFE]).isEmpty, "line buffer: no line before the LF")
        let decoded = lossy.append([0x0A])
        check(decoded.count == 1 && Nmea.parse(decoded[0]) == nil, "line buffer: bytes that are not UTF-8",
              "got \(decoded)")

        // --- parseGps ------------------------------------------------------------------------------
        check(parseGps([]) == 10, "parseGps: no argument is 10 s")
        check(parseGps(["30"]) == 30, "parseGps: 30")
        check(parseGps(["1"]) == 1, "parseGps: 1")
        check(parseGps(["600"]) == 600, "parseGps: 600")
        for words in [["0"], ["601"], ["x"], ["10", "20"], ["-5"], [""], ["1.5"]] {
            check(parseGps(words) == nil, "parseGps: \(words) is wrong usage")
        }

        print("nmea-test: \(checks) checks passed")
    }
}
