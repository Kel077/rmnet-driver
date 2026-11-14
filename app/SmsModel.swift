// The pure SMS message model: reading the AT text the modem answers in PDU mode, decoding
// SMS-DELIVER PDUs, assembling multi-part messages, and encoding SMS-SUBMIT PDUs.
// Formats: 3GPP TS 23.040 (PDUs, addresses, user data header, time stamp), TS 23.038 (the GSM 7-bit
// default alphabet and its extension table, septet packing, the data coding scheme), TS 27.005
// (+CMGL, +CMGS, +CPMS). No I/O here; every function is total and never traps on any input.
import Foundation

enum SmsStatus: Int { case unread = 0, read = 1, unsent = 2, sent = 3 }

struct StoredPdu: Equatable { let index: Int; let status: SmsStatus; let hex: String }

struct SmsConcat: Equatable { let reference: Int; let total: Int; let sequence: Int }

/// One stored entry, decoded or not.
struct SmsPart: Equatable {
    let index: Int
    let status: SmsStatus
    let sender: String     // "" when not readable
    let timestamp: Date?   // the service centre's time, nil when absent or invalid
    let text: String       // "" when not readable
    let concat: SmsConcat?
    let readable: Bool     // false: not an SMS-DELIVER, or malformed
}

struct SmsMessage: Equatable {
    let indices: [Int]     // every stored index of the message, ascending
    let unread: Bool       // any part was unread when listed
    let sender: String
    let timestamp: Date?
    let text: String
    let missingParts: Int  // 0 when complete
    let readable: Bool
}

enum SmsEncoding { case gsm7, ucs2 }

/// tpduLength: octets after the SMSC field (what AT+CMGS takes).
struct SubmitPdu: Equatable { let hex: String; let tpduLength: Int }

/// A sentence for the owner.
struct SmsFailure: Error, Equatable { let message: String }

protocol SmsServing {
    func list() -> Result<[SmsMessage], SmsFailure>
    func delete(indices: [Int]) -> Result<Int, SmsFailure>               // stored entries deleted
    func send(to number: String, text: String) -> Result<Int, SmsFailure> // parts sent
}

// MARK: - The GSM 7-bit default alphabet (TS 23.038 §6.2.1) and its extension table (§6.2.1.1)

/// The basic table, indexed by septet value 0x00...0x7F. 0x1B is the escape to the extension table;
/// it is never produced from text and is handled before this table is consulted.
private let gsmBasicTable: [Unicode.Scalar] = [
    // 0x00 - 0x0F
    "@", "\u{00A3}", "$", "\u{00A5}", "\u{00E8}", "\u{00E9}", "\u{00F9}", "\u{00EC}",
    "\u{00F2}", "\u{00C7}", "\n", "\u{00D8}", "\u{00F8}", "\r", "\u{00C5}", "\u{00E5}",
    // 0x10 - 0x1F
    "\u{0394}", "_", "\u{03A6}", "\u{0393}", "\u{039B}", "\u{03A9}", "\u{03A0}", "\u{03A8}",
    "\u{03A3}", "\u{0398}", "\u{039E}", "\u{001B}", "\u{00C6}", "\u{00E6}", "\u{00DF}", "\u{00C9}",
    // 0x20 - 0x2F
    " ", "!", "\"", "#", "\u{00A4}", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/",
    // 0x30 - 0x3F
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ":", ";", "<", "=", ">", "?",
    // 0x40 - 0x4F
    "\u{00A1}", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O",
    // 0x50 - 0x5F
    "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "\u{00C4}", "\u{00D6}", "\u{00D1}", "\u{00DC}", "\u{00A7}",
    // 0x60 - 0x6F
    "\u{00BF}", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
    // 0x70 - 0x7F
    "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "\u{00E4}", "\u{00F6}", "\u{00F1}", "\u{00FC}", "\u{00E0}",
]

