// Tests for app/SmsModel.swift: decoding SMS-DELIVER PDUs, the GSM 7-bit and UCS-2 alphabets,
// assembling multi-part messages, encoding SMS-SUBMIT, and reading the modem's AT answers.
// Built with swiftc by `make app-test`; needs no Xcode project and no hardware.
// Stops at the first failure, prints which check failed and exits 1.
//
// Hand-built vectors carry their derivation field by field (TS 23.040 / TS 23.038). Semi-octets are
// written swapped: the digits "86" are the octet 0x68. Time stamps are year, month, day, hour,
// minute, second, zone, each swapped; the zone is in quarter hours and bit 3 of the octet is the sign.
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

/// A UTC instant, so no check depends on this Mac's time zone.
func utc(_ secondsSince1970: TimeInterval) -> Date { Date(timeIntervalSince1970: secondsSince1970) }

func decode(_ hex: String, index: Int = 1, status: SmsStatus = .read) -> SmsPart {
    decodePart(StoredPdu(index: index, status: status, hex: hex))
}

func expectPart(_ hex: String, _ name: String, sender: String, text: String, time: Date?,
                concat: SmsConcat? = nil) {
    let p = decode(hex)
    check(p.readable, "\(name): readable", "\(p)")
    check(p.sender == sender, "\(name): sender", "want \"\(sender)\", got \"\(p.sender)\"")
    check(p.text == text, "\(name): text", "want \"\(text)\", got \"\(p.text)\"")
    check(p.timestamp == time, "\(name): time", "want \(String(describing: time)), got \(String(describing: p.timestamp))")
    check(p.concat == concat, "\(name): concatenation", "want \(String(describing: concat)), got \(String(describing: p.concat))")
}

func expectUnreadable(_ hex: String, _ name: String) {
    let p = decode(hex, index: 4, status: .unread)
    check(!p.readable && p.sender == "" && p.text == "" && p.timestamp == nil && p.concat == nil
            && p.index == 4 && p.status == .unread, "unreadable: \(name)", "\(p)")
}

// --- DELIVER vectors -------------------------------------------------------------------------------

// The classic vector (given in the plan, checked by hand by the controller).
let classic = "07917283010010F5040BC87238880900F10000993092516195800AE8329BFD4697D9EC37"

// UCS-2 Chinese, zone +8 hours.
//   08               SMSC length: 8 octets follow (type + 7)
//   91 683108200105F0  SMSC +8613800210500: international; "86 13 80 02 10 50 0F" swapped
//   04               first octet: TP-MTI 00 (DELIVER), TP-MMS 1, no UDHI
//   0D 91 683119325476F8  sender: 13 digits, international, "86 13 91 23 45 67 8F" swapped
//   00               TP-PID
//   08               TP-DCS: group 00xx, alphabet bits 10 = UCS-2
//   62 11 41 01 03 00 23  2026-11-14 10:30:00, zone 0x23: tens 3 (sign bit 0), units 2 = +32 quarters = +8 h
//   08               TP-UDL: 8 octets
//   4F60 597D 4E16 754C  你 好 世 界 in UTF-16 big-endian
// 10:30:00 at +8 is 02:30:00 UTC = 1794623400.
let chinese = "0891683108200105F0" + "04" + "0D91683119325476F8" + "00" + "08" + "62114101030023" + "08"
    + "4F60597D4E16754C"

