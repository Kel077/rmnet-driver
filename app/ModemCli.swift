// The command-line verbs for the modem's network and settings: `network`, `radio`, `mode`, `apn` and
// `sim`. The parser (wrong usage is nil: main.swift prints the usage line and exits 2 without opening the
// port) and what each verb prints, over a `ModemServing`, the readSecret that reads a password or a PIN
// without echo, and the output. Foundation only, with ModemNetwork.swift and ModemSettings.swift:
// `make app-test` builds it with them and a fake service.
//
// Each verb prints lines starting `<verb>: ` (the `network` rows and the `apn` profile lines aside) and
// returns 0, or 1 after a failure, printed as one line `<verb>: <sentence>`. A password or PIN goes from
// readSecret to the service and nowhere else: no line printed holds one.
import Foundation

enum ModemCommand: Equatable {
    case network(json: Bool)
    case radio(on: Bool?)                       // nil: show
    case mode(String?)                          // nil: show; else the mode as typed, upper-cased, the RATs in
                                                // the order typed: one canonicalMode accepts, not its reordered
                                                // value, so a put-back restores the modem's own string (R8, R17)
    case apnShow(json: Bool)
    case apnSet(apn: String?, type: PdpType?, user: String?, askPassword: Bool, clearPassword: Bool, auth: AuthMethod?,
                redial: Bool)
    case sim(json: Bool)
    case simUnlock(lastAttempt: Bool)

    /// Radio on or off, a mode set, apn set and sim unlock: main.swift ignores the stopping signals for these.
    var changesModem: Bool {
        switch self {
        case .network, .apnShow, .sim: return false
        case .radio(let on): return on != nil
        case .mode(let mode): return mode != nil
        case .apnSet, .simUnlock: return true
        }
    }
}

let modemVerbs: Set<String> = ["network", "radio", "mode", "apn", "sim"]

/// Appended to main.swift's usage line.
let modemUsage = "network [--json] | radio [on|off] | mode [auto|nr5g|lte|lte:nr5g|…] | apn [show] [--json] | "
    + "apn set [--apn <name>] [--type ipv4|ipv6|ipv4v6] [--user <name>] [--password | --no-password] "
    + "[--auth none|pap|chap|pap-or-chap] [--no-redial] | sim [--json] | sim unlock [--last-attempt]"

// MARK: - Parsing

/// The words including the verb; nil for wrong usage.
func parseModem(_ words: [String]) -> ModemCommand? {
    guard let verb = words.first else { return nil }
    let rest = Array(words.dropFirst())
    switch verb {
    case "network":
        return jsonOption(rest).map { .network(json: $0) }
    case "radio":
        switch rest {
        case []: return .radio(on: nil)
        case ["on"]: return .radio(on: true)
        case ["off"]: return .radio(on: false)
        default: return nil
        }
    case "mode":
        if rest.isEmpty { return .mode(nil) }
        guard rest.count == 1, canonicalMode(rest[0]) != nil else { return nil }
        return .mode(rest[0].uppercased())        // ASCII names only, as canonicalMode accepts them
    case "apn":
        if rest.first == "set" { return parseApnSet(Array(rest.dropFirst())) }
        return jsonOption(rest.first == "show" ? Array(rest.dropFirst()) : rest).map { .apnShow(json: $0) }
    case "sim":
        guard rest.first == "unlock" else { return jsonOption(rest).map { .sim(json: $0) } }
        switch Array(rest.dropFirst()) {
        case []: return .simUnlock(lastAttempt: false)
        case ["--last-attempt"]: return .simUnlock(lastAttempt: true)
        default: return nil                       // a PIN is never taken from the command line
        }
    default:
        return nil
    }
}

/// Nothing: false; `--json`: true; anything else: nil.
private func jsonOption(_ words: [String]) -> Bool? {
    switch words {
    case []: return false
    case ["--json"]: return true
    default: return nil
    }
}