private let gsmEscape: UInt8 = 0x1B

/// The extension table: the septet that follows 0x1B.
private let gsmExtensionTable: [UInt8: Unicode.Scalar] = [
    0x0A: "\u{000C}", // form feed
    0x14: "^", 0x28: "{", 0x29: "}", 0x2F: "\\", 0x3C: "[", 0x3D: "~", 0x3E: "]", 0x40: "|",
    0x65: "\u{20AC}", // euro sign
]

/// Text to septets: one septet for the basic table, the escape and one septet for the extension.
private let gsmEncodeTable: [Unicode.Scalar: [UInt8]] = {
    var table: [Unicode.Scalar: [UInt8]] = [:]
    for (code, scalar) in gsmBasicTable.enumerated() where code != Int(gsmEscape) {
        table[scalar] = [UInt8(truncatingIfNeeded: code)]
    }
    for (code, scalar) in gsmExtensionTable {
        table[scalar] = [gsmEscape, code]
    }
    return table
}()

private func gsmBasic(_ septet: UInt8) -> Unicode.Scalar {
    let i = Int(septet & 0x7F)
    return i < gsmBasicTable.count ? gsmBasicTable[i] : " "
}

/// Septets to text. An escape followed by a code the extension table lacks shows the basic
/// character (TS 23.038 §6.2.1.1); escape-escape shows a space; a lone escape at the end is dropped.
private func gsmDecode(_ septets: [UInt8]) -> String {
    var scalars = String.UnicodeScalarView()
    var i = 0
    while i < septets.count {
        let c = septets[i]
        if c == gsmEscape {
            if i + 1 < septets.count {
                let next = septets[i + 1]
                if next == gsmEscape {
                    scalars.append(" ")
                } else if let e = gsmExtensionTable[next] {
                    scalars.append(e)
                } else {
                    scalars.append(gsmBasic(next))
                }
            }
            i += 2
        } else {
            scalars.append(gsmBasic(c))
            i += 1
        }
    }
    return String(scalars)
}

// MARK: - Septet packing (TS 23.038 §6.1.2.1.1): septet n occupies bits 7n...7n+6, least significant first

/// Reads `count` septets starting at septet position `first` of `octets`; nil when the octets end too soon.
private func unpackSeptets(_ octets: [UInt8], from first: Int, count: Int) -> [UInt8]? {
    guard first >= 0, count >= 0 else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(count)
    var n = 0
    while n < count {
        let bit = (first + n) * 7
        let at = bit / 8, shift = bit % 8
        guard at < octets.count else { return nil }
        var value = Int(octets[at]) >> shift
        if shift > 1 {
            guard at + 1 < octets.count else { return nil }
            value |= Int(octets[at + 1]) << (8 - shift)
        }
        out.append(UInt8(truncatingIfNeeded: value & 0x7F))
        n += 1
    }
    return out
}

/// Packs `septets` after `header` octets, the first septet at the next septet boundary
/// (the fill bits between the header and the text stay 0).
private func packSeptets(_ septets: [UInt8], after header: [UInt8]) -> (octets: [UInt8], septetLength: Int) {
    let first = (header.count * 8 + 6) / 7
    let total = first + septets.count
    var out = header + [UInt8](repeating: 0, count: max(0, (total * 7 + 7) / 8 - header.count))
    for (n, s) in septets.enumerated() {
        let bit = (first + n) * 7
        let at = bit / 8, shift = bit % 8
        let value = Int(s & 0x7F)
        if at < out.count { out[at] |= UInt8(truncatingIfNeeded: value << shift) }
        if shift > 1, at + 1 < out.count { out[at + 1] |= UInt8(truncatingIfNeeded: value >> (8 - shift)) }
    }
    return (out, total)
}

// MARK: - Hex and a bounds-checked reader

