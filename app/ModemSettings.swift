// The modem's settings and the changes RMNet makes to them: the radio, the network mode, the USB network
// mode, the bands LTE and 5G may use, the data profiles (APN, user name, password, authentication) and the
// SIM's PIN. Here are the
// reading of their AT answers, the checks of what the owner types (also the one AT command `RMNet at`
// sends), the AT lines that change the modem, the questions asked before a change and the sentences said
// after it, and `ModemServing`, the interface of the service that does the I/O. Foundation only: pure
// functions over the answer lines (AtPort's lines between the echo and OK), so `make app-test` builds this
// file with ModemNetwork.swift alone. A missing field, `-` in place of a number, or a short line reads as
// "not known"; nothing here crashes on an odd answer.
//
// A profile's password is kept in memory only. No string conversion of any value here shows it (only
// whether one is set); the one text that holds it is `profileCommand`, the line sent to the modem.
import Foundation

// MARK: - Values

/// A sentence for the owner. A profile change that failed after its line may have reached the modem also
/// carries the profile's settings before it (ruling R19), so that the way back can be shown; nil otherwise.
/// A command sent by `at` that ended without OK carries how it ended, when `RMNet at` prints that its own
/// way (`atKind`); nil otherwise. Its string conversions show no password: ProfileSettings shows only
/// whether one is set.
struct ModemFailure: Error, Equatable {
    let message: String
    var profileBefore: ProfileSettings? = nil
    var atKind: AtFailureKind? = nil
}

/// How a command sent by `at` ended without OK: the modem's own error line (`ERROR`, `+CME ERROR: …`,
/// `+CMS ERROR: …`; the failure's message is that line), or no answer in the time given. Any other failure
/// of `at` (the port not opened, an I/O error) has none.
enum AtFailureKind: Equatable { case modemError, timeout }

/// So `error.localizedDescription` is the owner's sentence, not "The operation couldn't be completed".
extension ModemFailure: LocalizedError { var errorDescription: String? { message } }

/// AT+QICSGP <context_type>.
enum PdpType: Int, CaseIterable { case ipv4 = 1, ipv6 = 2, ipv4v6 = 3 }

/// AT+QICSGP <authentication>.
enum AuthMethod: Int, CaseIterable { case none = 0, pap = 1, chap = 2, papOrChap = 3 }

/// A profile's settings as AT+QICSGP reads and writes them. Interpolation, String(describing:),
/// String(reflecting:) and dump show `profileWords` and a mirror with `passwordSet` in place of the
/// password.
struct ProfileSettings: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var type: PdpType
    var apn: String
    var user: String
    var password: String            // in memory only: never printed, logged or stored
    var auth: AuthMethod

    var description: String { profileWords(self) }
    var debugDescription: String { profileWords(self) }
    var customMirror: Mirror {
        Mirror(self, children: ["type": type, "apn": apn, "user": user, "passwordSet": !password.isEmpty, "auth": auth],
               displayStyle: .struct)
    }
}

/// A profile as AT+CGDCONT? lists it (PDP type and APN display-safe), with its AT+QICSGP=<id> settings:
/// nil above 16 (AT+QICSGP takes profiles 1 to 16) or when they could not be read.
struct DataProfile: Equatable { let id: Int; let pdpType: String; let apn: String; let settings: ProfileSettings? }

/// AT+CPIN? READY, SIM PIN, SIM PUK, SIM PIN2, SIM PUK2; or its error line: +CME ERROR 10 (no SIM),
/// 13 (SIM failure), 14 (SIM busy); `other` holds any other answer, display-safe.
enum SimState: Equatable { case ready, pin, puk, pin2, puk2, notInserted, failure, busy, other(String) }

/// The SIM: its state, the PIN lock (AT+CLCK="SC",2) and the attempts left (AT+QPINC? "SC"); nil where
/// not read.
struct SimInfo: Equatable { let state: SimState; let pinLock: Bool?; let pinAttempts: Int?; let pukAttempts: Int? }

/// After AT+CFUN=1 or =4. Switched on: the registration last read, and the whole seconds until it was
/// registered (nil when it was not, within the wait). Switched off: both nil.
struct RadioChange: Equatable { let on: Bool; let registration: Registration?; let secondsToRegister: Int? }

/// mode_pref before and after a change, as the modem gave them.
struct ModeChange: Equatable { let before: String; let after: String }

/// What happened to the radio around a profile change: no redial asked; the radio was off, so it was left
/// off; switched off and on again; or left off after the change because it could not be switched on (why).
enum RedialResult: Equatable { case notAsked, radioWasOff, done(RadioChange), radioLeftOff(String) }

struct ProfileChange: Equatable { let id: Int; let before: ProfileSettings; let after: ProfileSettings; let redial: RedialResult }

/// Whether the SIM took the PIN, the SIM read again after it (nil when that read failed), and, when it was
/// not taken, the modem's error line (`+CME ERROR: 16` is a wrong PIN; another, such as 14, SIM busy, is not).
struct PinOutcome: Equatable {
    let accepted: Bool
    let sim: SimInfo?
    var refusal: String? = nil
}

