// Tests for app/ModemController.swift: the controller driven by a fake ModemServing whose calls block until
// the test releases them, with the main run loop pumped so that results come back as in the app. Built
// with swiftc by `make app-test` from app/ModemNetwork.swift, app/ModemSettings.swift,
// app/ModemController.swift and this file; needs no AppKit, no window and no modem.
// The controller's repeating timer is found by reflection, and its first turn is moved to the distant
// future each time before the run loop runs, so it never fires by itself during a test (its 5 s would
// otherwise depend on how long the test takes); a test fires it when it wants a turn.
// Stops at the first failure, prints which check failed and exits 1.
import Combine
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

// MARK: - The fake service

enum Call: Equatable {
    case networkInfo
    case setRadio(Bool)
    case setMode(String)
    case profiles
    case setProfile(Int, ProfileSettings, redial: Bool)
    case sim
    case enterPin(String, shownAttempts: Int)
}

let queueKey = DispatchSpecificKey<String>()
let queueName = "io.rmnetdriver.RMNet.modem.test"

/// Records each call, then blocks it (on the controller's queue) until the test releases it with a result.
/// Its mirror is empty: its log holds the test PINs, and the checks that the controller keeps no copy of a
/// PIN reflect over the controller, which holds the service.
final class FakeService: ModemServing, CustomReflectable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var log: [Call] = []
    private var infoResults: [Result<NetworkInfo, ModemFailure>] = []
    private var radioResults: [Result<RadioChange, ModemFailure>] = []
    private var modeResults: [Result<ModeChange, ModemFailure>] = []
    private var profilesResults: [Result<[DataProfile], ModemFailure>] = []
    private var profileResults: [Result<ProfileChange, ModemFailure>] = []
    private var simResults: [Result<SimInfo, ModemFailure>] = []
    private var pinResults: [Result<PinOutcome, ModemFailure>] = []
    private var inside = 0   // calls entered and not yet returned
    private var mostInside = 0
    private var misplaced = 0  // calls made on the main thread or on another queue than the controller's

    var customMirror: Mirror { Mirror(self, children: [:]) }
    var calls: [Call] { locked { log } }
    var blocked: Int { locked { inside } }
    var mostAtOnce: Int { locked { mostInside } }
    var callsOffQueue: Int { locked { misplaced } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func enter(_ call: Call) {
        let placed = !Thread.isMainThread && DispatchQueue.getSpecific(key: queueKey) == queueName
        locked {
            log.append(call)
            if !placed { misplaced += 1 }
            inside += 1
            mostInside = max(mostInside, inside)
        }
        gate.wait()
        locked { inside -= 1 }
    }

    func networkInfo() -> Result<NetworkInfo, ModemFailure> {
        enter(.networkInfo)
        return locked { infoResults.removeFirst() }
    }

    func setRadio(on: Bool) -> Result<RadioChange, ModemFailure> {
        enter(.setRadio(on))
        return locked { radioResults.removeFirst() }
    }

    func setMode(_ mode: String) -> Result<ModeChange, ModemFailure> {
        enter(.setMode(mode))
        return locked { modeResults.removeFirst() }
    }

    func profiles() -> Result<[DataProfile], ModemFailure> {
        enter(.profiles)
        return locked { profilesResults.removeFirst() }
    }

    func setProfile(_ id: Int, to settings: ProfileSettings, redial: Bool) -> Result<ProfileChange, ModemFailure> {
        enter(.setProfile(id, settings, redial: redial))
        return locked { profileResults.removeFirst() }
    }

    func sim() -> Result<SimInfo, ModemFailure> {
        enter(.sim)
        return locked { simResults.removeFirst() }
    }

    func enterPin(_ pin: String, shownAttempts: Int) -> Result<PinOutcome, ModemFailure> {
        enter(.enterPin(pin, shownAttempts: shownAttempts))
        return locked { pinResults.removeFirst() }
    }

    // The window does not read or set the USB mode (only `RMNet usbmode` does): these are never called.
    func usbMode() -> Result<UsbModeInfo, ModemFailure> { .failure(ModemFailure(message: "not used")) }
    func setUsbMode(_ mode: UsbNetMode, reboot: Bool) -> Result<UsbModeChange, ModemFailure> {
        .failure(ModemFailure(message: "not used"))
    }
    // Nor does it send a command as typed (only `RMNet at` does): never called.
    func at(_ line: String, timeout: TimeInterval) -> Result<[String], ModemFailure> {
        .failure(ModemFailure(message: "not used"))
    }
    // Nor does it show or lock the bands (only `RMNet bands` does): never called.
    func bands() -> Result<[BandSet], ModemFailure> { .failure(ModemFailure(message: "not used")) }
    func setBands(_ rat: BandRat, to bands: [Int]) -> Result<BandChange, ModemFailure> {
        .failure(ModemFailure(message: "not used"))
    }

    func releaseInfo(_ r: Result<NetworkInfo, ModemFailure>) { locked { infoResults.append(r) }; gate.signal() }
    func releaseRadio(_ r: Result<RadioChange, ModemFailure>) { locked { radioResults.append(r) }; gate.signal() }
    func releaseMode(_ r: Result<ModeChange, ModemFailure>) { locked { modeResults.append(r) }; gate.signal() }
    func releaseProfiles(_ r: Result<[DataProfile], ModemFailure>) { locked { profilesResults.append(r) }; gate.signal() }
    func releaseProfile(_ r: Result<ProfileChange, ModemFailure>) { locked { profileResults.append(r) }; gate.signal() }
    func releaseSim(_ r: Result<SimInfo, ModemFailure>) { locked { simResults.append(r) }; gate.signal() }
    func releasePin(_ r: Result<PinOutcome, ModemFailure>) { locked { pinResults.append(r) }; gate.signal() }
}

// MARK: - Helpers

/// Every controller a rig made, so that `pump` and `settle` can hold back their timers.
var liveControllers: [() -> ModemController?] = []
var changesSeen = 0  // published changes of the controllers and their quit notices, all on the main thread

/// The controller's repeating timer (its private `timer`), found by reflection; nil when none runs.
func timer(of c: ModemController) -> Timer? {
    Mirror(reflecting: c).children.first(where: { $0.label == "timer" }).flatMap { $0.value as? Timer }
}

/// The timer is scheduled in the main run loop's common modes (so it turns while a menu or a sheet is open).
func scheduled(_ t: Timer?) -> Bool {
    guard let t else { return false }
    return CFRunLoopContainsTimer(CFRunLoopGetMain(), unsafeBitCast(t, to: CFRunLoopTimer.self), .commonModes)
}

/// Waits for `condition` without running the main run loop, so that results handed to the main thread
/// stay unread (fails the check after 2 s).
func waitOffMain(until condition: () -> Bool, _ name: String) {
    let deadline = Date().addingTimeInterval(2)
    while !condition() {
        if Date() > deadline { check(false, "timed out waiting: \(name)") }
        usleep(1000)
    }
}

/// Moves the next turn of every controller's timer to the distant future, so that no turn comes by itself.
func holdTimers() {
    for live in liveControllers {
        if let t = live().flatMap(timer(of:)), t.isValid, t.fireDate != .distantFuture { t.fireDate = .distantFuture }
    }
}

