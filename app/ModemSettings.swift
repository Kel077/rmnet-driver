// The modem's settings and the changes RMNet makes to them: the radio, the network mode, the data
// profiles (APN, user name, password, authentication) and the SIM's PIN. Here are the reading of their AT
// answers, the checks of what the owner types, the AT lines that change the modem, the questions asked
// before a change and the sentences said after it, and `ModemServing`, the interface of the service that
// does the I/O. Foundation only: pure functions over the answer lines (AtPort's lines between the echo
// and OK), so `make app-test` builds this file with ModemNetwork.swift alone. A missing field, `-` in
// place of a number, or a short line reads as "not known"; nothing here crashes on an odd answer.
//
// A profile's password is kept in memory only. No string conversion of any value here shows it (only
// whether one is set); the one text that holds it is `profileCommand`, the line sent to the modem.
import Foundation

// MARK: - Values

/// A sentence for the owner.
struct ModemFailure: Error, Equatable { let message: String }

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

/// Whether the SIM took the PIN, and the SIM read again after it (nil when that read failed).
struct PinOutcome: Equatable { let accepted: Bool; let sim: SimInfo? }

/// The modem over its spare AT port. Each call blocks until done; callers keep it off the main thread.
protocol ModemServing {
    func networkInfo() -> Result<NetworkInfo, ModemFailure>
    func setRadio(on: Bool) -> Result<RadioChange, ModemFailure>
    func setMode(_ mode: String) -> Result<ModeChange, ModemFailure>          // one canonicalMode accepts (R8)
    func profiles() -> Result<[DataProfile], ModemFailure>
    func setProfile(_ id: Int, to settings: ProfileSettings, redial: Bool) -> Result<ProfileChange, ModemFailure>
    func sim() -> Result<SimInfo, ModemFailure>
    func enterPin(_ pin: String, shownAttempts: Int) -> Result<PinOutcome, ModemFailure>
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

/// What the window offers, in this order.
let networkModeChoices = ["AUTO", "LTE:NR5G", "NR5G", "LTE"]

private let modeRATs = ["WCDMA", "LTE", "NR5G"]

/// The mode_pref value for what the owner typed, ignoring case: `auto` alone, or RATs from `wcdma`,
/// `lte` and `nr5g` joined by `:`, each at most once, returned in the order WCDMA, LTE, NR5G
/// (`nr5g:lte` → `LTE:NR5G`). nil for anything else: empty, an unknown name, a repeat, `auto` with
/// others, an empty piece.
func canonicalMode(_ argument: String) -> String? {
    if argument.lowercased() == "auto" { return "AUTO" }
    var picked = Set<String>()
    for piece in argument.lowercased().split(separator: ":", omittingEmptySubsequences: false) {
        guard let rat = modeRATs.first(where: { $0.lowercased() == piece }), !picked.contains(rat) else { return nil }
        picked.insert(rat)
    }
    return picked.isEmpty ? nil : modeRATs.filter { picked.contains($0) }.joined(separator: ":")
}

/// AT+QNWPREFCFG="mode_pref",<mode>: written to the modem's NVM, in effect at once.
func modeCommand(_ mode: String) -> String {
    "AT+QNWPREFCFG=\"mode_pref\",\(mode)"
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

private let apnRule = "An APN is at most 100 characters of ASCII letters, digits, dots, hyphens and underscores, "
    + "and does not start or end with a dot."
private let userRule = "A user name is at most 127 characters of printable ASCII, without a double quote (\") or a backslash (\\)."
private let passwordRule = "A password is at most 127 characters of printable ASCII, without a double quote (\") or a backslash (\\)."
private let noAuthenticationRule = "With no authentication the user name and password must be empty; "
    + "choose PAP, CHAP or PAP or CHAP to use them."

/// Up to 100 of ASCII letters, digits, `.`, `-`, `_`, not starting or ending with `.`; empty is allowed
/// (the network chooses). Checked by Unicode scalar, so a combining mark is a character of its own.
private func apnAllowed(_ apn: String) -> Bool {
    let scalars = apn.unicodeScalars
    guard scalars.count <= 100 else { return false }
    guard scalars.first != ".", scalars.last != "." else { return false }
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

/// nil when the settings can be sent to profile `id`; else the sentence saying which rule they break
/// (the profile number first, then the APN, the user name, the password, then that with no authentication
/// both are empty; never quoting the password). With authentication 0 the modem turns a profile that has a
/// password into CHAP by itself (seen on 2026-11-15, ruling R15), so RMNet does not send such a profile.
func profileProblem(_ id: Int, _ s: ProfileSettings) -> String? {
    if !(1...16).contains(id) { return "Profile \(id) cannot be changed by RMNet: AT+QICSGP takes profiles 1 to 16." }
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