/// AT+QCFG="usbnet" <net>: what the modem offers on USB for the network, in effect after a restart. 0 is
/// RMNET (QMI), the one mode this driver works in; 1 ECM, 2 MBIM, 3 RNDIS.
enum UsbNetMode: Int, CaseIterable {
    case qmi = 0, ecm = 1, mbim = 2, rndis = 3

    /// As `RMNet usbmode` prints and takes it.
    var name: String {
        switch self {
        case .qmi: return "qmi"
        case .ecm: return "ecm"
        case .mbim: return "mbim"
        case .rndis: return "rndis"
        }
    }
}

/// AT+QCFG="usbnet" as read: the number the modem gave, kept also when RMNet does not know it (`mode` nil).
struct UsbModeInfo: Equatable {
    let value: Int
    var mode: UsbNetMode? { UsbNetMode(rawValue: value) }
}

/// After a USB mode change: it was already that mode (nothing sent but the read); set and the modem told to
/// restart (it goes away from USB for about 30 s); or set, in effect at the next restart.
enum UsbModeChange: Equatable { case unchanged, rebooting, setTakesEffectAfterRestart }

/// The radio access technologies whose bands `RMNet bands` shows and locks, in the order it shows them:
/// LTE, 5G non-standalone (EN-DC) and 5G standalone.
enum BandRat: String, CaseIterable {
    case lte, nsa, sa

    /// Its AT+QNWPREFCFG setting, the bands it may use; also its line in AT+QNWPREFCFG="rf_band", the bands
    /// the modem's hardware supports (which a lock does not change).
    var key: String {
        switch self {
        case .lte: return "lte_band"
        case .nsa: return "nsa_nr5g_band"
        case .sa: return "nr5g_band"
        }
    }

    /// As `RMNet bands` prints it.
    var name: String {
        switch self {
        case .lte: return "LTE"
        case .nsa: return "5G NSA"
        case .sa: return "5G SA"
        }
    }
}

/// One RAT's bands: those it may use and those the modem supports, each sorted, each band once.
struct BandSet: Equatable { let rat: BandRat; let allowed: [Int]; let supported: [Int] }

/// A RAT's allowed bands before and after a change, each sorted, each band once; the same when nothing was
/// written (they were already the ones asked).
struct BandChange: Equatable { let before: [Int]; let after: [Int] }

/// The modem over its spare AT port. Each call blocks until done; callers keep it off the main thread.
protocol ModemServing {
    func networkInfo() -> Result<NetworkInfo, ModemFailure>
    func setRadio(on: Bool) -> Result<RadioChange, ModemFailure>
    func setMode(_ mode: String) -> Result<ModeChange, ModemFailure>          // one canonicalMode accepts (R8)
    func profiles() -> Result<[DataProfile], ModemFailure>
    func setProfile(_ id: Int, to settings: ProfileSettings, redial: Bool) -> Result<ProfileChange, ModemFailure>
    func sim() -> Result<SimInfo, ModemFailure>
    func enterPin(_ pin: String, shownAttempts: Int) -> Result<PinOutcome, ModemFailure>
    func usbMode() -> Result<UsbModeInfo, ModemFailure>
    func setUsbMode(_ mode: UsbNetMode, reboot: Bool) -> Result<UsbModeChange, ModemFailure>
    func at(_ line: String, timeout: TimeInterval) -> Result<[String], ModemFailure>   // one atCommandProblem accepts
    func bands() -> Result<[BandSet], ModemFailure>                                  // in BandRat.allCases order
    func setBands(_ rat: BandRat, to bands: [Int]) -> Result<BandChange, ModemFailure> // refuses what bandsProblem does
}

// MARK: - Answer lines

private func answerField(_ f: [String], _ i: Int) -> String? {
    i >= 0 && i < f.count ? f[i] : nil
}

/// A whole number; nil when the field is missing, empty, `-` or not a number.
private func answerInt(_ f: [String], _ i: Int) -> Int? {
    answerField(f, i).flatMap { Int($0) }
}

/// A count (attempts left): a whole number of at least 0.
private func answerCount(_ f: [String], _ i: Int) -> Int? {
    answerInt(f, i).flatMap { $0 >= 0 ? $0 : nil }
}

/// The fields of the first line with the prefix; nil when no line has it.
private func firstAnswer(_ lines: [String], _ prefix: String) -> [String]? {
    for line in lines {
        if let f = atFields(line, prefix: prefix) { return f }
    }
    return nil
}

// MARK: - Network mode

/// What the window offers, in this order. canonicalMode is in ModemNetwork.swift, with modeWords.
let networkModeChoices = ["AUTO", "LTE:NR5G", "NR5G", "LTE"]

/// AT+QNWPREFCFG="mode_pref",<mode>: written to the modem's NVM, in effect at once.
func modeCommand(_ mode: String) -> String {
    "AT+QNWPREFCFG=\"mode_pref\",\(mode)"
}

// MARK: - USB network mode

/// AT+QCFG="usbnet": `+QCFG: "usbnet",<net>`. nil without that line, or with no number in it.
func parseUsbMode(_ lines: [String]) -> UsbModeInfo? {
    for line in lines {
        if let f = atFields(line, prefix: "+QCFG"), answerField(f, 0) == "usbnet" {
            return answerInt(f, 1).map { UsbModeInfo(value: $0) }
        }
    }
    return nil
}