private func hexNibble(_ c: UInt8) -> UInt8? {
    switch c {
    case 0x30...0x39: return c - 0x30
    case 0x41...0x46: return c - 0x41 + 10
    case 0x61...0x66: return c - 0x61 + 10
    default: return nil
    }
}

private func octets(fromHex hex: String) -> [UInt8]? {
    let chars = Array(hex.utf8)
    guard chars.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(chars.count / 2)
    var i = 0
    while i + 1 < chars.count {
        guard let high = hexNibble(chars[i]), let low = hexNibble(chars[i + 1]) else { return nil }
        out.append(high << 4 | low)
        i += 2
    }
    return out
}

private func hexString(_ octets: [UInt8]) -> String {
    let digits = Array("0123456789ABCDEF")
    var s = ""
    for o in octets {
        s.append(digits[Int(o >> 4)])
        s.append(digits[Int(o & 0x0F)])
    }
    return s
}

private struct OctetReader {
    let octets: [UInt8]
    var position = 0

    init(_ octets: [UInt8]) { self.octets = octets }

    mutating func next() -> UInt8? {
        guard position < octets.count else { return nil }
        defer { position += 1 }
        return octets[position]
    }

    mutating func take(_ n: Int) -> [UInt8]? {
        guard n >= 0, n <= octets.count - position else { return nil }
        defer { position += n }
        return Array(octets[position..<(position + n)])
    }

    mutating func rest() -> [UInt8] {
        let r = position < octets.count ? Array(octets[position...]) : []
        position = octets.count
        return r
    }
}

// MARK: - Addresses (TS 23.040 §9.1.2.5)

/// Semi-octet values to characters (TS 23.040 §9.1.2.3): 0-9, then *, #, a, b, c; 0xF is filler.
private func semiOctetCharacter(_ v: UInt8) -> Character? {
    switch v {
    case 0...9: return Character(Unicode.Scalar(0x30 + v))
    case 0xA: return "*"
    case 0xB: return "#"
    case 0xC: return "a"
    case 0xD: return "b"
    case 0xE: return "c"
    default: return nil
    }
}

/// Address-Length (useful semi-octets), Type-of-Address, then the value. International numbers get a
/// leading "+", other numbers are digits, alphanumeric (type of number 101) is packed GSM 7-bit.
private func readAddress(_ r: inout OctetReader) -> String? {
    guard let length = r.next(), let type = r.next() else { return nil }
    let semiOctets = Int(length)
    guard semiOctets <= 20, let value = r.take((semiOctets + 1) / 2) else { return nil }
    let typeOfNumber = (type >> 4) & 0x07
    if typeOfNumber == 5 {
        guard var septets = unpackSeptets(value, from: 0, count: semiOctets * 4 / 7) else { return nil }
        // A length given as twice the octets (not the useful semi-octets) can fill whole septets with the
        // zero padding; drop that last septet so it does not read as a trailing "@".
        if (semiOctets * 4) % 7 == 0, septets.last == 0x00 { septets.removeLast() }
        return gsmDecode(septets)
    }
    var s = typeOfNumber == 1 ? "+" : ""
    for n in 0..<semiOctets {
        let o = value[n / 2]
        let v = n % 2 == 0 ? o & 0x0F : o >> 4
        if v == 0x0F { continue }
        guard let c = semiOctetCharacter(v) else { return nil }
        s.append(c)
    }
    return s
}

private func encodeAddress(_ number: String) -> [UInt8] {
    let international = number.hasPrefix("+")
    let digits = Array((international ? String(number.dropFirst()) : number).utf8).map { $0 &- 0x30 }
    var out: [UInt8] = [UInt8(truncatingIfNeeded: digits.count), international ? 0x91 : 0x81]
    var i = 0
    while i < digits.count {
        let low = digits[i] & 0x0F
        let high: UInt8 = i + 1 < digits.count ? digits[i + 1] & 0x0F : 0x0F
        out.append(high << 4 | low)
        i += 2
    }
    return out
}