// Alphanumeric sender "Alerts", no SMSC stored, zone -5 hours, GSM 7-bit text "Code 1234".
//   00               SMSC length 0
//   04               first octet: DELIVER, MMS
//   0B               sender length: 11 useful semi-octets (6 septets x 7 = 42 bits -> 11 nibbles)
//   D0               type: ext 1, type of number 101 (alphanumeric), plan 0000
//   4176594E9F03     "Alerts" packed: septets A=1000001 l=1101100 e=1100101 r=1110010 t=1110100 s=1110011
//                    o0 = A | (l&1)<<7 = 0x41;   o1 = l>>1 | (e&3)<<6 = 0x36|0x40 = 0x76
//                    o2 = e>>2 | (r&7)<<5 = 0x19|0x40 = 0x59;  o3 = r>>3 | (t&0xF)<<4 = 0x0E|0x40 = 0x4E
//                    o4 = t>>4 | (s&0x1F)<<3 = 0x07|0x98 = 0x9F;  o5 = s>>5 = 0x03
//   00 00            TP-PID, TP-DCS 00 (GSM 7-bit)
//   62 10 50 80 00 00 0A  2026-01-05 08:00:00; zone 0x0A: low nibble 1010 = sign 1, tens 2; units 0
//                    -> -20 quarters = -5 h
//   09               TP-UDL: 9 septets
//   C337B90C8AC96634 "Code 1234" packed into 8 octets (63 bits)
// 08:00:00 at -5 is 13:00:00 UTC = 1767618000.
let alphanumeric = "00" + "04" + "0BD0" + "4176594E9F03" + "00" + "00" + "6210508000000A" + "09"
    + "C337B90C8AC96634"

// National-number sender 10086.
//   08 91 683108100005F0  SMSC +8613800100500
//   04               DELIVER, MMS
//   05 A1 0180F6     sender: 5 digits, type 0xA1 (type of number 010 national, plan 0001); "10 08 6F" swapped
//   00 00            PID, DCS GSM 7-bit
//   62 11 41 81 50 90 23  2026-11-14 18:05:09 +8 h
//   0D               13 septets
//   C2303BEC1E97413199AB0603  "Balance 12.50" packed (91 bits -> 12 octets)
// 18:05:09 at +8 is 10:05:09 UTC = 1794650709.
let national = "0891683108100005F0" + "04" + "05A10180F6" + "00" + "00" + "62114181509023" + "0D"
    + "C2303BEC1E97413199AB0603"

// GSM 7-bit with a user data header (8-bit concatenation, part 1 of 2) and one fill bit.
//   07 91 7283010010F5  SMSC +27381000015
//   44               first octet: DELIVER, MMS, TP-UDHI (bit 6)
//   0B 91 7238880900F1  sender +27838890001
//   00 00            PID, DCS GSM 7-bit
//   62 11 41 21 00 00 00  2026-11-14 12:00:00 +0
//   12               TP-UDL 18 septets: the header is 6 octets = 48 bits, padded with 1 fill bit to
//                    49 bits = 7 septets, then "Hello world" = 11 septets
//   05 00 03 42 02 01  UDHL 5; element 00 (concatenation, 8-bit reference), length 3, ref 0x42, total 2, seq 1
//   906536FB0DBABFE56C32  the 11 septets packed from bit 49 on (bit 48 is the fill bit, 0)
// 12:00:00 UTC = 1794657600.
let withHeader = "07917283010010F5" + "44" + "0B917238880900F1" + "00" + "00" + "62114121000000" + "12"
    + "050003420201" + "906536FB0DBABFE56C32"

// GSM 7-bit extension characters "€[]{}\~^|": each is escape 0x1B then the extension code
// (€ 65, [ 3C, ] 3E, { 28, } 29, \ 2F, ~ 3D, ^ 14, | 40), so 9 characters are 18 septets.
//   07 91 7283010010F5  SMSC; 04 DELIVER; 0B 91 7238880900F1 sender +27838890001; 00 00 PID, DCS
//   99 30 92 51 61 95 80  1999-03-29 15:16:59 +2 h (the classic vector's time)
//   12               18 septets
//   9BF286B7F16D509BD4E6B5E96D281B20  septets 1B 65 1B 3C 1B 3E 1B 28 1B 29 1B 2F 1B 3D 1B 14 1B 40
//                    packed (126 bits -> 16 octets); o0 = 1B | (65&1)<<7 = 0x9B
let extensionText = "07917283010010F5" + "04" + "0B917238880900F1" + "00" + "00" + "99309251619580" + "12"
    + "9BF286B7F16D509BD4E6B5E96D281B20"

// UCS-2 with an emoji (a surrogate pair): "Hi 😀".
//   00 SMSC; 04 DELIVER; 0B 91 7238880900F1 sender; 00 PID; 08 DCS UCS-2; 99309251619580 time
//   0A               10 octets
//   0048 0069 0020 D83D DE00  H i space, then U+1F600 as the pair D83D DE00
let emoji = "00" + "04" + "0B917238880900F1" + "00" + "08" + "99309251619580" + "0A" + "004800690020D83DDE00"