/// AT+QCFG="usbnet",<net>: kept by the modem, in effect at its next restart.
func usbModeCommand(_ mode: UsbNetMode) -> String {
    "AT+QCFG=\"usbnet\",\(mode.rawValue)"
}

/// `qmi`, `ecm`, `mbim`, `rndis`; `unknown (<n>)` for another number.
func usbModeName(_ value: Int) -> String {
    UsbNetMode(rawValue: value)?.name ?? "unknown (\(value))"
}

/// `RMNet usbmode --json`: `{"mode":"qmi","value":0,"driverWorks":true}`.
func usbModeJSON(_ info: UsbModeInfo) -> [String: Any] {
    ["mode": usbModeName(info.value), "value": info.value, "driverWorks": info.mode == .qmi]
}

// MARK: - Bands

/// Sorted, each band once.
func bandSorted(_ bands: [Int]) -> [Int] {
    Array(Set(bands)).sorted()
}

/// A band number as written: ASCII digits only (no sign, no space), at least 1; nil otherwise.
func parseBandNumber(_ text: Substring) -> Int? {
    guard !text.isEmpty, text.unicodeScalars.allSatisfy({ (0x30...0x39).contains($0.value) }),
          let n = Int(text), n >= 1 else { return nil }
    return n
}

/// The first line `+QNWPREFCFG: "<key>",<list>`, the list band numbers joined by `:` (`0` alone: none), in
/// quotes or not (rf_band quotes it, a RAT's own setting does not): the bands sorted, each once. nil without a
/// line for the key, or when its list is not such a list (an empty number, a letter or sign, a `0` among other
/// numbers, or a field after it).
func parseBandList(_ lines: [String], key: String) -> [Int]? {
    for line in lines {
        guard let f = atFields(line, prefix: "+QNWPREFCFG"), answerField(f, 0) == key else { continue }
        guard f.count == 2 else { return nil }
        if f[1] == "0" { return [] }
        var bands: [Int] = []
        for number in f[1].split(separator: ":", omittingEmptySubsequences: false) {
            guard let band = parseBandNumber(number) else { return nil }
            bands.append(band)
        }
        return bandSorted(bands)
    }
    return nil
}

/// AT+QNWPREFCFG="<key>",<b1>:<b2>:…, the bands sorted, each once: kept by the modem, in effect at once. Check
/// `bandsProblem` first (never an empty list, which would read as no list).
func bandsCommand(_ rat: BandRat, _ bands: [Int]) -> String {
    "AT+QNWPREFCFG=\"\(rat.key)\"," + bandSorted(bands).map { String($0) }.joined(separator: ":")
}

/// `3, 41`: ascending, each band once; `none` for no band.
func bandListWords(_ bands: [Int]) -> String {
    bands.isEmpty ? "none" : bandSorted(bands).map { String($0) }.joined(separator: ", ")
}

/// nil when `bands` may be written as `rat`'s bands; else why not: an empty list (the RAT would have no band
/// left), or bands the modem does not support, named, with the ones it does.
func bandsProblem(_ rat: BandRat, _ bands: [Int], supported: [Int]) -> String? {
    if bands.isEmpty { return "At least one \(rat.name) band is needed." }
    let unsupported = bandSorted(bands.filter { !supported.contains($0) })
    guard !unsupported.isEmpty else { return nil }
    return "The modem does not support \(rat.name) \(unsupported.count == 1 ? "band" : "bands") "
        + "\(bandListWords(unsupported)) (supported: \(bandListWords(supported)))."
}

/// `RMNet bands --json`, one RAT: `{"rat":"lte","allowed":[3,41],"supported":[1,2,…]}`.
func bandsJSON(_ set: BandSet) -> [String: Any] {
    ["rat": set.rat.rawValue, "allowed": set.allowed, "supported": set.supported]
}

// MARK: - One AT command as typed (`RMNet at`)

/// The longest command `RMNet at` sends, in characters.
let atCommandLimit = 512

/// The commands that answer with a "> " prompt and wait for a second stage (a message body, an SMS command
/// PDU) that one line cannot give, each with what `RMNet at` says about it. The modem may ignore spaces in a
/// command line and runs commands joined with `;`, so these are looked for anywhere in the line, spaces
/// removed (also inside a quoted string, which is refused too).
private let atPromptCommands: [(name: String, reason: String)] = [
    ("+CMGS", "AT+CMGS needs a message body; use RMNet sms send"),
    ("+CMGW", "AT+CMGW needs a message body; use RMNet sms send"),
    ("+CMGC", "AT+CMGC needs a second stage after a > prompt; RMNet at sends one line only"),
    ("+QCMGS", "AT+QCMGS needs a second stage after a > prompt; RMNet at sends one line only"),
]

/// The first basic command after AT that would take the AT port to data mode (D dials, O goes online) or
/// change whether and how the modem answers (V: words or numbers; Q: result codes on or off).
private let atLockoutFirstCommands: [Character] = ["D", "O", "V", "Q"]

/// Anywhere in the line: the line-end characters the modem expects and answers with (S3, S4), &W, which
/// would keep such settings across a restart, and +CGDATA, which enters data state.
private let atLockoutAnywhere = ["S3=", "S4=", "&W", "+CGDATA"]

