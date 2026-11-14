// Tests for app/ModemService.swift: the AT sequences of the modem service (the network read, the radio, the
// network mode, the data profiles with the redial, the SIM and PIN entry), run against a scripted port that
// answers from a queue and records every line sent, an opener that counts the ports it hands out, and a
// fake clock that `sleep` moves on. The fixtures are the modem's real answers (2026-11-15, firmware
// RM520NGLAAR03A04M4G_01.204.01.204). Built with swiftc by `make app-test` together with app/AtPort.swift,
// app/SmsModel.swift, app/SmsService.swift (for `describe`), app/ModemNetwork.swift and
// app/ModemSettings.swift; opens no port and needs no hardware.
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

func expectEqual(_ got: String, _ want: String, _ name: String) {
    check(got == want, name, "want \"\(want)\"\n  got  \"\(got)\"")
}

// MARK: - The scripted port

typealias Answer = Result<[String], AtError>

let ok: Answer = .success([])
let timedOut: Answer = .failure(.timeout)
let ioError: Answer = .failure(.io(Int32(bitPattern: 0xE000_02ED)))    // kIOReturnNotResponding
let notOpen = AtError.io(Int32(bitPattern: 0xE000_02CD))               // kIOReturnNotOpen

func cme(_ n: Int) -> Answer { .failure(.modem("+CME ERROR: \(n)")) }

/// Answers each line from its script, in order, and records every line sent with its timeout. Like AtPort
/// after a timeout, it closes itself after a timeout or an I/O error: a line sent after that is refused
/// with `.io(kIOReturnNotOpen)` and noted as a problem, as is a line other than the one expected, or a
/// line when nothing more is expected.
final class ScriptedPort: AtCommanding {
    let name: String
    private var script: [(line: String, answer: Answer)]
    private(set) var sent: [(line: String, timeout: TimeInterval)] = []
    private(set) var problems: [String] = []
    private(set) var closed = false
    private(set) var closedItself = false
    var onCommand: (() -> Void)?      // the rig's clock: the time a command takes

    init(_ name: String, _ script: [(String, Answer)]) {
        self.name = name
        self.script = script.map { (line: $0.0, answer: $0.1) }
    }

    var lines: [String] { sent.map { $0.line } }
    var leftover: [String] { script.map { $0.line } }

    func timeout(of line: String) -> TimeInterval? { sent.first(where: { $0.line == line })?.timeout }

    func command(_ line: String, timeout: TimeInterval) -> Answer {
        sent.append((line: line, timeout: timeout))
        onCommand?()
        if closed || closedItself {
            problems.append("\(line) sent after the port closed")
            return .failure(notOpen)
        }
        guard !script.isEmpty else {
            problems.append("\(line) sent; nothing more was expected")
            closedItself = true
            return timedOut
        }
        let next = script.removeFirst()
        if next.line != line { problems.append("sent \(line), expected \(next.line)") }
        if case .failure(let error) = next.answer, error == .timeout || error == .io(Int32(bitPattern: 0xE000_02ED)) {
            closedItself = true
        }
        return next.answer
    }

    func close() { closed = true }
}

/// A service with scripted ports for its opens (in order), a fake clock and the sleeps it asked for.
final class Rig {
    private var opens: [Result<ScriptedPort, AtError>]
    private(set) var opened: [ScriptedPort] = []
    private(set) var openCount = 0
    private(set) var extraOpens = 0
    private(set) var opensWhileOpen = 0     // ports asked for while an earlier one was not closed
    var clock = Date(timeIntervalSinceReferenceDate: 1000)
    let start: Date
    private(set) var sleeps: [TimeInterval] = []
    var commandSeconds: TimeInterval = 0     // fake time each command takes
    var sleepMovesClock = true               // false: a clock that stands still (or was set back)

    init(_ opens: [Result<ScriptedPort, AtError>]) {
        self.opens = opens
        start = clock
    }

    convenience init(_ scripts: [(String, Answer)]...) {
        self.init(scripts.enumerated().map { .success(ScriptedPort("port \($0.offset + 1)", $0.element)) })
    }

    lazy var service = ModemService(open: { [unowned self] in self.open() },
                                    sleep: { [unowned self] in
                                        self.sleeps.append($0)
                                        if self.sleepMovesClock { self.clock += $0 }
                                    },
                                    now: { [unowned self] in self.clock })

    var elapsed: TimeInterval { clock.timeIntervalSince(start) }