// MARK: - The service centre time stamp (TS 23.040 §9.2.3.11)

/// Seven swapped-BCD octets: year, month, day, hour, minute, second, zone in quarter hours whose
/// bit 3 is the sign (1: behind UTC). Two-digit years 90-99 are 1990s, 00-89 are 2000s.
private func serviceCentreTime(_ o: [UInt8]) -> Date? {
    guard o.count == 7 else { return nil }
    var fields: [Int] = []
    for b in o.prefix(6) {
        let tens = Int(b & 0x0F), units = Int(b >> 4)
        guard tens <= 9, units <= 9 else { return nil }
        fields.append(tens * 10 + units)
    }
    let zone = o[6]
    let zoneTens = Int(zone & 0x07), zoneUnits = Int(zone >> 4)
    guard zoneUnits <= 9, fields.count == 6 else { return nil }
    let quarters = zoneTens * 10 + zoneUnits
    let seconds = (zone & 0x08 != 0 ? -1 : 1) * quarters * 15 * 60
    guard let timeZone = TimeZone(secondsFromGMT: seconds) else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let year = fields[0] >= 90 ? 1900 + fields[0] : 2000 + fields[0]
    let (month, day, hour, minute, second) = (fields[1], fields[2], fields[3], fields[4], fields[5])
    guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
    let wanted = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    guard let date = calendar.date(from: wanted) else { return nil }
    // A day the month does not have (31 April) would roll over; refuse it instead.
    let back = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    guard back.year == year, back.month == month, back.day == day,
          back.hour == hour, back.minute == minute, back.second == second else { return nil }
    return date
}

// MARK: - Data coding scheme (TS 23.038 §4) and user data (TS 23.040 §9.2.3.24)

private enum Alphabet { case gsm7, latin1, ucs2 }

/// General data coding groups 00xx and 01xx (automatic deletion), not compressed; the message waiting
/// groups 1100 and 1101 (7-bit) and 1110 (UCS-2); the message class group 1111. 1000-1011 are reserved.
private func alphabet(fromCodingScheme dcs: UInt8) -> Alphabet? {
    switch dcs >> 4 {
    case 0xC, 0xD:
        return .gsm7
    case 0xE:
        return .ucs2
    case 0x0...0x7:
        if dcs & 0x20 != 0 { return nil } // compressed
        switch (dcs >> 2) & 0x03 {
        case 0: return .gsm7
        case 1: return .latin1
        case 2: return .ucs2
        default: return nil // reserved
        }
    case 0xF:
        return dcs & 0x04 == 0 ? .gsm7 : .latin1
    default:
        return nil
    }
}

/// The information elements of a user data header; the concatenation elements 0x00 (8-bit reference)
/// and 0x08 (16-bit reference) are read, others skipped. nil when an element runs past the header.
private struct HeaderElements { let concat: SmsConcat? }

private func readHeader(_ h: [UInt8]) -> HeaderElements? {
    var concat: SmsConcat? = nil
    var i = 0
    while i < h.count {
        guard i + 1 < h.count else { return nil }
        let id = h[i], length = Int(h[i + 1])
        guard length <= h.count - i - 2 else { return nil }
        let data = Array(h[(i + 2)..<(i + 2 + length)])
        if concat == nil {
            var found: SmsConcat? = nil
            if id == 0x00, data.count == 3 {
                found = SmsConcat(reference: Int(data[0]), total: Int(data[1]), sequence: Int(data[2]))
            } else if id == 0x08, data.count == 4 {
                found = SmsConcat(reference: Int(data[0]) << 8 | Int(data[1]), total: Int(data[2]), sequence: Int(data[3]))
            }
            // A sequence of 0 or past the total makes the element meaningless (TS 23.040 §9.2.3.24.1).
            if let f = found, f.total >= 1, f.sequence >= 1, f.sequence <= f.total { concat = f }
        }
        i += 2 + length
    }
    return HeaderElements(concat: concat)
}