private func atLockout(_ what: String) -> String {
    "RMNet at does not send \(what) (it would switch the AT port to data mode or change how the modem answers, "
        + "and RMNet's own AT features would stop working)"
}

/// The values written to the modem's USB setting `key` (`USBNET`, `USBCFG`) anywhere in `compact` (the line
/// upper-cased, spaces removed): for each `+QCFG=<key>,` (the key in quotes or not), the text after the comma up
/// to the next `;` or the line's end. A read (`+QCFG="usbnet"`, no comma) has none.
private func usbSettingWrites(_ compact: String, key: String) -> [Substring] {
    var values: [Substring] = []
    for quoted in ["\"\(key)\",", "\(key),"] {
        let pattern = "+QCFG=" + quoted
        var rest = compact[...]
        while let found = rest.range(of: pattern) {
            let after = rest[found.upperBound...]
            values.append(after.prefix { $0 != ";" })
            rest = after
        }
    }
    return values
}

/// nil when `line` may be sent as one AT command; else why not, as `RMNet at` says it after `at: ` (never
/// quoting the line). Refused: an empty line; a character outside printable ASCII (0x20–0x7E), so no CR or LF
/// (which would end the line early and send a second command) and no Ctrl-Z (which ends a message body); more
/// than 512 characters; a line that does not start with AT (any case). Then, on the line upper-cased with its
/// spaces removed: a prompt command anywhere (`atPromptCommands`); ATD, ATO, ATV or ATQ as the first basic
/// command; S3=, S4=, &W or +CGDATA anywhere; a write of the USB network mode (AT+QCFG="usbnet",<n>) other than
/// 0, QMI (`RMNet usbmode set` warns and checks first), and any write of the USB configuration
/// (AT+QCFG="usbcfg",…), after which the modem may no longer be found on USB 2c7c:0801; the reads of both are
/// sent. Those would leave the port waiting for a second stage, or unusable for RMNet's own AT features (AtPort
/// expects verbose answers ending in OK, in command mode), or take the modem away from RMNet.
func atCommandProblem(_ line: String) -> String? {
    let scalars = line.unicodeScalars
    if scalars.isEmpty { return "no command given; usage: RMNet at [--timeout <seconds>] <command>" }
    guard scalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else {
        return "a command is printable ASCII only (no line end, tab or Ctrl-Z)"
    }
    if scalars.count > atCommandLimit { return "a command is at most \(atCommandLimit) characters" }
    let upper = line.uppercased()              // ASCII only by now
    guard upper.hasPrefix("AT") else { return "a command starts with AT" }
    let compact = upper.replacingOccurrences(of: " ", with: "")
    for command in atPromptCommands where compact.contains(command.name) { return command.reason }
    if let first = compact.dropFirst(2).first, atLockoutFirstCommands.contains(first) { return atLockout("AT\(first)") }
    for part in atLockoutAnywhere where compact.contains(part) { return atLockout("AT\(part)") }
    if usbSettingWrites(compact, key: "USBNET").contains(where: { $0 != "0" }) {
        return "use RMNet usbmode set to change the USB mode; it warns and checks first"
    }
    if !usbSettingWrites(compact, key: "USBCFG").isEmpty {
        return "RMNet at does not change the USB configuration (usbcfg): the modem could disappear from RMNet"
    }
    return nil
}

// MARK: - Data profiles

/// AT+CGDCONT?: `+CGDCONT: <cid>,<PDP_type>,<APN>,…`. A line without a profile number of at least 1, a
/// type and an APN is skipped; a number listed twice keeps its first line. Type and APN display-safe.
func parseProfiles(_ lines: [String]) -> [(id: Int, pdpType: String, apn: String)] {
    var profiles: [(id: Int, pdpType: String, apn: String)] = []
    for line in lines {
        guard let f = atFields(line, prefix: "+CGDCONT"), let id = answerInt(f, 0), id >= 1,
              let pdpType = answerField(f, 1), let apn = answerField(f, 2),
              !profiles.contains(where: { $0.id == id }) else { continue }
        profiles.append((id: id, pdpType: modemTextSafe(pdpType), apn: modemTextSafe(apn)))
    }
    return profiles
}

/// AT+QICSGP=<id>: `+QICSGP: <type>,"<APN>","<user>","<password>",<auth>`, the values exactly as given
/// (a quoted comma stays in its field). nil without such a line, or with a type or auth out of range.
func parseProfileSettings(_ lines: [String]) -> ProfileSettings? {
    guard let f = firstAnswer(lines, "+QICSGP"),
          let type = answerInt(f, 0).flatMap({ PdpType(rawValue: $0) }),
          let apn = answerField(f, 1), let user = answerField(f, 2), let password = answerField(f, 3),
          let auth = answerInt(f, 4).flatMap({ AuthMethod(rawValue: $0) }) else { return nil }
    return ProfileSettings(type: type, apn: apn, user: user, password: password, auth: auth)
}