private let typeOptions: [String: PdpType] = ["ipv4": .ipv4, "ipv6": .ipv6, "ipv4v6": .ipv4v6]
private let authOptions: [String: AuthMethod] = ["none": AuthMethod.none, "pap": .pap, "chap": .chap,
                                                  "pap-or-chap": .papOrChap]

/// The words after `apn set`. Each option at most once; `--password` and `--no-password` not together; at
/// least one option that changes a setting (`--no-redial` alone changes nothing). The word after `--apn` or
/// `--user` is the value as given, whatever it is (also '').
private func parseApnSet(_ words: [String]) -> ModemCommand? {
    var apn: String? = nil
    var type: PdpType? = nil
    var user: String? = nil
    var auth: AuthMethod? = nil
    var askPassword = false
    var clearPassword = false
    var redial = true
    var seen = Set<String>()
    var i = 0
    while i < words.count {
        let option = words[i]
        i += 1
        guard seen.insert(option).inserted else { return nil }
        switch option {
        case "--password": askPassword = true
        case "--no-password": clearPassword = true
        case "--no-redial": redial = false
        case "--apn", "--user", "--type", "--auth":
            guard i < words.count else { return nil }
            let value = words[i]
            i += 1
            switch option {
            case "--apn": apn = value
            case "--user": user = value
            case "--type":
                guard let t = typeOptions[value] else { return nil }
                type = t
            default:
                guard let a = authOptions[value] else { return nil }
                auth = a
            }
        default:
            return nil
        }
    }
    guard !(askPassword && clearPassword) else { return nil }
    guard apn != nil || type != nil || user != nil || auth != nil || askPassword || clearPassword else { return nil }
    return .apnSet(apn: apn, type: type, user: user, askPassword: askPassword, clearPassword: clearPassword, auth: auth,
                   redial: redial)
}

// MARK: - Running

/// Runs `command` (blocking: off the main thread) and returns the exit code, 0 or 1. `driverProfile` is the
/// driver's `RMNetProfile` (nil when the driver is not attached); `readSecret` reads a password or PIN
/// without echo after showing its prompt (nil without a terminal); `output` prints one line.
func runModem(_ command: ModemCommand, service: ModemServing, driverProfile: Int?,
              readSecret: (String) -> String?, output: (String) -> Void) -> Int32 {
    switch command {
    case .network(let json):
        return showNetwork(service, json: json, output)
    case .radio(let on):
        guard let on else { return showRadio(service, output) }
        switch service.setRadio(on: on) {
        case .failure(let failure): return fail("radio", failure.message, output)
        case .success(let change):
            output("radio: \(radioSentence(change))")
            return 0
        }
    case .mode(let mode):
        guard let mode else { return showMode(service, output) }
        return setMode(service, mode, output)
    case .apnShow(let json):
        return showProfiles(service, driverProfile: driverProfile, json: json, output)
    case let .apnSet(apn, type, user, askPassword, clearPassword, auth, redial):
        let options = ProfileOptions(apn: apn, type: type, user: user, auth: auth, askPassword: askPassword,
                                     clearPassword: clearPassword, redial: redial)
        return setProfile(service, driverProfile ?? 1, options, readSecret: readSecret, output)
    case .sim(let json):
        switch service.sim() {
        case .failure(let failure): return fail("sim", failure.message, output)
        case .success(let sim):
            if json { return outputJSON("sim", simJSON(sim), output) }
            for row in simRows(sim) {
                // The SIM row is the state itself: `sim: ready`; the others `sim: pin lock: off`.
                output(row.label == "SIM" ? "sim: \(row.value)" : "sim: \(row.label.lowercased()): \(row.value)")
            }
            return 0
        }
    case .simUnlock(let lastAttempt):
        return unlockSim(service, lastAttempt: lastAttempt, readSecret: readSecret, output)
    }
}

/// One failure line, exit 1.
private func fail(_ verb: String, _ sentence: String, _ output: (String) -> Void) -> Int32 {
    output("\(verb): \(sentence)")
    return 1
}