/// Decodes user data of `length` (septets for 7-bit, octets otherwise), with or without a header.
private func readUserData(_ ud: [UInt8], length: Int, alphabet: Alphabet,
                          hasHeader: Bool) -> (text: String, concat: SmsConcat?)? {
    let maximum = alphabet == .gsm7 ? 160 : 140
    let needed = alphabet == .gsm7 ? (length * 7 + 7) / 8 : length
    guard length >= 0, length <= maximum, ud.count >= needed else { return nil }
    var headerOctets = 0
    var concat: SmsConcat? = nil
    if hasHeader {
        guard let headerLength = ud.first else { return nil }
        headerOctets = 1 + Int(headerLength)
        guard headerOctets <= needed, let elements = readHeader(Array(ud[1..<headerOctets])) else { return nil }
        concat = elements.concat
    }
    switch alphabet {
    case .gsm7:
        let first = (headerOctets * 8 + 6) / 7
        guard length >= first, let septets = unpackSeptets(ud, from: first, count: length - first) else { return nil }
        return (gsmDecode(septets), concat)
    case .latin1:
        var scalars = String.UnicodeScalarView()
        for o in ud[headerOctets..<length] { scalars.append(Unicode.Scalar(o)) }
        return (String(scalars), concat)
    case .ucs2:
        // An odd octet count is read without its last octet.
        let body = Array(ud[headerOctets..<length])
        var units: [UInt16] = []
        units.reserveCapacity(body.count / 2)
        var i = 0
        while i + 1 < body.count {
            units.append(UInt16(body[i]) << 8 | UInt16(body[i + 1]))
            i += 2
        }
        // UTF-16 big-endian: surrogate pairs join; a lone surrogate becomes U+FFFD.
        return (String(decoding: units, as: UTF16.self), concat)
    }
}

// MARK: - Reading the modem's answers (TS 27.005)

private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

private func isHexLine(_ s: String) -> Bool {
    !s.isEmpty && s.utf8.allSatisfy { hexNibble($0) != nil }
}

/// The lines AT+CMGL=4 answers: "+CMGL: <index>,<stat>,[<alpha>],<length>" then a hex line.
/// An entry without its hex line is dropped; any other line is ignored. Between a header and its hex line,
/// lines that are neither hex nor a header (blank lines, unsolicited results such as +CMTI) are skipped;
/// the next header ends the search, so a header never takes another header's hex.
func parseListing(_ lines: [String]) -> [StoredPdu] {
    var out: [StoredPdu] = []
    var i = 0
    while i < lines.count {
        let line = trimmed(lines[i])
        i += 1
        guard line.hasPrefix("+CMGL:") else { continue }
        let fields = line.dropFirst("+CMGL:".count).split(separator: ",", omittingEmptySubsequences: false)
            .map { trimmed(String($0)) }
        guard fields.count >= 2, let index = Int(fields[0]), index >= 0,
              let stat = Int(fields[1]), let status = SmsStatus(rawValue: stat) else { continue }
        var j = i
        while j < lines.count {
            let candidate = trimmed(lines[j])
            if candidate.hasPrefix("+CMGL:") { break }
            if isHexLine(candidate) {
                out.append(StoredPdu(index: index, status: status, hex: candidate))
                i = j + 1
                break
            }
            j += 1
        }
    }
    return out
}

/// "+CMGS: <mr>" (0-255) after a message was sent.
func parseSendReference(_ lines: [String]) -> Int? {
    for raw in lines {
        let line = trimmed(raw)
        guard line.hasPrefix("+CMGS:") else { continue }
        let first = line.dropFirst("+CMGS:".count).split(separator: ",", omittingEmptySubsequences: false).first
        guard let f = first, let mr = Int(trimmed(String(f))), (0...255).contains(mr) else { return nil }
        return mr
    }
    return nil
}