// UCS-2 with a 16-bit concatenation element after an element that must be skipped.
//   00 SMSC; 44 DELIVER with UDHI; 0B 91 7238880900F1 sender; 00 PID; 08 UCS-2; 99309251619580 time
//   0D               13 octets: header 11 (UDHL octet + 10) and text 2
//   0A               UDHL 10
//   01 02 00 00      element 01 (special message indication), length 2: skipped
//   08 04 12 34 03 02  element 08 (concatenation, 16-bit reference), length 4: ref 0x1234 = 4660, total 3, seq 2
//   597D             好
let concat16 = "00" + "44" + "0B917238880900F1" + "00" + "08" + "99309251619580" + "0D" + "0A01020000080412340302"
    + "597D"

// 8-bit data shown as Latin-1: DCS 04 (group 00xx, alphabet 01); UDL 4; 63 61 66 E9 = "café".
let latin1 = "00" + "04" + "0B917238880900F1" + "00" + "04" + "99309251619580" + "04" + "636166E9"

// The classic vector with DCS F0 (group 1111: class 0, bit 2 = 0 -> GSM 7-bit).
let classGroup = "07917283010010F5040BC87238880900F100F0993092516195800AE8329BFD4697D9EC37"

let classicTime = utc(922713419) // 1999-03-29 13:16:59 UTC

let deliverVectors = [classic, chinese, alphanumeric, national, withHeader, extensionText, emoji, concat16,
                      latin1, classGroup]

// --- assembly helpers ------------------------------------------------------------------------------

func part(_ index: Int, _ sender: String = "+111", _ time: Date? = nil, _ text: String,
          _ concat: (Int, Int, Int)? = nil, status: SmsStatus = .read) -> SmsPart {
    SmsPart(index: index, status: status, sender: sender, timestamp: time, text: text,
            concat: concat.map { SmsConcat(reference: $0.0, total: $0.1, sequence: $0.2) }, readable: true)
}

/// A fixed-seed generator (SplitMix64), so the round trip sees the same texts every run.
struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

/// Reads every PDU back and joins the texts; nil when one does not read back or its concatenation
/// element is wrong.
func readBack(_ pdus: [SubmitPdu], reference: Int, number: String) -> String? {
    var text = ""
    for (n, pdu) in pdus.enumerated() {
        guard pdu.tpduLength == pdu.hex.utf8.count / 2 - 1, pdu.hex.hasPrefix("00"),
              let r = readSubmit(pdu.hex), r.number == number else { return nil }
        let want = pdus.count == 1 ? nil : SmsConcat(reference: reference, total: pdus.count, sequence: n + 1)
        guard r.concat == want else { return nil }
        text += r.text
    }
    return text
}