/// AT+QICSGP=<id>,<type>,"<apn>","<user>","<password>",<auth>. It holds the password: send it, never
/// show or log it. Check `profileProblem` first (no value may hold a `"` or a `\`).
func profileCommand(_ id: Int, _ s: ProfileSettings) -> String {
    "AT+QICSGP=\(id),\(s.type.rawValue),\"\(s.apn)\",\"\(s.user)\",\"\(s.password)\",\(s.auth.rawValue)"
}

private let apnRule = "An APN is at most 100 characters of ASCII letters, digits, dots, hyphens and underscores; it does not "
    + "start or end with a dot or a hyphen, has no two dots in a row, and has no hyphen next to a dot."
private let userRule = "A user name is at most 127 characters of printable ASCII, without a double quote (\") or a backslash (\\)."
private let passwordRule = "A password is at most 127 characters of printable ASCII, without a double quote (\") or a backslash (\\)."
private let noAuthenticationRule = "With no authentication the user name and password must be empty; "
    + "choose PAP, CHAP or PAP or CHAP to use them."

/// Up to 100 of ASCII letters, digits, `.`, `-`, `_`, in labels joined by dots, none empty and none starting
/// or ending with `-` (3GPP TS 23.003's DNS rules, ruling R21: so `apn set --apn --no-redial` is refused);
/// empty is allowed (the network chooses). Checked by Unicode scalar, so a combining mark is a character of
/// its own.
private func apnAllowed(_ apn: String) -> Bool {
    let scalars = apn.unicodeScalars
    guard scalars.count <= 100 else { return false }
    guard !scalars.isEmpty else { return true }
    let labels = scalars.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.allSatisfy({ !$0.isEmpty && $0.first != "-" && $0.last != "-" }) else { return false }
    return scalars.allSatisfy { c in
        switch c.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return c == "." || c == "-" || c == "_"
        }
    }
}

/// Up to 127 of printable ASCII (0x20–0x7E) without `"`, which would end the quoted value, and without
/// `\`, since a V.250 / 27.007 string constant may read `\hh` as an escape (`a\41` stored as `aA`).
private func credentialAllowed(_ value: String) -> Bool {
    let scalars = value.unicodeScalars
    return scalars.count <= 127 && scalars.allSatisfy { (0x20...0x7E).contains($0.value) && $0 != "\"" && $0 != "\\" }
}

/// nil for a profile RMNet can change (1 to 16); else the sentence.
func profileNumberProblem(_ id: Int) -> String? {
    (1...16).contains(id) ? nil : "Profile \(id) cannot be changed by RMNet: AT+QICSGP takes profiles 1 to 16."
}

/// nil when the settings can be sent to profile `id`; else the sentence saying which rule they break
/// (the profile number first, then the APN, the user name, the password, then that with no authentication
/// both are empty; never quoting the password). With authentication 0 the modem turns a profile that has a
/// password into CHAP by itself (seen on 2026-11-15, ruling R15), so RMNet does not send such a profile.
func profileProblem(_ id: Int, _ s: ProfileSettings) -> String? {
    if let problem = profileNumberProblem(id) { return problem }
    if !apnAllowed(s.apn) { return apnRule }
    if !credentialAllowed(s.user) { return userRule }
    if !credentialAllowed(s.password) { return passwordRule }
    if s.auth == AuthMethod.none && !(s.user.isEmpty && s.password.isEmpty) { return noAuthenticationRule }
    return nil
}

private func typeWords(_ t: PdpType) -> String {
    switch t {
    case .ipv4: return "IPV4"
    case .ipv6: return "IPV6"
    case .ipv4v6: return "IPV4V6"
    }
}

private func authWords(_ a: AuthMethod) -> String {
    switch a {
    case .none: return "no authentication"
    case .pap: return "PAP"
    case .chap: return "CHAP"
    case .papOrChap: return "PAP or CHAP"
    }
}

/// The `--type` and `--auth` values of `RMNet apn set`, also the JSON's auth.
private func typeOption(_ t: PdpType) -> String {
    switch t {
    case .ipv4: return "ipv4"
    case .ipv6: return "ipv6"
    case .ipv4v6: return "ipv4v6"
    }
}

private func authOption(_ a: AuthMethod) -> String {
    switch a {
    case .none: return "none"
    case .pap: return "pap"
    case .chap: return "chap"
    case .papOrChap: return "pap-or-chap"
    }
}

/// The settings in words without the password's part: `IPV4V6, APN "cmnet", PAP, user "u"`.
private func settingsWords(_ s: ProfileSettings) -> String {
    var parts = [typeWords(s.type), "APN \"\(modemTextSafe(s.apn))\"" + (s.apn.isEmpty ? " (the network chooses)" : ""),
                 authWords(s.auth)]
    if !s.user.isEmpty { parts.append("user \"\(modemTextSafe(s.user))\"") }
    return parts.joined(separator: ", ")
}

/// `IPV4V6, APN "cmnet", PAP, user "u", password set`: an empty APN reads `APN "" (the network
/// chooses)`; an empty user name and an empty password are left out. Never the password itself.
func profileWords(_ s: ProfileSettings) -> String {
    settingsWords(s) + (s.password.isEmpty ? "" : ", password set")
}