/// The first used/total pair of "+CPMS: "ME",0,255,..." (or "+CPMS: 0,255,..." without names).
func parseStorage(_ lines: [String]) -> (used: Int, total: Int)? {
    for raw in lines {
        let line = trimmed(raw)
        guard line.hasPrefix("+CPMS:") else { continue }
        let fields = line.dropFirst("+CPMS:".count).split(separator: ",", omittingEmptySubsequences: false)
            .map { trimmed(String($0)) }
        let start = fields.first?.hasPrefix("\"") == true ? 1 : 0
        guard fields.count >= start + 2, let used = Int(fields[start]), let total = Int(fields[start + 1]),
              used >= 0, total >= 0, used <= total else { return nil }
        return (used, total)
    }
    return nil
}

// MARK: - Decoding SMS-DELIVER (TS 23.040 §9.2.2.1)

private struct Deliver { let sender: String; let timestamp: Date?; let text: String; let concat: SmsConcat? }

private func decodeDeliver(_ hex: String) -> Deliver? {
    guard let all = octets(fromHex: hex) else { return nil }
    var r = OctetReader(all)
    guard let serviceCentreLength = r.next(), r.take(Int(serviceCentreLength)) != nil else { return nil }
    guard let first = r.next(), first & 0x03 == 0 else { return nil } // TP-MTI 0: SMS-DELIVER
    guard let sender = readAddress(&r) else { return nil }
    guard r.next() != nil, let dcs = r.next(), let alpha = alphabet(fromCodingScheme: dcs) else { return nil }
    guard let time = r.take(7), let length = r.next() else { return nil }
    guard let body = readUserData(r.rest(), length: Int(length), alphabet: alpha,
                                  hasHeader: first & 0x40 != 0) else { return nil }
    return Deliver(sender: sender, timestamp: serviceCentreTime(time), text: body.text, concat: body.concat)
}

func decodePart(_ stored: StoredPdu) -> SmsPart {
    guard let d = decodeDeliver(stored.hex) else {
        return SmsPart(index: stored.index, status: stored.status, sender: "", timestamp: nil, text: "",
                       concat: nil, readable: false)
    }
    return SmsPart(index: stored.index, status: stored.status, sender: d.sender, timestamp: d.timestamp,
                   text: d.text, concat: d.concat, readable: true)
}

/// Reads back an SMS-SUBMIT (TS 23.040 §9.2.2.2) with the same address and user data routines the
/// decoder uses. The checks use it to prove that what encodeSubmit writes reads back as the same text.
func readSubmit(_ hex: String) -> (number: String, text: String, concat: SmsConcat?)? {
    guard let all = octets(fromHex: hex) else { return nil }
    var r = OctetReader(all)
    guard let serviceCentreLength = r.next(), r.take(Int(serviceCentreLength)) != nil else { return nil }
    guard let first = r.next(), first & 0x03 == 1 else { return nil } // TP-MTI 1: SMS-SUBMIT
    guard r.next() != nil, let number = readAddress(&r) else { return nil } // message reference, then address
    guard r.next() != nil, let dcs = r.next(), let alpha = alphabet(fromCodingScheme: dcs) else { return nil }
    let validityOctets = [0, 7, 1, 7][Int((first >> 3) & 0x03)]
    guard r.take(validityOctets) != nil, let length = r.next() else { return nil }
    guard let body = readUserData(r.rest(), length: Int(length), alphabet: alpha,
                                  hasHeader: first & 0x40 != 0) else { return nil }
    return (number, body.text, body.concat)
}

// MARK: - Assembling multi-part messages

private struct GroupKey: Hashable { let sender: String; let reference: Int; let total: Int }

/// Parts further than this from a group's earliest part start another message.
private let groupWindow: TimeInterval = 15 * 60

private struct PartGroup { let key: GroupKey; var earliest: Date?; var members: [SmsPart] }