    private func open() -> Result<AtCommanding, AtError> {
        openCount += 1
        // AtPort keeps the interface after an I/O error: a second open while it is held would be busy.
        if opened.contains(where: { !$0.closed }) { opensWhileOpen += 1 }
        guard !opens.isEmpty else {
            extraOpens += 1
            return .failure(.modemNotAttached)
        }
        switch opens.removeFirst() {
        case .success(let port):
            opened.append(port)
            port.onCommand = { [unowned self] in self.clock += self.commandSeconds }
            return .success(port)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// The port opened n-th (from 1), or an empty one when it was not opened (the checks then fail).
    func port(_ n: Int) -> ScriptedPort {
        n >= 1 && n <= opened.count ? opened[n - 1] : ScriptedPort("port \(n) (not opened)", [])
    }

    /// Every line sent, over all ports.
    var allLines: [String] { opened.flatMap { $0.lines } }

    /// `opens` ports were asked for, each one opened was closed, every script was used up, and nothing was
    /// sent out of order or on a closed port.
    func finish(_ name: String, opens want: Int) {
        check(openCount == want && extraOpens == 0, "\(name): \(want) port(s) asked for", "asked for \(openCount)")
        check(opens.isEmpty, "\(name): every scripted open happened", "\(opens.count) left")
        check(opensWhileOpen == 0, "\(name): each port was closed before the next was opened")
        for p in opened {
            check(p.closed, "\(name): \(p.name) was closed")
            check(p.problems.isEmpty, "\(name): \(p.name) got its lines in order", p.problems.joined(separator: "; "))
            check(p.leftover.isEmpty, "\(name): \(p.name) was sent every line scripted", "not sent: \(p.leftover)")
        }
    }
}

func linesText(_ lines: [String]) -> String {
    lines.joined(separator: " | ")
}

func expectLines(_ got: [String], _ want: [String], _ name: String) {
    check(got == want, name, "want \(linesText(want))\n  got  \(linesText(got))")
}

func success<T>(_ result: Result<T, ModemFailure>, _ name: String) -> T? {
    switch result {
    case .success(let value):
        return value
    case .failure(let failure):
        check(false, "\(name): succeeds", failure.message)
        return nil
    }
}

func failureMessage<T>(_ result: Result<T, ModemFailure>, _ name: String) -> String {
    switch result {
    case .success(let value):
        check(false, "\(name): fails", "succeeded with \(value)")
        return ""
    case .failure(let failure):
        return failure.message
    }
}

// MARK: - The modem's answers

let cfunOn: Answer = .success(["+CFUN: 1"])
let cfunOff: Answer = .success(["+CFUN: 4"])
let qspn = "+QSPN: \"4E2D56FD79FB52A8\",\"4E2D56FD79FB52A8\",\"0043004D00430043\",1,\"46000\""
let sa = "+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",460,00,123456789,32,1A2B3C,504990,41,12,-95,-10,8,1,-"
let qcainfo = ["+QCAINFO: \"PCC\",504990,12,\"NR5G BAND 41\",32",
               "+QCAINFO: \"SCC\",155770,3,\"NR5G BAND 28\",1,6,0,-,-"]

let networkLines = ["AT+CFUN?", "AT+COPS?", "AT+QSPN", "AT+C5GREG?", "AT+CEREG?", "AT+CGREG?", "AT+CREG?",
                    "AT+QENG=\"servingcell\"", "AT+QCAINFO", "AT+QNWPREFCFG=\"mode_pref\"",
                    "AT+QNWPREFCFG=\"nr5g_disable_mode\""]

func networkScript(qcainfo qca: Answer = .success(qcainfo)) -> [(String, Answer)] {
    [("AT+CFUN?", cfunOn),
     ("AT+COPS?", .success(["+COPS: 0,0,\"CHINA MOBILE\",11"])),
     ("AT+QSPN", .success([qspn])),
     ("AT+C5GREG?", .success(["+C5GREG: 0,1"])),
     ("AT+CEREG?", .success(["+CEREG: 0,0"])),
     ("AT+CGREG?", .success(["+CGREG: 0,0"])),
     ("AT+CREG?", .success(["+CREG: 0,0"])),
     ("AT+QENG=\"servingcell\"", .success([sa])),
     ("AT+QCAINFO", qca),
     ("AT+QNWPREFCFG=\"mode_pref\"", .success(["+QNWPREFCFG: \"mode_pref\",AUTO"])),
     ("AT+QNWPREFCFG=\"nr5g_disable_mode\"", .success(["+QNWPREFCFG: \"nr5g_disable_mode\",0"]))]
}

let saLeg = CellLeg(rat: "NR5G-SA", duplex: "TDD", mcc: "460", mnc: "00", cellID: "123456789", pci: 32,
                    tac: "1A2B3C", channel: 504990, band: "n41", bandwidthMHz: 100, rsrp: -95, rsrq: -10, sinr: 8)
let homeSA = Registration(status: .home, domain: "5GS")
let searchingSA = Registration(status: .searching, domain: "5GS")

let saInfo: NetworkInfo = {
    var info = NetworkInfo()
    info.radio = .on
    info.registration = homeSA
    info.operatorName = "CHINA MOBILE"
    info.networkName = "\u{4E2D}\u{56FD}\u{79FB}\u{52A8}"
    info.plmn = "46000"
    info.accessTechnology = 11
    info.serving = ServingCell(state: "NOCONN", cells: [saLeg])
    info.carriers = ["n41", "n28"]
    info.mode = "AUTO"
    info.nr5gDisable = 0
    return info
}()

/// The four registration reads, 5GS with `fiveG`, the others not registered.
func registrationReads(_ fiveG: Int) -> [(String, Answer)] {
    [("AT+C5GREG?", .success(["+C5GREG: 0,\(fiveG)"])), ("AT+CEREG?", .success(["+CEREG: 0,0"])),
     ("AT+CGREG?", .success(["+CGREG: 0,0"])), ("AT+CREG?", .success(["+CREG: 0,0"]))]
}

let registered = registrationReads(1)
let searching = registrationReads(2)
let registrationLines = ["AT+C5GREG?", "AT+CEREG?", "AT+CGREG?", "AT+CREG?"]

let cgdcont = [
    "+CGDCONT: 1,\"IPV4V6\",\"\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 2,\"IPV4V6\",\"ims\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 3,\"IPV4V6\",\"CMNET\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 4,\"IPV4V6\",\"CMWAP\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,0,,,,,,,,,,\"\",,,,0",
    "+CGDCONT: 5,\"IPV4V6\",\"SOS\",\"0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0\",0,0,0,1,,,,,,,,,,\"\",,,,0",
]
let profile1 = ProfileSettings(type: .ipv4v6, apn: "", user: "", password: "", auth: .none)
let profile3 = ProfileSettings(type: .ipv4v6, apn: "CMNET", user: "", password: "", auth: .none)
let cmnet = ProfileSettings(type: .ipv4v6, apn: "cmnet", user: "", password: "", auth: .none)
let qicsgp1: Answer = .success(["+QICSGP: 3,\"\",\"\",\"\",0"])
let qicsgpCmnet: Answer = .success(["+QICSGP: 3,\"cmnet\",\"\",\"\",0"])
let setCmnet = "AT+QICSGP=1,3,\"cmnet\",\"\",\"\",0"

// A password that no failure sentence and no line other than the change may hold.
let secret = "hunter2-secret"
let withSecret = ProfileSettings(type: .ipv4v6, apn: "cmnet", user: "u", password: secret, auth: .pap)
let setWithSecret = "AT+QICSGP=1,3,\"cmnet\",\"u\",\"hunter2-secret\",1"
let qicsgpWithSecret: Answer = .success(["+QICSGP: 3,\"cmnet\",\"u\",\"hunter2-secret\",1"])

let cpinReady: Answer = .success(["+CPIN: READY"])
let cpinPin: Answer = .success(["+CPIN: SIM PIN"])
func qpinc(_ pin: Int, _ puk: Int = 10) -> Answer { .success(["+QPINC: \"SC\",\(pin),\(puk)", "+QPINC: \"P2\",3,10"]) }
let clckOff: Answer = .success(["+CLCK: 0"])
let clckOn: Answer = .success(["+CLCK: 1"])
let simLines = ["AT+CPIN?", "AT+QPINC?", "AT+CLCK=\"SC\",2"]

// A PIN that no failure sentence and no line other than AT+CPIN="…" may hold.
let pin = "73519"
let pinLine = "AT+CPIN=\"73519\""

/// The redial's lines before the change: the settings now, the radio's state, the radio off.
let redialStart: [(String, Answer)] = [("AT+QICSGP=1", qicsgp1), ("AT+CFUN?", cfunOn), ("AT+CFUN=4", ok)]

@main
struct ModemServiceTests {
    static func main() {
        conformance()
        networkInfo()
        radio()
        mode()
        profiles()
        profileChange()
        profileRedialFailures()
        sim()
        pinEntry()
        print("modem service: \(checks) checks passed")
    }

    // AtPort is a port the service can use, and the default service and readSecret have the planned shapes.
    // Nothing here opens a port: the service opens one only when a method is called.
    static func conformance() {
        let asPort: (AtPort) -> AtCommanding = { $0 }
        _ = asPort
        let service: ModemServing = ModemService()
        _ = service
        let reader: (String) -> String? = readSecret(prompt:)
        _ = reader
        check(true, "conformance: AtPort is AtCommanding; ModemService() and readSecret(prompt:) compile")
    }

    // MARK: networkInfo

    static func networkInfo() {
        do {
            let rig = Rig(networkScript())
            let info = success(rig.service.networkInfo(), "networkInfo")
            check(info == saInfo, "networkInfo: the fixtures give the SA NetworkInfo", "\(String(describing: info))")
            expectLines(rig.port(1).lines, networkLines, "networkInfo: the eleven reads in order")
            check(rig.port(1).sent.allSatisfy { $0.timeout == 3 }, "networkInfo: each read has 3 s",
                  "\(rig.port(1).sent.map { $0.timeout })")
            check(rig.sleeps.isEmpty, "networkInfo: no sleep")
            rig.finish("networkInfo", opens: 1)
        }
        do {
            let rig = Rig(networkScript(qcainfo: cme(3)))
            let info = success(rig.service.networkInfo(), "networkInfo, QCAINFO refused")
            var want = saInfo
            want.carriers = []
            check(info == want, "networkInfo: +CME ERROR: 3 for AT+QCAINFO leaves carriers [] and reads on",
                  "\(String(describing: info))")
            expectLines(rig.port(1).lines, networkLines, "networkInfo, QCAINFO refused: all eleven reads")
            rig.finish("networkInfo, QCAINFO refused", opens: 1)
        }
        do {
            // Every read refused: an empty NetworkInfo, not a failure.
            let rig = Rig(networkLines.map { ($0, cme(3)) })
            let info = success(rig.service.networkInfo(), "networkInfo, all refused")
            check(info == NetworkInfo(), "networkInfo: every read refused gives an empty NetworkInfo", "\(String(describing: info))")
            rig.finish("networkInfo, all refused", opens: 1)
        }
        do {
            // AT+QSPN answering a bare OK (not registered): no network name and no PLMN; nothing invented.
            var script = networkScript()
            script[2] = ("AT+QSPN", ok)
            let rig = Rig(script)
            let info = success(rig.service.networkInfo(), "networkInfo, bare QSPN")
            check(info?.networkName == nil && info?.plmn == nil, "networkInfo: a bare OK to AT+QSPN gives no name and no plmn (R1)",
                  "\(String(describing: info))")
            rig.finish("networkInfo, bare QSPN", opens: 1)
        }
        for (answer, word) in [(timedOut, "a timeout"), (ioError, "an I/O error")] {
            var script = Array(networkScript().prefix(2))
            script[1] = ("AT+COPS?", answer)
            let rig = Rig(script)
            let message = failureMessage(rig.service.networkInfo(), "networkInfo, \(word) on COPS")
            guard case .failure(let error) = answer else { continue }
            expectEqual(message, describe(error), "networkInfo: \(word) on AT+COPS? fails with describe(error)")
            expectLines(rig.port(1).lines, ["AT+CFUN?", "AT+COPS?"], "networkInfo: nothing is sent after \(word)")
            rig.finish("networkInfo, \(word) on COPS", opens: 1)
        }
        do {
            let rig = Rig([.failure(.modemNotAttached)])
            let message = failureMessage(rig.service.networkInfo(), "networkInfo, no modem")
            expectEqual(message, describe(.modemNotAttached), "networkInfo: a failed open fails with describe(error)")
            rig.finish("networkInfo, no modem", opens: 1)
        }
    }

    // MARK: setRadio

    static func radio() {
        do {
            let rig = Rig([("AT+CFUN=1", ok)] + searching + searching + registered)
            let change = success(rig.service.setRadio(on: true), "radio on")
            check(change == RadioChange(on: true, registration: homeSA, secondsToRegister: 2),
                  "setRadio(on: true): registered on the third read gives secondsToRegister 2", "\(String(describing: change))")
            expectLines(rig.port(1).lines, ["AT+CFUN=1"] + registrationLines + registrationLines + registrationLines,
                        "setRadio(on: true): AT+CFUN=1, then the four registration reads until registered")
            check(rig.port(1).timeout(of: "AT+CFUN=1") == 20, "setRadio: AT+CFUN=1 has 20 s")
            check(rig.port(1).sent.dropFirst().allSatisfy { $0.timeout == 3 }, "setRadio: the registration reads have 3 s")
            check(rig.sleeps == [1, 1], "setRadio(on: true): one second between reads", "\(rig.sleeps)")
            rig.finish("radio on", opens: 1)
        }
        do {
            // Registered at once: 0 s.
            let rig = Rig([("AT+CFUN=1", ok)] + registered)
            let change = success(rig.service.setRadio(on: true), "radio on, registered at once")
            check(change == RadioChange(on: true, registration: homeSA, secondsToRegister: 0),
                  "setRadio(on: true): registered on the first read gives 0 s", "\(String(describing: change))")
            check(rig.sleeps.isEmpty, "setRadio(on: true): no sleep when registered at once", "\(rig.sleeps)")
            rig.finish("radio on, registered at once", opens: 1)
        }
        do {
            // Roaming counts as registered.
            let rig = Rig([("AT+CFUN=1", ok)] + searching + registrationReads(5))
            let change = success(rig.service.setRadio(on: true), "radio on, roaming")
            check(change == RadioChange(on: true, registration: Registration(status: .roaming, domain: "5GS"), secondsToRegister: 1),
                  "setRadio(on: true): roaming is registered", "\(String(describing: change))")
            rig.finish("radio on, roaming", opens: 1)
        }
        do {
            // Never registered: reads at 0, 1, …, 30 s of fake time, then stops.
            let reads = Array(repeating: searching, count: 31).flatMap { $0 }
            let rig = Rig([("AT+CFUN=1", ok)] + reads)
            let change = success(rig.service.setRadio(on: true), "radio on, never registered")
            check(change == RadioChange(on: true, registration: searchingSA, secondsToRegister: nil),
                  "setRadio(on: true): never registered gives the last registration and no seconds", "\(String(describing: change))")
            check(rig.elapsed == 30, "setRadio(on: true): stops after 30 s of fake time", "\(rig.elapsed)")
            check(rig.sleeps.count == 30 && rig.sleeps.allSatisfy { $0 == 1 }, "setRadio(on: true): 30 sleeps of 1 s",
                  "\(rig.sleeps)")
            check(rig.port(1).lines.count == 1 + 31 * 4, "setRadio(on: true): 31 reads of four lines",
                  "\(rig.port(1).lines.count)")
            rig.finish("radio on, never registered", opens: 1)
        }
        do {
            // Reads that take time: the 30 s are counted by the clock, not by the reads. Each command takes
            // 0.5 s, so a read of four takes 2 s and a round 3 s: reads end at 2, 5, …, 32 s after AT+CFUN=1.
            let reads = Array(repeating: searching, count: 11).flatMap { $0 }
            let rig = Rig([("AT+CFUN=1", ok)] + reads)
            rig.commandSeconds = 0.5
            let change = success(rig.service.setRadio(on: true), "radio on, slow reads")
            check(change == RadioChange(on: true, registration: searchingSA, secondsToRegister: nil),
                  "setRadio(on: true): slow reads, never registered", "\(String(describing: change))")
            check(rig.port(1).lines.count == 1 + 11 * 4, "setRadio(on: true): slow reads stop once 30 s have passed (11 reads)",
                  "\(rig.port(1).lines.count)")
            rig.finish("radio on, slow reads", opens: 1)
        }
        do {
            // A read that ends exactly 30 s after AT+CFUN=1 answered is the last: each command takes 1.6875 s,
            // so reads (6.75 s) end at 6.75, 14.5, 22.25 and 30 s.
            let reads = Array(repeating: searching, count: 4).flatMap { $0 }
            let rig = Rig([("AT+CFUN=1", ok)] + reads)
            rig.commandSeconds = 1.6875
            _ = success(rig.service.setRadio(on: true), "radio on, a read ends at 30 s")
            check(rig.port(1).lines.count == 1 + 4 * 4, "setRadio(on: true): a read ending at exactly 30 s is the last",
                  "\(rig.port(1).lines.count)")
            rig.finish("radio on, a read ends at 30 s", opens: 1)
        }
        do {
            // Registered on a slow read: the whole seconds from the AT+CFUN=1 answer, not from its sending. Each
            // command takes 0.9375 s: AT+CFUN=1 answers at 0.9375 s; the second read ends 8.5 s later (9.4375 s
            // after the line was sent).
            let rig = Rig([("AT+CFUN=1", ok)] + searching + registered)
            rig.commandSeconds = 0.9375
            let change = success(rig.service.setRadio(on: true), "radio on, slow, registered")
            check(change?.secondsToRegister == 8, "setRadio(on: true): seconds from the AT+CFUN=1 answer to the registered read",
                  "\(String(describing: change))")
            rig.finish("radio on, slow, registered", opens: 1)
        }
        do {
            // A clock that stands still (or was set back) cannot keep the wait going: at most 31 reads.
            let reads = Array(repeating: searching, count: 31).flatMap { $0 }
            let rig = Rig([("AT+CFUN=1", ok)] + reads)
            rig.sleepMovesClock = false
            let change = success(rig.service.setRadio(on: true), "radio on, clock stands still")
            check(change == RadioChange(on: true, registration: searchingSA, secondsToRegister: nil),
                  "setRadio(on: true): a clock that stands still", "\(String(describing: change))")
            check(rig.port(1).lines.count == 1 + 31 * 4, "setRadio(on: true): a clock that stands still stops after 31 reads",
                  "\(rig.port(1).lines.count)")
            rig.finish("radio on, clock stands still", opens: 1)
        }
        do {
            // A read that times out ends the wait: the radio is on all the same.
            let rig = Rig([("AT+CFUN=1", ok)] + searching + [("AT+C5GREG?", .success(["+C5GREG: 0,2"])), ("AT+CEREG?", timedOut)])
            let change = success(rig.service.setRadio(on: true), "radio on, read times out")
            check(change == RadioChange(on: true, registration: searchingSA, secondsToRegister: nil),
                  "setRadio(on: true): a timed-out read ends the wait with the last full read", "\(String(describing: change))")
            rig.finish("radio on, read times out", opens: 1)
        }
        do {
            let rig = Rig([("AT+CFUN=4", ok)])
            let change = success(rig.service.setRadio(on: false), "radio off")
            check(change == RadioChange(on: false, registration: nil, secondsToRegister: nil),
                  "setRadio(on: false): no registration and no seconds", "\(String(describing: change))")
            expectLines(rig.port(1).lines, ["AT+CFUN=4"], "setRadio(on: false): only AT+CFUN=4")
            check(rig.port(1).timeout(of: "AT+CFUN=4") == 20, "setRadio: AT+CFUN=4 has 20 s")
            check(rig.sleeps.isEmpty, "setRadio(on: false): no sleep")
            rig.finish("radio off", opens: 1)
        }
        do {
            let rig = Rig([("AT+CFUN=1", cme(3))])
            let message = failureMessage(rig.service.setRadio(on: true), "radio on refused")
            expectEqual(message, "The radio could not be switched on. The modem refused the command (+CME ERROR: 3).",
                        "setRadio: a refusal says so")
            rig.finish("radio on refused", opens: 1)
        }
        do {
            let rig = Rig([("AT+CFUN=4", timedOut)])
            let message = failureMessage(rig.service.setRadio(on: false), "radio off times out")
            expectEqual(message, "It is not known whether the radio was switched off. The modem did not answer in time.",
                        "setRadio: a timeout says it is not known")
            rig.finish("radio off times out", opens: 1)
        }
        do {
            let rig = Rig([.failure(.busy)])
            let message = failureMessage(rig.service.setRadio(on: false), "radio off, busy")
            expectEqual(message, "\(describe(.busy)) The radio was not switched off.", "setRadio: a failed open changes nothing")
            rig.finish("radio off, busy", opens: 1)
        }
    }

    // MARK: setMode

    static func mode() {
        let read = "AT+QNWPREFCFG=\"mode_pref\""
        func pref(_ value: String) -> Answer { .success(["+QNWPREFCFG: \"mode_pref\",\(value)"]) }
        do {
            let rig = Rig([(read, pref("AUTO")), ("AT+QNWPREFCFG=\"mode_pref\",LTE", ok), (read, pref("LTE"))])
            let change = success(rig.service.setMode("LTE"), "mode LTE")
            check(change == ModeChange(before: "AUTO", after: "LTE"), "setMode(\"LTE\"): AUTO to LTE", "\(String(describing: change))")
            expectLines(rig.port(1).lines, [read, "AT+QNWPREFCFG=\"mode_pref\",LTE", read], "setMode: read, write, read")
            check(rig.port(1).sent.map { $0.timeout } == [3, 5, 3], "setMode: the write has 5 s, the reads 3 s",
                  "\(rig.port(1).sent.map { $0.timeout })")
            rig.finish("mode LTE", opens: 1)
        }
        do {
            // Lower case is sent upper case; the caller's own order is kept (ruling R8).
            let rig = Rig([(read, pref("AUTO")), ("AT+QNWPREFCFG=\"mode_pref\",NR5G:LTE", ok), (read, pref("NR5G:LTE"))])
            let change = success(rig.service.setMode("nr5g:lte"), "mode nr5g:lte")
            check(change == ModeChange(before: "AUTO", after: "NR5G:LTE"),
                  "setMode(\"nr5g:lte\"): sends NR5G:LTE in its own order (R8)", "\(String(describing: change))")
            rig.finish("mode nr5g:lte", opens: 1)
        }
        do {
            let rig = Rig([(read, pref("NR5G:LTE")), ("AT+QNWPREFCFG=\"mode_pref\",AUTO", ok), (read, pref("AUTO"))])
            let change = success(rig.service.setMode("auto"), "mode auto")
            check(change == ModeChange(before: "NR5G:LTE", after: "AUTO"), "setMode(\"auto\"): before is the modem's own string",
                  "\(String(describing: change))")
            rig.finish("mode auto", opens: 1)
        }
        for bad in ["lte:lte", "5g", "auto:lte", "", "lte:", "LTE NR5G"] {
            let rig = Rig()
            let message = failureMessage(rig.service.setMode(bad), "mode \(bad)")
            check(message.hasSuffix("Nothing was changed."), "setMode(\"\(bad)\"): refused, nothing changed", message)
            rig.finish("mode \(bad)", opens: 0)
        }
        do {
            let rig = Rig([(read, pref("AUTO")), ("AT+QNWPREFCFG=\"mode_pref\",LTE", ok), (read, pref("LTE:NR5G"))])
            let message = failureMessage(rig.service.setMode("lte"), "mode read-back differs")
            expectEqual(message, "The modem answered OK but now reports LTE:NR5G. It was AUTO.",
                        "setMode: a different read-back fails")
            rig.finish("mode read-back differs", opens: 1)
        }
        do {
            let rig = Rig([(read, pref("AUTO")), ("AT+QNWPREFCFG=\"mode_pref\",LTE", ok), (read, ok)])
            let message = failureMessage(rig.service.setMode("lte"), "mode read-back empty")
            expectEqual(message, "The modem answered OK but now reports no mode. It was AUTO.",
                        "setMode: a read-back without a mode fails")
            rig.finish("mode read-back empty", opens: 1)
        }
        do {
            let rig = Rig([(read, pref("AUTO")), ("AT+QNWPREFCFG=\"mode_pref\",LTE", ok), (read, timedOut)])
            let message = failureMessage(rig.service.setMode("lte"), "mode read-back times out")
            expectEqual(message, "The modem answered OK, but the network mode could not be read back. "
                        + "The modem did not answer in time. It was AUTO.", "setMode: a read-back that times out fails")
            rig.finish("mode read-back times out", opens: 1)
        }
        do {
            let rig = Rig([(read, pref("AUTO")), ("AT+QNWPREFCFG=\"mode_pref\",LTE", cme(3))])
            let message = failureMessage(rig.service.setMode("lte"), "mode refused")
            expectEqual(message, "The network mode was not changed. The modem refused the command (+CME ERROR: 3).",
                        "setMode: a refused write")
            rig.finish("mode refused", opens: 1)
        }
        do {
            let rig = Rig([(read, pref("AUTO")), ("AT+QNWPREFCFG=\"mode_pref\",LTE", timedOut)])
            let message = failureMessage(rig.service.setMode("lte"), "mode write times out")
            expectEqual(message, "It is not known whether the network mode changed. The modem did not answer in time. It was AUTO.",
                        "setMode: a write that times out")
            rig.finish("mode write times out", opens: 1)
        }
        for (answer, name) in [(cme(3), "refused"), (ok, "without a mode"), (timedOut, "timed out")] {
            // Without the mode before, there is no way back: nothing is written.
            let rig = Rig([(read, answer)])
            let message = failureMessage(rig.service.setMode("lte"), "mode before \(name)")
            check(message.hasSuffix("Nothing was changed."), "setMode: the mode before \(name): nothing written", message)
            expectLines(rig.port(1).lines, [read], "setMode: the mode before \(name): only the read")
            rig.finish("mode before \(name)", opens: 1)
        }
    }

    // MARK: profiles

    static func profiles() {
        do {
            let rig = Rig([("AT+CGDCONT?", .success(cgdcont)),
                           ("AT+QICSGP=1", qicsgp1),
                           ("AT+QICSGP=2", .success(["+QICSGP: 3,\"ims\",\"\",\"\",0"])),
                           ("AT+QICSGP=3", .success(["+QICSGP: 3,\"CMNET\",\"\",\"\",0"])),
                           ("AT+QICSGP=4", cme(3)),
                           ("AT+QICSGP=5", .success(["+QICSGP: 3,\"SOS\",\"\",\"\",0"]))])
            let got = success(rig.service.profiles(), "profiles")
            let want = [
                DataProfile(id: 1, pdpType: "IPV4V6", apn: "", settings: profile1),
                DataProfile(id: 2, pdpType: "IPV4V6", apn: "ims",
                            settings: ProfileSettings(type: .ipv4v6, apn: "ims", user: "", password: "", auth: .none)),
                DataProfile(id: 3, pdpType: "IPV4V6", apn: "CMNET", settings: profile3),
                DataProfile(id: 4, pdpType: "IPV4V6", apn: "CMWAP", settings: nil),
                DataProfile(id: 5, pdpType: "IPV4V6", apn: "SOS",
                            settings: ProfileSettings(type: .ipv4v6, apn: "SOS", user: "", password: "", auth: .none)),
            ]
            check(got == want, "profiles: five profiles; a refused AT+QICSGP=4 leaves its settings nil", "\(String(describing: got))")
            check(rig.port(1).sent.allSatisfy { $0.timeout == 3 }, "profiles: each read has 3 s")
            rig.finish("profiles", opens: 1)
        }
        do {
            // Profile 20 is listed but AT+QICSGP takes 1 to 16: not asked.
            let rig = Rig([("AT+CGDCONT?", .success([cgdcont[0], "+CGDCONT: 20,\"IP\",\"x\",\"0.0.0.0\",0,0"])),
                           ("AT+QICSGP=1", qicsgp1)])
            let got = success(rig.service.profiles(), "profiles, 20")
            check(got == [DataProfile(id: 1, pdpType: "IPV4V6", apn: "", settings: profile1),
                          DataProfile(id: 20, pdpType: "IP", apn: "x", settings: nil)],
                  "profiles: a profile above 16 has no settings and is not asked", "\(String(describing: got))")
            rig.finish("profiles, 20", opens: 1)
        }
        do {
            let rig = Rig([("AT+CGDCONT?", .success(cgdcont)), ("AT+QICSGP=1", qicsgp1), ("AT+QICSGP=2", timedOut)])
            let message = failureMessage(rig.service.profiles(), "profiles, QICSGP times out")
            expectEqual(message, "Profile 2 could not be read. The modem did not answer in time.",
                        "profiles: a timeout on one profile fails the call")
            rig.finish("profiles, QICSGP times out", opens: 1)
        }
        do {
            let rig = Rig([("AT+CGDCONT?", cme(3))])
            let message = failureMessage(rig.service.profiles(), "profiles, CGDCONT refused")
            expectEqual(message, "The data profiles could not be read. The modem refused the command (+CME ERROR: 3).",
                        "profiles: AT+CGDCONT? refused fails")
            rig.finish("profiles, CGDCONT refused", opens: 1)
        }
    }

    // MARK: setProfile

    static func profileChange() {
        do {
            // The redial: the settings now, the radio's state, the radio off, a second, the change, the
            // read-back, the radio on, the registration.
            let rig = Rig(redialStart + [(setCmnet, ok), ("AT+QICSGP=1", qicsgpCmnet), ("AT+CFUN=1", ok)] + searching + registered)
            let change = success(rig.service.setProfile(1, to: cmnet, redial: true), "redial")
            let radio = RadioChange(on: true, registration: homeSA, secondsToRegister: 1)
            check(change == ProfileChange(id: 1, before: profile1, after: cmnet, redial: .done(radio)),
                  "setProfile(redial: true): before, after and .done with the seconds from the fake clock",
                  "\(String(describing: change))")
            expectLines(rig.port(1).lines, ["AT+QICSGP=1", "AT+CFUN?", "AT+CFUN=4", setCmnet, "AT+QICSGP=1", "AT+CFUN=1"]
                        + registrationLines + registrationLines, "setProfile(redial: true): the lines sent, exactly")
            check(rig.port(1).sent.map { $0.timeout } == [3, 3, 20, 5, 3, 20, 3, 3, 3, 3, 3, 3, 3, 3],
                  "setProfile: the timeouts (reads 3 s, AT+CFUN= 20 s, the change 5 s)", "\(rig.port(1).sent.map { $0.timeout })")
            check(rig.sleeps == [1, 1], "setProfile: one second after AT+CFUN=4, one between registration reads", "\(rig.sleeps)")
            rig.finish("redial", opens: 1)
        }
        do {
            // The password goes only in the change line.
            let rig = Rig(redialStart + [(setWithSecret, ok), ("AT+QICSGP=1", qicsgpWithSecret), ("AT+CFUN=1", ok)] + registered)
            let change = success(rig.service.setProfile(1, to: withSecret, redial: true), "redial with a password")
            check(change?.after == withSecret, "setProfile: a password set reads back", "\(String(describing: change))")
            check(rig.allLines.filter { $0.contains(secret) } == [setWithSecret],
                  "setProfile: the password is in no line but the change", linesText(rig.allLines.filter { $0 != setWithSecret }))
            rig.finish("redial with a password", opens: 1)
        }
        do {
            // Radio off at the start: no AT+CFUN= at all.
            let rig = Rig([("AT+QICSGP=1", qicsgp1), ("AT+CFUN?", cfunOff), (setCmnet, ok), ("AT+QICSGP=1", qicsgpCmnet)])
            let change = success(rig.service.setProfile(1, to: cmnet, redial: true), "radio was off")
            check(change == ProfileChange(id: 1, before: profile1, after: cmnet, redial: .radioWasOff),
                  "setProfile: the radio off at the start gives .radioWasOff", "\(String(describing: change))")
            check(!rig.allLines.contains(where: { $0.hasPrefix("AT+CFUN=") }), "setProfile: radio off: no AT+CFUN= sent",
                  linesText(rig.allLines))
            check(rig.sleeps.isEmpty, "setProfile: radio off: no sleep")
            rig.finish("radio was off", opens: 1)
        }
        do {
            // Minimum functionality (AT+CFUN 0) is not on either.
            let rig = Rig([("AT+QICSGP=1", qicsgp1), ("AT+CFUN?", .success(["+CFUN: 0"])), (setCmnet, ok), ("AT+QICSGP=1", qicsgpCmnet)])
            let change = success(rig.service.setProfile(1, to: cmnet, redial: true), "radio at minimum")
            check(change?.redial == .radioWasOff, "setProfile: CFUN 0 is not on: .radioWasOff", "\(String(describing: change))")
            rig.finish("radio at minimum", opens: 1)
        }
        do {
            let rig = Rig([("AT+QICSGP=1", qicsgp1), (setCmnet, ok), ("AT+QICSGP=1", qicsgpCmnet)])
            let change = success(rig.service.setProfile(1, to: cmnet, redial: false), "no redial")
            check(change == ProfileChange(id: 1, before: profile1, after: cmnet, redial: .notAsked),
                  "setProfile(redial: false): .notAsked", "\(String(describing: change))")
            expectLines(rig.port(1).lines, ["AT+QICSGP=1", setCmnet, "AT+QICSGP=1"], "setProfile(redial: false): no AT+CFUN")
            rig.finish("no redial", opens: 1)
        }
        do {
            // AT+CFUN=4 refused: the radio stays on, nothing else is sent.
            let rig = Rig([("AT+QICSGP=1", qicsgp1), ("AT+CFUN?", cfunOn), ("AT+CFUN=4", cme(3))])
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "CFUN=4 refused")
            check(message.hasSuffix("Nothing was changed."), "setProfile: AT+CFUN=4 refused ends \"Nothing was changed.\"", message)
            check(!rig.allLines.contains(where: { $0.hasPrefix("AT+QICSGP=1,") }), "setProfile: AT+CFUN=4 refused: no change sent",
                  linesText(rig.allLines))
            check(!rig.allLines.contains("AT+CFUN=1"), "setProfile: AT+CFUN=4 refused: the radio was not switched off, so no AT+CFUN=1")
            rig.finish("CFUN=4 refused", opens: 1)
        }
        do {
            // The read-back differs (APN x): a failure, and the radio is switched back on.
            let rig = Rig(redialStart + [(setCmnet, ok), ("AT+QICSGP=1", .success(["+QICSGP: 3,\"x\",\"\",\"\",0"])),
                                         ("AT+CFUN=1", ok)] + registered)
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "read-back differs")
            expectEqual(message, "Profile 1 does not read back as sent: the modem now reports IPV4V6, APN \"x\", no authentication. "
                        + "The radio was switched back on.", "setProfile: a different read-back fails and names what the modem reports")
            rig.finish("read-back differs", opens: 1)
        }
        do {
            // The read-back with another password: said, never shown.
            let rig = Rig([("AT+QICSGP=1", qicsgp1), (setWithSecret, ok), ("AT+QICSGP=1", .success(["+QICSGP: 3,\"cmnet\",\"u\",\"****\",1"]))])
            let message = failureMessage(rig.service.setProfile(1, to: withSecret, redial: false), "read-back masked")
            expectEqual(message, "Profile 1 does not read back as sent: the modem now reports IPV4V6, APN \"cmnet\", PAP, user \"u\", "
                        + "password set. Its password is not the one sent.", "setProfile: a different password is said, not shown")
            check(!message.contains(secret) && !message.contains("****"), "setProfile: no password in the failure", message)
            rig.finish("read-back masked", opens: 1)
        }
        do {
            let rig = Rig([("AT+QICSGP=1", qicsgp1), (setCmnet, cme(3))])
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: false), "refused, no redial")
            expectEqual(message, "The new settings for profile 1 were refused. The modem refused the command (+CME ERROR: 3). "
                        + "Nothing was changed.", "setProfile(redial: false): a refusal")
            rig.finish("refused, no redial", opens: 1)
        }
        // The checks of what the owner typed: no port is opened.
        for (id, settings, name) in [
            (17, cmnet, "profile 17"), (0, cmnet, "profile 0"),
            (1, ProfileSettings(type: .ipv4v6, apn: "a b", user: "", password: "", auth: .none), "an APN with a space"),
            (1, ProfileSettings(type: .ipv4v6, apn: "a", user: "u\"", password: "", auth: .pap), "a user name with a quote"),
            (1, ProfileSettings(type: .ipv4v6, apn: "a", user: "u", password: "p\\41", auth: .pap), "a password with a backslash"),
        ] {
            let rig = Rig()
            let message = failureMessage(rig.service.setProfile(id, to: settings, redial: true), "problem: \(name)")
            expectEqual(message, profileProblem(id, settings) ?? "(no problem)", "setProfile: \(name) is refused with profileProblem")
            rig.finish("problem: \(name)", opens: 0)
        }
        do {
            // Without the settings before, nothing is changed.
            let rig = Rig([("AT+QICSGP=1", cme(3))])
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "before refused")
            expectEqual(message, "Profile 1 could not be read. The modem refused the command (+CME ERROR: 3). Nothing was changed.",
                        "setProfile: the settings before could not be read")
            rig.finish("before refused", opens: 1)
        }
        do {
            // Without the radio's state, no redial is started and nothing is changed.
            let rig = Rig([("AT+QICSGP=1", qicsgp1), ("AT+CFUN?", ok)])
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "radio state unknown")
            expectEqual(message, "The modem did not say whether the radio is on. Nothing was changed.",
                        "setProfile: the radio's state unknown changes nothing")
            rig.finish("radio state unknown", opens: 1)
        }
        do {
            let rig = Rig([.failure(.busy)])
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "busy")
            expectEqual(message, "\(describe(.busy)) Nothing was changed.", "setProfile: a failed open changes nothing")
            rig.finish("busy", opens: 1)
        }
    }

    // A redial whose change, read-back or own port fails in the middle still switches the radio back on, on
    // a new port when the first closed itself, and says plainly when it could not.
    static func profileRedialFailures() {
        let stillOff = "Run `RMNet radio on`, or press Radio On in the window."
        do {
            // The change refused: AT+CFUN=1 is still sent; nothing changed.
            let rig = Rig(redialStart + [(setCmnet, cme(3)), ("AT+CFUN=1", ok)] + registered)
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "change refused")
            expectEqual(message, "The new settings for profile 1 were refused. The modem refused the command (+CME ERROR: 3). "
                        + "Nothing was changed. The radio was switched back on.",
                        "redial: the change refused says the radio was switched back on and nothing changed")
            expectLines(rig.port(1).lines, ["AT+QICSGP=1", "AT+CFUN?", "AT+CFUN=4", setCmnet, "AT+CFUN=1"] + registrationLines,
                        "redial: the change refused: AT+CFUN=1 still sent")
            rig.finish("change refused", opens: 1)
        }
        do {
            // The change times out: the port closed itself; a second port switches the radio on.
            let rig = Rig(redialStart + [(setCmnet, timedOut)], [("AT+CFUN=1", ok)] + registered)
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "change times out")
            expectEqual(message, "It is not known whether profile 1 was changed. The modem did not answer in time. "
                        + "The radio was switched back on.", "redial: a timeout on the change")
            check(rig.port(1).closedItself, "redial: the first port closed itself")
            expectLines(rig.port(2).lines, ["AT+CFUN=1"] + registrationLines, "redial: AT+CFUN=1 is sent on the second port")
            check(rig.port(2).timeout(of: "AT+CFUN=1") == 20, "redial: AT+CFUN=1 on the second port has 20 s")
            rig.finish("change times out", opens: 2)
        }
        do {
            // An I/O error on the read-back: the same, on a second port.
            let rig = Rig(redialStart + [(setCmnet, ok), ("AT+QICSGP=1", ioError)], [("AT+CFUN=1", ok)] + registered)
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "read-back I/O error")
            check(message.hasPrefix("Profile 1 could not be read back after the change. An I/O error occurred")
                  && message.hasSuffix("The radio was switched back on."), "redial: an I/O error on the read-back", message)
            rig.finish("read-back I/O error", opens: 2)
        }
        do {
            // The change and its read-back are fine; AT+CFUN=1 fails on both ports: the radio is left off.
            let rig = Rig(redialStart + [(setCmnet, ok), ("AT+QICSGP=1", qicsgpCmnet), ("AT+CFUN=1", timedOut)],
                          [("AT+CFUN=1", timedOut)])
            let change = success(rig.service.setProfile(1, to: cmnet, redial: true), "CFUN=1 fails twice")
            check(change == ProfileChange(id: 1, before: profile1, after: cmnet, redial: .radioLeftOff("The modem did not answer in time.")),
                  "redial: AT+CFUN=1 failing on both ports gives .radioLeftOff", "\(String(describing: change))")
            if let change {
                check(profileSentence(change).contains("the radio is still off"), "redial: the sentence names the radio still off",
                      profileSentence(change))
            }
            rig.finish("CFUN=1 fails twice", opens: 2)
        }
        do {
            // The change refused and AT+CFUN=1 failing on both ports (the second will not open).
            let rig = Rig([.success(ScriptedPort("port 1", redialStart + [(setCmnet, cme(3)), ("AT+CFUN=1", ioError)])),
                           .failure(.busy)])
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "refused, radio still off")
            expectEqual(message, "The new settings for profile 1 were refused. The modem refused the command (+CME ERROR: 3). "
                        + "Nothing was changed, but the radio is still off. \(describe(.busy)) \(stillOff)",
                        "redial: the change refused and the radio still off")
            rig.finish("refused, radio still off", opens: 2)
        }
        do {
            // The change times out and AT+CFUN=1 fails on the second port too.
            let rig = Rig(redialStart + [(setCmnet, timedOut)], [("AT+CFUN=1", ioError)])
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "unknown, radio still off")
            check(message.hasPrefix("It is not known whether profile 1 was changed. The modem did not answer in time. "
                                    + "The radio is still off. An I/O error occurred") && message.hasSuffix(stillOff),
                  "redial: not known, and the radio still off", message)
            rig.finish("unknown, radio still off", opens: 2)
        }
        do {
            // AT+CFUN=1 refused by the modem on a working port: no second port; the radio is left off.
            let rig = Rig(redialStart + [(setCmnet, ok), ("AT+QICSGP=1", qicsgpCmnet), ("AT+CFUN=1", cme(3))])
            let change = success(rig.service.setProfile(1, to: cmnet, redial: true), "CFUN=1 refused")
            check(change?.redial == .radioLeftOff("The modem refused the command (+CME ERROR: 3)."),
                  "redial: AT+CFUN=1 refused leaves the radio off, with the reason", "\(String(describing: change))")
            rig.finish("CFUN=1 refused", opens: 1)
        }
        do {
            // AT+CFUN=4 times out: whether the radio went off is not known; it is switched on again on a new port.
            let rig = Rig([("AT+QICSGP=1", qicsgp1), ("AT+CFUN?", cfunOn), ("AT+CFUN=4", timedOut)], [("AT+CFUN=1", ok)] + registered)
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "CFUN=4 times out")
            expectEqual(message, "The radio could not be switched off for the redial. The modem did not answer in time. "
                        + "Nothing was changed. The radio is on.", "redial: AT+CFUN=4 timing out changes nothing and switches the radio on")
            check(!rig.allLines.contains(setCmnet), "redial: AT+CFUN=4 timing out: no change sent")
            rig.finish("CFUN=4 times out", opens: 2)
        }
        do {
            // AT+CFUN=4 times out and the radio cannot be switched on: it may be off.
            let rig = Rig([.success(ScriptedPort("port 1", [("AT+QICSGP=1", qicsgp1), ("AT+CFUN?", cfunOn), ("AT+CFUN=4", timedOut)])),
                           .failure(.modemNotAttached)])
            let message = failureMessage(rig.service.setProfile(1, to: cmnet, redial: true), "CFUN=4 times out, no port")
            expectEqual(message, "The radio could not be switched off for the redial. The modem did not answer in time. "
                        + "Nothing was changed, but the radio may be off. \(describe(.modemNotAttached)) \(stillOff)",
                        "redial: AT+CFUN=4 timing out and no second port")
            rig.finish("CFUN=4 times out, no port", opens: 2)
        }
        do {
            // The password is in no failure, also when the change fails in the middle of a redial.
            let rig = Rig(redialStart + [(setWithSecret, ok), ("AT+QICSGP=1", .success(["+QICSGP: 3,\"cmnet\",\"u\",\"\",1"])),
                                         ("AT+CFUN=1", ok)] + registered)
            let message = failureMessage(rig.service.setProfile(1, to: withSecret, redial: true), "redial, password not kept")
            check(!message.contains(secret), "redial: no password in the failure", message)
            check(message.contains("Its password is not the one sent."), "redial: a dropped password is said", message)
            check(rig.allLines.filter { $0.contains(secret) } == [setWithSecret], "redial: the password only in the change line")
            rig.finish("redial, password not kept", opens: 1)
        }
    }

    // MARK: sim

    static func sim() {
        do {
            let rig = Rig([("AT+CPIN?", cpinReady), ("AT+QPINC?", qpinc(3)), ("AT+CLCK=\"SC\",2", clckOff)])
            let got = success(rig.service.sim(), "sim")
            check(got == SimInfo(state: .ready, pinLock: false, pinAttempts: 3, pukAttempts: 10), "sim: the READY fixture",
                  "\(String(describing: got))")
            expectLines(rig.port(1).lines, simLines, "sim: the three reads")
            check(rig.port(1).sent.allSatisfy { $0.timeout == 3 }, "sim: each read has 3 s")
            rig.finish("sim", opens: 1)
        }
        do {
            // AT+CPIN?'s error line is a state.
            let rig = Rig([("AT+CPIN?", cme(10)), ("AT+QPINC?", cme(10)), ("AT+CLCK=\"SC\",2", cme(10))])
            let got = success(rig.service.sim(), "sim, no SIM")
            check(got == SimInfo(state: .notInserted, pinLock: nil, pinAttempts: nil, pukAttempts: nil),
                  "sim: +CME ERROR: 10 is not inserted; the refused reads are nil", "\(String(describing: got))")
            rig.finish("sim, no SIM", opens: 1)
        }
        do {
            let rig = Rig([("AT+CPIN?", ok)])
            let message = failureMessage(rig.service.sim(), "sim, no CPIN line")
            expectEqual(message, "The modem did not say what state the SIM is in.", "sim: an answer without +CPIN fails")
            rig.finish("sim, no CPIN line", opens: 1)
        }
        do {
            let rig = Rig([("AT+CPIN?", cpinReady), ("AT+QPINC?", timedOut)])
            let got = success(rig.service.sim(), "sim, QPINC times out")
            check(got == SimInfo(state: .ready, pinLock: nil, pinAttempts: nil, pukAttempts: nil),
                  "sim: a timeout after the state leaves the rest nil, and nothing more is sent", "\(String(describing: got))")
            rig.finish("sim, QPINC times out", opens: 1)
        }
        do {
            let rig = Rig([("AT+CPIN?", timedOut)])
            let message = failureMessage(rig.service.sim(), "sim, CPIN times out")
            expectEqual(message, "The SIM's state could not be read. The modem did not answer in time.", "sim: a timeout on AT+CPIN?")
            rig.finish("sim, CPIN times out", opens: 1)
        }
    }

    // MARK: enterPin

    static func pinEntry() {
        var messages: [String] = []
        var allSent: [String] = []
        func done(_ rig: Rig, _ name: String, opens: Int) {
            allSent += rig.allLines
            rig.finish(name, opens: opens)
        }
        do {
            let rig = Rig([("AT+CPIN?", cpinReady), ("AT+QPINC?", qpinc(3))])
            let message = failureMessage(rig.service.enterPin(pin, shownAttempts: 3), "pin, ready")
            expectEqual(message, "The SIM does not ask for a PIN (ready). Nothing was sent.", "enterPin: READY sends nothing")
            expectLines(rig.port(1).lines, ["AT+CPIN?", "AT+QPINC?"], "enterPin: READY: only the reads")
            messages.append(message)
            done(rig, "pin, ready", opens: 1)
        }
        do {
            let rig = Rig([("AT+CPIN?", .success(["+CPIN: SIM PUK"])), ("AT+QPINC?", qpinc(0, 10))])
            let message = failureMessage(rig.service.enterPin(pin, shownAttempts: 3), "pin, puk")
            expectEqual(message, "The SIM does not ask for a PIN (blocked: needs its PUK from the carrier). Nothing was sent.",
                        "enterPin: SIM PUK sends nothing")
            messages.append(message)
            done(rig, "pin, puk", opens: 1)
        }
        do {
            let rig = Rig([("AT+CPIN?", cpinPin), ("AT+QPINC?", qpinc(2))])
            let message = failureMessage(rig.service.enterPin(pin, shownAttempts: 3), "pin, attempts changed")
            expectEqual(message, "The attempts left changed to 2 since they were shown. Nothing was sent; check and enter the PIN again.",
                        "enterPin: 2 attempts when 3 were shown sends nothing")
            expectLines(rig.port(1).lines, ["AT+CPIN?", "AT+QPINC?"], "enterPin: attempts changed: only the reads")
            messages.append(message)
            done(rig, "pin, attempts changed", opens: 1)
        }
        for shown in [0, 3] {
            let rig = Rig([("AT+CPIN?", cpinPin), ("AT+QPINC?", qpinc(0))])
            let message = failureMessage(rig.service.enterPin(pin, shownAttempts: shown), "pin, 0 attempts (\(shown) shown)")
            check(message.contains("Nothing was sent"), "enterPin: 0 attempts left (\(shown) shown) sends nothing", message)
            expectLines(rig.port(1).lines, ["AT+CPIN?", "AT+QPINC?"], "enterPin: 0 attempts: only the reads")
            messages.append(message)
            done(rig, "pin, 0 attempts (\(shown) shown)", opens: 1)
        }
        do {
            let rig = Rig([("AT+CPIN?", cpinPin), ("AT+QPINC?", cme(3))])
            let message = failureMessage(rig.service.enterPin(pin, shownAttempts: 3), "pin, attempts unknown")
            expectEqual(message, "The attempts left could not be read; RMNet does not send a PIN without them. Nothing was sent.",
                        "enterPin: unknown attempts send nothing")
            messages.append(message)
            done(rig, "pin, attempts unknown", opens: 1)
        }
        do {
            let rig = Rig([("AT+CPIN?", cpinPin), ("AT+QPINC?", timedOut)])
            let message = failureMessage(rig.service.enterPin(pin, shownAttempts: 3), "pin, QPINC times out")
            check(message.hasSuffix("Nothing was sent."), "enterPin: a timeout on AT+QPINC? sends nothing", message)
            messages.append(message)
            done(rig, "pin, QPINC times out", opens: 1)
        }
        do {
            let rig = Rig([("AT+CPIN?", cme(13)), ("AT+QPINC?", cme(13))])
            let message = failureMessage(rig.service.enterPin(pin, shownAttempts: 3), "pin, SIM failure")
            expectEqual(message, "The SIM does not ask for a PIN (SIM failure). Nothing was sent.",
                        "enterPin: AT+CPIN?'s error line is the state")
            messages.append(message)
            done(rig, "pin, SIM failure", opens: 1)
        }
        for bad in ["12a4", "123", "123456789", ""] {
            let rig = Rig()
            let message = failureMessage(rig.service.enterPin(bad, shownAttempts: 3), "pin \(bad)")
            expectEqual(message, pinProblem(bad) ?? "(no problem)", "enterPin(\"\(bad)\"): refused before the port opens")
            done(rig, "pin \(bad)", opens: 0)
        }
        do {
            let rig = Rig([("AT+CPIN?", cpinPin), ("AT+QPINC?", qpinc(3)), (pinLine, ok),
                           ("AT+CPIN?", cpinReady), ("AT+QPINC?", qpinc(3)), ("AT+CLCK=\"SC\",2", clckOn)])
            let outcome = success(rig.service.enterPin(pin, shownAttempts: 3), "pin accepted")
            check(outcome == PinOutcome(accepted: true, sim: SimInfo(state: .ready, pinLock: true, pinAttempts: 3, pukAttempts: 10)),
                  "enterPin: OK is accepted, and the SIM is read again", "\(String(describing: outcome))")
            expectLines(rig.port(1).lines, ["AT+CPIN?", "AT+QPINC?", pinLine] + simLines, "enterPin: the reads, the PIN, the three SIM reads")
            check(rig.port(1).timeout(of: pinLine) == 10, "enterPin: AT+CPIN=\"…\" has 10 s")
            check(!String(describing: outcome).contains(pin) && !String(reflecting: outcome).contains(pin),
                  "enterPin: the outcome does not hold the PIN")
            done(rig, "pin accepted", opens: 1)
        }
        do {
            let rig = Rig([("AT+CPIN?", cpinPin), ("AT+QPINC?", qpinc(3)), (pinLine, cme(16)),
                           ("AT+CPIN?", cpinPin), ("AT+QPINC?", qpinc(2)), ("AT+CLCK=\"SC\",2", clckOn)])
            let outcome = success(rig.service.enterPin(pin, shownAttempts: 3), "pin refused")
            check(outcome == PinOutcome(accepted: false, sim: SimInfo(state: .pin, pinLock: true, pinAttempts: 2, pukAttempts: 10)),
                  "enterPin: +CME ERROR: 16 is not accepted, with the new attempts", "\(String(describing: outcome))")
            done(rig, "pin refused", opens: 1)
        }
        do {
            // The SIM read after the PIN fails: accepted, without the SIM.
            let rig = Rig([("AT+CPIN?", cpinPin), ("AT+QPINC?", qpinc(3)), (pinLine, ok), ("AT+CPIN?", timedOut)])
            let outcome = success(rig.service.enterPin(pin, shownAttempts: 3), "pin accepted, read fails")
            check(outcome == PinOutcome(accepted: true, sim: nil), "enterPin: the read after the PIN failing gives sim nil",
                  "\(String(describing: outcome))")
            done(rig, "pin accepted, read fails", opens: 1)
        }
        for (answer, word) in [(timedOut, "a timeout"), (ioError, "an I/O error")] {
            let rig = Rig([("AT+CPIN?", cpinPin), ("AT+QPINC?", qpinc(3)), (pinLine, answer)])
            let message = failureMessage(rig.service.enterPin(pin, shownAttempts: 3), "pin, \(word)")
            check(message.hasSuffix("It is not known whether the SIM took the PIN. "
                                    + "Check the attempts left (RMNet sim) before entering it again."),
                  "enterPin: \(word) after sending: not known", message)
            expectLines(rig.port(1).lines, ["AT+CPIN?", "AT+QPINC?", pinLine], "enterPin: \(word): nothing after the PIN")
            messages.append(message)
            done(rig, "pin, \(word)", opens: 1)
        }
        do {
            let rig = Rig([.failure(.busy)])
            let message = failureMessage(rig.service.enterPin(pin, shownAttempts: 3), "pin, busy")
            expectEqual(message, "\(describe(.busy)) Nothing was sent.", "enterPin: a failed open sends nothing")
            messages.append(message)
            done(rig, "pin, busy", opens: 1)
        }
        // In every case: the PIN is in no failure, and in no line but the one AT+CPIN="…".
        for message in messages {
            check(!message.contains(pin), "enterPin: the PIN is in no failure", message)
        }
        check(allSent.filter { $0.contains(pin) }.allSatisfy { $0 == pinLine } && allSent.contains(pinLine),
              "enterPin: the PIN is in no line sent but AT+CPIN=\"…\"", linesText(allSent.filter { $0.contains(pin) }))
    }
}