/// The value in single quotes for the shell, each `'` inside as `'\''` (found by Unicode scalar, so a
/// quote that a combining mark joins into one Character is escaped too).
private func shellQuoted(_ value: String) -> String {
    var out = String.UnicodeScalarView()
    out.append("'")
    for c in value.unicodeScalars {
        if c == "'" { out.append(contentsOf: "'\\''".unicodeScalars) } else { out.append(c) }
    }
    out.append("'")
    return String(out)
}

/// The `RMNet apn set` options that put `s` back: `--apn '' --type ipv4v6 --user '' --auth none
/// --no-password`. The last option always says what becomes of the password (ruling R6): `--no-password`
/// when `s` had none, so a password the change added is cleared; `--password` when `s` had one (the
/// owner types the old one at the prompt; it is never printed).
func profileRestoreArguments(_ s: ProfileSettings) -> String {
    let words = ["--apn", shellQuoted(modemTextSafe(s.apn)), "--type", typeOption(s.type),
                 "--user", shellQuoted(modemTextSafe(s.user)), "--auth", authOption(s.auth),
                 s.password.isEmpty ? "--no-password" : "--password"]
    return words.joined(separator: " ")
}

/// The command that puts a profile back to `s`, as `apn set` and the window show it: `RMNet apn set
/// <profileRestoreArguments(s)>` (never the password: `--password` asks for it).
func profileRestoreCommand(_ s: ProfileSettings) -> String {
    "RMNet apn set " + profileRestoreArguments(s)
}

/// The command that puts the network mode back to `before`, as the modem gave it, lower-cased (ruling R8:
/// `NR5G:LTE` is put back as `nr5g:lte`); nil for a value RMNet cannot set.
func modeRestoreCommand(_ before: String) -> String? {
    canonicalMode(before) == nil ? nil : "RMNet mode \(before.lowercased())"
}

private func orNull<T>(_ value: T?) -> Any {
    if let value { return value }
    return NSNull()
}

/// `RMNet apn show --json`: the driver's profile number and each profile; `auth`, `user` and
/// `passwordSet` are null when the profile's settings were not read. Never the password.
func profilesJSON(_ profiles: [DataProfile], driverProfile: Int) -> [String: Any] {
    let rows: [[String: Any]] = profiles.map { p in
        ["id": p.id, "pdpType": p.pdpType, "apn": p.apn,
         "auth": orNull(p.settings.map { authOption($0.auth) }),
         "user": orNull(p.settings.map { modemTextSafe($0.user) }),
         "passwordSet": orNull(p.settings.map { !$0.password.isEmpty }),
         "driver": p.id == driverProfile]
    }
    return ["driverProfile": driverProfile, "profiles": rows]
}

// MARK: - SIM

/// AT+CPIN?: `+CPIN: <code>`. nil without a +CPIN line, or with an empty code.
func parseSimState(_ lines: [String]) -> SimState? {
    guard let code = firstAnswer(lines, "+CPIN").flatMap({ answerField($0, 0) }), !code.isEmpty else { return nil }
    switch code {
    case "READY": return .ready
    case "SIM PIN": return .pin
    case "SIM PUK": return .puk
    case "SIM PIN2": return .pin2
    case "SIM PUK2": return .puk2
    default: return .other(modemTextSafe(code))
    }
}

/// The state that AT+CPIN?'s error line gives: `+CME ERROR: 10` no SIM, `13` SIM failure, `14` SIM busy;
/// any other line is `.other(line)`, display-safe.
func simState(fromError line: String) -> SimState {
    switch atFields(line, prefix: "+CME ERROR").flatMap({ answerInt($0, 0) }) {
    case 10: return .notInserted
    case 13: return .failure
    case 14: return .busy
    default: return .other(modemTextSafe(line))
    }
}

/// AT+QPINC?: the `"SC"` line, `+QPINC: "SC",<PIN attempts left>,<PUK attempts left>`.
func parsePinAttempts(_ lines: [String]) -> (pin: Int?, puk: Int?) {
    for line in lines {
        if let f = atFields(line, prefix: "+QPINC"), answerField(f, 0) == "SC" { return (answerCount(f, 1), answerCount(f, 2)) }
    }
    return (nil, nil)
}

/// AT+CLCK="SC",2: `+CLCK: <status>`, 1 locked (the SIM asks for its PIN at start), 0 not.
func parsePinLock(_ lines: [String]) -> Bool? {
    switch firstAnswer(lines, "+CLCK").flatMap({ answerInt($0, 0) }) {
    case 0: return false
    case 1: return true
    default: return nil
    }
}

/// AT+CPIN="<pin>". It holds the PIN: send it, never show or log it. Check `pinProblem` first.
func pinCommand(_ pin: String) -> String {
    "AT+CPIN=\"\(pin)\""
}

/// nil for 4 to 8 ASCII digits; else the rule (never quoting what was typed).
func pinProblem(_ pin: String) -> String? {
    let scalars = pin.unicodeScalars
    let digits = (4...8).contains(scalars.count) && scalars.allSatisfy { (0x30...0x39).contains($0.value) }
    return digits ? nil : "A PIN is 4 to 8 digits."
}