/// Parts belong to one message when they have the same sender, reference and total, each part's time is
/// within 15 minutes of the group's earliest part (a part without a time joins by the key alone), and the
/// group does not already hold that sequence number with a different text. A repeated sequence with the
/// same text is a duplicate: the lower index gives the text and both indices are listed. Parts are taken
/// in order of time, then index, so the result does not depend on the order of the listing.
/// Messages come newest first; entries without a time last, by index.
func assemble(_ parts: [SmsPart]) -> [SmsMessage] {
    var messages: [SmsMessage] = []
    var candidates: [SmsPart] = []
    for p in parts {
        if p.readable, p.concat != nil {
            candidates.append(p)
        } else {
            messages.append(SmsMessage(indices: [p.index], unread: p.status == .unread, sender: p.sender,
                                       timestamp: p.timestamp, text: p.text, missingParts: 0,
                                       readable: p.readable))
        }
    }
    // Time first (parts without a time after the others), then index; the rest only breaks exact ties.
    candidates.sort { a, b in
        switch (a.timestamp, b.timestamp) {
        case let (ta?, tb?) where ta != tb: return ta < tb
        case (.some, .none): return true
        case (.none, .some): return false
        default:
            if a.index != b.index { return a.index < b.index }
            let sa = a.concat?.sequence ?? 0, sb = b.concat?.sequence ?? 0
            if sa != sb { return sa < sb }
            if a.sender != b.sender { return a.sender < b.sender }
            return a.text < b.text
        }
    }
    var groups: [PartGroup] = []
    for p in candidates {
        guard let c = p.concat else { continue }
        let key = GroupKey(sender: p.sender, reference: c.reference, total: c.total)
        let home = groups.firstIndex { g in
            guard g.key == key else { return false }
            if let t = p.timestamp, let e = g.earliest, abs(t.timeIntervalSince(e)) > groupWindow { return false }
            return !g.members.contains { $0.concat?.sequence == c.sequence && $0.text != p.text }
        }
        if let h = home {
            groups[h].members.append(p)
            if groups[h].earliest == nil { groups[h].earliest = p.timestamp }
        } else {
            groups.append(PartGroup(key: key, earliest: p.timestamp, members: [p]))
        }
    }
    for g in groups {
        var text = ""
        var missing = 0
        var inGap = false
        for sequence in 1...max(1, g.key.total) {
            // A duplicate sequence keeps the lower index for the text.
            let same = g.members.filter { $0.concat?.sequence == sequence }
            if let chosen = same.min(by: { $0.index < $1.index }) {
                text += chosen.text
                inGap = false
            } else {
                // A run of missing parts shows as one mark; each one is counted.
                if !inGap { text += "[...]" }
                inGap = true
                missing += 1
            }
        }
        // The message's time is its earliest part's.
        let timestamp = g.members.compactMap { $0.timestamp }.min()
        messages.append(SmsMessage(indices: g.members.map { $0.index }.sorted(),
                                   unread: g.members.contains { $0.status == .unread }, sender: g.key.sender,
                                   timestamp: timestamp, text: text, missingParts: missing, readable: true))
    }
    return messages.sorted { a, b in
        let ia = a.indices.first ?? 0, ib = b.indices.first ?? 0
        switch (a.timestamp, b.timestamp) {
        case let (ta?, tb?): return ta != tb ? ta > tb : ia > ib
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return ia < ib
        }
    }
}

// MARK: - Encoding SMS-SUBMIT (TS 23.040 §9.2.2.2)

func chooseEncoding(_ text: String) -> SmsEncoding {
    text.unicodeScalars.allSatisfy { gsmEncodeTable[$0] != nil } ? .gsm7 : .ucs2
}

private let maximumParts = 10

