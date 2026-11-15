// Tests for app/ModemCli.swift: the command-line verbs `network`, `radio`, `mode`, `apn` and `sim`. The
// parser for every form and each wrong usage, and what each verb prints and returns, against a fake
// ModemServing that records its calls and returns set results (no port is opened). The fixtures are the
// modem's real answers (2026-11-15, firmware RM520NGLAAR03A04M4G_01.204.01.204). A password or PIN that
// the fake `readSecret` gives must reach the service and appear in no output line. Built with swiftc by
// `make app-test` together with app/ModemNetwork.swift and app/ModemSettings.swift; needs no Xcode project
// and no hardware. Stops at the first failure, prints which check failed and exits 1.
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

// --- the modem's answers ------------------------------------------------------------------------
let saInfo: NetworkInfo = {
    var info = NetworkInfo()
    info.radio = parseRadio(["+CFUN: 1"])
    let op = parseOperator(["+COPS: 0,0,\"CHINA MOBILE\",11"])
    info.operatorName = op.name
    info.accessTechnology = op.accessTechnology
    let sp = parseServiceProvider(["+QSPN: \"4E2D56FD79FB52A8\",\"4E2D56FD79FB52A8\",\"0043004D00430043\",1,\"46000\""])
    info.networkName = sp.fullName
    info.plmn = sp.plmn
    info.registration = summarizeRegistration(fiveG: parseRegistrationStat(["+C5GREG: 0,1"], prefix: "+C5GREG"),
                                              eps: parseRegistrationStat(["+CEREG: 0,0"], prefix: "+CEREG"),
                                              ps: parseRegistrationStat(["+CGREG: 0,0"], prefix: "+CGREG"),
                                              cs: parseRegistrationStat(["+CREG: 0,0"], prefix: "+CREG"))
    info.serving = parseServingCell(
        ["+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",460,00,123456789,32,1A2B3C,504990,41,12,-95,-10,8,1,-"])
    info.carriers = parseCarriers(["+QCAINFO: \"PCC\",504990,12,\"NR5G BAND 41\",32",
                                   "+QCAINFO: \"SCC\",155770,3,\"NR5G BAND 28\",1,6,0,-,-"])
    info.mode = parseModePreference(["+QNWPREFCFG: \"mode_pref\",AUTO"])
    info.nr5gDisable = parseNr5gDisable(["+QNWPREFCFG: \"nr5g_disable_mode\",0"])
    return info
}()

let readySim: SimInfo = {
    let attempts = parsePinAttempts(["+QPINC: \"SC\",3,10", "+QPINC: \"P2\",3,10"])
    return SimInfo(state: parseSimState(["+CPIN: READY"])!, pinLock: parsePinLock(["+CLCK: 0"]),
                   pinAttempts: attempts.pin, pukAttempts: attempts.puk)
}()

let profile1 = parseProfileSettings(["+QICSGP: 3,\"\",\"\",\"\",0"])!
let profile3 = parseProfileSettings(["+QICSGP: 3,\"CMNET\",\"\",\"\",0"])!
let listed = parseProfiles([
    "+CGDCONT: 1,\"IPV4V6\",\"\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 2,\"IPV4V6\",\"ims\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 3,\"IPV4V6\",\"CMNET\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 4,\"IPV4V6\",\"CMWAP\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 5,\"IPV4V6\",\"SOS\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,1,,,,,,,,,,\"\",,,,0",
])

func settings(_ apn: String, password: String = "") -> ProfileSettings {
    ProfileSettings(type: .ipv4v6, apn: apn, user: "", password: password, auth: .none)
}

/// The five profiles as the modem lists them; profile 2's settings are left unread (as after a refusal).
let fixtureProfiles: [DataProfile] = listed.map { p in
    let s: ProfileSettings?
    switch p.id {
    case 1: s = profile1
    case 2: s = nil
    case 3: s = profile3
    default: s = settings(p.apn)
    }
    return DataProfile(id: p.id, pdpType: p.pdpType, apn: p.apn, settings: s)
}

let homeSA = Registration(status: .home, domain: "5GS")
let radioOn = RadioChange(on: true, registration: homeSA, secondsToRegister: 12)
let radioOff = RadioChange(on: false, registration: nil, secondsToRegister: nil)

// Distinctive secrets that no output line may contain.
let secret = "hunter2-secret"
let oldSecret = "old-secret-77"
let pinSecret = "4711"

// --- the fake service ---------------------------------------------------------------------------

/// Records every call, in order, in `events` (shared with the fake readSecret and the output), and answers
/// with the results set. `setProfile` answers by default with the change asked for, its `before` being the
/// profile as `profiles` gives it.
final class FakeModem: ModemServing {
    var events: [String] = []
    var networkResult: Result<NetworkInfo, ModemFailure> = .success(saInfo)
    var radioResult: Result<RadioChange, ModemFailure>? = nil        // nil: as asked, registered after 12 s
    var modeResult: Result<ModeChange, ModemFailure>? = nil          // nil: from AUTO to what was asked
    var profilesResult: Result<[DataProfile], ModemFailure> = .success(fixtureProfiles)
    var setProfileResult: Result<ProfileChange, ModemFailure>? = nil
    var redialResult: RedialResult = .done(radioOn)                  // when the default change redials
    var simResult: Result<SimInfo, ModemFailure> = .success(readySim)
    var pinResult: Result<PinOutcome, ModemFailure> =
        .success(PinOutcome(accepted: true, sim: SimInfo(state: .ready, pinLock: true, pinAttempts: 3, pukAttempts: 10)))

    var radioAsked: [Bool] = []
    var modesAsked: [String] = []
    var profilesSet: [(id: Int, settings: ProfileSettings, redial: Bool)] = []
    var pinsEntered: [(pin: String, shownAttempts: Int)] = []

    func networkInfo() -> Result<NetworkInfo, ModemFailure> {
        events.append("networkInfo")
        return networkResult
    }
    func setRadio(on: Bool) -> Result<RadioChange, ModemFailure> {
        events.append("setRadio")
        radioAsked.append(on)
        return radioResult ?? .success(on ? radioOn : radioOff)
    }
    func setMode(_ mode: String) -> Result<ModeChange, ModemFailure> {
        events.append("setMode")
        modesAsked.append(mode)
        return modeResult ?? .success(ModeChange(before: "AUTO", after: mode))
    }
    func profiles() -> Result<[DataProfile], ModemFailure> {
        events.append("profiles")
        return profilesResult
    }
    func setProfile(_ id: Int, to settings: ProfileSettings, redial: Bool) -> Result<ProfileChange, ModemFailure> {
        events.append("setProfile")
        profilesSet.append((id: id, settings: settings, redial: redial))
        if let setProfileResult { return setProfileResult }
        let before = (try? profilesResult.get())?.first(where: { $0.id == id })?.settings ?? profile1
        return .success(ProfileChange(id: id, before: before, after: settings, redial: redial ? redialResult : .notAsked))
    }
    func sim() -> Result<SimInfo, ModemFailure> {
        events.append("sim")
        return simResult
    }
    func enterPin(_ pin: String, shownAttempts: Int) -> Result<PinOutcome, ModemFailure> {
        events.append("enterPin")
        pinsEntered.append((pin: pin, shownAttempts: shownAttempts))
        return pinResult
    }
}

/// One run of a verb: what it printed, its exit code, the prompts the fake readSecret was asked.
struct Run {
    let lines: [String]
    let code: Int32
    let prompts: [String]
}

/// Parses `words` (which must be right usage) and runs it against `fake`; readSecret answers `secretAnswer`.
@discardableResult
func run(_ words: [String], _ fake: FakeModem, driverProfile: Int? = 1, secretAnswer: String? = nil,
         _ name: String) -> Run {
    guard let command = parseModem(words) else {
        check(false, "\(name): \(words.joined(separator: " ")) parses")
        return Run(lines: [], code: -1, prompts: [])
    }
    var lines: [String] = []
    var prompts: [String] = []
    let code = runModem(command, service: fake, driverProfile: driverProfile,
                        readSecret: { prompt in
                            fake.events.append("readSecret")
                            prompts.append(prompt)
                            return secretAnswer
                        },
                        output: { line in
                            fake.events.append("output")
                            lines.append(line)
                        })
    return Run(lines: lines, code: code, prompts: prompts)
}

func linesText(_ lines: [String]) -> String {
    lines.map { "    \($0)" }.joined(separator: "\n")
}

func expectLines(_ got: Run, _ want: [String], code: Int32, _ name: String) {
    check(got.lines == want, "\(name): the lines", "want\n\(linesText(want))\n  got\n\(linesText(got.lines))")
    check(got.code == code, "\(name): exit \(code)", "got \(got.code)")
}

/// No line printed (nor any prompt) may hold the secret; a failure shows the lines with it masked.
func expectNoSecret(_ got: Run, _ value: String, _ name: String) {
    let text = (got.lines + got.prompts).joined(separator: "\n")
    check(!text.contains(value), "redaction: \(name)", text.replacingOccurrences(of: value, with: "<the secret>"))
}

func expectParse(_ words: [String], _ want: ModemCommand) {
    let got = parseModem(words)
    check(got == want, "parseModem: \(words)", "want \(want)\n  got  \(String(describing: got))")
}

func expectWrongUsage(_ words: [String]) {
    let got = parseModem(words)
    check(got == nil, "parseModem: \(words) is wrong usage", "got \(String(describing: got))")
}

/// The JSON text a verb must print: the object pretty-printed with sorted keys.
func prettyJSON(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    return String(data: data, encoding: .utf8)!
}

func apnSet(apn: String? = nil, type: PdpType? = nil, user: String? = nil, askPassword: Bool = false,
            clearPassword: Bool = false, auth: AuthMethod? = nil, redial: Bool = true) -> ModemCommand {
    .apnSet(apn: apn, type: type, user: user, askPassword: askPassword, clearPassword: clearPassword, auth: auth,
            redial: redial)
}

let warning = "apn: A wrong APN breaks the connection."
let noAuthentication = "apn: With no authentication the user name and password must be empty; "
    + "choose PAP, CHAP or PAP or CHAP to use them."

/// What `apn --json` prints: profilesJSON with `driverAttached` (ruling R17).
func apnJSON(_ profiles: [DataProfile], driverProfile: Int?) -> [String: Any] {
    var object = profilesJSON(profiles, driverProfile: driverProfile ?? 1)
    object["driverAttached"] = driverProfile != nil
    return object
}

/// The `driverAttached` value of one printed JSON object.
func driverAttached(_ got: Run) -> Bool? {
    guard got.lines.count == 1, let data = got.lines[0].data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return object["driverAttached"] as? Bool
}
let restoreProfile1 = "apn: to put it back: RMNet apn set --apn '' --type ipv4v6 --user '' --auth none --no-password"

@main
struct ModemCliTests {
    static func main() {
        // --- the verbs and the usage -------------------------------------------------------------
        check(modemVerbs == ["network", "radio", "mode", "apn", "sim"], "modemVerbs", "\(modemVerbs.sorted())")
        check(modemUsage == "network [--json] | radio [on|off] | mode [auto|nr5g|lte|lte:nr5g|…] | apn [show] [--json] | "
              + "apn set [--apn <name>] [--type ipv4|ipv6|ipv4v6] [--user <name>] [--password | --no-password] "
              + "[--auth none|pap|chap|pap-or-chap] [--no-redial] | sim [--json] | sim unlock [--last-attempt]",
              "modemUsage: the brief's usage without the leading RMNet", modemUsage)

        // --- parseModem: every form --------------------------------------------------------------
        expectParse(["network"], .network(json: false))
        expectParse(["network", "--json"], .network(json: true))
        expectParse(["radio"], .radio(on: nil))
        expectParse(["radio", "on"], .radio(on: true))
        expectParse(["radio", "off"], .radio(on: false))
        expectParse(["mode"], .mode(nil))
        expectParse(["mode", "auto"], .mode("AUTO"))
        expectParse(["mode", "AUTO"], .mode("AUTO"))
        expectParse(["mode", "lte"], .mode("LTE"))
        expectParse(["mode", "nr5g"], .mode("NR5G"))
        expectParse(["mode", "lte:nr5g"], .mode("LTE:NR5G"))
        expectParse(["mode", "Lte:Nr5g"], .mode("LTE:NR5G"))
        // Ruling R8: the RATs keep the order typed, so a put-back restores the modem's own string.
        expectParse(["mode", "nr5g:lte"], .mode("NR5G:LTE"))
        expectParse(["mode", "wcdma:nr5g:lte"], .mode("WCDMA:NR5G:LTE"))
        expectParse(["apn"], .apnShow(json: false))
        expectParse(["apn", "--json"], .apnShow(json: true))
        expectParse(["apn", "show"], .apnShow(json: false))
        expectParse(["apn", "show", "--json"], .apnShow(json: true))
        expectParse(["apn", "set", "--apn", "cmnet"], apnSet(apn: "cmnet"))
        expectParse(["apn", "set", "--apn", ""], apnSet(apn: ""))
        expectParse(["apn", "set", "--type", "ipv4"], apnSet(type: .ipv4))
        expectParse(["apn", "set", "--type", "ipv6"], apnSet(type: .ipv6))
        expectParse(["apn", "set", "--type", "ipv4v6"], apnSet(type: .ipv4v6))
        expectParse(["apn", "set", "--user", "u"], apnSet(user: "u"))
        expectParse(["apn", "set", "--user", ""], apnSet(user: ""))
        expectParse(["apn", "set", "--password"], apnSet(askPassword: true))
        expectParse(["apn", "set", "--no-password"], apnSet(clearPassword: true))
        expectParse(["apn", "set", "--auth", "none"], apnSet(auth: AuthMethod.none))
        expectParse(["apn", "set", "--auth", "pap"], apnSet(auth: .pap))
        expectParse(["apn", "set", "--auth", "chap"], apnSet(auth: .chap))
        expectParse(["apn", "set", "--auth", "pap-or-chap"], apnSet(auth: .papOrChap))
        expectParse(["apn", "set", "--apn", "cmnet", "--no-redial"], apnSet(apn: "cmnet", redial: false))
        expectParse(["apn", "set", "--no-redial", "--apn", "cmnet"], apnSet(apn: "cmnet", redial: false))
        expectParse(["apn", "set", "--apn", "x", "--type", "ipv4", "--user", "u", "--password", "--auth", "pap-or-chap",
                     "--no-redial"],
                    apnSet(apn: "x", type: .ipv4, user: "u", askPassword: true, auth: .papOrChap, redial: false))
        expectParse(["apn", "set", "--auth", "chap", "--no-password", "--user", "u v", "--type", "ipv6", "--apn", "a.b"],
                    apnSet(apn: "a.b", type: .ipv6, user: "u v", clearPassword: true, auth: .chap))
        // Any value after --apn or --user is taken as given, also one that looks like an option.
        expectParse(["apn", "set", "--apn", "--no-redial"], apnSet(apn: "--no-redial"))
        expectParse(["apn", "set", "--user", "--apn"], apnSet(user: "--apn"))
        expectParse(["sim"], .sim(json: false))
        expectParse(["sim", "--json"], .sim(json: true))
        expectParse(["sim", "unlock"], .simUnlock(lastAttempt: false))
        expectParse(["sim", "unlock", "--last-attempt"], .simUnlock(lastAttempt: true))

        // --- parseModem: wrong usage -------------------------------------------------------------
        for words in [
            ["radio", "up"], ["mode", "5g"], ["apn", "set"], ["apn", "set", "--apn"],
            ["apn", "set", "--apn", "a", "--apn", "b"], ["sim", "unlock", "1234"], ["network", "--xml"],
            ["apn", "set", "--password", "--no-password"], ["apn", "set", "--no-password", "--password"],
            [], ["status"], ["sms"], ["Network"], ["network", "--json", "--json"], ["network", "json"],
            ["radio", "on", "off"], ["radio", "ON"], ["radio", "--json"],
            ["mode", ""], ["mode", "lte:lte"], ["mode", "auto:lte"], ["mode", "lte", "nr5g"], ["mode", "nr"],
            ["mode", "--json"],
            ["apn", "list"], ["apn", "show", "--xml"], ["apn", "--json", "show"], ["apn", "show", "show"],
            ["apn", "--json", "--json"],
            ["apn", "set", "--no-redial"], ["apn", "set", "--type"], ["apn", "set", "--type", "ipv5"],
            ["apn", "set", "--type", "IPV4"], ["apn", "set", "--auth"], ["apn", "set", "--auth", "md5"],
            ["apn", "set", "--user"], ["apn", "set", "--apn", "x", "extra"], ["apn", "set", "cmnet"],
            ["apn", "set", "--password", "--password"], ["apn", "set", "--no-password", "--no-password"],
            ["apn", "set", "--apn", "x", "--no-redial", "--no-redial"], ["apn", "set", "--user", "a", "--user", "b"],
            ["apn", "set", "--type", "ipv4", "--type", "ipv6"], ["apn", "set", "--auth", "pap", "--auth", "pap"],
            ["apn", "set", "--apn", "x", "--pin", "1234"], ["apn", "set", "--password", "secret"],
            ["sim", "--xml"], ["sim", "lock"], ["sim", "unlock", "--last-attempt", "--last-attempt"],
            ["sim", "unlock", "--json"], ["sim", "--json", "unlock"], ["sim", "unlock", "--last-attempt", "1234"],
        ] {
            expectWrongUsage(words)
        }

        // --- changesModem: exactly the five changing forms ---------------------------------------
        let changing: [ModemCommand] = [.radio(on: true), .radio(on: false), .mode("LTE"), apnSet(apn: "x"),
                                        .simUnlock(lastAttempt: false), .simUnlock(lastAttempt: true)]
        let reading: [ModemCommand] = [.network(json: false), .network(json: true), .radio(on: nil), .mode(nil),
                                       .apnShow(json: false), .apnShow(json: true), .sim(json: false), .sim(json: true)]
        for c in changing { check(c.changesModem, "changesModem: \(c) changes the modem") }
        for c in reading { check(!c.changesModem, "changesModem: \(c) only reads") }

        // --- network -----------------------------------------------------------------------------
        let saLines = [
            "registration: registered, home network (5GS)",
            "operator: CHINA MOBILE (中国移动), PLMN 46000",
            "technology: 5G SA (TDD)",
            "band: n41 + n28 (carrier aggregation)",
            "signal: RSRP -95 dBm, RSRQ -10 dB, SINR 8 dB",
            "cell: PCI 32, cell ID 123456789, TAC 1A2B3C",
            "channel: ARFCN 504990, 100 MHz",
            "connection: idle",
            "radio: on",
            "network mode: automatic (5G, LTE and WCDMA)",
        ]
        var fake = FakeModem()
        expectLines(run(["network"], fake, "network"), saLines, code: 0, "network: the SA fixture")
        check(fake.events.filter { $0 != "output" } == ["networkInfo"], "network: one read", "\(fake.events)")

        fake = FakeModem()
        expectLines(run(["network", "--json"], fake, "network --json"), [prettyJSON(networkJSON(saInfo))], code: 0,
                    "network --json: networkJSON, pretty, sorted keys")

        fake = FakeModem()
        fake.networkResult = .failure(ModemFailure(message: "Fake: no modem."))
        expectLines(run(["network"], fake, "network failed"), ["network: Fake: no modem."], code: 1, "network: a failure")
        fake = FakeModem()
        fake.networkResult = .failure(ModemFailure(message: "Fake: no modem."))
        expectLines(run(["network", "--json"], fake, "network --json failed"), ["network: Fake: no modem."], code: 1,
                    "network --json: a failure")

        // --- radio -------------------------------------------------------------------------------
        fake = FakeModem()
        expectLines(run(["radio"], fake, "radio"), ["radio: on"], code: 0, "radio: on")
        check(fake.radioAsked.isEmpty, "radio: showing changes nothing")
        fake = FakeModem()
        var airplane = saInfo
        airplane.radio = .airplane
        fake.networkResult = .success(airplane)
        expectLines(run(["radio"], fake, "radio airplane"), ["radio: off (airplane mode)"], code: 0, "radio: airplane mode")
        fake = FakeModem()
        var minimum = saInfo
        minimum.radio = .minimum
        fake.networkResult = .success(minimum)
        expectLines(run(["radio"], fake, "radio minimum"), ["radio: minimum functionality"], code: 0, "radio: minimum")
        fake = FakeModem()
        var unread = saInfo
        unread.radio = nil
        fake.networkResult = .success(unread)
        let radioUnread = run(["radio"], fake, "radio unread")
        check(radioUnread.code == 1 && radioUnread.lines.count == 1 && radioUnread.lines[0].hasPrefix("radio: "),
              "radio: a state not read is one failure line, exit 1", linesText(radioUnread.lines))
        fake = FakeModem()
        fake.networkResult = .failure(ModemFailure(message: "Fake: busy."))
        expectLines(run(["radio"], fake, "radio failed"), ["radio: Fake: busy."], code: 1, "radio: a failure")

        fake = FakeModem()
        expectLines(run(["radio", "off"], fake, "radio off"),
                    ["radio: The radio is off. The driver's connection is down until the radio is switched on again."],
                    code: 0, "radio off")
        check(fake.radioAsked == [false], "radio off: setRadio(on: false)", "\(fake.radioAsked)")
        fake = FakeModem()
        expectLines(run(["radio", "on"], fake, "radio on"),
                    ["radio: The radio is on; registered, home network (5GS) after 12 s."], code: 0, "radio on")
        check(fake.radioAsked == [true], "radio on: setRadio(on: true)", "\(fake.radioAsked)")
        check(fake.events.filter { $0 != "output" } == ["setRadio"], "radio on: nothing read before", "\(fake.events)")
        fake = FakeModem()
        let searching = RadioChange(on: true, registration: Registration(status: .searching, domain: "5GS"),
                                    secondsToRegister: nil)
        fake.radioResult = .success(searching)
        expectLines(run(["radio", "on"], fake, "radio on, searching"), ["radio: " + radioSentence(searching)],
                    code: 0, "radio on: not registered yet is still on")
        fake = FakeModem()
        fake.radioResult = .failure(ModemFailure(message: "Fake: the radio could not be switched."))
        expectLines(run(["radio", "off"], fake, "radio off failed"), ["radio: Fake: the radio could not be switched."],
                    code: 1, "radio off: a failure")

        // --- mode --------------------------------------------------------------------------------
        fake = FakeModem()
        expectLines(run(["mode"], fake, "mode"), ["mode: AUTO (automatic (5G, LTE and WCDMA))"], code: 0, "mode: AUTO")
        check(fake.modesAsked.isEmpty, "mode: showing changes nothing")
        fake = FakeModem()
        var nr5gLte = saInfo
        nr5gLte.mode = "NR5G:LTE"
        fake.networkResult = .success(nr5gLte)
        expectLines(run(["mode"], fake, "mode NR5G:LTE"), ["mode: NR5G:LTE (5G and LTE)"], code: 0,
                    "mode: the modem's own order")
        fake = FakeModem()
        var noMode = saInfo
        noMode.mode = nil
        fake.networkResult = .success(noMode)
        let modeUnread = run(["mode"], fake, "mode unread")
        check(modeUnread.code == 1 && modeUnread.lines.count == 1 && modeUnread.lines[0].hasPrefix("mode: "),
              "mode: a mode not read is one failure line, exit 1", linesText(modeUnread.lines))
        fake = FakeModem()
        fake.networkResult = .failure(ModemFailure(message: "Fake: timeout."))
        expectLines(run(["mode"], fake, "mode failed"), ["mode: Fake: timeout."], code: 1, "mode: a failure")

        fake = FakeModem()
        expectLines(run(["mode", "lte:nr5g"], fake, "mode lte:nr5g"),
                    ["mode: " + modeSentence(ModeChange(before: "AUTO", after: "LTE:NR5G")),
                     "mode: to put it back: RMNet mode auto"], code: 0, "mode lte:nr5g")
        check(fake.modesAsked == ["LTE:NR5G"], "mode lte:nr5g: setMode(LTE:NR5G)", "\(fake.modesAsked)")
        check(fake.events.filter { $0 != "output" } == ["setMode"], "mode lte:nr5g: one call", "\(fake.events)")
        fake = FakeModem()
        fake.modeResult = .success(ModeChange(before: "NR5G:LTE", after: "LTE"))
        expectLines(run(["mode", "lte"], fake, "mode lte from NR5G:LTE"),
                    ["mode: " + modeSentence(ModeChange(before: "NR5G:LTE", after: "LTE")),
                     "mode: to put it back: RMNet mode nr5g:lte"], code: 0, "mode: the put-back keeps the modem's order (R8)")
        fake = FakeModem()
        expectLines(run(["mode", "nr5g:lte"], fake, "mode nr5g:lte"),
                    ["mode: " + modeSentence(ModeChange(before: "AUTO", after: "NR5G:LTE")),
                     "mode: to put it back: RMNet mode auto"], code: 0, "mode nr5g:lte")
        check(fake.modesAsked == ["NR5G:LTE"], "mode nr5g:lte: sent in the order typed (R8)", "\(fake.modesAsked)")
        fake = FakeModem()
        fake.modeResult = .success(ModeChange(before: "GSM:LTE", after: "LTE"))
        expectLines(run(["mode", "lte"], fake, "mode lte from GSM:LTE"),
                    ["mode: " + modeSentence(ModeChange(before: "GSM:LTE", after: "LTE")),
                     "mode: the earlier value GSM:LTE cannot be set by RMNet; set it again on the modem's console."],
                    code: 0, "mode: an earlier value RMNet cannot set (R8)")
        fake = FakeModem()
        fake.modeResult = .failure(ModemFailure(message: "Fake: refused. It was AUTO."))
        expectLines(run(["mode", "nr5g"], fake, "mode nr5g failed"), ["mode: Fake: refused. It was AUTO."], code: 1,
                    "mode nr5g: a failure")

        // --- apn / apn show ----------------------------------------------------------------------
        let shown = [
            "profile 1: IPV4V6, APN \"\" (the network chooses), no authentication (the driver's)",
            "profile 2: IPV4V6, APN \"ims\"; other settings not read",
            "profile 3: IPV4V6, APN \"CMNET\", no authentication",
            "profile 4: IPV4V6, APN \"CMWAP\", no authentication",
            "profile 5: IPV4V6, APN \"SOS\", no authentication",
        ]
        for words in [["apn"], ["apn", "show"]] {
            fake = FakeModem()
            expectLines(run(words, fake, "\(words)"), ["apn: the driver dials profile 1"] + shown, code: 0, "\(words)")
            check(fake.events.filter { $0 != "output" } == ["profiles"], "\(words): one read", "\(fake.events)")
            check(fake.profilesSet.isEmpty, "\(words): changes nothing")
        }
        fake = FakeModem()
        let notAttached = run(["apn"], fake, driverProfile: nil, "apn, driver not attached")
        expectLines(notAttached, ["apn: the driver is not attached; it dials profile 1 unless set otherwise"] + shown, code: 0,
                    "apn: the driver not attached")
        fake = FakeModem()
        expectLines(run(["apn"], fake, driverProfile: 3, "apn, driver on 3"), [
            "apn: the driver dials profile 3",
            "profile 1: IPV4V6, APN \"\" (the network chooses), no authentication",
            "profile 2: IPV4V6, APN \"ims\"; other settings not read",
            "profile 3: IPV4V6, APN \"CMNET\", no authentication (the driver's)",
            "profile 4: IPV4V6, APN \"CMWAP\", no authentication",
            "profile 5: IPV4V6, APN \"SOS\", no authentication",
        ], code: 0, "apn: the driver dials profile 3")
        fake = FakeModem()
        fake.profilesResult = .success([DataProfile(id: 17, pdpType: "IPV4", apn: "", settings: nil),
                                        DataProfile(id: 1, pdpType: "IPV4V6", apn: "x",
                                                    settings: ProfileSettings(type: .ipv4v6, apn: "x", user: "u",
                                                                              password: secret, auth: .pap))])
        let withPassword = run(["apn"], fake, "apn with a password")
        expectLines(withPassword, [
            "apn: the driver dials profile 1",
            "profile 17: IPV4, APN \"\" (the network chooses); other settings not read",
            "profile 1: IPV4V6, APN \"x\", PAP, user \"u\", password set (the driver's)",
        ], code: 0, "apn: a password shows as set, a profile above 16 unread")
        expectNoSecret(withPassword, secret, "apn shows no password")
        fake.events = []
        let jsonWithPassword = run(["apn", "show", "--json"], fake, "apn show --json with a password")
        expectNoSecret(jsonWithPassword, secret, "apn show --json shows no password")
        check(jsonWithPassword.lines.count == 1 && jsonWithPassword.lines[0].contains("\"passwordSet\" : true"),
              "apn show --json: passwordSet true", linesText(jsonWithPassword.lines))

        for words in [["apn", "--json"], ["apn", "show", "--json"]] {
            fake = FakeModem()
            let got = run(words, fake, "\(words)")
            expectLines(got, [prettyJSON(apnJSON(fixtureProfiles, driverProfile: 1))], code: 0,
                        "\(words): profilesJSON and driverAttached, pretty, sorted keys")
            check(driverAttached(got) == true, "\(words): driverAttached true", linesText(got.lines))
        }
        fake = FakeModem()
        expectLines(run(["apn", "--json"], fake, driverProfile: 3, "apn --json, driver on 3"),
                    [prettyJSON(apnJSON(fixtureProfiles, driverProfile: 3))], code: 0, "apn --json: the driver's profile 3")
        fake = FakeModem()
        let jsonNotAttached = run(["apn", "--json"], fake, driverProfile: nil, "apn --json, driver not attached")
        expectLines(jsonNotAttached, [prettyJSON(apnJSON(fixtureProfiles, driverProfile: nil))], code: 0,
                    "apn --json: not attached, profile 1")
        check(driverAttached(jsonNotAttached) == false, "apn --json: driverAttached false without the driver",
              linesText(jsonNotAttached.lines))
        check(jsonNotAttached.lines.first?.contains("\"driverProfile\" : 1") == true,
              "apn --json: driverProfile 1 without the driver", linesText(jsonNotAttached.lines))
        fake = FakeModem()
        fake.profilesResult = .failure(ModemFailure(message: "Fake: the profiles could not be read."))
        expectLines(run(["apn"], fake, "apn failed"), ["apn: Fake: the profiles could not be read."], code: 1, "apn: a failure")

        // --- apn set -----------------------------------------------------------------------------
        fake = FakeModem()
        let cmnet = run(["apn", "set", "--apn", "cmnet"], fake, "apn set --apn cmnet")
        let cmnetSettings = ProfileSettings(type: .ipv4v6, apn: "cmnet", user: "", password: "", auth: .none)
        check(fake.profilesSet.count == 1 && fake.profilesSet[0].id == 1 && fake.profilesSet[0].settings == cmnetSettings
              && fake.profilesSet[0].redial == true,
              "apn set --apn cmnet: setProfile(1, to: profile 1 with apn cmnet, redial: true)",
              "\(fake.profilesSet.map { "(\($0.id), \($0.settings), \($0.redial))" })")
        let cmnetChange = ProfileChange(id: 1, before: profile1, after: cmnetSettings, redial: .done(radioOn))
        expectLines(cmnet, [warning, "apn: " + profileSentence(cmnetChange), restoreProfile1], code: 0, "apn set --apn cmnet")
        check(fake.events == ["profiles", "output", "setProfile", "output", "output"],
              "apn set --apn cmnet: read, warn, change, say", "\(fake.events)")
        check(cmnet.prompts.isEmpty, "apn set --apn cmnet: no password asked")

        fake = FakeModem()
        run(["apn", "set", "--apn", "cmnet", "--no-redial"], fake, "apn set --no-redial")
        check(fake.profilesSet.count == 1 && fake.profilesSet[0].redial == false, "apn set --no-redial: redial: false")

        fake = FakeModem()
        let full = run(["apn", "set", "--type", "ipv4", "--user", "me", "--auth", "chap"], fake, driverProfile: 3, "apn set 3")
        check(fake.profilesSet.count == 1 && fake.profilesSet[0].id == 3
              && fake.profilesSet[0].settings
                == ProfileSettings(type: .ipv4, apn: "CMNET", user: "me", password: "", auth: .chap),
              "apn set on profile 3: the options over its current settings",
              "\(fake.profilesSet.map { "(\($0.id), \($0.settings))" })")
        check(full.code == 0
              && full.lines.last == "apn: to put it back: RMNet apn set --apn 'CMNET' --type ipv4v6 --user '' --auth none --no-password",
              "apn set on profile 3: the put-back line", linesText(full.lines))

        // A password kept from the current settings: sent as it was, never printed; the put-back ends --password.
        fake = FakeModem()
        let keptPassword = ProfileSettings(type: .ipv4v6, apn: "old", user: "u", password: oldSecret, auth: .pap)
        fake.profilesResult = .success([DataProfile(id: 1, pdpType: "IPV4V6", apn: "old", settings: keptPassword)])
        let kept = run(["apn", "set", "--apn", "new"], fake, "apn set keeping the password")
        check(fake.profilesSet.count == 1 && fake.profilesSet[0].settings.password == oldSecret
              && fake.profilesSet[0].settings.apn == "new" && fake.profilesSet[0].settings.user == "u",
              "apn set without a password option keeps the current password")
        check(kept.code == 0
              && kept.lines.last == "apn: to put it back: RMNet apn set --apn 'old' --type ipv4v6 --user 'u' --auth pap --password",
              "apn set: the put-back of a profile with a password ends --password (R6)", linesText(kept.lines))
        expectNoSecret(kept, oldSecret, "apn set keeping the password")

        // --no-password sends an empty password (R6).
        fake = FakeModem()
        fake.profilesResult = .success([DataProfile(id: 1, pdpType: "IPV4V6", apn: "old", settings: keptPassword)])
        let cleared = run(["apn", "set", "--no-password"], fake, "apn set --no-password")
        check(fake.profilesSet.count == 1 && fake.profilesSet[0].settings.password == ""
              && fake.profilesSet[0].settings.apn == "old",
              "apn set --no-password: an empty password, the rest as it was")
        check(cleared.code == 0 && cleared.prompts.isEmpty, "apn set --no-password: no password asked")
        expectNoSecret(cleared, oldSecret, "apn set --no-password")

        // --password: read by readSecret after the warning, sent, never printed.
        fake = FakeModem()
        let typed = run(["apn", "set", "--password", "--auth", "pap"], fake, secretAnswer: secret, "apn set --password")
        check(typed.prompts == ["New password for profile 1: "], "apn set --password: the prompt (R16)", "\(typed.prompts)")
        check(fake.profilesSet.count == 1 && fake.profilesSet[0].settings.password == secret
              && fake.profilesSet[0].settings.auth == .pap,
              "apn set --password: the password read reaches setProfile")
        check(fake.events == ["profiles", "output", "readSecret", "setProfile", "output", "output"],
              "apn set --password: read, warn, ask, change, say", "\(fake.events)")
        check(typed.code == 0 && typed.lines.first == warning, "apn set --password: the warning first", linesText(typed.lines))
        expectNoSecret(typed, secret, "apn set --password")
        // An empty answer (a hang-up gives one too) is refused: --no-password clears a password (R16).
        fake = FakeModem()
        fake.profilesResult = .success([DataProfile(id: 1, pdpType: "IPV4V6", apn: "old", settings: keptPassword)])
        let typedEmpty = run(["apn", "set", "--password"], fake, secretAnswer: "", "apn set --password, empty")
        expectLines(typedEmpty, [warning, "apn: No password was entered. Nothing was changed; use --no-password to clear the password."],
                    code: 1, "apn set --password: an empty answer is refused")
        check(fake.profilesSet.isEmpty && fake.events.filter { $0 != "output" } == ["profiles", "readSecret"],
              "apn set --password: an empty answer changes nothing", "\(fake.events)")
        fake = FakeModem()
        fake.profilesResult = .success([DataProfile(id: 1, pdpType: "IPV4V6", apn: "", settings: profile1)])
        let quoteSecret = "pa\"ss-\(secret)"
        let badPassword = run(["apn", "set", "--password", "--auth", "chap"], fake, secretAnswer: quoteSecret,
                              "apn set --password with a quote")
        check(badPassword.code == 1 && fake.profilesSet.isEmpty && badPassword.lines.count == 2
              && badPassword.lines[1].hasPrefix("apn: "),
              "apn set --password: a password the rules refuse is one failure line, nothing set", linesText(badPassword.lines))
        expectNoSecret(badPassword, secret, "apn set --password refused")
        // Not read (Ctrl-C at the prompt, or no terminal): nothing is changed (R16).
        fake = FakeModem()
        let noTerminal = run(["apn", "set", "--password", "--auth", "pap"], fake, secretAnswer: nil,
                             "apn set --password, not read")
        expectLines(noTerminal, [warning, "apn: The password was not read (cancelled, or no terminal). Nothing was changed."],
                    code: 1, "apn set --password: a password not read")
        check(fake.profilesSet.isEmpty && fake.events.filter { $0 != "output" } == ["profiles", "readSecret"],
              "apn set --password: a password not read changes nothing", "\(fake.events)")
        // With no authentication a password is refused before the prompt (R15).
        fake = FakeModem()
        let noAuthPassword = run(["apn", "set", "--password"], fake, secretAnswer: secret, "apn set --password, no auth")
        expectLines(noAuthPassword, [noAuthentication], code: 1, "apn set --password on a profile with no authentication")
        check(noAuthPassword.prompts.isEmpty && fake.profilesSet.isEmpty,
              "apn set --password with no authentication: nothing asked, nothing set")
        for words in [["apn", "set", "--user", "u"], ["apn", "set", "--password", "--auth", "none"],
                      ["apn", "set", "--auth", "none"]] {
            fake = FakeModem()
            fake.profilesResult = .success([DataProfile(id: 1, pdpType: "IPV4V6", apn: "x", settings: keptPassword)])
            if words.contains("--user") { fake.profilesResult = .success(fixtureProfiles) }
            let got = run(words, fake, secretAnswer: secret, "\(words)")
            expectLines(got, [noAuthentication], code: 1, "\(words): credentials with no authentication are refused")
            check(got.prompts.isEmpty && fake.profilesSet.isEmpty, "\(words): nothing asked, nothing set")
            expectNoSecret(got, oldSecret, "\(words)")
        }
        fake = FakeModem()
        run(["apn", "set", "--user", "u", "--auth", "pap-or-chap"], fake, "apn set --user with PAP or CHAP")
        check(fake.profilesSet.count == 1 && fake.profilesSet[0].settings.user == "u"
              && fake.profilesSet[0].settings.auth == .papOrChap, "apn set: a user name with an authentication method is sent")
        fake = FakeModem()
        fake.profilesResult = .success([DataProfile(id: 1, pdpType: "IPV4V6", apn: "x", settings: keptPassword)])
        run(["apn", "set", "--no-password", "--user", "", "--auth", "none"], fake, "apn set back to no authentication")
        check(fake.profilesSet.count == 1 && fake.profilesSet[0].settings
                == ProfileSettings(type: .ipv4v6, apn: "old", user: "", password: "", auth: .none),
              "apn set: back to no authentication with the credentials cleared")
        // An old password the rules refuse does not stop a new one being typed.
        fake = FakeModem()
        let badOld = ProfileSettings(type: .ipv4v6, apn: "x", user: "", password: "a\"b", auth: .pap)
        fake.profilesResult = .success([DataProfile(id: 1, pdpType: "IPV4V6", apn: "x", settings: badOld)])
        let replaced = run(["apn", "set", "--password"], fake, secretAnswer: secret, "apn set --password over a refused one")
        check(replaced.code == 0 && fake.profilesSet.count == 1 && fake.profilesSet[0].settings.password == secret,
              "apn set --password: an old password with a quote is replaced", linesText(replaced.lines))

        // Checked before any change: the profile, then the rules.
        fake = FakeModem()
        let badApn = run(["apn", "set", "--apn", "bad apn", "--password"], fake, secretAnswer: secret, "apn set, bad APN")
        check(badApn.code == 1 && badApn.lines.count == 1 && badApn.lines[0].hasPrefix("apn: ") && badApn.lines[0] != warning,
              "apn set: an APN the rules refuse is one line, exit 1", linesText(badApn.lines))
        check(fake.profilesSet.isEmpty && badApn.prompts.isEmpty, "apn set: a refused APN asks nothing and sets nothing")
        // `--apn` takes the next word as it is; an option typed there is refused as an APN (ruling R21).
        fake = FakeModem()
        let optionAsApn = run(["apn", "set", "--apn", "--no-redial"], fake, "apn set --apn --no-redial")
        expectLines(optionAsApn, ["apn: An APN is at most 100 characters of ASCII letters, digits, dots, hyphens and underscores; "
                                  + "it does not start or end with a dot or a hyphen, has no two dots in a row, and has no hyphen "
                                  + "next to a dot."], code: 1, "apn set --apn --no-redial: refused before anything is changed")
        check(fake.profilesSet.isEmpty, "apn set --apn --no-redial: nothing set")
        fake = FakeModem()
        let unreadProfile = run(["apn", "set", "--apn", "x"], fake, driverProfile: 2, "apn set, profile 2 unread")
        expectLines(unreadProfile, ["apn: Profile 2 could not be read. Nothing was changed."], code: 1,
                    "apn set: settings not read")
        check(fake.profilesSet.isEmpty, "apn set: settings not read, nothing set")
        fake = FakeModem()
        let unlisted = run(["apn", "set", "--apn", "x"], fake, driverProfile: 7, "apn set, profile 7 unlisted")
        expectLines(unlisted, ["apn: Profile 7 could not be read. Nothing was changed."], code: 1, "apn set: profile not listed")
        // A driver's profile above 16: AT+QICSGP cannot change it; said before anything is read.
        for id in [17, 255] {
            fake = FakeModem()
            expectLines(run(["apn", "set", "--apn", "x"], fake, driverProfile: id, "apn set, profile \(id)"),
                        ["apn: Profile \(id) cannot be changed by RMNet: AT+QICSGP takes profiles 1 to 16."], code: 1,
                        "apn set: profile \(id) is refused with the 1-16 rule")
            check(fake.events.filter { $0 != "output" }.isEmpty, "apn set: profile \(id): nothing read, asked or set",
                  "\(fake.events)")
        }
        fake = FakeModem()
        run(["apn", "set", "--apn", "x"], fake, driverProfile: nil, "apn set, driver not attached")
        check(fake.profilesSet.count == 1 && fake.profilesSet[0].id == 1, "apn set: without the driver, profile 1")
        fake = FakeModem()
        fake.profilesResult = .failure(ModemFailure(message: "Fake: the profiles could not be read."))
        expectLines(run(["apn", "set", "--apn", "x"], fake, "apn set, read failed"),
                    ["apn: Fake: the profiles could not be read."], code: 1, "apn set: the read failed")
        check(fake.profilesSet.isEmpty, "apn set: the read failed, nothing set")
        fake = FakeModem()
        fake.setProfileResult = .failure(ModemFailure(message: "Fake: refused. The radio was switched back on."))
        expectLines(run(["apn", "set", "--apn", "x"], fake, "apn set, change failed"),
                    [warning, "apn: Fake: refused. The radio was switched back on."], code: 1, "apn set: the change failed")
        // A change that failed after its line may have reached the modem: the failure, then the way back
        // (ruling R19), one for each of the service's paths.
        for sentence in [
            "It is not known whether profile 1 was changed. The modem did not answer in time. The radio was switched back on.",
            "Profile 1 does not read back as sent: the modem now reports IPV4V6, APN \"y\", no authentication. "
                + "The radio was switched back on.",
            "Profile 1 could not be read back after the change. The modem did not answer in time. The radio was switched back on.",
        ] {
            fake = FakeModem()
            fake.setProfileResult = .failure(ModemFailure(message: sentence, profileBefore: profile1))
            expectLines(run(["apn", "set", "--apn", "x"], fake, "apn set, \(sentence)"), [warning, "apn: \(sentence)", restoreProfile1],
                        code: 1, "apn set: a failure that may have changed the profile says how to put it back: \(sentence)")
        }
        fake = FakeModem()
        let hadPassword = ProfileSettings(type: .ipv4v6, apn: "old", user: "u", password: oldSecret, auth: .pap)
        fake.setProfileResult = .failure(ModemFailure(message: "Fake: not known.", profileBefore: hadPassword))
        let unknownWithPassword = run(["apn", "set", "--apn", "x"], fake, "apn set, not known, a password before")
        expectLines(unknownWithPassword, [warning, "apn: Fake: not known.",
                                          "apn: to put it back: RMNet apn set --apn 'old' --type ipv4v6 --user 'u' --auth pap --password"],
                    code: 1, "apn set: the way back after a failure asks for the password again (--password)")
        expectNoSecret(unknownWithPassword, oldSecret, "apn set, a failure's way back")

        // The redial's outcomes.
        fake = FakeModem()
        fake.redialResult = .radioWasOff
        let wasOff = run(["apn", "set", "--apn", "x"], fake, "apn set, radio was off")
        check(wasOff.code == 0 && wasOff.lines.count == 3, "apn set: the radio was off", linesText(wasOff.lines))
        fake = FakeModem()
        fake.redialResult = .radioLeftOff("Fake: the modem did not answer in time.")
        let leftOff = run(["apn", "set", "--apn", "x"], fake, "apn set, radio left off")
        let leftOffChange = ProfileChange(id: 1, before: profile1, after: settings("x"),
                                          redial: .radioLeftOff("Fake: the modem did not answer in time."))
        expectLines(leftOff, [warning, "apn: " + profileSentence(leftOffChange), restoreProfile1], code: 1,
                    "apn set: the radio left off is exit 1, with the put-back")

        // --- sim ---------------------------------------------------------------------------------
        fake = FakeModem()
        expectLines(run(["sim"], fake, "sim"), ["sim: ready", "sim: pin lock: off", "sim: attempts left: PIN 3, PUK 10"],
                    code: 0, "sim: the READY fixture")
        fake = FakeModem()
        expectLines(run(["sim", "--json"], fake, "sim --json"), [prettyJSON(simJSON(readySim))], code: 0,
                    "sim --json: simJSON, pretty, sorted keys")
        fake = FakeModem()
        fake.simResult = .failure(ModemFailure(message: "Fake: the SIM's state could not be read."))
        expectLines(run(["sim"], fake, "sim failed"), ["sim: Fake: the SIM's state could not be read."], code: 1,
                    "sim: a failure")

        // --- sim unlock --------------------------------------------------------------------------
        let askingSim = SimInfo(state: .pin, pinLock: true, pinAttempts: 3, pukAttempts: 10)
        fake = FakeModem()
        let notAsked = run(["sim", "unlock"], fake, secretAnswer: pinSecret, "sim unlock, READY")
        expectLines(notAsked, ["sim: The SIM does not ask for a PIN (ready)."], code: 1, "sim unlock: READY")
        check(notAsked.prompts.isEmpty && fake.pinsEntered.isEmpty, "sim unlock: READY never reads a PIN or sends one")
        fake = FakeModem()
        fake.simResult = .success(SimInfo(state: .notInserted, pinLock: nil, pinAttempts: nil, pukAttempts: nil))
        expectLines(run(["sim", "unlock"], fake, secretAnswer: pinSecret, "sim unlock, no SIM"),
                    ["sim: The SIM does not ask for a PIN (not inserted)."], code: 1, "sim unlock: no SIM")
        check(fake.pinsEntered.isEmpty, "sim unlock: no SIM, nothing sent")
        fake = FakeModem()
        fake.simResult = .success(SimInfo(state: .puk, pinLock: true, pinAttempts: 0, pukAttempts: 10))
        let blocked = run(["sim", "unlock", "--last-attempt"], fake, secretAnswer: pinSecret, "sim unlock, PUK")
        check(blocked.code == 1 && blocked.lines.count == 1 && blocked.lines[0].hasPrefix("sim: ")
              && blocked.lines[0].contains("PUK") && blocked.lines[0].contains("RMNet does not enter PUKs"),
              "sim unlock: blocked, one line naming the PUK", linesText(blocked.lines))
        check(blocked.prompts.isEmpty && fake.pinsEntered.isEmpty, "sim unlock: blocked never reads a PIN or sends one")
        fake = FakeModem()
        fake.simResult = .success(SimInfo(state: .pin, pinLock: true, pinAttempts: nil, pukAttempts: nil))
        let unknown = run(["sim", "unlock", "--last-attempt"], fake, secretAnswer: pinSecret, "sim unlock, attempts unread")
        expectLines(unknown, ["sim: The attempts left could not be read; RMNet does not send a PIN without them."], code: 1,
                    "sim unlock: attempts not read")
        check(unknown.prompts.isEmpty && fake.pinsEntered.isEmpty, "sim unlock: attempts not read, nothing asked or sent")
        fake = FakeModem()
        fake.simResult = .success(SimInfo(state: .pin, pinLock: true, pinAttempts: 0, pukAttempts: 10))
        let none = run(["sim", "unlock", "--last-attempt"], fake, secretAnswer: pinSecret, "sim unlock, 0 attempts")
        check(none.code == 1 && none.lines.count == 1 && none.lines[0].hasPrefix("sim: ") && none.prompts.isEmpty
              && fake.pinsEntered.isEmpty, "sim unlock: 0 attempts, nothing asked or sent", linesText(none.lines))

        let lastAttempt = SimInfo(state: .pin, pinLock: true, pinAttempts: 1, pukAttempts: 10)
        fake = FakeModem()
        fake.simResult = .success(lastAttempt)
        let refusedLast = run(["sim", "unlock"], fake, secretAnswer: pinSecret, "sim unlock, 1 attempt")
        expectLines(refusedLast, [
            "sim: The SIM asks for its PIN. 1 attempt(s) left; a wrong PIN uses one.",
            "sim: This is the last attempt: a wrong PIN blocks the SIM until its PUK is entered. "
                + "Run again with --last-attempt to send it.",
        ], code: 1, "sim unlock: the last attempt without --last-attempt")
        check(refusedLast.prompts.isEmpty && fake.pinsEntered.isEmpty
              && fake.events.filter { $0 != "output" } == ["sim"],
              "sim unlock: the last attempt without --last-attempt never reads a PIN or calls enterPin", "\(fake.events)")

        fake = FakeModem()
        fake.simResult = .success(lastAttempt)
        let sentLast = run(["sim", "unlock", "--last-attempt"], fake, secretAnswer: pinSecret, "sim unlock --last-attempt")
        expectLines(sentLast, [
            "sim: The SIM asks for its PIN. 1 attempt(s) left; a wrong PIN uses one.",
            "sim: The SIM accepted the PIN and is ready.",
        ], code: 0, "sim unlock --last-attempt: accepted")
        check(sentLast.prompts == ["PIN: "], "sim unlock: the prompt", "\(sentLast.prompts)")
        check(fake.pinsEntered.count == 1 && fake.pinsEntered[0].pin == pinSecret && fake.pinsEntered[0].shownAttempts == 1,
              "sim unlock --last-attempt: enterPin(pin, shownAttempts: 1)")
        check(fake.events == ["sim", "output", "readSecret", "enterPin", "output"],
              "sim unlock: read, show the attempts, ask, send, say", "\(fake.events)")
        expectNoSecret(sentLast, pinSecret, "sim unlock --last-attempt")

        fake = FakeModem()
        fake.simResult = .success(askingSim)
        let refusedOutcome = PinOutcome(accepted: false,
                                        sim: SimInfo(state: .pin, pinLock: true, pinAttempts: 2, pukAttempts: 10),
                                        refusal: "+CME ERROR: 16")
        fake.pinResult = .success(refusedOutcome)
        let refused = run(["sim", "unlock"], fake, secretAnswer: pinSecret, "sim unlock, refused")
        expectLines(refused, ["sim: The SIM asks for its PIN. 3 attempt(s) left; a wrong PIN uses one.",
                              "sim: " + pinSentence(refusedOutcome)], code: 1, "sim unlock: refused is exit 1")
        check(fake.pinsEntered.count == 1 && fake.pinsEntered[0].shownAttempts == 3, "sim unlock: shownAttempts 3")
        expectNoSecret(refused, pinSecret, "sim unlock refused")

        check(refused.lines.last == "sim: The SIM refused the PIN. 2 attempts left.", "sim unlock: +CME ERROR: 16 is a wrong PIN",
              linesText(refused.lines))
        fake = FakeModem()
        fake.simResult = .success(askingSim)
        fake.pinResult = .success(PinOutcome(accepted: false, sim: askingSim, refusal: "+CME ERROR: 14"))
        let simBusy = run(["sim", "unlock"], fake, secretAnswer: pinSecret, "sim unlock, SIM busy")
        expectLines(simBusy, ["sim: The SIM asks for its PIN. 3 attempt(s) left; a wrong PIN uses one.",
                              "sim: The modem did not take the PIN (+CME ERROR: 14). 3 attempts left; check them before "
                                + "entering it again."], code: 1, "sim unlock: SIM busy is not said as a wrong PIN (F10)")
        expectNoSecret(simBusy, pinSecret, "sim unlock, SIM busy")

        fake = FakeModem()
        fake.simResult = .success(askingSim)
        fake.pinResult = .failure(ModemFailure(message: "Fake: the attempts left changed. Nothing was sent."))
        let changed = run(["sim", "unlock"], fake, secretAnswer: pinSecret, "sim unlock, service refused")
        check(changed.code == 1 && changed.lines.last == "sim: Fake: the attempts left changed. Nothing was sent.",
              "sim unlock: the service's failure", linesText(changed.lines))
        expectNoSecret(changed, pinSecret, "sim unlock failed")

        fake = FakeModem()
        fake.simResult = .success(askingSim)
        let wrongPin = run(["sim", "unlock"], fake, secretAnswer: "12ab", "sim unlock, a PIN with letters")
        check(wrongPin.code == 1 && wrongPin.lines.count == 2 && wrongPin.lines[1].hasPrefix("sim: ") && fake.pinsEntered.isEmpty,
              "sim unlock: a PIN the rules refuse is one failure line, nothing sent", linesText(wrongPin.lines))
        expectNoSecret(wrongPin, "12ab", "sim unlock, a PIN refused")
        fake = FakeModem()
        fake.simResult = .success(askingSim)
        let noTty = run(["sim", "unlock"], fake, secretAnswer: nil, "sim unlock, not read")
        expectLines(noTty, ["sim: The SIM asks for its PIN. 3 attempt(s) left; a wrong PIN uses one.",
                            "sim: The PIN was not read (cancelled, or no terminal). Nothing was sent."],
                    code: 1, "sim unlock: a PIN not read (R16)")
        check(fake.pinsEntered.isEmpty, "sim unlock: a PIN not read, nothing sent")
        fake = FakeModem()
        fake.simResult = .success(askingSim)
        let emptyPin = run(["sim", "unlock"], fake, secretAnswer: "", "sim unlock, empty")
        check(emptyPin.code == 1 && emptyPin.lines.count == 2 && emptyPin.lines[1].hasPrefix("sim: ") && fake.pinsEntered.isEmpty,
              "sim unlock: an empty answer (a hang-up) sends nothing", linesText(emptyPin.lines))
        fake = FakeModem()
        fake.simResult = .failure(ModemFailure(message: "Fake: no modem."))
        expectLines(run(["sim", "unlock"], fake, secretAnswer: pinSecret, "sim unlock, read failed"), ["sim: Fake: no modem."],
                    code: 1, "sim unlock: the read failed")
        check(fake.pinsEntered.isEmpty, "sim unlock: the read failed, nothing sent")

        print("modem cli: \(checks) checks passed")
    }
}