@main
struct SmsModelTests {
    static func main() {
        // --- the classic vector ------------------------------------------------------------------
        expectPart(classic, "classic", sender: "27838890001", text: "hellohello", time: classicTime)

        // --- hand-built vectors ------------------------------------------------------------------
        expectPart(chinese, "UCS-2 Chinese, +8 h", sender: "+8613912345678", text: "你好世界", time: utc(1794623400))
        expectPart(alphanumeric, "alphanumeric sender, -5 h", sender: "Alerts", text: "Code 1234",
                   time: utc(1767618000))
        expectPart(national, "national sender", sender: "10086", text: "Balance 12.50", time: utc(1794650709))
        expectPart(withHeader, "7-bit with header and fill bit", sender: "+27838890001", text: "Hello world",
                   time: utc(1794657600), concat: SmsConcat(reference: 0x42, total: 2, sequence: 1))
        expectPart(extensionText, "extension characters", sender: "+27838890001", text: "€[]{}\\~^|",
                   time: classicTime)
        expectPart(emoji, "UCS-2 surrogate pair", sender: "+27838890001", text: "Hi 😀", time: classicTime)
        check(decode(emoji).text.unicodeScalars.last == "\u{1F600}", "surrogate pair joins into U+1F600")
        expectPart(concat16, "16-bit concatenation after a skipped element", sender: "+27838890001", text: "好",
                   time: classicTime, concat: SmsConcat(reference: 0x1234, total: 3, sequence: 2))
        expectPart(latin1, "8-bit as Latin-1", sender: "+27838890001", text: "café", time: classicTime)
        expectPart(classGroup, "class group 1111, 7-bit", sender: "27838890001", text: "hellohello",
                   time: classicTime)
        let kept = decode(classic, index: 17, status: .unread)
        check(kept.index == 17 && kept.status == .unread, "decodePart keeps index and status")

        // An invalid time stamp leaves the message readable without a time.
        // Month octet 31 = month 13.
        let month13 = decode("07917283010010F5040BC87238880900F10000993192516195800AE8329BFD4697D9EC37")
        check(month13.readable && month13.timestamp == nil && month13.text == "hellohello",
              "month 13: readable, no time", "\(month13)")
        // 99 20 03 = 1999-02-30, a day February does not have.
        let february30 = decode("07917283010010F5040BC87238880900F10000992003516195800AE8329BFD4697D9EC37")
        check(february30.readable && february30.timestamp == nil, "30 February: readable, no time", "\(february30)")

        // --- not readable, no crash ----------------------------------------------------------------
        expectUnreadable("", "empty hex")
        expectUnreadable("0", "one hex digit")
        expectUnreadable(String(classic.dropLast()), "odd number of hex digits")
        expectUnreadable("07917283010010F5040BC87238880900F10000993092516195800AE8329BFD4697D9EC3G", "not hex")
        // Status report: 00 SMSC; 06 = TP-MTI 10 (SMS-STATUS-REPORT); 05 message reference;
        // 0B 91 7238880900F1 recipient; two time stamps; 00 status.
        expectUnreadable("00" + "06" + "05" + "0B917238880900F1" + "99309251619580" + "99309251619580" + "00",
                         "status report (TP-MTI 2)")
        // SMS-SUBMIT read as a stored entry (TP-MTI 1) is not a received message.
        expectUnreadable("0001000B917238880900F100000AE8329BFD4697D9EC37", "SMS-SUBMIT (TP-MTI 1)")
        // The classic vector with DCS 0C: group 00xx, alphabet bits 11 = reserved.
        expectUnreadable("07917283010010F5040BC87238880900F1000C993092516195800AE8329BFD4697D9EC37",
                         "reserved alphabet")
        // DCS 20: group 00xx with the compressed bit.
        expectUnreadable("07917283010010F5040BC87238880900F10020993092516195800AE8329BFD4697D9EC37",
                         "compressed text")
        // The header vector with element length 04 where only 3 octets remain in the 5-octet header.
        expectUnreadable("07917283010010F5" + "44" + "0B917238880900F1" + "00" + "00" + "62114121000000" + "12"
                         + "050004420201" + "906536FB0DBABFE56C32", "header element past the header")
        // UDL 0xA1 = 161 septets, more than an SMS holds.
        expectUnreadable("07917283010010F5040BC87238880900F1000099309251619580A1" + String(repeating: "00", count: 141),
                         "user data length over 160")
        // An SMSC length that runs past the end.
        expectUnreadable("FF00", "SMSC length past the end")
        for (n, vector) in deliverVectors.enumerated() {
            var failedAt: Int? = nil
            for k in 0..<vector.utf8.count where decode(String(vector.prefix(k))).readable {
                failedAt = k
                break
            }
            check(failedAt == nil, "every prefix of DELIVER vector \(n) is unreadable",
                  "the prefix of \(failedAt ?? -1) hex digits read as a message")
        }

        // --- parseListing --------------------------------------------------------------------------
        let listing = parseListing(["AT+CMGL=4", "", "+CMGL: 3,0,,29", classic, "", "+CMGL: 7,1,,24",
                                    extensionText, "stray line", "+CMGL: 5,1,,24", "+CMGL: 6,0,,24", emoji,
                                    "+CMGL: x,0,,24", latin1, "+CMGL: 8,9,,24", latin1,
                                    "+CMGL: 9,1,,24", "OK"])
        check(listing.map { $0.index } == [3, 7, 6], "parseListing: indices", "\(listing)")
        check(listing.first == StoredPdu(index: 3, status: .unread, hex: classic), "parseListing: 3 is unread, its hex")
        check(listing.count > 1 && listing[1] == StoredPdu(index: 7, status: .read, hex: extensionText),
              "parseListing: 7 is read, its hex")
        check(parseListing(["+CMGL: 2,1,,29"]).isEmpty, "parseListing: no hex line after +CMGL, dropped")
        check(parseListing(["+CMGL: 2,1,,29", "OK"]).isEmpty, "parseListing: OK is not a hex line")
        check(parseListing(["+CMGL: 2,1,,29\r", "\(classic)\r"]) == [StoredPdu(index: 2, status: .read, hex: classic)],
              "parseListing: carriage returns trimmed")
        check(parseListing(["OK"]).isEmpty && parseListing([]).isEmpty, "parseListing: empty store")
        check(parseListing(["+CMGL: 99999999999999999999999,1,,29", classic]).isEmpty,
              "parseListing: an index past Int is dropped, no trap")

        // --- assemble ------------------------------------------------------------------------------
        let t0 = utc(1_699_999_000), t1 = utc(1_700_000_000), t2 = utc(1_700_000_100), t3 = utc(1_700_000_200)
        let ordered = assemble([part(10, "+111", t1, "C", (5, 3, 3)), part(11, "+111", t1, "A", (5, 3, 1)),
                                part(12, "+111", t1, "B", (5, 3, 2))])
        check(ordered.count == 1 && ordered.first?.text == "ABC" && ordered.first?.indices == [10, 11, 12]
                && ordered.first?.missingParts == 0 && ordered.first?.readable == true,
              "assemble: parts 3, 1, 2 give ABC", "\(ordered)")
        let duplicate = assemble([part(20, "+111", t1, "X", (6, 2, 1)), part(5, "+111", t1, "A", (6, 2, 1)),
                                  part(21, "+111", t1, "B", (6, 2, 2))])
        check(duplicate.count == 1 && duplicate.first?.text == "AB" && duplicate.first?.indices == [5, 20, 21]
                && duplicate.first?.missingParts == 0,
              "assemble: a duplicate keeps the lower index's text, lists both", "\(duplicate)")
        let gap = assemble([part(1, "+111", t1, "A", (7, 3, 1)), part(3, "+111", t1, "C", (7, 3, 3))])
        check(gap.count == 1 && gap.first?.text == "A[...]C" && gap.first?.missingParts == 1 && gap.first?.indices == [1, 3],
              "assemble: a missing middle part", "\(gap)")
        let senders = assemble([part(1, "+111", t1, "A", (9, 2, 1)), part(2, "+222", t2, "B", (9, 2, 1))])
        check(senders.count == 2 && senders.allSatisfy { $0.missingParts == 1 },
              "assemble: two senders with the same reference and total kept apart", "\(senders)")
        let totals = assemble([part(1, "+111", t1, "A", (9, 2, 1)), part(2, "+111", t1, "B", (9, 3, 2))])
        check(totals.count == 2, "assemble: same reference, different totals kept apart", "\(totals)")
        let unreadPart = assemble([part(1, "+111", t1, "A", (4, 2, 1)),
                                   part(2, "+111", t1, "B", (4, 2, 2), status: .unread)])
        check(unreadPart.first?.unread == true, "assemble: unread when any part is unread")
        let unreadable = SmsPart(index: 2, status: .unread, sender: "", timestamp: nil, text: "", concat: nil,
                                 readable: false)
        let mixed = assemble([part(4, "+111", t0, "old"), unreadable, part(9, "+333", nil, "no time"),
                              part(6, "+222", t3, "new"), part(7, "+111", t2, "Z", (1, 2, 2)),
                              part(3, "+111", t1, "Y", (1, 2, 1))])
        check(mixed.map { $0.text } == ["new", "YZ", "old", "", "no time"],
              "assemble: newest first, entries without a time last by index", "\(mixed.map { $0.text })")
        check(mixed.count == 5 && mixed[1].timestamp == t1 && mixed[1].indices == [3, 7],
              "assemble: a multi-part message takes its earliest part's time", "\(mixed)")
        check(mixed.count == 5 && mixed[3] == SmsMessage(indices: [2], unread: true, sender: "", timestamp: nil, text: "",
                                                        missingParts: 0, readable: false),
              "assemble: an unreadable entry is a message by itself", "\(mixed)")
        check(mixed.first?.unread == false && mixed.first?.sender == "+222", "assemble: a single part keeps its sender")
        check(assemble([]).isEmpty, "assemble: nothing")
        let fromPdus = assemble(parseListing(["+CMGL: 1,1,,24", withHeader, "+CMGL: 2,0,,29", classic]).map(decodePart))
        check(fromPdus.map { $0.text } == ["Hello world[...]", "hellohello"] && fromPdus.first?.missingParts == 1,
              "assemble: from the listing through decodePart", "\(fromPdus)")

        // --- chooseEncoding and partCount ----------------------------------------------------------
        check(chooseEncoding("hello") == .gsm7, "chooseEncoding: ASCII letters are GSM")
        check(chooseEncoding("€[]{}\\~^|\u{000C}") == .gsm7, "chooseEncoding: the extension table is GSM")
        check(chooseEncoding("@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ!\"#¤%&'()*+,-./:;<=>?¡ÄÖÑÜ§¿äöñüà") == .gsm7,
              "chooseEncoding: the whole basic table is GSM")
        check(chooseEncoding("你好") == .ucs2, "chooseEncoding: Chinese is UCS-2")
        check(chooseEncoding("ç") == .ucs2, "chooseEncoding: lower-case c cedilla is not in the GSM table")
        check(chooseEncoding("`") == .ucs2, "chooseEncoding: backtick is not in the GSM table")
        check(partCount("") == 0, "partCount: empty text is 0")
        let a = { (n: Int) in String(repeating: "a", count: n) }
        let zh = { (n: Int) in String(repeating: "中", count: n) }
        check(partCount(a(160)) == 1, "partCount: 160 GSM characters, 1 part")
        check(partCount(a(161)) == 2, "partCount: 161 GSM characters, 2 parts")
        check(partCount(a(158) + "€") == 1, "partCount: 158 + € is 160 septets, 1 part")
        check(partCount(a(159) + "€") == 2, "partCount: 160 characters with a € are 161 septets, 2 parts")
        check(partCount(a(306)) == 2 && partCount(a(307)) == 3, "partCount: 153 septets per part")
        check(partCount(zh(70)) == 1, "partCount: 70 Chinese characters, 1 part")
        check(partCount(zh(71)) == 2, "partCount: 71 Chinese characters, 2 parts")
        check(partCount(zh(134)) == 2 && partCount(zh(135)) == 3, "partCount: 67 units per part")
        check(partCount(String(repeating: "😀", count: 35)) == 1 && partCount(String(repeating: "😀", count: 36)) == 2,
              "partCount: an emoji is two units")

        // An escape pair at the boundary: 152 a then € (2 septets) would be 154 > 153, so € moves whole.
        let euroEdge = encodeSubmit(to: "+27838890001", text: a(152) + "€" + a(10), reference: 1)
        if case .success(let pdus) = euroEdge, pdus.count == 2,
           let first = readSubmit(pdus[0].hex), let second = readSubmit(pdus[1].hex) {
            check(first.text == a(152) && second.text == "€" + a(10), "escape pair at a part boundary moves whole",
                  "\(first.text.count), \(second.text)")
        } else {
            check(false, "escape pair at a part boundary: two parts", "\(euroEdge)")
        }
        // A surrogate pair at the boundary: 66 中 then 😀 (2 units) would be 68 > 67, so 😀 moves whole.
        let pairEdge = encodeSubmit(to: "+27838890001", text: zh(66) + "😀" + zh(10), reference: 1)
        if case .success(let pdus) = pairEdge, pdus.count == 2,
           let first = readSubmit(pdus[0].hex), let second = readSubmit(pdus[1].hex) {
            check(first.text == zh(66) && second.text == "😀" + zh(10), "surrogate pair at a part boundary moves whole",
                  "\(first.text), \(second.text)")
        } else {
            check(false, "surrogate pair at a part boundary: two parts", "\(pairEdge)")
        }

        // --- encodeSubmit --------------------------------------------------------------------------
        // The plan's vector: 00 SMSC; 01 SUBMIT; 00 MR; 0B 91 7238880900F1; 00 PID; 00 DCS; 0A UDL; text.
        check(encodeSubmit(to: "+27838890001", text: "hellohello", reference: 0)
                == .success([SubmitPdu(hex: "0001000B917238880900F100000AE8329BFD4697D9EC37", tpduLength: 22)]),
              "encodeSubmit: hellohello to +27838890001", "\(encodeSubmit(to: "+27838890001", text: "hellohello", reference: 0))")
        // No "+": 0A digits, type 81, "08 38 89 00 01" swapped = 80 83 98 00 10; "hello" = E8329BFD06 (35 bits).
        // TPDU: 01 00 0A 81 8083980010 00 00 05 E8329BFD06 = 4 + 5 + 3 + 5 = 17 octets.
        check(encodeSubmit(to: "0838890001", text: "hello", reference: 0)
                == .success([SubmitPdu(hex: "0001000A81" + "8083980010" + "0000" + "05" + "E8329BFD06", tpduLength: 17)]),
              "encodeSubmit: a number without + uses type 81",
              "\(encodeSubmit(to: "0838890001", text: "hello", reference: 0))")
        // UCS-2: 01 00 0B 91 7238880900F1 00 08 04 4F60 597D = 4 + 6 + 3 + 4 = 17 octets.
        check(encodeSubmit(to: "+27838890001", text: "你好", reference: 0)
                == .success([SubmitPdu(hex: "0001000B917238880900F10008044F60597D", tpduLength: 17)]),
              "encodeSubmit: UCS-2 single part", "\(encodeSubmit(to: "+27838890001", text: "你好", reference: 0))")
        // Multi-part GSM: first octet 41 (SUBMIT + UDHI); part 1 UDL A0 = 160 = 7 header septets + 153;
        // header 05 00 03 2A 02 01; part 2 UDL 0F = 7 + 8.
        if case .success(let pdus) = encodeSubmit(to: "+27838890001", text: a(161), reference: 0x2A), pdus.count == 2 {
            check(pdus[0].hex.hasPrefix("0041000B917238880900F10000A00500032A0201"), "encodeSubmit: part 1 header", pdus[0].hex)
            check(pdus[1].hex.hasPrefix("0041000B917238880900F100000F0500032A0202"), "encodeSubmit: part 2 header", pdus[1].hex)
            check(pdus[0].tpduLength == 13 + 140, "encodeSubmit: a full 7-bit part is 140 octets of user data",
                  "\(pdus[0].tpduLength)")
        } else {
            check(false, "encodeSubmit: 161 characters are 2 parts")
        }
        check(encodeSubmit(to: "+27838890001", text: a(153 * 10), reference: 0).map { $0.count } == .success(10),
              "encodeSubmit: 10 parts are allowed")
        if case .failure(let f) = encodeSubmit(to: "+27838890001", text: a(153 * 10 + 1), reference: 0) {
            check(f.message.contains("too long"), "encodeSubmit: 11 parts, the failure says too long", f.message)
        } else {
            check(false, "encodeSubmit: 11 parts are a failure")
        }
        check(encodeSubmit(to: "+27838890001", text: zh(67 * 11), reference: 0).map { $0.count }
                == .failure(SmsFailure(message: "The message is too long: it needs 11 parts and at most 10 can be sent.")),
              "encodeSubmit: 11 UCS-2 parts are a failure")
        for bad in ["", "12", "+12", "+12a45", "+1 234 567", "++123", "1234567890123456789012"] {
            if case .failure = encodeSubmit(to: bad, text: "hi", reference: 0) {
                check(true, "encodeSubmit: invalid number \"\(bad)\"")
            } else {
                check(false, "encodeSubmit: invalid number \"\(bad)\" is a failure")
            }
        }
        if case .failure = encodeSubmit(to: "+27838890001", text: "", reference: 0) {
            check(true, "encodeSubmit: empty text is a failure")
        } else {
            check(false, "encodeSubmit: empty text is a failure")
        }

        // Round trip over generated texts with a fixed seed: GSM only, GSM with the extension
        // table, and mixed with characters that force UCS-2 (including surrogate pairs).
        let basicPool = Array("@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà".unicodeScalars)
        let extensionPool = Array("\u{000C}^{}\\[~]|€".unicodeScalars)
        let widePool = Array("你好世界中文短信çÿЖ😀🎉👍".unicodeScalars)
        var random = SplitMix(state: 20261114)
        var roundTrips = 0, tooLong = 0
        for n in 0..<300 {
            let kind = n % 3
            let length = 1 + random.below(kind == 0 ? 1530 : kind == 1 ? 900 : 650)
            var scalars = String.UnicodeScalarView()
            for _ in 0..<length {
                let pick = random.below(10)
                if kind >= 1 && pick == 0 {
                    scalars.append(extensionPool[random.below(extensionPool.count)])
                } else if kind == 2 && pick <= 3 {
                    scalars.append(widePool[random.below(widePool.count)])
                } else {
                    scalars.append(basicPool[random.below(basicPool.count)])
                }
            }
            let text = String(scalars)
            let reference = UInt8(truncatingIfNeeded: n)
            let parts = partCount(text)
            switch encodeSubmit(to: "+27838890001", text: text, reference: reference) {
            case .success(let pdus):
                let back = readBack(pdus, reference: Int(reference), number: "+27838890001")
                guard pdus.count == parts, parts <= 10, let b = back,
                      Array(b.unicodeScalars) == Array(text.unicodeScalars) else {
                    check(false, "round trip text \(n)", "kind \(kind), length \(length), parts \(parts)/\(pdus.count)")
                    continue
                }
                roundTrips += 1
            case .failure(let f):
                guard parts > 10, f.message.contains("too long") else {
                    check(false, "round trip text \(n): unexpected failure", f.message)
                    continue
                }
                tooLong += 1
            }
        }
        check(roundTrips >= 200, "round trip: at least 200 texts read back the same", "\(roundTrips) of 300")
        check(roundTrips + tooLong == 300, "round trip: every text either reads back or is too long",
              "\(roundTrips) + \(tooLong)")

        // --- validNumber ---------------------------------------------------------------------------
        for good in ["+27838890001", "10086", "123", "+123", String(repeating: "9", count: 20),
                     "+" + String(repeating: "9", count: 20)] {
            check(validNumber(good), "validNumber: \"\(good)\" is valid")
        }
        for bad in ["", "+", "12", "+12", String(repeating: "9", count: 21), "+1 234", "12-34", "123+",
                    "１２３", "+٣٤٥"] {
            check(!validNumber(bad), "validNumber: \"\(bad)\" is not valid")
        }

        // --- parseSendReference --------------------------------------------------------------------
        check(parseSendReference(["AT+CMGS=22", "> ", "+CMGS: 12", "", "OK"]) == 12, "parseSendReference: 12")
        check(parseSendReference(["+CMGS: 0,\"99/03/29,15:16:59+08\""]) == 0, "parseSendReference: with a time after it")
        check(parseSendReference(["+CMGS: 256"]) == nil, "parseSendReference: 256 is out of range")
        check(parseSendReference(["+CMGS: x"]) == nil, "parseSendReference: not a number")
        check(parseSendReference(["+CMS ERROR: 500"]) == nil && parseSendReference([]) == nil,
              "parseSendReference: an error")

        // --- parseStorage --------------------------------------------------------------------------
        let storage = parseStorage(["AT+CPMS?", "+CPMS: \"ME\",0,255,\"ME\",0,255,\"ME\",0,255", "OK"])
        check(storage?.used == 0 && storage?.total == 255, "parseStorage: ME 0 of 255", "\(String(describing: storage))")
        let unnamed = parseStorage(["+CPMS: 3,255,3,255,3,255"])
        check(unnamed?.used == 3 && unnamed?.total == 255, "parseStorage: without names", "\(String(describing: unnamed))")
        check(parseStorage(["+CPMS: \"ME\",x,255"]) == nil, "parseStorage: not a number")
        check(parseStorage(["+CPMS: \"ME\",300,255"]) == nil, "parseStorage: more used than there is")
        check(parseStorage(["+CPMS: \"ME\""]) == nil, "parseStorage: no numbers")
        check(parseStorage(["OK"]) == nil && parseStorage([]) == nil, "parseStorage: no +CPMS line")

        print("sms-test: \(checks) checks passed")
    }
}
