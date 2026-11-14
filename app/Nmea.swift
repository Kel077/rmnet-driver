// The gps verb's logic, apart from the port so that `make app-test` covers it without hardware: NMEA 0183
// sentences, coordinates, the report built from the sentences, the verb's outcome text and its
// arguments. Foundation only. Nothing here prints, logs or stores a position.
import Foundation

// One sentence. "$GPRMC,123519,A,...*6A" is talker "GP", type "RMC" and the fields after the address,
// so fields[0] is "123519".
struct NmeaSentence: Equatable {
    let talker: String
    let type: String
    let fields: [String]
}

extension NmeaSentence {
    // The field at `index`, or "" when the sentence is shorter, so a short sentence reads as empty fields.
    func field(_ index: Int) -> String { index < fields.count ? fields[index] : "" }
}

enum Nmea {
    // A sentence, or nil. The line (trailing CR, LF and spaces ignored) starts with "$"; its address (up
    // to the first comma) is 3 to 10 ASCII letters or digits; it ends with "*" and two hex digits (either
    // case) equal to the XOR of every byte between "$" and "*". The talker is the address's first two
    // characters and the type the rest.
    static func parse(_ line: String) -> NmeaSentence? {
        var bytes = Array(line.utf8)
        while let last = bytes.last, last == 0x0D || last == 0x0A || last == 0x20 { bytes.removeLast() }
        let n = bytes.count
        guard n >= 4, bytes[0] == UInt8(ascii: "$"), bytes[n - 3] == UInt8(ascii: "*"),
              let high = hexValue(bytes[n - 2]), let low = hexValue(bytes[n - 1]) else { return nil }
        let body = bytes[1 ..< n - 3]
        guard body.reduce(0, ^) == high << 4 | low else { return nil }
        let parts = body.split(separator: UInt8(ascii: ","), omittingEmptySubsequences: false)
        guard let address = parts.first, (3...10).contains(address.count),
              address.allSatisfy({ isDigit($0) || isLetter($0) }) else { return nil }
        let name = String(decoding: address, as: UTF8.self)
        return NmeaSentence(talker: String(name.prefix(2)), type: String(name.dropFirst(2)),
                            fields: parts.dropFirst().map { String(decoding: $0, as: UTF8.self) })
    }

    // Signed degrees from a latitude ("ddmm.mmmm" with N or S) or a longitude ("dddmm.mmmm" with E or
    // W): the two digits before the point and the digits after it are minutes, the digits before those
    // are degrees. S and W are negative. nil for an empty or malformed value, another hemisphere,
    // minutes of 60 or more, or more than 90 degrees of latitude or 180 of longitude.
    static func coordinate(_ value: String, _ hemisphere: String) -> Double? {
        let limit: Double
        let sign: Double
        switch hemisphere {
        case "N": (limit, sign) = (90, 1)
        case "S": (limit, sign) = (90, -1)
        case "E": (limit, sign) = (180, 1)
        case "W": (limit, sign) = (180, -1)
        default: return nil
        }
        let bytes = Array(value.utf8)
        let point = bytes.firstIndex(of: UInt8(ascii: ".")) ?? bytes.count
        let whole = bytes[..<point]
        let fraction = point < bytes.count ? bytes[(point + 1)...] : []
        guard (3...5).contains(whole.count), whole.allSatisfy(isDigit), fraction.allSatisfy(isDigit) else { return nil }
        let text = { (digits: ArraySlice<UInt8>) in String(decoding: digits, as: UTF8.self) }
        let degrees = Double(text(whole.dropLast(2)))!
        let minutes = Double(text(whole.suffix(2)) + (fraction.isEmpty ? "" : "." + text(fraction)))!
        guard minutes < 60 else { return nil }
        let result = degrees + minutes / 60
        guard result <= limit else { return nil }
        return result == 0 ? 0 : sign * result  // never -0, which would print as "-0.000000"
    }

    private static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}

// Splits the bytes read from the port into lines: at LF, with a CR before the LF dropped and empty lines
// skipped; a partial line is kept for the next call. A line longer than 512 bytes (NMEA allows 82) is
// dropped up to its LF, so a port that never sends an LF cannot grow the buffer. Bytes that are not UTF-8
// are decoded lossily, and the checksum then rejects the line.
struct NmeaLineBuffer {
    private static let longestLine = 512
    private var pending: [UInt8] = []
    private var discarding = false  // the current line is too long; drop bytes until its LF