/// Runs the main run loop until `condition` holds (or fails the check after 2 s).
func pump(until condition: () -> Bool, _ name: String) {
    let deadline = Date().addingTimeInterval(2)
    while !condition() {
        if Date() > deadline { check(false, "timed out waiting: \(name)") }
        holdTimers()
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
}

/// Runs the main run loop for a while, so that anything wrongly started would show.
func settle() {
    let end = Date().addingTimeInterval(0.1)
    while Date() < end {
        holdTimers()
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
}

func onMainOnly(_ what: String) {
    guard Thread.isMainThread else {
        print("FAIL: \(what) changed off the main thread")
        exit(1)
    }
    changesSeen += 1
}

/// A controller with a fake service on its own queue, the driver's profile number it reads, and what it
/// answered to quits and how often it asked for attention.
final class Rig {
    let fake = FakeService()
    let queue = DispatchQueue(label: queueName)
    var driver: Int? = 1
    var replies: [Bool] = []
    var attention = 0
    private var watchers: [AnyCancellable] = []
    lazy var controller: ModemController = makeController()

    init() { queue.setSpecific(key: queueKey, value: queueName) }

    private func makeController() -> ModemController {
        let c = ModemController(service: fake, queue: queue,
                                driverProfile: { [unowned self] in self.driver },
                                replyToQuit: { [unowned self] in self.replies.append($0) },
                                requestAttention: { [unowned self] in self.attention += 1 })
        watchers.append(c.objectWillChange.sink { _ in onMainOnly("a published value of the controller") })
        watchers.append(c.quitNotice.objectWillChange.sink { _ in onMainOnly("the quit notice") })
        liveControllers.append { [weak c] in c }
        return c
    }

    /// Waits until the fake has had `count` calls in all and one of them is blocked in it.
    func waitForCall(_ count: Int, _ name: String) {
        pump(until: { fake.calls.count == count && fake.blocked == 1 }, name)
    }

    /// Answers the network read that is call `count` and waits for it to come back.
    func answerInfo(_ count: Int, _ result: Result<NetworkInfo, ModemFailure>, _ name: String) {
        waitForCall(count, name)
        fake.releaseInfo(result)
        pump(until: { controller.running == nil }, "\(name): the read comes back")
    }

    /// Answers the settings read whose profiles() is call `count` (sim() is the next) and waits for it.
    func answerSettings(_ count: Int, _ profiles: Result<[DataProfile], ModemFailure>,
                        _ sim: Result<SimInfo, ModemFailure>, _ name: String) {
        waitForCall(count, "\(name): profiles()")
        fake.releaseProfiles(profiles)
        waitForCall(count + 1, "\(name): sim()")
        fake.releaseSim(sim)
        pump(until: { controller.running == nil }, "\(name): the read comes back")
    }
}

/// True when no stored property of the controller holds `secret`: not in any child's description,
/// reflection or dump, nor in a dump of the whole controller.
func keepsNoCopy(_ c: ModemController, of secret: String) -> Bool {
    for child in Mirror(reflecting: c).children {
        var dumped = ""
        dump(child.value, to: &dumped)
        for text in [String(describing: child.value), String(reflecting: child.value), dumped] where text.contains(secret) {
            return false
        }
    }
    var whole = ""
    dump(c, to: &whole)
    return !whole.contains(secret)
}

// MARK: - Fixtures

let home = Registration(status: .home, domain: "5GS")

func network(_ mode: String?) -> NetworkInfo {
    NetworkInfo(radio: .on, registration: home, operatorName: "CHINA MOBILE", mode: mode)
}

let profile1 = ProfileSettings(type: .ipv4v6, apn: "", user: "", password: "", auth: .none)
let profile2 = ProfileSettings(type: .ipv4v6, apn: "ims", user: "", password: "", auth: .none)
let profile3 = ProfileSettings(type: .ipv4v6, apn: "CMNET", user: "", password: "", auth: .none)

/// Profiles 1, 2 and 3 as AT+CGDCONT? and AT+QICSGP read them; nil settings: not read.
func listing(_ one: ProfileSettings? = profile1, three: ProfileSettings? = profile3) -> [DataProfile] {
    [DataProfile(id: 1, pdpType: "IPV4V6", apn: one?.apn ?? "", settings: one),
     DataProfile(id: 2, pdpType: "IPV4V6", apn: "ims", settings: profile2),
     DataProfile(id: 3, pdpType: "IPV4V6", apn: three?.apn ?? "", settings: three)]
}

let ready = SimInfo(state: .ready, pinLock: false, pinAttempts: 3, pukAttempts: 10)

func asksPin(_ attempts: Int?) -> SimInfo {
    SimInfo(state: .pin, pinLock: true, pinAttempts: attempts, pukAttempts: 10)
}

let radioOn = RadioChange(on: true, registration: home, secondsToRegister: 9)
let radioOff = RadioChange(on: false, registration: nil, secondsToRegister: nil)

let portBusy = ModemFailure(message: "Another program is using the modem's spare AT port.")
let notAnswered = ModemFailure(message: "The modem did not answer in time.")
let refused = ModemFailure(message: "The modem refused the command (+CME ERROR: 3). Nothing was changed.")

let waitingLine = "Waiting for the current read to finish…"
let anotherChange = "Another change to the modem has not finished yet. Nothing was changed; try again when it has."
let anotherChangePin = "Another change to the modem has not finished yet. The PIN was not sent; enter it again when it has."

// MARK: - The checks

@main
struct ModemControllerTests {
    static func main() {
        reading()
        tabSwitching()
        settingsReads()
        formAndPick()
        enabledStates()
        modeChanges()
        modeOrder()
        radio()
        profileChanges()
        profileWayBack()
        queuedChanges()
        refreshing()
        nothingDone()
        pinEntry()
        quitting()
        resuming()
        check(changesSeen > 0, "main thread: the controllers' changes were watched")
        print("modem controller: \(checks) checks passed")
    }

    // The shown tab is read at once and on each timer turn; nothing while no tab is shown, the window is
    // hidden or a confirmation is open; a turn while a call runs is skipped; a failed read keeps the last
    // values and says why, a good one clears that.
    static func reading() {
        let rig = Rig()
        let c = rig.controller
        check(ModemController.networkInterval == 5 && ModemController.settingsInterval == 30,
              "read: the turns are 5 s (Network) and 30 s (SIM & APN)")
        c.tick()
        c.refresh()
        settle()
        check(rig.fake.calls.isEmpty && timer(of: c) == nil, "read: nothing is read and no timer runs before a tab is shown",
              "\(rig.fake.calls)")
        check(c.info == nil && c.sim == nil && c.profiles.isEmpty && c.running == nil && c.result == "",
              "read: nothing is known at first")

        // The Network tab: networkInfo() at once, then every 5 s.
        c.setTabShown(.network)
        rig.waitForCall(1, "the Network tab is read at once")
        check(rig.fake.calls == [.networkInfo] && c.running == .reading, "read: the Network tab reads networkInfo() at once",
              "\(rig.fake.calls)")
        check(timer(of: c)?.timeInterval == 5, "read: the Network tab's timer turns every 5 s")
        check(scheduled(timer(of: c)), "read: the Network tab's timer is scheduled in the main run loop")
        check(c.refreshEnabled, "read: a read leaves Refresh on (R12)")
        c.tick()
        c.refresh()
        timer(of: c)?.fire()
        c.setTabShown(.network)
        c.setWindowVisible(true)
        settle()
        check(rig.fake.calls == [.networkInfo],
              "read: a tick, a refresh, a timer turn and showing the tab again start nothing while a read runs",
              "\(rig.fake.calls)")
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { c.running == nil }, "the first network read comes back")
        settle()
        check(c.info == network("AUTO") && c.infoAt != nil && c.infoFailure == nil, "read: a good read sets info and its time")
        check(rig.fake.calls.count == 1 && c.refreshEnabled, "read: nothing more is read until the next turn", "\(rig.fake.calls)")

        timer(of: c)?.fire()
        rig.waitForCall(2, "a timer turn reads")
        check(rig.fake.calls.last == .networkInfo, "read: a timer turn reads networkInfo()")
        let firstAt = c.infoAt
        rig.fake.releaseInfo(.failure(portBusy))
        pump(until: { c.running == nil }, "the failed read comes back")
        check(c.info == network("AUTO") && c.infoAt == firstAt && c.infoFailure == portBusy.message,
              "read: a failed read keeps the last values and says why", "\(String(describing: c.infoFailure))")
        check(c.result == "", "read: a read never writes the result line", c.result)

        c.tick()
        rig.answerInfo(3, .success(network("LTE")), "a tick")
        check(c.info == network("LTE") && c.infoFailure == nil && c.infoAt != nil && c.infoAt != firstAt,
              "read: a good read clears the failure")

        // A confirmation is open: turns skip.
        c.setConfirming(true)
        c.tick()
        timer(of: c)?.fire()
        settle()
        check(rig.fake.calls.count == 3, "read: turns skip while a confirmation is open", "\(rig.fake.calls)")
        c.setConfirming(false)
        settle()
        check(rig.fake.calls.count == 3, "read: closing a confirmation reads nothing by itself", "\(rig.fake.calls)")
        c.tick()
        rig.answerInfo(4, .success(network("LTE")), "a tick after the confirmation")

        // The window shown again while a confirmation is open: the read waits until it closes.
        c.setConfirming(true)
        c.setWindowVisible(false)
        c.setWindowVisible(true)
        settle()
        check(rig.fake.calls.count == 4, "read: nothing is read while a confirmation is open, also when the window shows again",
              "\(rig.fake.calls)")
        c.setConfirming(false)
        rig.answerInfo(5, .success(network("LTE")), "the read that was due starts when the confirmation closes")

        // The window hidden: no timer, no reads; shown again: read at once.
        c.setWindowVisible(false)
        check(timer(of: c) == nil, "read: the timer stops while the window is hidden")
        c.tick()
        settle()
        check(rig.fake.calls.count == 5, "read: a tick reads nothing while the window is hidden", "\(rig.fake.calls)")
        c.setWindowVisible(true)
        rig.answerInfo(6, .success(network("LTE")), "the window shown again is read at once")
        check(timer(of: c)?.timeInterval == 5 && scheduled(timer(of: c)), "read: the timer runs again when the window shows")

        // The SIM & APN tab: profiles() then sim() in one queued block, at once and every 30 s.
        c.setTabShown(.simAndApn)
        rig.waitForCall(7, "the SIM & APN tab is read at once")
        check(rig.fake.calls.last == .profiles && c.running == .reading, "read: the SIM & APN tab reads profiles() first",
              "\(rig.fake.calls)")
        check(timer(of: c)?.timeInterval == 30 && scheduled(timer(of: c)),
              "read: the SIM & APN tab's timer turns every 30 s, scheduled in the main run loop")
        rig.fake.releaseProfiles(.success(listing()))
        rig.waitForCall(8, "sim() follows profiles()")
        check(rig.fake.calls.last == .sim && c.running == .reading, "read: sim() follows profiles() in the same read")
        c.tick()
        c.refresh()
        settle()
        check(rig.fake.calls.count == 8, "read: nothing starts between profiles() and sim()", "\(rig.fake.calls)")
        rig.fake.releaseSim(.success(ready))
        pump(until: { c.running == nil }, "the settings read comes back")
        check(c.profiles == listing() && c.sim == ready && c.settingsAt != nil && c.settingsFailure == nil,
              "read: a good settings read sets the profiles, the SIM and the time")
        check(c.info == network("LTE"), "read: the network values are kept while the other tab is shown")
        timer(of: c)?.fire()
        rig.answerSettings(9, .success(listing()), .success(ready), "a timer turn on the SIM & APN tab")

        // Neither modem tab shown.
        c.setTabShown(nil)
        check(timer(of: c) == nil, "read: the timer stops while neither modem tab is shown")
        c.tick()
        c.refresh()
        settle()
        check(rig.fake.calls.count == 10, "read: nothing is read while neither modem tab is shown", "\(rig.fake.calls)")
        check(rig.fake.mostAtOnce == 1, "read: never two calls in the service at once")
        check(rig.fake.callsOffQueue == 0, "read: every call runs on the controller's queue, off the main thread")
    }

    // A tab shown while a read of the other runs is read as soon as that read has finished (not a turn
    // later); the tab's own read is never doubled; nothing follows while the window is hidden.
    static func tabSwitching() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.network)
        rig.waitForCall(1, "the Network tab is read")
        c.setTabShown(.simAndApn)
        settle()
        check(rig.fake.calls == [.networkInfo], "switch: the other tab waits for the running read", "\(rig.fake.calls)")
        rig.fake.releaseInfo(.success(network("AUTO")))
        rig.answerSettings(2, .success(listing()), .success(ready), "the SIM & APN tab after the running read")
        check(c.info == network("AUTO") && c.sim == ready, "switch: both reads are applied")
        settle()
        check(rig.fake.calls.count == 3, "switch: the new tab is read once", "\(rig.fake.calls)")

        // Hiding and showing the window while the tab's own read runs: no second read.
        c.tick()
        rig.waitForCall(4, "a turn starts")
        c.setWindowVisible(false)
        c.setWindowVisible(true)
        rig.answerSettings(4, .success(listing()), .success(ready), "the turn")
        settle()
        check(rig.fake.calls.count == 5, "switch: hiding and showing the window during the tab's own read reads it once",
              "\(rig.fake.calls)")

        // Away and back during a read: once.
        c.tick()
        rig.waitForCall(6, "a turn starts")
        c.setTabShown(.network)
        c.setTabShown(.simAndApn)
        rig.answerSettings(6, .success(listing()), .success(ready), "the turn")
        settle()
        check(rig.fake.calls.count == 7, "switch: away and back during the tab's own read reads it once", "\(rig.fake.calls)")

        // Switched while hidden: nothing follows until the window shows again.
        c.tick()
        rig.waitForCall(8, "a turn starts")
        c.setWindowVisible(false)
        c.setTabShown(.network)
        rig.answerSettings(8, .success(listing()), .success(ready), "the turn")
        settle()
        check(rig.fake.calls.count == 9, "switch: nothing follows a read while the window is hidden", "\(rig.fake.calls)")
        c.setWindowVisible(true)
        rig.answerInfo(10, .success(network("AUTO")), "the Network tab when the window shows")
        check(rig.fake.calls.last == .networkInfo, "switch: the tab shown is read when the window shows")
        c.setTabShown(nil)
        check(rig.fake.mostAtOnce == 1 && rig.fake.callsOffQueue == 0, "switch: one call at a time, on the queue")
    }

    // A settings read's two parts: either failing keeps its last values and sets the failure; a good read
    // clears it. The driver's profile number is read at each settings refresh.
    static func settingsReads() {
        let rig = Rig()
        let c = rig.controller
        check(c.profileID == 1 && !c.driverAttached, "settings: before any read, profile 1 and no driver known")
        c.setTabShown(.simAndApn)
        rig.answerSettings(1, .success(listing()), .success(ready), "the first settings read")
        check(c.profileID == 1 && c.driverAttached, "settings: the driver's profile is read at the refresh")
        let firstAt = c.settingsAt

        c.tick()
        rig.answerSettings(3, .failure(portBusy), .success(asksPin(3)), "profiles() fails")
        check(c.profiles == listing() && c.sim == asksPin(3), "settings: a failed profiles() keeps the profiles; sim() still counts")
        check(c.settingsFailure == portBusy.message && c.settingsAt == firstAt,
              "settings: the failure is said; the time stays that of the last good read")

        let otherOne = ProfileSettings(type: .ipv4, apn: "a.b", user: "u", password: "", auth: .pap)
        c.tick()
        rig.answerSettings(5, .success(listing(otherOne)), .failure(notAnswered), "sim() fails")
        check(c.profiles == listing(otherOne) && c.sim == asksPin(3), "settings: a failed sim() keeps the SIM; profiles() still counts")
        check(c.settingsFailure == notAnswered.message && c.settingsAt == firstAt, "settings: sim()'s failure is said")

        c.tick()
        rig.answerSettings(7, .failure(portBusy), .failure(notAnswered), "both fail")
        check(c.settingsFailure == portBusy.message, "settings: both failing says the first failure",
              "\(String(describing: c.settingsFailure))")

        c.tick()
        rig.answerSettings(9, .success(listing()), .success(ready), "a good read")
        check(c.settingsFailure == nil && c.settingsAt != nil && c.settingsAt != firstAt && c.sim == ready && c.profiles == listing(),
              "settings: a good read clears the failure and sets the time")

        rig.driver = 3
        c.tick()
        rig.answerSettings(11, .success(listing()), .success(ready), "the driver on profile 3")
        check(c.profileID == 3 && c.driverAttached && c.form == profile3 && !c.formEdited,
              "settings: the form is the driver's profile, read at each refresh")
        rig.driver = nil
        c.tick()
        rig.answerSettings(13, .success(listing()), .success(ready), "the driver not attached")
        check(c.profileID == 1 && !c.driverAttached && c.form == profile1, "settings: without the driver, profile 1")
        c.setTabShown(nil)

        // The driver's profile not listed, or listed without its settings: no form, no Apply.
        let rig2 = Rig()
        rig2.driver = 7
        let d = rig2.controller
        d.setTabShown(.simAndApn)
        rig2.answerSettings(1, .success(listing()), .success(ready), "profile 7 is not listed")
        check(d.profileID == 7 && d.form == nil && !d.formEdited && !d.applyEnabled, "settings: a profile not listed has no form")
        d.revertForm()
        check(d.form == nil, "settings: Revert leaves a profile not listed without a form")
        d.setTabShown(nil)

        let rig3 = Rig()
        rig3.driver = 3
        let e = rig3.controller
        e.setTabShown(.simAndApn)
        rig3.answerSettings(1, .success(listing(three: nil)), .success(ready), "profile 3 without settings")
        check(e.profileID == 3 && e.form == nil && !e.applyEnabled, "settings: a profile whose settings were not read has no form")
        e.setTabShown(nil)
    }

    // The editor's form and the Network tab's pick: filled when nil, never overwritten by a refresh when
    // the owner changed them, following the modem when not.
    static func formAndPick() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.simAndApn)
        rig.answerSettings(1, .success(listing()), .success(ready), "the first settings read")
        check(c.form == profile1 && !c.formEdited, "form: filled from the driver's profile when nil")
        c.form?.apn = "cmnet"
        check(c.formEdited, "form: an edit shows as edited")
        let elsewhere = ProfileSettings(type: .ipv4v6, apn: "internet", user: "", password: "", auth: .none)
        c.tick()
        rig.answerSettings(3, .success(listing(elsewhere)), .success(ready), "the profile changed elsewhere")
        check(c.form?.apn == "cmnet" && c.formEdited, "form: a refresh never overwrites an edited form",
              "\(String(describing: c.form))")
        c.revertForm()
        check(c.form == elsewhere && !c.formEdited, "form: Revert fills it from the last read")
        c.tick()
        rig.answerSettings(5, .success(listing()), .success(ready), "the profile changed back elsewhere")
        check(c.form == profile1 && !c.formEdited, "form: a form not edited follows the modem's values")
        c.form?.apn = "cmnet"
        rig.driver = 3
        c.tick()
        rig.answerSettings(7, .success(listing()), .success(ready), "the driver's profile changes")
        check(c.form == profile3 && !c.formEdited, "form: when the driver's profile changes, the form is that profile's")
        c.setTabShown(nil)

        let rig2 = Rig()
        let m = rig2.controller
        m.setTabShown(.network)
        rig2.answerInfo(1, .success(network(nil)), "a read without the mode")
        check(m.pickedMode == nil && !m.modeChangeEnabled, "pick: nil while the mode is not known")
        m.tick()
        rig2.answerInfo(2, .success(network("AUTO")), "a read with the mode")
        check(m.pickedMode == "AUTO" && !m.modeChangeEnabled, "pick: set from info.mode when nil; Change is off for the current mode")
        m.tick()
        rig2.answerInfo(3, .success(network("LTE")), "the mode changed elsewhere")
        check(m.pickedMode == "LTE" && !m.modeChangeEnabled, "pick: a pick the owner did not change follows the modem's mode")
        m.pickedMode = "NR5G"
        check(m.modeChangeEnabled, "pick: a different pick enables Change")
        m.tick()
        rig2.answerInfo(4, .success(network("AUTO")), "the mode changed elsewhere again")
        check(m.pickedMode == "NR5G" && m.modeChangeEnabled, "pick: a refresh never overwrites a different pick")
        m.pickedMode = "5g"
        check(!m.modeChangeEnabled, "pick: a mode RMNet cannot set does not enable Change")
        m.setTabShown(nil)
    }

    // Apply, Change, Unlock and Refresh are off while a call runs and once the app quits.
    static func enabledStates() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.simAndApn)
        rig.answerSettings(1, .success(listing()), .success(asksPin(3)), "the first settings read")
        check(!c.applyEnabled, "apply: off while the form is not edited")
        c.form?.apn = "cm net"
        check(c.formEdited && !c.applyEnabled, "apply: off while profileProblem has a sentence")
        c.form?.apn = "cmnet"
        check(c.applyEnabled, "apply: on for an edited form without a problem")
        check(c.pinEnabled, "pin: on when the SIM asks for its PIN with attempts left")
        c.pickedMode = "LTE"
        check(c.modeChangeEnabled, "mode: on for a pick that differs from the mode read (none yet)")

        c.tick()
        rig.waitForCall(3, "a turn starts")
        check(c.applyEnabled && c.pinEnabled && c.modeChangeEnabled && c.refreshEnabled,
              "enabled: a read leaves every button on (R12)")
        rig.fake.releaseProfiles(.success(listing()))
        rig.fake.releaseSim(.success(asksPin(1)))
        pump(until: { c.running == nil }, "the turn comes back")
        check(c.applyEnabled && c.pinEnabled && c.modeChangeEnabled && c.refreshEnabled,
              "enabled: on again afterwards; Unlock is on with 1 attempt left")

        var n = 5
        let puk = SimInfo(state: .puk, pinLock: true, pinAttempts: 0, pukAttempts: 10)
        for (sim, name) in [(asksPin(0), "no attempts are left"), (asksPin(nil), "the attempts are not known"),
                            (ready, "the SIM is ready"), (puk, "the SIM needs its PUK")] {
            c.tick()
            rig.answerSettings(n, .success(listing()), .success(sim), name)
            n += 2
            check(!c.pinEnabled, "pin: off when \(name)")
        }
        c.tick()
        rig.answerSettings(n, .success(listing()), .success(asksPin(3)), "the SIM asks again")
        check(c.pinEnabled, "pin: on again")
        check(c.quitWhenFinished() == false, "enabled: a quit with nothing running answers at once")
        check(!c.applyEnabled && !c.pinEnabled && !c.modeChangeEnabled && !c.refreshEnabled,
              "enabled: everything is off once the app quits")
        c.setTabShown(nil)
    }

    // changeMode: the pick goes to the service; the sentence; the undo; the pick and the tab read again.
    // putBack sends the modem's own string (ruling R8) and clears the undo on success only.
    static func modeChanges() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.network)
        rig.answerInfo(1, .success(network("AUTO")), "the first read")
        c.pickedMode = "LTE"
        c.changeMode()
        rig.waitForCall(2, "the mode change reaches the service")
        check(rig.fake.calls.last == .setMode("LTE") && c.running == .mode, "mode: the pick goes to setMode", "\(rig.fake.calls)")
        check(c.result == "Changing the network mode to LTE only…" && !c.resultIsFailure, "mode: the running sentence", c.result)
        check(!c.modeChangeEnabled && !c.refreshEnabled, "mode: Change and Refresh are off while it runs")
        c.tick()
        c.refresh()
        timer(of: c)?.fire()
        c.changeMode()
        settle()
        check(rig.fake.calls.count == 2, "mode: nothing else starts while the change runs", "\(rig.fake.calls)")
        check(c.result == anotherChange && c.resultIsFailure, "mode: a second Change while one runs is refused with a sentence",
              c.result)
        let change = ModeChange(before: "AUTO", after: "LTE")
        rig.fake.releaseMode(.success(change))
        rig.waitForCall(3, "the tab is read again after the change")
        check(rig.fake.calls.last == .networkInfo, "mode: the Network tab is read again after the change")
        check(c.result == modeSentence(change) && !c.resultIsFailure, "mode: the success sentence", c.result)
        check(c.undo == .mode("AUTO") && c.pickedMode == "LTE", "mode: the undo is the mode before; the pick is the new mode")
        rig.fake.releaseInfo(.success(network("LTE")))
        pump(until: { c.running == nil }, "the read after the change comes back")
        check(c.result == modeSentence(change) && !c.modeChangeEnabled, "mode: the read after it leaves the result line; Change is off")

        c.pickedMode = "NR5G"
        c.changeMode()
        rig.waitForCall(4, "a second change reaches the service")
        rig.fake.releaseMode(.failure(refused))
        rig.waitForCall(5, "the tab is read again after the failed change")
        check(c.result == refused.message && c.resultIsFailure, "mode: a failure's sentence", c.result)
        check(c.undo == .mode("AUTO") && c.pickedMode == "LTE", "mode: a failure keeps the undo; the pick goes back to the mode read")
        rig.fake.releaseInfo(.success(network("LTE")))
        pump(until: { c.running == nil }, "the read comes back")
        c.setTabShown(nil)

        // Put Back: the modem's own string, unchanged (R8).
        let rig2 = Rig()
        let m = rig2.controller
        m.setTabShown(.network)
        rig2.answerInfo(1, .success(network("NR5G:LTE")), "the first read")
        m.pickedMode = "AUTO"
        m.changeMode()
        rig2.waitForCall(2, "the change reaches the service")
        rig2.fake.releaseMode(.success(ModeChange(before: "NR5G:LTE", after: "AUTO")))
        rig2.answerInfo(3, .success(network("AUTO")), "the read after the change")
        check(m.undo == .mode("NR5G:LTE"), "put back: the undo keeps the modem's own string")
        check(m.undoCommand == "RMNet mode nr5g:lte", "put back: the window's command for a terminal (F9)",
              "\(String(describing: m.undoCommand))")
        m.putBack()
        rig2.waitForCall(4, "the put back reaches the service")
        check(rig2.fake.calls.last == .setMode("NR5G:LTE") && m.running == .mode,
              "put back: setMode gets the modem's own string, unchanged (R8)", "\(rig2.fake.calls)")
        check(m.result == "Putting the network mode back to 5G and LTE…", "put back: the running sentence", m.result)
        rig2.fake.releaseMode(.failure(notAnswered))
        rig2.answerInfo(5, .success(network("AUTO")), "the read after the failed put back")
        check(m.result == notAnswered.message && m.resultIsFailure && m.undo == .mode("NR5G:LTE"),
              "put back: a failure keeps the undo", m.result)
        m.putBack()
        rig2.waitForCall(6, "the put back again")
        let back = ModeChange(before: "AUTO", after: "NR5G:LTE")
        rig2.fake.releaseMode(.success(back))
        rig2.waitForCall(7, "the tab is read again after the put back")
        check(m.undo == nil && m.result == modeSentence(back) && !m.resultIsFailure && m.pickedMode == "NR5G:LTE",
              "put back: success clears the undo; its sentence; the pick is the mode put back", m.result)
        check(m.undoCommand == nil, "put back: no command without an undo")
        rig2.fake.releaseInfo(.success(network("NR5G:LTE")))
        pump(until: { m.running == nil }, "the read comes back")
        m.putBack()
        settle()
        check(rig2.fake.calls.count == 7, "put back: with nothing to put back it does nothing", "\(rig2.fake.calls)")
        m.setTabShown(nil)

        // A mode before that RMNet cannot set again gives no Put Back.
        let rig3 = Rig()
        let o = rig3.controller
        o.setTabShown(.network)
        rig3.answerInfo(1, .success(network("GSM:LTE")), "an odd mode")
        o.pickedMode = "LTE"
        o.changeMode()
        rig3.waitForCall(2, "the change reaches the service")
        rig3.fake.releaseMode(.success(ModeChange(before: "GSM:LTE", after: "LTE")))
        rig3.answerInfo(3, .success(network("LTE")), "the read after the change")
        check(o.undo == nil && !o.resultIsFailure && o.undoCommand == nil,
              "mode: no undo and no command when the mode before cannot be set by RMNet")
        check(o.result == modeSentence(ModeChange(before: "GSM:LTE", after: "LTE"))
                + " The earlier value GSM:LTE cannot be set by RMNet; set it again on the modem's console.",
              "mode: the result line says the mode before cannot be put back by RMNet (R8)", o.result)
        o.setTabShown(nil)
    }

    // setRadio: its sentence, no undo of its own (an earlier one stays), the tab read again; not while
    // the window is hidden, until it shows.
    // The same RATs in another order are the same mode (compared by canonicalMode): no change to make, and
    // the pick follows the modem. (Put Back still sends the modem's own string: modeChanges, R8.)
    static func modeOrder() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.network)
        rig.answerInfo(1, .success(network("NR5G:LTE")), "the first read")
        check(c.pickedMode == "NR5G:LTE" && !c.modeChangeEnabled, "mode order: the modem's own value, no change")
        c.pickedMode = "LTE:NR5G"
        check(!c.modeChangeEnabled, "mode order: LTE:NR5G for NR5G:LTE is not a change")
        c.changeMode()
        settle()
        check(rig.fake.calls.count == 1, "mode order: changeMode sends nothing for the same mode", "\(rig.fake.calls)")
        check(c.result == "The network mode is already 5G and LTE. Nothing was changed." && c.resultIsFailure,
              "mode order: changeMode says it is the mode already", c.result)
        timer(of: c)?.fire()
        rig.answerInfo(2, .success(network("AUTO")), "a read after the modem changed")
        check(c.pickedMode == "AUTO", "mode order: the pick of the same mode in another order follows the modem",
              "\(String(describing: c.pickedMode))")
        c.pickedMode = "LTE"
        check(c.modeChangeEnabled, "mode order: another mode is a change")
        c.setTabShown(nil)
    }

    static func radio() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.network)
        rig.answerInfo(1, .success(network("AUTO")), "the first read")
        c.pickedMode = "LTE"
        c.changeMode()
        rig.waitForCall(2, "a mode change, for an undo")
        rig.fake.releaseMode(.success(ModeChange(before: "AUTO", after: "LTE")))
        rig.answerInfo(3, .success(network("LTE")), "the read after it")

        c.setRadio(on: false)
        rig.waitForCall(4, "the radio switch reaches the service")
        check(rig.fake.calls.last == .setRadio(false) && c.running == .radio, "radio: off goes to setRadio(on: false)")
        check(c.result == "Switching the radio off…" && !c.resultIsFailure, "radio: the running sentence", c.result)
        rig.fake.releaseRadio(.success(radioOff))
        rig.waitForCall(5, "the tab is read again after the radio")
        check(rig.fake.calls.last == .networkInfo, "radio: the Network tab is read again")
        check(c.result == radioSentence(radioOff) && !c.resultIsFailure, "radio: off's sentence", c.result)
        check(c.undo == .mode("AUTO"), "radio: no undo of its own; the earlier one stays")
        rig.fake.releaseInfo(.success(network("LTE")))
        pump(until: { c.running == nil }, "the read comes back")

        c.setRadio(on: true)
        rig.waitForCall(6, "radio on")
        check(rig.fake.calls.last == .setRadio(true) && c.result == "Switching the radio on…", "radio: on", c.result)
        rig.fake.releaseRadio(.success(radioOn))
        rig.waitForCall(7, "the tab is read again")
        check(c.result == radioSentence(radioOn) && !c.resultIsFailure, "radio: on's sentence", c.result)
        rig.fake.releaseInfo(.success(network("LTE")))
        pump(until: { c.running == nil }, "the read comes back")

        c.setRadio(on: true)
        rig.waitForCall(8, "radio on again")
        c.setWindowVisible(false)
        rig.fake.releaseRadio(.failure(notAnswered))
        pump(until: { c.running == nil }, "the failed switch comes back")
        settle()
        check(c.result == notAnswered.message && c.resultIsFailure && c.undo == .mode("AUTO"), "radio: a failure's sentence", c.result)
        check(rig.fake.calls.count == 8, "radio: no read after a change while the window is hidden", "\(rig.fake.calls)")
        c.setWindowVisible(true)
        rig.answerInfo(9, .success(network("LTE")), "the window shows again")
        c.setTabShown(nil)
    }

    // applyProfile: the form to the driver's profile with redial; the sentence; the undo with the settings
    // before (the old password in memory only); the form filled after; putBack the same way.
    static func profileChanges() {
        let rig = Rig()
        rig.driver = 3
        let c = rig.controller
        let old = ProfileSettings(type: .ipv4v6, apn: "CMNET", user: "carrier", password: "oldSecret1", auth: .pap)
        c.setTabShown(.simAndApn)
        rig.answerSettings(1, .success(listing(three: old)), .success(ready), "the first settings read")
        check(c.form == old, "profile: the form holds the driver's profile")
        c.form?.apn = "cmnet.example"
        let applied = c.form!
        check(c.applyEnabled, "profile: Apply is on")
        c.applyProfile()
        rig.waitForCall(3, "the profile change reaches the service")
        check(rig.fake.calls.last == .setProfile(3, applied, redial: true) && c.running == .profile,
              "profile: the form goes to the driver's profile, with redial")
        check(c.result == "Changing profile 3…" && !c.resultIsFailure, "profile: the running sentence", c.result)
        check(!c.applyEnabled && !c.refreshEnabled, "profile: Apply and Refresh are off while it runs")
        let change = ProfileChange(id: 3, before: old, after: applied, redial: .done(radioOn))
        rig.fake.releaseProfile(.success(change))
        rig.waitForCall(4, "the tab is read again after the change")
        check(rig.fake.calls.last == .profiles, "profile: the SIM & APN tab is read again")
        check(c.result == profileSentence(change) && !c.resultIsFailure, "profile: the success sentence", c.result)
        check(c.undo == .profile(id: 3, old), "profile: the undo holds the settings before, password included")
        check(c.undoCommand == "RMNet apn set --apn 'CMNET' --type ipv4v6 --user 'carrier' --auth pap --password",
              "profile: the window's command for a terminal, without the password (F9)", "\(String(describing: c.undoCommand))")
        check(c.form == applied && !c.formEdited, "profile: the form is filled with the new settings")
        rig.fake.releaseProfiles(.success(listing(three: applied)))
        rig.waitForCall(5, "sim()")
        rig.fake.releaseSim(.success(ready))
        pump(until: { c.running == nil }, "the read comes back")
        check(c.form == applied && !c.formEdited && !c.applyEnabled, "profile: the read after it leaves the form as read")

        var dumped = ""
        dump(c, to: &dumped)
        check(!dumped.contains("oldSecret1") && dumped.contains("passwordSet"),
              "profile: a dump of the controller does not show the old password")
        check(!String(describing: c.undo).contains("oldSecret1") && !String(reflecting: c.undo).contains("oldSecret1"),
              "profile: the undo's descriptions do not show the old password")

        // Put Back: the settings before, with redial; the undo cleared; an edit replaced by what the modem has.
        c.form?.user = "typed"
        c.putBack()
        rig.waitForCall(6, "the put back reaches the service")
        check(rig.fake.calls.last == .setProfile(3, old, redial: true) && c.running == .profile,
              "put back: the settings before, with redial")
        check(c.result == "Putting profile 3 back…", "put back: the running sentence", c.result)
        let back = ProfileChange(id: 3, before: applied, after: old, redial: .done(radioOn))
        rig.fake.releaseProfile(.success(back))
        rig.waitForCall(7, "the tab is read again after the put back")
        check(c.undo == nil && c.result == profileSentence(back) && !c.resultIsFailure, "put back: success clears the undo", c.result)
        check(c.form == old && !c.formEdited, "put back: the form is filled with the settings put back")
        rig.fake.releaseProfiles(.success(listing(three: old)))
        rig.waitForCall(8, "sim()")
        rig.fake.releaseSim(.success(ready))
        pump(until: { c.running == nil }, "the read comes back")

        // A change that fails: its sentence, the undo unchanged, the owner's edit kept to be corrected (R11).
        c.form?.apn = "x"
        c.form?.password = "newSecret2"
        let typed = c.form!
        c.applyProfile()
        rig.waitForCall(9, "a change that will fail")
        rig.fake.releaseProfile(.failure(refused))
        rig.waitForCall(10, "the tab is read again after the failure")
        check(c.result == refused.message && c.resultIsFailure && c.undo == nil, "profile: a failure's sentence; no undo", c.result)
        check(c.form == typed && c.formEdited, "profile: a failed Apply keeps the edited form (R11)")
        rig.fake.releaseProfiles(.success(listing(three: old)))
        rig.waitForCall(11, "sim()")
        rig.fake.releaseSim(.success(ready))
        pump(until: { c.running == nil }, "the read comes back")
        check(c.form == typed && c.formEdited && c.applyEnabled, "profile: the read after it keeps the edit; Apply is on to try again")
        var afterFailure = ""
        dump(c, to: &afterFailure)
        check(!afterFailure.contains("newSecret2") && !afterFailure.contains("oldSecret1"),
              "profile: a dump of the controller shows neither password")
        c.revertForm()

        // A change whose redial left the radio off: said as a failure; it can be put back.
        c.form?.apn = "y"
        let tried = c.form!
        c.applyProfile()
        rig.waitForCall(12, "a change whose redial fails")
        let leftOff = ProfileChange(id: 3, before: old, after: tried, redial: .radioLeftOff("The modem did not answer in time."))
        rig.fake.releaseProfile(.success(leftOff))
        rig.waitForCall(13, "the tab is read again")
        check(c.result == profileSentence(leftOff) && c.resultIsFailure, "profile: the radio left off is said as a failure", c.result)
        check(c.undo == .profile(id: 3, old), "profile: a change that left the radio off can be put back")
        check(c.form == tried && !c.formEdited, "profile: a change made (radio left off) fills the form")
        rig.fake.releaseProfiles(.success(listing(three: tried)))
        rig.waitForCall(14, "sim()")
        rig.fake.releaseSim(.success(ready))
        pump(until: { c.running == nil }, "the read comes back")

        // A Put Back that fails keeps an edit made meanwhile and the undo; one that succeeds fills the form.
        c.form?.user = "edited"
        let edit = c.form!
        c.putBack()
        rig.waitForCall(15, "a put back that will fail")
        rig.fake.releaseProfile(.failure(notAnswered))
        rig.answerSettings(16, .success(listing(three: tried)), .success(ready), "the read after the failed put back")
        check(c.form == edit && c.formEdited && c.undo == .profile(id: 3, old) && c.resultIsFailure,
              "put back: a failure keeps the edited form and the undo (R11)", c.result)
        c.putBack()
        rig.waitForCall(18, "the put back again")
        rig.fake.releaseProfile(.success(ProfileChange(id: 3, before: tried, after: old, redial: .done(radioOn))))
        rig.waitForCall(19, "the read after the put back")
        check(c.form == old && !c.formEdited && c.undo == nil, "put back: success fills the form with what the modem has")
        rig.fake.releaseProfiles(.success(listing(three: old)))
        rig.waitForCall(20, "sim()")
        rig.fake.releaseSim(.success(ready))
        pump(until: { c.running == nil }, "the read comes back")
        check(c.form == old && !c.formEdited, "put back: the read after it fills the form from what was read")
        c.setTabShown(nil)
    }

    // A profile change that failed after its line may have reached the modem (ruling R19), one for each of
    // the service's paths: its sentence, the undo set to the settings before it, and the owner's edit kept
    // (R11) with the form's source reset, so that the earlier settings typed again count as a change.
    static func profileWayBack() {
        let old = ProfileSettings(type: .ipv4v6, apn: "CMNET", user: "carrier", password: "oldSecret1", auth: .pap)
        for sentence in [
            "It is not known whether profile 3 was changed. The modem did not answer in time. The radio was switched back on.",
            "Profile 3 does not read back as sent: the modem now reports IPV4V6, APN \"x\", no authentication. "
                + "The radio was switched back on.",
            "Profile 3 could not be read back after the change. The modem did not answer in time. The radio was switched back on.",
        ] {
            let name = "way back after \"\(sentence.prefix(40))…\""
            let rig = Rig()
            rig.driver = 3
            let c = rig.controller
            c.setTabShown(.simAndApn)
            rig.answerSettings(1, .success(listing(three: old)), .success(ready), "\(name): the first read")
            c.form?.apn = "cmnet.example"
            c.form?.password = "newSecret2"
            let typed = c.form!
            c.applyProfile()
            rig.waitForCall(3, "\(name): the change")
            rig.fake.releaseProfile(.failure(ModemFailure(message: sentence, profileBefore: old)))
            rig.waitForCall(4, "\(name): the tab is read again")
            check(c.result == sentence && c.resultIsFailure, "\(name): the failure's sentence", c.result)
            check(c.undo == .profile(id: 3, old), "\(name): the undo holds the settings before, password included",
                  "\(String(describing: c.undo))")
            check(c.form == typed && c.formEdited, "\(name): the edit is kept (R11)")
            rig.fake.releaseProfiles(.success(listing(three: typed)))
            rig.waitForCall(5, "\(name): sim()")
            rig.fake.releaseSim(.success(ready))
            pump(until: { c.running == nil }, "\(name): the read comes back")
            check(c.form == typed && c.formEdited && c.applyEnabled, "\(name): the read after it keeps the edit; Apply is on")
            c.form = old
            check(c.formEdited && c.applyEnabled, "\(name): the settings before typed again are a change Apply can make")
            var dumped = ""
            dump(c, to: &dumped)
            check(!dumped.contains("oldSecret1") && !dumped.contains("newSecret2"), "\(name): a dump shows neither password")
            c.putBack()
            rig.waitForCall(6, "\(name): Put Back")
            check(rig.fake.calls.last == .setProfile(3, old, redial: true), "\(name): Put Back writes the settings before")
            rig.fake.releaseProfile(.success(ProfileChange(id: 3, before: typed, after: old, redial: .done(radioOn))))
            rig.answerSettings(7, .success(listing(three: old)), .success(ready), "\(name): the read after Put Back")
            check(c.undo == nil && c.form == old && !c.formEdited, "\(name): Put Back clears the undo and fills the form")
            c.setTabShown(nil)
        }

        // Without the settings before (nothing was sent), the undo stays as it was; a Put Back that fails keeps
        // the undo it was to apply, also when it may have changed the profile.
        let rig = Rig()
        rig.driver = 3
        let c = rig.controller
        c.setTabShown(.simAndApn)
        rig.answerSettings(1, .success(listing(three: old)), .success(ready), "the first read")
        c.form?.apn = "a"
        c.applyProfile()
        rig.waitForCall(3, "a change that sends nothing")
        rig.fake.releaseProfile(.failure(ModemFailure(message: "Profile 3 could not be read. Nothing was changed.")))
        rig.answerSettings(4, .success(listing(three: old)), .success(ready), "the read after it")
        check(c.undo == nil && c.resultIsFailure, "way back: nothing sent: no undo", "\(String(describing: c.undo))")
        let applied = c.form!
        c.applyProfile()
        rig.waitForCall(6, "a change made")
        rig.fake.releaseProfile(.success(ProfileChange(id: 3, before: old, after: applied, redial: .done(radioOn))))
        rig.answerSettings(7, .success(listing(three: applied)), .success(ready), "the read after it")
        check(c.undo == .profile(id: 3, old), "way back: a change made sets the undo")
        c.putBack()
        rig.waitForCall(9, "a put back that will fail")
        rig.fake.releaseProfile(.failure(ModemFailure(message: "It is not known whether profile 3 was changed.", profileBefore: applied)))
        rig.answerSettings(10, .success(listing(three: applied)), .success(ready), "the read after it")
        check(c.undo == .profile(id: 3, old) && c.resultIsFailure, "way back: a failed Put Back keeps the undo it was to apply",
              "\(String(describing: c.undo))")
        check(c.form == applied && !c.formEdited, "way back: an unedited form follows the read after a failed Put Back")
        c.setTabShown(nil)
    }

    // A change asked for while a read runs (a turn began just before its confirmation opened) waits for
    // it on the queue and starts as soon as it has finished (R12); at most one waits; a change running or
    // waiting turns the buttons off, a read does not.
    static func queuedChanges() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.network)
        rig.answerInfo(1, .success(network("AUTO")), "the first read")
        c.tick()
        rig.waitForCall(2, "a turn starts")
        c.pickedMode = "LTE"
        check(c.modeChangeEnabled && c.refreshEnabled, "queue: a read leaves Change and Refresh on")
        c.changeMode()
        check(c.result == waitingLine && !c.resultIsFailure && c.running == .reading, "queue: the change waits for the read", c.result)
        check(!c.modeChangeEnabled && !c.refreshEnabled && !c.pinEnabled && !c.applyEnabled,
              "queue: a waiting change turns the buttons off")
        c.setRadio(on: false)
        check(c.result == anotherChange && c.resultIsFailure, "queue: a second change while one waits is refused with a sentence",
              c.result)
        c.tick()
        c.refresh()
        settle()
        check(rig.fake.calls == [.networkInfo, .networkInfo], "queue: the waiting change has not reached the service yet",
              "\(rig.fake.calls)")
        rig.fake.releaseInfo(.success(network("AUTO")))
        rig.waitForCall(3, "the waiting change starts after the read")
        check(rig.fake.calls.last == .setMode("LTE") && c.running == .mode, "queue: the change starts as soon as the read has finished",
              "\(rig.fake.calls)")
        check(c.result == "Changing the network mode to LTE only…" && !c.resultIsFailure, "queue: then its running line", c.result)
        check(c.info == network("AUTO") && c.infoAt != nil, "queue: the read before it was applied")
        let change = ModeChange(before: "AUTO", after: "LTE")
        rig.fake.releaseMode(.success(change))
        rig.answerInfo(4, .success(network("LTE")), "the read after the change")
        check(c.undo == .mode("AUTO") && c.result == modeSentence(change) && !c.resultIsFailure, "queue: the change was made", c.result)
        settle()
        check(rig.fake.calls.count == 4 && rig.fake.mostAtOnce == 1 && rig.fake.callsOffQueue == 0,
              "queue: the refused radio switch never ran; one call at a time, on the queue", "\(rig.fake.calls)")

        // The view calls the action before setConfirming(false): it starts at once, before the read that
        // became due while the confirmation was open; that read follows it.
        c.setConfirming(true)
        c.setWindowVisible(false)
        c.setWindowVisible(true)
        c.setRadio(on: false)
        rig.waitForCall(5, "the confirmed change starts at once")
        check(rig.fake.calls.last == .setRadio(false) && c.running == .radio, "queue: a confirmed change starts at once")
        c.setConfirming(false)
        settle()
        check(rig.fake.calls.count == 5, "queue: no read while the change runs")
        rig.fake.releaseRadio(.success(radioOff))
        rig.answerInfo(6, .success(network("LTE")), "the read after the change")
        check(c.result == radioSentence(radioOff), "queue: the change's sentence", c.result)

        // The other order (setConfirming(false) first, so the due read starts): the change is not refused,
        // it waits for that read (reviewer minor 8).
        c.setConfirming(true)
        c.setWindowVisible(false)
        c.setWindowVisible(true)
        c.setConfirming(false)
        rig.waitForCall(7, "the read that was due starts")
        c.setRadio(on: true)
        check(c.result == waitingLine, "queue: a change confirmed after the read started waits for it", c.result)
        rig.fake.releaseInfo(.success(network("LTE")))
        rig.waitForCall(8, "the change after the read")
        check(rig.fake.calls.last == .setRadio(true) && c.running == .radio, "queue: then it starts")
        rig.fake.releaseRadio(.success(radioOn))
        rig.answerInfo(9, .success(network("LTE")), "the read after the change")
        check(c.result == radioSentence(radioOn) && !c.resultIsFailure, "queue: the change was made", c.result)
        c.setTabShown(nil)

        // A PIN that waits: the attempts the confirmation showed go to the service unchanged, not the ones
        // read meanwhile (R13), and no stored property holds the PIN while it waits.
        let rig2 = Rig()
        let p = rig2.controller
        p.setTabShown(.simAndApn)
        rig2.answerSettings(1, .success(listing()), .success(asksPin(3)), "the first settings read")
        p.tick()
        rig2.waitForCall(3, "a turn starts")
        let pin = "75318642"
        p.enterPin(pin, shownAttempts: 3)
        check(p.result == waitingLine && !p.pinEnabled, "queue: the PIN waits for the read", p.result)
        check(keepsNoCopy(p, of: pin), "queue: no stored property holds a waiting PIN")
        p.enterPin(pin, shownAttempts: 3)
        check(p.result == anotherChangePin && p.resultIsFailure, "queue: a second PIN while one waits is refused", p.result)
        rig2.fake.releaseProfiles(.success(listing()))
        rig2.waitForCall(4, "sim()")
        rig2.fake.releaseSim(.success(asksPin(2)))
        rig2.waitForCall(5, "the PIN after the read")
        check(rig2.fake.calls.last == .enterPin(pin, shownAttempts: 3) && p.running == .pin,
              "queue: the attempts shown are passed unchanged, not the ones read meanwhile (R13)")
        check(p.sim == asksPin(2), "queue: the read before the PIN was applied")
        rig2.fake.releasePin(.success(PinOutcome(accepted: false, sim: asksPin(2), refusal: "+CME ERROR: 16")))
        rig2.answerSettings(6, .success(listing()), .success(asksPin(2)), "the read after the PIN")
        check(keepsNoCopy(p, of: pin), "queue: no stored property holds the PIN afterwards")
        check(rig2.fake.calls.count == 7, "queue: the refused second PIN was never sent", "\(rig2.fake.calls.count)")
        p.setTabShown(nil)
    }

    // An explicit Refresh: works in a visible window with a tab shown; does nothing (and is off) while a
    // confirmation is open; does nothing while the window is hidden; adds nothing to a read that runs.
    static func refreshing() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.network)
        rig.answerInfo(1, .success(network("AUTO")), "the first read")
        c.refresh()
        rig.answerInfo(2, .success(network("AUTO")), "Refresh in a visible window reads at once")
        c.setConfirming(true)
        check(!c.refreshEnabled, "refresh: off while a confirmation is open")
        c.refresh()
        settle()
        check(rig.fake.calls.count == 2, "refresh: does nothing while a confirmation is open", "\(rig.fake.calls)")
        c.setConfirming(false)
        check(c.refreshEnabled, "refresh: on again when the confirmation closes")
        settle()
        check(rig.fake.calls.count == 2, "refresh: a Refresh refused during the confirmation is not run later", "\(rig.fake.calls)")
        c.setWindowVisible(false)
        c.refresh()
        settle()
        check(rig.fake.calls.count == 2, "refresh: does nothing while the window is hidden", "\(rig.fake.calls)")
        c.setWindowVisible(true)
        rig.answerInfo(3, .success(network("AUTO")), "the window shows again")
        c.refresh()
        rig.waitForCall(4, "a Refresh")
        c.refresh()
        settle()
        check(rig.fake.calls.count == 4, "refresh: a second Refresh while a read runs adds nothing", "\(rig.fake.calls)")
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { c.running == nil }, "the read comes back")
        c.setTabShown(nil)
        c.refresh()
        settle()
        check(rig.fake.calls.count == 4, "refresh: does nothing with no modem tab shown", "\(rig.fake.calls)")
    }

    // Every change that does nothing says why on the result line, and nothing reaches the service.
    static func nothingDone() {
        let rig = Rig()
        let c = rig.controller
        c.putBack()
        check(c.result == "There is no change to put back." && c.resultIsFailure, "nothing: Put Back with no undo", c.result)
        c.applyProfile()
        check(c.result == "The settings of profile 1 have not been read. Nothing was changed.", "nothing: Apply before a read", c.result)
        c.changeMode()
        check(c.result == "Choose a network mode first. Nothing was changed.", "nothing: Change with no pick", c.result)
        c.enterPin("1234", shownAttempts: 3)
        check(c.result == "The SIM has not been read yet. The PIN was not sent.", "nothing: Unlock before the SIM is read", c.result)

        c.setTabShown(.network)
        rig.answerInfo(1, .success(network("AUTO")), "the first read")
        c.changeMode()
        check(c.result == "The network mode is already automatic (5G, LTE and WCDMA). Nothing was changed.",
              "nothing: Change to the mode the modem has", c.result)
        c.pickedMode = "5g"
        c.changeMode()
        check(c.result == "RMNet cannot set the network mode 5g. Nothing was changed.", "nothing: Change to a mode RMNet cannot set",
              c.result)

        c.setTabShown(.simAndApn)
        rig.answerSettings(2, .success(listing()), .success(ready), "the settings read")
        c.applyProfile()
        check(c.result == "Profile 1 already has these settings. Nothing was changed.", "nothing: Apply of an unedited form", c.result)
        c.form?.apn = "cm net"
        c.applyProfile()
        check(c.result == profileProblem(1, c.form!)! + " Nothing was changed." && c.resultIsFailure,
              "nothing: Apply with a problem says the rule", c.result)
        c.enterPin("1234", shownAttempts: 3)
        check(c.result == "The SIM does not ask for its PIN now (SIM: ready). The PIN was not sent.",
              "nothing: Unlock when the SIM does not ask for its PIN", c.result)
        rig.driver = 7
        c.tick()
        rig.answerSettings(4, .success(listing()), .success(ready), "the driver on profile 7")
        c.applyProfile()
        check(c.result == "The modem does not list profile 7. Nothing was changed.", "nothing: Apply to a profile not listed", c.result)
        settle()
        check(rig.fake.calls == [.networkInfo, .profiles, .sim, .profiles, .sim], "nothing: none of them reached the service",
              "\(rig.fake.calls)")
        c.setTabShown(nil)
    }

    // enterPin: the PIN with the attempts the owner was shown; pinSentence, a refusal said as a failure;
    // the controller keeps no copy of the PIN; a malformed PIN or a SIM not asking sends nothing.
    static func pinEntry() {
        let pin = "97538642"
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.simAndApn)
        rig.answerSettings(1, .success(listing()), .success(asksPin(3)), "the first settings read")
        c.enterPin(pin, shownAttempts: 3)
        rig.waitForCall(3, "the PIN reaches the service")
        check(rig.fake.calls.last == .enterPin(pin, shownAttempts: 3), "pin: the PIN goes with the attempts the owner was shown")
        check(c.running == .pin && c.result == "Sending the PIN to the SIM…" && !c.pinEnabled, "pin: the running sentence", c.result)
        check(keepsNoCopy(c, of: pin), "pin: no stored property holds the PIN while it is checked")
        let taken = PinOutcome(accepted: true, sim: ready)
        rig.fake.releasePin(.success(taken))
        rig.waitForCall(4, "the tab is read again after the PIN")
        check(rig.fake.calls.last == .profiles, "pin: the SIM & APN tab is read again")
        check(c.result == pinSentence(taken) && !c.resultIsFailure, "pin: the accepted sentence", c.result)
        check(keepsNoCopy(c, of: pin), "pin: no stored property holds the PIN after the call")
        rig.fake.releaseProfiles(.success(listing()))
        rig.waitForCall(5, "sim()")
        rig.fake.releaseSim(.success(ready))
        pump(until: { c.running == nil }, "the read comes back")
        check(!c.pinEnabled && c.sim == ready, "pin: Unlock is off once the SIM is ready")
        c.enterPin(pin, shownAttempts: 3)
        settle()
        check(rig.fake.calls.count == 5, "pin: nothing is sent while the SIM does not ask for its PIN")
        check(c.result == "The SIM does not ask for its PIN now (SIM: ready). The PIN was not sent." && c.resultIsFailure,
              "pin: and it says why", c.result)
        c.setTabShown(nil)

        // A refused PIN, the last attempt, a failure, and a malformed PIN.
        let rig2 = Rig()
        let p = rig2.controller
        p.setTabShown(.simAndApn)
        rig2.answerSettings(1, .success(listing()), .success(asksPin(2)), "the first settings read")
        let other = "86420135"
        p.enterPin(other, shownAttempts: 2)
        rig2.waitForCall(3, "the PIN reaches the service")
        check(rig2.fake.calls.last == .enterPin(other, shownAttempts: 2), "pin: 2 attempts shown, 2 passed")
        let wrong = PinOutcome(accepted: false, sim: asksPin(1), refusal: "+CME ERROR: 16")
        rig2.fake.releasePin(.success(wrong))
        rig2.waitForCall(4, "the read after the refused PIN starts")
        check(p.sim == asksPin(1) && p.pinEnabled, "pin: the SIM read with the outcome is shown at once (1 attempt left)")
        rig2.fake.releaseProfiles(.success(listing()))
        rig2.waitForCall(5, "sim()")
        rig2.fake.releaseSim(.success(asksPin(1)))
        pump(until: { p.running == nil }, "the read comes back")
        check(p.result == pinSentence(wrong) && p.resultIsFailure, "pin: a refused PIN is said as a failure", p.result)
        check(keepsNoCopy(p, of: other), "pin: no stored property holds a refused PIN")

        p.enterPin(other, shownAttempts: 1)
        rig2.waitForCall(6, "the last attempt")
        check(rig2.fake.calls.last == .enterPin(other, shownAttempts: 1), "pin: the last attempt passes 1")
        rig2.fake.releasePin(.failure(notAnswered))
        rig2.answerSettings(7, .success(listing()), .success(asksPin(1)), "the read after the failure")
        check(p.result == notAnswered.message && p.resultIsFailure, "pin: a failure's sentence", p.result)

        p.enterPin("12a4", shownAttempts: 1)
        p.enterPin("123", shownAttempts: 1)
        settle()
        check(rig2.fake.calls.count == 8, "pin: a malformed PIN is not sent")
        check(p.result == "A PIN is 4 to 8 digits. The PIN was not sent." && p.resultIsFailure,
              "pin: a malformed PIN is refused with the rule", p.result)
        p.enterPin(other, shownAttempts: 0)
        settle()
        check(rig2.fake.calls.count == 8, "pin: nothing is sent when the confirmation showed no attempts left")
        check(p.result == "The SIM has no PIN attempts left: it needs its PUK from the carrier, and RMNet does not enter PUKs. "
              + "The PIN was not sent.", "pin: and it says why", p.result)
        p.enterPin(other, shownAttempts: 2)
        rig2.waitForCall(9, "attempts shown that differ from the SIM read")
        check(rig2.fake.calls.last == .enterPin(other, shownAttempts: 2), "pin: the attempts shown are passed unchanged (R13)")
        rig2.fake.releasePin(.failure(ModemFailure(message: "The SIM now shows 1 attempt left, not 2. The PIN was not sent.")))
        rig2.answerSettings(10, .success(listing()), .success(asksPin(1)), "the read after it")
        check(keepsNoCopy(p, of: other), "pin: still no copy afterwards")
        p.setTabShown(nil)
    }

    // Quitting: at once with nothing running; otherwise the line for what runs, then true after a read or
    // a change that succeeded, false (and attention, and working again) after one that failed.
    static func quitting() {
        do {
            let rig = Rig()
            let c = rig.controller
            c.setTabShown(.network)
            rig.answerInfo(1, .success(network("AUTO")), "the first read")
            check(c.quitWhenFinished() == false, "quit: nothing running answers at once (terminate now)")
            check(timer(of: c) == nil && c.quitNotice.line == "", "quit: the timer stops; no line")
            c.tick()
            c.refresh()
            c.setRadio(on: false)
            c.pickedMode = "LTE"
            c.changeMode()
            c.setWindowVisible(false)
            c.setWindowVisible(true)
            c.setTabShown(.simAndApn)
            settle()
            check(rig.fake.calls.count == 1 && rig.replies.isEmpty && rig.attention == 0 && timer(of: c) == nil,
                  "quit: nothing starts and no later reply", "\(rig.fake.calls)")
            check(!c.refreshEnabled && !c.modeChangeEnabled, "quit: nothing is enabled while the app ends")
        }

        struct Case {
            let name: String
            let tab: ModemTab
            let notice: String
            let goesAhead: Bool
            let calls: Int  // calls the activity makes
            let start: (ModemController) -> Void
            let end: (FakeService) -> Void
            let result: String?  // the result line after a failure
        }
        let reading = "RMNet quits when the current request to the modem has finished."
        let radioBack = "RMNet quits when the radio has been switched back on."
        let radioOffLine = "RMNet quits when the radio has been switched off."
        let modeLine = "RMNet quits when the network mode has been changed."
        let pinLine = "RMNet quits when the PIN has been checked."
        let edited = ProfileSettings(type: .ipv4v6, apn: "cmnet", user: "", password: "", auth: .none)
        let applied = ProfileChange(id: 1, before: profile1, after: edited, redial: .done(radioOn))
        let leftOff = ProfileChange(id: 1, before: profile1, after: edited, redial: .radioLeftOff("The modem did not answer in time."))
        let refusedPin = PinOutcome(accepted: false, sim: asksPin(2), refusal: "+CME ERROR: 16")
        let tick: (ModemController) -> Void = { $0.tick() }
        let apply: (ModemController) -> Void = { $0.form?.apn = "cmnet"; $0.applyProfile() }
        let changeMode: (ModemController) -> Void = { $0.pickedMode = "LTE"; $0.changeMode() }
        let unlock: (ModemController) -> Void = { $0.enterPin("24681357", shownAttempts: 3) }
        let cases: [Case] = [
            Case(name: "a network read", tab: .network, notice: reading, goesAhead: true, calls: 1, start: tick,
                 end: { $0.releaseInfo(.success(network("AUTO"))) }, result: nil),
            Case(name: "a network read that fails", tab: .network, notice: reading, goesAhead: true, calls: 1, start: tick,
                 end: { $0.releaseInfo(.failure(portBusy)) }, result: nil),
            Case(name: "a settings read", tab: .simAndApn, notice: reading, goesAhead: true, calls: 2, start: tick,
                 end: { $0.releaseProfiles(.success(listing())); $0.releaseSim(.success(asksPin(3))) }, result: nil),
            Case(name: "a radio switch", tab: .network, notice: radioBack, goesAhead: true, calls: 1,
                 start: { $0.setRadio(on: true) }, end: { $0.releaseRadio(.success(radioOn)) }, result: nil),
            Case(name: "a radio switch off", tab: .network, notice: radioOffLine, goesAhead: true, calls: 1,
                 start: { $0.setRadio(on: false) }, end: { $0.releaseRadio(.success(radioOff)) }, result: nil),
            Case(name: "a radio switch off that fails", tab: .network, notice: radioOffLine, goesAhead: false, calls: 1,
                 start: { $0.setRadio(on: false) }, end: { $0.releaseRadio(.failure(notAnswered)) }, result: notAnswered.message),
            Case(name: "a radio switch on that fails", tab: .network, notice: radioBack, goesAhead: false, calls: 1,
                 start: { $0.setRadio(on: true) }, end: { $0.releaseRadio(.failure(notAnswered)) }, result: notAnswered.message),
            Case(name: "a mode change", tab: .network, notice: modeLine, goesAhead: true, calls: 1, start: changeMode,
                 end: { $0.releaseMode(.success(ModeChange(before: "AUTO", after: "LTE"))) }, result: nil),
            Case(name: "a mode change that fails", tab: .network, notice: modeLine, goesAhead: false, calls: 1, start: changeMode,
                 end: { $0.releaseMode(.failure(refused)) }, result: refused.message),
            Case(name: "a profile change", tab: .simAndApn, notice: radioBack, goesAhead: true, calls: 1, start: apply,
                 end: { $0.releaseProfile(.success(applied)) }, result: nil),
            Case(name: "a profile change that fails", tab: .simAndApn, notice: radioBack, goesAhead: false, calls: 1, start: apply,
                 end: { $0.releaseProfile(.failure(notAnswered)) }, result: notAnswered.message),
            Case(name: "a profile change that left the radio off", tab: .simAndApn, notice: radioBack, goesAhead: false, calls: 1,
                 start: apply, end: { $0.releaseProfile(.success(leftOff)) }, result: profileSentence(leftOff)),
            Case(name: "a PIN taken", tab: .simAndApn, notice: pinLine, goesAhead: true, calls: 1, start: unlock,
                 end: { $0.releasePin(.success(PinOutcome(accepted: true, sim: ready))) }, result: nil),
            Case(name: "a PIN refused", tab: .simAndApn, notice: pinLine, goesAhead: false, calls: 1, start: unlock,
                 end: { $0.releasePin(.success(refusedPin)) }, result: pinSentence(refusedPin)),
            Case(name: "a PIN that fails", tab: .simAndApn, notice: pinLine, goesAhead: false, calls: 1, start: unlock,
                 end: { $0.releasePin(.failure(notAnswered)) }, result: notAnswered.message),
        ]
        for k in cases {
            let name = "quit during \(k.name)"
            let rig = Rig()
            let c = rig.controller
            c.setTabShown(k.tab)
            if k.tab == .network {
                rig.answerInfo(1, .success(network("AUTO")), "\(name): the first read")
            } else {
                rig.answerSettings(1, .success(listing()), .success(asksPin(3)), "\(name): the first read")
            }
            let before = rig.fake.calls.count
            k.start(c)
            rig.waitForCall(before + 1, "\(name): the call reaches the service")
            check(c.quitWhenFinished() == true, "\(name): the quit waits (terminate later)")
            check(c.quitNotice.line == k.notice, "\(name): the window's quit line", c.quitNotice.line)
            check(timer(of: c) == nil, "\(name): the timer stops")
            check(rig.replies.isEmpty, "\(name): no reply while the call runs", "\(rig.replies)")
            c.tick()
            c.refresh()
            k.end(rig.fake)
            pump(until: { !rig.replies.isEmpty }, "\(name): the reply")
            settle()
            check(rig.replies == [k.goesAhead], "\(name): replies \(k.goesAhead) exactly once", "\(rig.replies)")
            check(c.quitNotice.line == "", "\(name): the quit line goes when the call has finished", c.quitNotice.line)
            if k.goesAhead {
                check(rig.attention == 0, "\(name): no request for attention")
                check(rig.fake.calls.count == before + k.calls, "\(name): no read follows", "\(rig.fake.calls)")
                c.tick()
                c.refresh()
                settle()
                check(rig.fake.calls.count == before + k.calls && !c.refreshEnabled && timer(of: c) == nil,
                      "\(name): nothing starts while the app ends", "\(rig.fake.calls)")
            } else {
                check(rig.attention == 1, "\(name): asks for attention once", "\(rig.attention)")
                check(c.result == k.result && c.resultIsFailure, "\(name): the result line keeps the sentence", c.result)
                // The quit is cancelled: the controller works again and the shown tab is read at once.
                if k.tab == .network {
                    rig.answerInfo(before + 2, .success(network("AUTO")), "\(name): the tab is read again")
                } else {
                    rig.answerSettings(before + 2, .success(listing()), .success(asksPin(3)), "\(name): the tab is read again")
                }
                check(c.result == k.result, "\(name): the read after the cancelled quit leaves the result line", c.result)
                check(c.refreshEnabled && timer(of: c) != nil, "\(name): the controller works again after the cancelled quit")
                settle()
                check(rig.replies == [false] && rig.attention == 1, "\(name): still exactly one reply", "\(rig.replies)")
            }
            c.setTabShown(nil)
        }

        // A change waiting behind a read when the quit begins is dropped: it is never made, and the quit
        // waits only for the read (R12).
        do {
            let rig = Rig()
            let c = rig.controller
            c.setTabShown(.simAndApn)
            rig.answerSettings(1, .success(listing()), .success(asksPin(3)), "the first read")
            c.tick()
            rig.waitForCall(3, "a turn starts")
            c.form?.apn = "cmnet"
            c.applyProfile()
            check(c.result == waitingLine, "quit with a waiting change: the change waits", c.result)
            check(c.quitWhenFinished() == true, "quit with a waiting change: the quit waits for the read")
            check(c.quitNotice.line == reading, "quit with a waiting change: the line is the read's", c.quitNotice.line)
            check(c.result == "RMNet is quitting, so the change that waited for a read was not made." && c.resultIsFailure,
                  "quit with a waiting change: the result line says it was not made", c.result)
            rig.fake.releaseProfiles(.success(listing()))
            rig.fake.releaseSim(.success(asksPin(3)))
            pump(until: { !rig.replies.isEmpty }, "the reply")
            settle()
            check(rig.replies == [true] && rig.attention == 0, "quit with a waiting change: replies true once after the read",
                  "\(rig.replies)")
            check(rig.fake.calls == [.profiles, .sim, .profiles, .sim], "quit with a waiting change: it never reached the service",
                  "\(rig.fake.calls)")
            c.setTabShown(nil)
        }

        // A waiting change that has already started on the queue when the quit begins (the main thread has
        // not yet heard that the read finished): the quit waits for the change, with its line.
        do {
            let rig = Rig()
            let c = rig.controller
            c.setTabShown(.network)
            rig.answerInfo(1, .success(network("AUTO")), "the first read")
            c.tick()
            rig.waitForCall(2, "a turn starts")
            c.setRadio(on: false)
            rig.fake.releaseInfo(.success(network("AUTO")))
            waitOffMain(until: { rig.fake.calls.count == 3 && rig.fake.blocked == 1 }, "the change starts on the queue")
            check(c.running == .reading, "quit with a started change: the main thread has not heard yet")
            check(c.quitWhenFinished() == true, "quit with a started change: the quit waits")
            check(c.quitNotice.line == radioOffLine, "quit with a started change: the line is the change's", c.quitNotice.line)
            pump(until: { c.running == .radio }, "the main thread hears the read has finished")
            check(c.result == "Switching the radio off…" && rig.replies.isEmpty, "quit with a started change: it runs", c.result)
            rig.fake.releaseRadio(.success(radioOff))
            pump(until: { !rig.replies.isEmpty }, "the reply")
            settle()
            check(rig.replies == [true] && c.result == radioSentence(radioOff), "quit with a started change: replies true once after it",
                  "\(rig.replies)")
            check(rig.fake.calls.count == 3, "quit with a started change: no read follows", "\(rig.fake.calls)")
            c.setTabShown(nil)
        }
    }

    // resumeAfterCancelledQuit (the Messages controller cancelled the quit): working again, the timer
    // back if a tab is shown; a quit still waiting is cancelled too and never answered.
    static func resuming() {
        let rig = Rig()
        let c = rig.controller
        c.setTabShown(.network)
        rig.answerInfo(1, .success(network("AUTO")), "the first read")
        check(c.quitWhenFinished() == false, "resume: the quit answered at once")
        c.resumeAfterCancelledQuit()
        rig.answerInfo(2, .success(network("AUTO")), "resume: the shown tab is read at once")
        check(timer(of: c)?.timeInterval == 5 && c.refreshEnabled && c.quitNotice.line == "",
              "resume: the timer runs again and the controller works")

        c.tick()
        rig.waitForCall(3, "a turn starts")
        check(c.quitWhenFinished() == true, "resume: a quit waits for the turn")
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { rig.replies == [true] }, "the quit goes ahead")
        c.resumeAfterCancelledQuit()
        rig.answerInfo(4, .success(network("AUTO")), "resume after the quit went ahead: read at once")
        check(c.refreshEnabled && timer(of: c) != nil && rig.replies == [true] && rig.attention == 0,
              "resume: works again after the Messages controller cancelled")

        c.setTabShown(nil)
        _ = c.quitWhenFinished()
        c.resumeAfterCancelledQuit()
        settle()
        check(rig.fake.calls.count == 4 && timer(of: c) == nil && c.refreshEnabled,
              "resume: with no tab shown, nothing is read and no timer runs", "\(rig.fake.calls)")

        c.setTabShown(.network)
        rig.waitForCall(5, "the tab is read")
        check(c.quitWhenFinished() == true, "resume: a quit waits for the read")
        c.resumeAfterCancelledQuit()
        check(c.quitNotice.line == "", "resume: the quit line goes at once")
        rig.fake.releaseInfo(.success(network("AUTO")))
        pump(until: { c.running == nil }, "the read comes back")
        settle()
        check(rig.replies == [true] && rig.attention == 0, "resume: a cancelled quit that was waiting is never answered",
              "\(rig.replies)")
        check(rig.fake.calls.count == 5 && c.refreshEnabled && timer(of: c) != nil,
              "resume: the read is not doubled and the controller works", "\(rig.fake.calls)")
        c.setTabShown(nil)
    }
}