/// The object pretty-printed with sorted keys, as one output.
private func outputJSON(_ verb: String, _ object: [String: Any], _ output: (String) -> Void) -> Int32 {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return fail(verb, "The answer could not be written as JSON.", output)
    }
    output(text)
    return 0
}

private func showNetwork(_ service: ModemServing, json: Bool, _ output: (String) -> Void) -> Int32 {
    switch service.networkInfo() {
    case .failure(let failure): return fail("network", failure.message, output)
    case .success(let info):
        if json { return outputJSON("network", networkJSON(info), output) }
        for row in networkRows(info) { output("\(row.label.lowercased()): \(row.value)") }
        return 0
    }
}

/// The network read's Radio row: `on`, `off (airplane mode)`, `minimum functionality`, `AT+CFUN <n>`.
private func showRadio(_ service: ModemServing, _ output: (String) -> Void) -> Int32 {
    switch service.networkInfo() {
    case .failure(let failure): return fail("radio", failure.message, output)
    case .success(let info):
        guard info.radio != nil, let words = networkRows(info).first(where: { $0.label == "Radio" })?.value else {
            return fail("radio", "The modem did not say whether the radio is on.", output)
        }
        output("radio: \(words)")
        return 0
    }
}

private func showMode(_ service: ModemServing, _ output: (String) -> Void) -> Int32 {
    switch service.networkInfo() {
    case .failure(let failure): return fail("mode", failure.message, output)
    case .success(let info):
        guard let mode = info.mode else { return fail("mode", "The modem did not say which network mode it uses.", output) }
        output("mode: \(mode) (\(modeWords(mode)))")
        return 0
    }
}

/// The change, then the way back (ruling R8): a mode RMNet can set again is put back as the modem gave it.
private func setMode(_ service: ModemServing, _ mode: String, _ output: (String) -> Void) -> Int32 {
    switch service.setMode(mode) {
    case .failure(let failure): return fail("mode", failure.message, output)
    case .success(let change):
        output("mode: \(modeSentence(change))")
        if canonicalMode(change.before) != nil {
            output("mode: to put it back: RMNet mode \(change.before.lowercased())")
        } else {
            output("mode: the earlier value \(modemTextSafe(change.before)) cannot be set by RMNet; "
                   + "set it again on the modem's console.")
        }
        return 0
    }
}

/// A listed profile whose AT+QICSGP settings were not read (refused, or above 16): its AT+CGDCONT type
/// and APN (both display-safe already).
private func listedWords(_ p: DataProfile) -> String {
    "\(p.pdpType), APN \"\(p.apn)\"" + (p.apn.isEmpty ? " (the network chooses)" : "") + "; other settings not read"
}

private func showProfiles(_ service: ModemServing, driverProfile: Int?, json: Bool, _ output: (String) -> Void) -> Int32 {
    switch service.profiles() {
    case .failure(let failure): return fail("apn", failure.message, output)
    case .success(let profiles):
        let driver = driverProfile ?? 1
        if json {
            var object = profilesJSON(profiles, driverProfile: driver)
            object["driverAttached"] = driverProfile != nil
            return outputJSON("apn", object, output)
        }
        if let driverProfile {
            output("apn: the driver dials profile \(driverProfile)")
        } else {
            output("apn: the driver is not attached; it dials profile 1 unless set otherwise")
        }
        for p in profiles {
            let words = p.settings.map(profileWords) ?? listedWords(p)
            output("profile \(p.id): \(words)" + (p.id == driver ? " (the driver's)" : ""))
        }
        return 0
    }
}

/// What `apn set` was given, apart from the password itself.
private struct ProfileOptions {
    let apn: String?
    let type: PdpType?
    let user: String?
    let auth: AuthMethod?
    let askPassword: Bool
    let clearPassword: Bool
    let redial: Bool
}