    mutating func append(_ bytes: [UInt8]) -> [String] {
        var lines: [String] = []
        for byte in bytes {
            if byte == 0x0A {
                if pending.last == 0x0D { pending.removeLast() }
                if !discarding, !pending.isEmpty, pending.count <= NmeaLineBuffer.longestLine {
                    lines.append(String(decoding: pending, as: UTF8.self))
                }
                pending.removeAll(keepingCapacity: true)
                discarding = false
            } else if !discarding {
                pending.append(byte)
                if pending.count > NmeaLineBuffer.longestLine + 1 {  // one more for the CR before the LF
                    pending.removeAll(keepingCapacity: true)
                    discarding = true
                }
            }
        }
        return lines
    }
}

// What the sentences read so far say. Every parsed sentence counts in `sentences`. The latest RMC or GGA
// decides the position: RMC with status A, or GGA with a quality of 1 or more, sets it and the time (GGA
// also the satellites used and the altitude); any other status or quality clears it (GGA also clears the
// satellites used and the altitude). A coordinate that does not parse is no position. GSV gives one
// talker's satellites in view (GP for GPS, GL for GLONASS, and so on), and `satellitesInView` sums each
// talker's latest.
struct GpsReport {
    private(set) var sentences = 0
    private(set) var latitude: Double?
    private(set) var longitude: Double?
    private(set) var altitude: Double?
    private(set) var satellitesUsed: Int?
    private(set) var time: String?  // hhmmss[.ss] in UTC, as the sentence gave it
    private var inViewByTalker: [String: Int] = [:]

    var satellitesInView: Int { inViewByTalker.values.reduce(0, +) }
    var hasFix: Bool { latitude != nil && longitude != nil }

    mutating func add(_ s: NmeaSentence) {
        sentences += 1
        switch s.type {
        case "RMC":
            guard s.field(1) == "A" else {
                setPosition(nil, nil)
                return
            }
            setPosition(Nmea.coordinate(s.field(2), s.field(3)), Nmea.coordinate(s.field(4), s.field(5)))
            time = s.field(0).isEmpty ? nil : s.field(0)
        case "GGA":
            guard let quality = Int(s.field(5)), quality >= 1 else {
                setPosition(nil, nil)
                satellitesUsed = nil
                altitude = nil
                return
            }
            setPosition(Nmea.coordinate(s.field(1), s.field(2)), Nmea.coordinate(s.field(3), s.field(4)))
            time = s.field(0).isEmpty ? nil : s.field(0)
            satellitesUsed = Int(s.field(6)).flatMap { $0 >= 0 ? $0 : nil }
            altitude = Double(s.field(8)).flatMap { $0.isFinite ? $0 : nil }
        case "GSV":
            if let count = Int(s.field(2)), count >= 0 { inViewByTalker[s.talker] = count }
        default:
            break
        }
    }

    // Both coordinates or neither.
    private mutating func setPosition(_ lat: Double?, _ lon: Double?) {
        if let lat = lat, let lon = lon {
            (latitude, longitude) = (lat, lon)
        } else {
            (latitude, longitude) = (nil, nil)
        }
    }
}

// The lines the gps verb prints after reading for `seconds`, and its exit code: 0 with a fix, 1 without.
// Only numbers parsed from the sentences are printed, never a field as it came.
func gpsOutcome(_ report: GpsReport, seconds: Int) -> (lines: [String], code: Int32) {
    guard report.sentences > 0 else {
        return (["gps: no NMEA sentences in \(seconds) s; GNSS may be off (AT+QGPS? on the console shows it, "
                 + "AT+QGPS=1 switches it on)"], 1)
    }
    guard let latitude = report.latitude, let longitude = report.longitude else {
        return (["gps: no fix after \(seconds) s (\(report.sentences) sentences, "
                 + "\(report.satellitesInView) satellites in view)"], 1)
    }
    var lines = [String(format: "gps: fix %.6f, %.6f", latitude, longitude)]
    var parts: [String] = []
    if let altitude = report.altitude { parts.append(String(format: "altitude %.1f m", altitude)) }
    if let used = report.satellitesUsed { parts.append("\(used) satellites used") }
    if let time = report.time.flatMap(clockTime) { parts.append("\(time) UTC") }
    if !parts.isEmpty { lines.append("  " + parts.joined(separator: ", ")) }
    return (lines, 0)
}

// "hh:mm:ss" from the first six characters of an NMEA time, or nil unless they are all digits.
private func clockTime(_ time: String) -> String? {
    let digits = Array(time.utf8.prefix(6))
    guard digits.count == 6, digits.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
    let pair = { (i: Int) in String(decoding: digits[i ..< i + 2], as: UTF8.self) }
    return "\(pair(0)):\(pair(2)):\(pair(4))"
}

// The words after "gps": none is 10 seconds; one whole number from 1 to 600 is that many seconds;
// anything else is wrong usage (nil).
func parseGps(_ words: [String]) -> Int? {
    if words.isEmpty { return 10 }
    guard words.count == 1, let seconds = Int(words[0]), (1...600).contains(seconds) else { return nil }
    return seconds
}