/// The SIM's state in words, as the SIM row reads it.
func simStateWords(_ state: SimState) -> String {
    switch state {
    case .ready: return "ready"
    case .pin: return "asks for its PIN"
    case .puk: return "blocked: needs its PUK from the carrier"
    case .pin2: return "asks for PIN2"
    case .puk2: return "asks for PUK2"
    case .notInserted: return "not inserted"
    case .failure: return "SIM failure"
    case .busy: return "busy"
    case .other(let text): return text
    }
}

private func simStateKey(_ state: SimState) -> String {
    switch state {
    case .ready: return "ready"
    case .pin: return "pin"
    case .puk: return "puk"
    case .pin2: return "pin2"
    case .puk2: return "puk2"
    case .notInserted: return "not inserted"
    case .failure: return "failure"
    case .busy: return "busy"
    case .other(let text): return text
    }
}

/// The window's rows and the CLI's lines: SIM, PIN lock, Attempts left; a row whose value was not read
/// is left out.
func simRows(_ sim: SimInfo) -> [(label: String, value: String)] {
    var rows: [(label: String, value: String)] = [(label: "SIM", value: simStateWords(sim.state))]
    if let lock = sim.pinLock { rows.append((label: "PIN lock", value: lock ? "on" : "off")) }
    let attempts = [sim.pinAttempts.map { "PIN \($0)" }, sim.pukAttempts.map { "PUK \($0)" }].compactMap { $0 }
    if !attempts.isEmpty { rows.append((label: "Attempts left", value: attempts.joined(separator: ", "))) }
    return rows
}

/// `RMNet sim --json`: every key is always there; a value not read is null.
func simJSON(_ sim: SimInfo) -> [String: Any] {
    ["state": simStateKey(sim.state), "pinLock": orNull(sim.pinLock), "pinAttempts": orNull(sim.pinAttempts),
     "pukAttempts": orNull(sim.pukAttempts)]
}

/// "1 attempt left", "3 attempts left".
private func attemptsLeft(_ n: Int) -> String {
    n == 1 ? "1 attempt left" : "\(n) attempts left"
}

// MARK: - Before a change: the questions

func radioOffQuestion() -> (title: String, message: String) {
    (title: "Switch the radio off?",
     message: "The modem leaves the network (airplane mode), and the driver's connection is down until the radio is "
        + "switched on again: press Radio On, or run `RMNet radio on`.")
}

/// The way back from a mode change: for any mode `canonicalMode` accepts, which the service sends in the
/// modem's own order (ruling R8: `NR5G:LTE` is put back as `NR5G:LTE`); not for another value.
private func modeWayBack(_ from: String?) -> String {
    guard let from else { return "After the change, RMNet says how to put the earlier mode back." }
    guard canonicalMode(from) != nil else {
        return "RMNet cannot set \(from) again; to put it back, set it again on the modem's console."
    }
    return "To put it back, press Put Back in the window or run `RMNet mode \(from.lowercased())`."
}

func modeQuestion(from: String?, to: String) -> (title: String, message: String) {
    let change = from.map { "The modem changes from \(modeWords($0)) to \(modeWords(to)) at once" }
        ?? "The current mode could not be read. The modem changes to \(modeWords(to)) at once"
    return (title: "Change the network mode to \(modeWords(to))?",
            message: "\(change); the connection can drop while it finds a network. "
                + "The modem keeps this setting, also after a restart. " + modeWayBack(from))
}

/// Before and after side by side, with whether the password changes (never its value). Without the
/// earlier settings (they could not be read), it says whether a password is set.
func profileQuestion(id: Int, before: ProfileSettings?, after: ProfileSettings) -> (title: String, message: String) {
    let now = before.map { "Now: \(profileWords($0))." } ?? "Now: the current settings could not be read."
    let password: String
    if let before {
        password = before.password == after.password ? "unchanged" : "changed"
    } else {
        password = after.password.isEmpty ? "none" : "set"
    }
    let new = "New: \(settingsWords(after)); password: \(password)."
    let warning = "A wrong APN breaks the connection. If the radio is on, RMNet switches it off and on again (a redial) "
        + "so that the driver dials with the new settings; the connection drops for about 10 to 30 seconds. "
        + "The modem keeps these settings until they are changed again."
    return (title: "Change profile \(id)?", message: [now, new, warning].joined(separator: "\n"))
}

func pinQuestion(attempts: Int) -> (title: String, message: String) {
    let message: String
    if attempts < 1 {
        message = "The SIM has no PIN attempts left: it needs its PUK from the carrier, and RMNet does not enter PUKs."
    } else if attempts == 1 {
        message = "1 attempt left. This is the last attempt: a wrong PIN blocks the SIM until its PUK (from the carrier) "
            + "is entered, and RMNet does not enter PUKs."
    } else {
        message = "The SIM has \(attemptsLeft(attempts)); a wrong PIN uses one."
    }
    return (title: "Send the PIN to the SIM?", message: message)
}

/// The window's checkbox while the SIM has 1 PIN attempt left, its `--last-attempt` (ruling R20).
let lastAttemptChoice = "Use the last attempt (a wrong PIN blocks the SIM until its PUK is entered)"

/// Whether the window's Unlock… may be pressed: a PIN of 4 to 8 digits, at least 1 attempt left, and at the
/// last attempt the checkbox ticked (ruling R20).
func unlockAllowed(pin: String, attempts: Int, lastAttemptTicked: Bool) -> Bool {
    pinProblem(pin) == nil && attempts >= 1 && (attempts > 1 || lastAttemptTicked)
}