/// Reads the profile's settings, puts the options over them, checks them, warns, reads a new password if
/// asked, and changes the profile. Nothing is changed before the checks pass, nor when the password was not
/// read or is empty. A password kept from the current settings is sent as it is; none is ever printed.
private func setProfile(_ service: ModemServing, _ id: Int, _ options: ProfileOptions,
                        readSecret: (String) -> String?, _ output: (String) -> Void) -> Int32 {
    var settings: ProfileSettings
    switch service.profiles() {
    case .failure(let failure): return fail("apn", failure.message, output)
    case .success(let profiles):
        guard let current = profiles.first(where: { $0.id == id })?.settings else {
            return fail("apn", "Profile \(id) could not be read. Nothing was changed.", output)
        }
        settings = current
    }
    if let apn = options.apn { settings.apn = apn }
    if let type = options.type { settings.type = type }
    if let user = options.user { settings.user = user }
    if let auth = options.auth { settings.auth = auth }
    if options.clearPassword { settings.password = "" }
    // With --password the new password is read after the warning, and an empty one is refused: the checks
    // before the prompt take it as set (any allowed text stands for it), so a rule it breaks, such as no
    // authentication (ruling R15), is told before anything is typed. The old password is not checked.
    var beforePrompt = settings
    if options.askPassword { beforePrompt.password = "?" }
    if let problem = profileProblem(id, beforePrompt) { return fail("apn", problem, output) }
    output("apn: A wrong APN breaks the connection.")
    if options.askPassword {
        guard let password = readSecret("New password for profile \(id): ") else {
            return fail("apn", "The password was not read (cancelled, or no terminal). Nothing was changed.", output)
        }
        guard !password.isEmpty else {
            return fail("apn", "No password was entered. Nothing was changed; use --no-password to clear the password.",
                        output)
        }
        settings.password = password
        if let problem = profileProblem(id, settings) { return fail("apn", problem, output) }
    }
    switch service.setProfile(id, to: settings, redial: options.redial) {
    case .failure(let failure): return fail("apn", failure.message, output)
    case .success(let change):
        output("apn: \(profileSentence(change))")
        output("apn: to put it back: RMNet apn set \(profileRestoreArguments(change.before))")
        // Changed, but the redial left the radio off: the connection is down until `RMNet radio on`.
        if case .radioLeftOff = change.redial { return 1 }
        return 0
    }
}

/// Sends a PIN only when the SIM asks for one and the attempts left are known and shown first; the last
/// attempt only with `--last-attempt`. The service checks the attempts again before sending.
private func unlockSim(_ service: ModemServing, lastAttempt: Bool, readSecret: (String) -> String?,
                       _ output: (String) -> Void) -> Int32 {
    let sim: SimInfo
    switch service.sim() {
    case .failure(let failure): return fail("sim", failure.message, output)
    case .success(let read): sim = read
    }
    switch sim.state {
    case .pin:
        break
    case .puk:
        return fail("sim", "The SIM is blocked: it needs its PUK from the carrier. RMNet does not enter PUKs.", output)
    default:
        return fail("sim", "The SIM does not ask for a PIN (\(simStateWords(sim.state))).", output)
    }
    guard let attempts = sim.pinAttempts else {
        return fail("sim", "The attempts left could not be read; RMNet does not send a PIN without them.", output)
    }
    guard attempts >= 1 else {
        return fail("sim", "The SIM has no PIN attempts left: it needs its PUK from the carrier, and RMNet does not "
                    + "enter PUKs.", output)
    }
    output("sim: The SIM asks for its PIN. \(attempts) attempt(s) left; a wrong PIN uses one.")
    if attempts == 1 && !lastAttempt {
        return fail("sim", "This is the last attempt: a wrong PIN blocks the SIM until its PUK is entered. "
                    + "Run again with --last-attempt to send it.", output)
    }
    guard let pin = readSecret("PIN: ") else {
        return fail("sim", "The PIN was not read (cancelled, or no terminal). Nothing was sent.", output)
    }
    if let problem = pinProblem(pin) { return fail("sim", problem, output) }
    switch service.enterPin(pin, shownAttempts: attempts) {
    case .failure(let failure): return fail("sim", failure.message, output)
    case .success(let outcome):
        output("sim: \(pinSentence(outcome))")
        return outcome.accepted ? 0 : 1
    }
}