/// Splits text into parts of whole characters: an escape pair or a surrogate pair is never cut.
/// GSM 7-bit: one part up to 160 septets, else parts of 153; UCS-2: one up to 70 units, else 67.
private func splitText(_ text: String) -> (encoding: SmsEncoding, parts: [[Unicode.Scalar]]) {
    let encoding = chooseEncoding(text)
    func cost(_ s: Unicode.Scalar) -> Int {
        encoding == .gsm7 ? (gsmEncodeTable[s]?.count ?? 1) : UTF16.width(s)
    }
    let scalars = Array(text.unicodeScalars)
    let total = scalars.reduce(0) { $0 + cost($1) }
    let single = encoding == .gsm7 ? 160 : 70
    let multi = encoding == .gsm7 ? 153 : 67
    if total == 0 { return (encoding, []) }
    if total <= single { return (encoding, [scalars]) }
    var parts: [[Unicode.Scalar]] = []
    var current: [Unicode.Scalar] = []
    var used = 0
    for s in scalars {
        let c = cost(s)
        if used + c > multi {
            parts.append(current)
            current = []
            used = 0
        }
        current.append(s)
        used += c
    }
    if !current.isEmpty { parts.append(current) }
    return (encoding, parts)
}

/// Parts the text needs; 0 for empty text.
func partCount(_ text: String) -> Int { splitText(text).parts.count }

/// An optional leading "+", then 3 to 20 digits.
func validNumber(_ number: String) -> Bool {
    let digits = Array((number.hasPrefix("+") ? String(number.dropFirst()) : number).unicodeScalars)
    return (3...20).contains(digits.count) && digits.allSatisfy { ("0"..."9").contains($0) }
}

/// SMS-SUBMIT PDUs with the stored service centre (00), no validity period, no status report and
/// message reference 00. Multi-part messages carry the 8-bit concatenation element with `reference`.
func encodeSubmit(to number: String, text: String, reference: UInt8) -> Result<[SubmitPdu], SmsFailure> {
    guard validNumber(number) else {
        return .failure(SmsFailure(message: "The number is not valid: use 3 to 20 digits, with an optional + in front."))
    }
    let (encoding, parts) = splitText(text)
    guard !parts.isEmpty else { return .failure(SmsFailure(message: "The message is empty.")) }
    guard parts.count <= maximumParts else {
        return .failure(SmsFailure(message: "The message is too long: it needs \(parts.count) parts and at most \(maximumParts) can be sent."))
    }
    let multipart = parts.count > 1
    let address = encodeAddress(number)
    var out: [SubmitPdu] = []
    for (n, part) in parts.enumerated() {
        // First octet: TP-MTI 01 (SUBMIT), TP-VPF 00 (no validity), TP-SRR 0, TP-UDHI when multi-part.
        var tpdu: [UInt8] = [multipart ? 0x41 : 0x01, 0x00] + address + [0x00, encoding == .gsm7 ? 0x00 : 0x08]
        let header: [UInt8] = multipart
            ? [0x05, 0x00, 0x03, reference, UInt8(truncatingIfNeeded: parts.count), UInt8(truncatingIfNeeded: n + 1)]
            : []
        switch encoding {
        case .gsm7:
            let septets = part.flatMap { gsmEncodeTable[$0] ?? [] }
            let packed = packSeptets(septets, after: header)
            tpdu.append(UInt8(truncatingIfNeeded: packed.septetLength)) // at most 160
            tpdu += packed.octets
        case .ucs2:
            var ud = header
            for unit in String(String.UnicodeScalarView(part)).utf16 {
                ud.append(UInt8(truncatingIfNeeded: unit >> 8))
                ud.append(UInt8(truncatingIfNeeded: unit))
            }
            tpdu.append(UInt8(truncatingIfNeeded: ud.count)) // at most 140
            tpdu += ud
        }
        out.append(SubmitPdu(hex: "00" + hexString(tpdu), tpduLength: tpdu.count))
    }
    return .success(out)
}