// MARK: - After a change: the sentences

/// Registered: "The radio is on; <registration words> after <n> s." (ruling R5: the words already say
/// "registered"); not registered within the wait: "…has not registered yet (<words>)".
func radioSentence(_ c: RadioChange) -> String {
    guard c.on else { return "The radio is off. The driver's connection is down until the radio is switched on again." }
    let words = registrationWords(c.registration)
    let registered = c.registration.map { $0.status == .home || $0.status == .roaming } ?? false
    guard registered else { return "The radio is on, but the modem has not registered yet (\(words))." }
    if let n = c.secondsToRegister { return "The radio is on; \(words) after \(n) s." }
    return "The radio is on; \(words)."
}

func modeSentence(_ c: ModeChange) -> String {
    if c.before == c.after { return "The network mode is \(modeWords(c.after)), as it was." }
    return "The network mode is now \(modeWords(c.after)); it was \(modeWords(c.before)). The modem keeps this setting."
}

/// A reason from the service as the middle of a sentence: trimmed, a first word such as "The" lowercased
/// (not "AT+CFUN" or "I/O"), ending in `.`, `?` or `!` (a full stop added otherwise). An empty reason
/// reads "the radio could not be switched on."
private func clause(_ why: String) -> String {
    var scalars = Array(modemTextSafe(why.trimmingCharacters(in: .whitespacesAndNewlines)).unicodeScalars)
    guard let last = scalars.last else { return "the radio could not be switched on." }
    if scalars.count >= 2, (0x41...0x5A).contains(scalars[0].value), (0x61...0x7A).contains(scalars[1].value),
       let lower = Unicode.Scalar(scalars[0].value + 0x20) {
        scalars[0] = lower
    }
    if last != ".", last != "?", last != "!" { scalars.append(".") }
    var out = String.UnicodeScalarView()
    out.append(contentsOf: scalars)
    return String(out)
}

func profileSentence(_ c: ProfileChange) -> String {
    let now = "Profile \(c.id) is now \(profileWords(c.after))."
    switch c.redial {
    case .notAsked:
        return "\(now) The driver uses it the next time it dials (after the radio is switched off and on, or the modem restarts)."
    case .radioWasOff:
        return "\(now) The radio was off; the new settings are used when the radio is switched on."
    case .done(let radio):
        return "\(now) The radio was switched off and on again. \(radioSentence(radio))"
    case .radioLeftOff(let why):
        return "The profile was changed, but the radio is still off: \(clause(why)) \(now) "
            + "Run `RMNet radio on`, or press Radio On in the window."
    }
}

func pinSentence(_ o: PinOutcome) -> String {
    if o.accepted {
        guard let sim = o.sim else { return "The SIM accepted the PIN." }
        if sim.state == .ready { return "The SIM accepted the PIN and is ready." }
        return "The SIM accepted the PIN (SIM: \(simStateWords(sim.state)))."
    }
    // Only +CME ERROR: 16 (incorrect password) is the SIM refusing the PIN; another line (such as 14, SIM
    // busy) is the modem not taking it, which may or may not have used an attempt (F10).
    let wrongPin = o.refusal.flatMap { atFields($0, prefix: "+CME ERROR") }.flatMap { answerInt($0, 0) } == 16
    guard wrongPin else { return pinNotTakenSentence(o) }
    guard let sim = o.sim else {
        return "The SIM refused the PIN. Its state could not be read; check the attempts left (RMNet sim) before entering it again."
    }
    switch sim.state {
    case .puk:
        return "The SIM refused the PIN and is now blocked: it needs its PUK from the carrier. RMNet does not enter PUKs."
    case .pin:
        guard let n = sim.pinAttempts else { return "The SIM refused the PIN. The attempts left could not be read." }
        if n == 1 {
            return "The SIM refused the PIN. 1 attempt left: the next wrong PIN blocks the SIM until its PUK is entered."
        }
        return "The SIM refused the PIN. \(attemptsLeft(n))."
    default:
        return "The SIM refused the PIN (SIM: \(simStateWords(sim.state)))."
    }
}

/// A PIN not taken with a line other than +CME ERROR: 16: the line (display-safe), then the attempts left
/// as read again, to be checked before the PIN is entered again.
private func pinNotTakenSentence(_ o: PinOutcome) -> String {
    let start = "The modem did not take the PIN" + (o.refusal.map { " (\(modemTextSafe($0)))" } ?? "") + "."
    guard let sim = o.sim else {
        return "\(start) The SIM's state could not be read; check the attempts left (RMNet sim) before entering it again."
    }
    switch sim.state {
    case .puk:
        return "\(start) The SIM is now blocked: it needs its PUK from the carrier. RMNet does not enter PUKs."
    case .pin:
        guard let n = sim.pinAttempts else {
            return "\(start) The attempts left could not be read; check them (RMNet sim) before entering it again."
        }
        return "\(start) \(attemptsLeft(n)); check them before entering it again."
    default:
        return "\(start) SIM: \(simStateWords(sim.state))."
    }
}
