// The Network and SIM & APN tabs' state and the calls they make to the modem: reads only while a tab is
// shown in a visible window, one call at a time, the result line of the last change, a way back (Put Back)
// for a mode or profile change, and quitting that waits for a running call. It takes any ModemServing,
// and the two AppKit calls it needs (the answer to the terminate question, the request for attention) and
// the driver's profile number are closures given by the app delegate, so it uses no AppKit or SwiftUI and
// is tested with a fake service (tests/app/ModemControllerTests.swift), as SmsController is.
//
// A PIN is passed to the service and never kept: no stored property holds it. A profile's old password is
// kept in memory only, in `undo` (ProfileSettings shows only whether one is set in any string conversion).
import Combine
import Foundation

/// The modem tab shown in the window.
enum ModemTab: Equatable { case network, simAndApn }

/// What is running on the service's queue; at most one call at a time.
enum ModemActivity: Equatable { case reading, radio, mode, profile, pin }

/// The way back from the last mode or profile change: the mode before (as the modem gave it, ruling R8), or
/// the profile's settings before, password included (in memory only).
enum ModemUndo: Equatable {
    case mode(String)
    case profile(id: Int, ProfileSettings)
}

/// The line the window shows above its tabs while a quit waits for a call to the modem; "" otherwise.
/// Its own object, so the window can show it without observing the whole controller.
final class ModemQuitNotice: ObservableObject {
    @Published fileprivate(set) var line = ""
}

/// The app has exactly one, owned by the app delegate, so that quitting can wait for a running call. Its
/// methods are called on the main thread; every service call runs on `queue` (shared with the Messages
/// tab, so the AT port is never opened twice at once), one at a time, with the result handed back to the
/// main thread.
final class ModemController: ObservableObject {
    @Published private(set) var info: NetworkInfo? = nil         // the last network read that succeeded
    @Published private(set) var infoAt: Date? = nil
    @Published private(set) var infoFailure: String? = nil       // the last network read's failure; nil after a success
    @Published private(set) var profiles: [DataProfile] = []     // the last profiles() that succeeded
    @Published private(set) var sim: SimInfo? = nil               // the last sim() that succeeded
    @Published private(set) var settingsAt: Date? = nil           // the last settings read whose two parts succeeded
    @Published private(set) var settingsFailure: String? = nil    // the last settings read's failure; nil after a success
    @Published private(set) var running: ModemActivity? = nil
    // The result of the last change (or what runs now). A read never writes here.
    @Published private(set) var result = ""
    @Published private(set) var resultIsFailure = false
    @Published private(set) var undo: ModemUndo? = nil
    @Published var form: ProfileSettings? = nil   // the editor's values for the driver's profile
    @Published var pickedMode: String? = nil      // the Network tab's picker

    let quitNotice = ModemQuitNotice()

    static let networkInterval: TimeInterval = 5
    static let settingsInterval: TimeInterval = 30

    private let service: ModemServing
    private let queue: DispatchQueue
    private let driverProfile: () -> Int?        // the driver's RMNetProfile; nil when it is not attached
    private let replyToQuit: (Bool) -> Void      // NSApp.reply(toApplicationShouldTerminate:)
    private let requestAttention: () -> Void     // NSApp.requestUserAttention(.criticalRequest)
    private var timer: Timer?
    private var timerTab: ModemTab?              // the tab the timer reads
    private var tab: ModemTab?                   // the modem tab shown; nil: neither
    private var windowVisible = true
    private var confirming = false               // a confirmation is open: nothing new is read
    private var stopping = false                 // the app is quitting: nothing new starts
    private var quitWaits = false                // a quit waits for the running call to finish
    private var readingTab: ModemTab?            // the tab the running read is for
    private var readWanted = false               // the shown tab is to be read as soon as nothing runs
    private var driverProfileRead: Int? = nil    // driverProfile() at the last settings refresh
    private var formSource: ProfileSettings? = nil  // the values `form` was last filled from
    private var pickedFrom: String? = nil        // the mode `pickedMode` was last set from

    init(service: ModemServing, queue: DispatchQueue, driverProfile: @escaping () -> Int?,
         replyToQuit: @escaping (Bool) -> Void, requestAttention: @escaping () -> Void) {
        self.service = service
        self.queue = queue
        self.driverProfile = driverProfile
        self.replyToQuit = replyToQuit
        self.requestAttention = requestAttention
    }

    deinit { timer?.invalidate() }

    /// The profile the driver dials, as read at the last settings refresh; 1 when it was not attached.
    var profileID: Int { driverProfileRead ?? 1 }
    /// The driver gave its profile number at the last settings refresh.
    var driverAttached: Bool { driverProfileRead != nil }
    /// The form differs from the values it was filled from.
    var formEdited: Bool { form != formSource }
    var applyEnabled: Bool {
        guard idle, formEdited, let form else { return false }
        return profileProblem(profileID, form) == nil
    }
    var modeChangeEnabled: Bool {
        guard idle, let picked = pickedMode, canonicalMode(picked) != nil else { return false }
        return picked != info?.mode
    }
    var pinEnabled: Bool {
        guard idle, let sim, sim.state == .pin, let attempts = sim.pinAttempts else { return false }
        return attempts >= 1
    }
    var refreshEnabled: Bool { idle }

    private var idle: Bool { running == nil && !stopping }

    /// The driver's profile's settings in the last profiles read; nil when it is not listed or not read.
    private var driverSettings: ProfileSettings? {
        profiles.first(where: { $0.id == profileID })?.settings
    }

    // MARK: When the modem is read

    /// The modem tab shown (nil: neither, also when the window closes).
    func setTabShown(_ tab: ModemTab?) {
        self.tab = tab
        updateTimer()
    }

    /// The window can be seen (true) or is minimized, hidden or covered (false).
    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        updateTimer()
    }

    /// While a confirmation is open the timer's turns skip and nothing new is read; a read that was due
    /// meanwhile starts when it closes.
    func setConfirming(_ open: Bool) {
        confirming = open
        readIfDue()
    }

    private var active: Bool { tab != nil && windowVisible && !stopping }

    // Reads the shown tab at once when it becomes active (or another tab is shown), then on each turn of
    // its timer (5 s Network, 30 s SIM & APN); stops when it is not active.
    private func updateTimer() {
        guard active, let tab else {
            timer?.invalidate()
            timer = nil
            timerTab = nil
            readWanted = false
            return
        }
        if timer != nil, timerTab == tab { return }
        timer?.invalidate()
        let interval = tab == .network ? ModemController.networkInterval : ModemController.settingsInterval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        timerTab = tab
        if running == .reading, readingTab == tab {
            readWanted = false  // the read running now is this tab's
        } else {
            readWanted = true
            readIfDue()
        }
    }

    /// Starts the read that is due, once nothing runs and no confirmation is open.
    private func readIfDue() {
        guard readWanted, active, !confirming, running == nil else { return }
        refresh()
    }

    /// One turn of the timer: skipped while a confirmation is open or a call runs.
    func tick() {
        guard active, !confirming else { return }
        refresh()
    }

    /// Reads what the shown tab needs, unless a call is already running: the Network tab networkInfo();
    /// the SIM & APN tab profiles() then sim(), in one block on the queue.
    func refresh() {
        guard running == nil, !stopping, let tab else { return }
        readWanted = false
        running = .reading
        readingTab = tab
        let service = self.service
        switch tab {
        case .network:
            queue.async {
                let read = service.networkInfo()
                DispatchQueue.main.async { self.finishNetwork(read) }
            }
        case .simAndApn:
            queue.async {
                let listed = service.profiles()
                let read = service.sim()
                DispatchQueue.main.async { self.finishSettings(listed, read) }
            }
        }
    }

    private func finishNetwork(_ outcome: Result<NetworkInfo, ModemFailure>) {
        running = nil
        readingTab = nil
        switch outcome {
        case .success(let read):
            info = read
            infoAt = Date()
            infoFailure = nil
            // The pick follows the modem unless the owner picked another mode.
            if pickedMode == nil || pickedMode == pickedFrom { setPick(read.mode) }
        case .failure(let failure):
            infoFailure = failure.message
        }
        finished(succeeded: true, changed: false)
    }

    private func finishSettings(_ listed: Result<[DataProfile], ModemFailure>, _ read: Result<SimInfo, ModemFailure>) {
        running = nil
        readingTab = nil
        let earlierProfile = profileID
        driverProfileRead = driverProfile()
        var failure: String? = nil
        switch listed {
        case .success(let found): profiles = found
        case .failure(let f): failure = f.message
        }
        switch read {
        case .success(let found): sim = found
        case .failure(let f): failure = failure ?? f.message
        }
        settingsFailure = failure
        if failure == nil { settingsAt = Date() }
        // The editor follows the modem unless the owner edited it; an edit for another profile than the
        // driver's now is dropped.
        if form == nil || !formEdited || profileID != earlierProfile { fillForm(driverSettings) }
        finished(succeeded: true, changed: false)
    }

    private func fillForm(_ settings: ProfileSettings?) {
        form = settings
        formSource = settings
    }

    private func setPick(_ mode: String?) {
        pickedMode = mode
        pickedFrom = mode
    }

    /// The form back to the driver's profile's settings as last read.
    func revertForm() {
        fillForm(driverSettings)
    }

    // MARK: Quitting

    /// Asked when the app is about to end. Stops the timer and anything new. With no call running it
    /// returns false and the app may end now. Otherwise it returns true, and once the running call has
    /// finished `replyToQuit` is called once (a change is never cut short): with true after a read or a
    /// change that succeeded; with false (the quit is cancelled, the app asks for attention and the
    /// controller works again) after a change that did not, so that the owner sees its result line.
    func quitWhenFinished() -> Bool {
        stopping = true
        updateTimer()
        guard let now = running else { return false }
        quitWaits = true
        quitNotice.line = quitWaitLine(now)
        return true
    }

    /// The quit was cancelled elsewhere (the Messages controller's call failed): working again, the shown
    /// tab read at once. A quit of this controller that still waited is cancelled too and never answered.
    func resumeAfterCancelledQuit() {
        stopping = false
        quitWaits = false
        quitNotice.line = ""
        updateTimer()
    }

    // Called by each finish after `running` is cleared; true when a quit was waiting (it is answered).
    private func answeredQuit(succeeded: Bool) -> Bool {
        guard quitWaits else { return false }
        quitWaits = false
        quitNotice.line = ""
        if succeeded {
            replyToQuit(true)
            return true
        }
        stopping = false
        replyToQuit(false)
        requestAttention()
        updateTimer()  // the app goes on: the shown tab is read again
        return true
    }

    // After every call: the quit's answer, else the shown tab read again after a change, or a read that
    // became due while the call ran.
    private func finished(succeeded: Bool, changed: Bool) {
        if answeredQuit(succeeded: succeeded) { return }
        if changed { readWanted = true }
        readIfDue()
    }

    // MARK: The changes

    /// True when a change may start now. While a read runs (a turn began just before the confirmation
    /// opened) the change is refused with `busy`; while a change runs nothing is said (its line stays).
    private func mayStart(busy: String) -> Bool {
        guard !stopping else { return false }
        if running == .reading { setResult(busy, failure: true) }
        return running == nil
    }

    private static let busyChange = "The modem was busy with another request. Nothing was changed; try again."

    /// Runs one call on the queue and hands its result to `finish` on the main thread.
    private func run<T>(_ activity: ModemActivity, _ call: @escaping (ModemServing) -> Result<T, ModemFailure>,
                        then finish: @escaping (Result<T, ModemFailure>) -> Void) {
        running = activity
        let service = self.service
        queue.async {
            let outcome = call(service)
            DispatchQueue.main.async { finish(outcome) }
        }
    }

    /// Switches the radio on (AT+CFUN=1) or off (AT+CFUN=4). No undo: the other switch is the way back.
    func setRadio(on: Bool) {
        guard mayStart(busy: ModemController.busyChange) else { return }
        setResult(on ? "Switching the radio on…" : "Switching the radio off…", failure: false)
        run(.radio, { $0.setRadio(on: on) }) { outcome in
            self.running = nil
            switch outcome {
            case .success(let change): self.setResult(radioSentence(change), failure: false)
            case .failure(let failure): self.setResult(failure.message, failure: true)
            }
            self.finished(succeeded: (try? outcome.get()) != nil, changed: true)
        }
    }

    /// Changes the network mode to `pickedMode`.
    func changeMode() {
        guard mayStart(busy: ModemController.busyChange) else { return }
        guard let mode = pickedMode, canonicalMode(mode) != nil, mode != info?.mode else { return }
        setResult("Changing the network mode to \(modeWords(mode))…", failure: false)
        run(.mode, { $0.setMode(mode) }) { self.finishMode($0, puttingBack: false) }
    }

    private func finishMode(_ outcome: Result<ModeChange, ModemFailure>, puttingBack: Bool) {
        running = nil
        switch outcome {
        case .success(let change):
            if puttingBack {
                undo = nil
            } else {
                // Put Back only for a mode RMNet can set again (ruling R8).
                undo = canonicalMode(change.before) != nil ? .mode(change.before) : nil
            }
            setPick(change.after)
            setResult(modeSentence(change), failure: false)
        case .failure(let failure):
            setPick(info?.mode)
            setResult(failure.message, failure: true)
        }
        finished(succeeded: (try? outcome.get()) != nil, changed: true)
    }

    /// Writes the form to the driver's profile, with a redial (the service switches the radio off and on
    /// again when it was on).
    func applyProfile() {
        guard mayStart(busy: ModemController.busyChange) else { return }
        guard let settings = form, formEdited, profileProblem(profileID, settings) == nil else { return }
        let id = profileID
        setResult("Changing profile \(id)…", failure: false)
        run(.profile, { $0.setProfile(id, to: settings, redial: true) }) { self.finishProfile($0, id: id, puttingBack: false) }
    }

    private func finishProfile(_ outcome: Result<ProfileChange, ModemFailure>, id: Int, puttingBack: Bool) {
        running = nil
        let succeeded: Bool
        switch outcome {
        case .success(let change):
            undo = puttingBack ? nil : .profile(id: id, change.before)
            // The editor shows what the modem now has; the read that follows fills it again.
            fillForm(id == profileID ? change.after : driverSettings)
            // The profile was changed, but a radio left off is said as a failure: the connection is down.
            if case .radioLeftOff = change.redial { succeeded = false } else { succeeded = true }
            setResult(profileSentence(change), failure: !succeeded)
        case .failure(let failure):
            fillForm(driverSettings)
            setResult(failure.message, failure: true)
            succeeded = false
        }
        finished(succeeded: succeeded, changed: true)
    }

    /// Applies the undo the way the change was made (a profile put back redials); clears it on success.
    func putBack() {
        guard mayStart(busy: ModemController.busyChange) else { return }
        guard let undo else { return }
        switch undo {
        case .mode(let mode):
            setResult("Putting the network mode back to \(modeWords(mode))…", failure: false)
            run(.mode, { $0.setMode(mode) }) { self.finishMode($0, puttingBack: true) }
        case .profile(let id, let settings):
            setResult("Putting profile \(id) back…", failure: false)
            run(.profile, { $0.setProfile(id, to: settings, redial: true) }) { self.finishProfile($0, id: id, puttingBack: true) }
        }
    }

    /// Sends the PIN with the attempts left the owner was shown (the service sends nothing unless the SIM
    /// still shows that many). The PIN is not kept: only the call on the queue holds it, until it returns.
    func enterPin(_ pin: String) {
        guard mayStart(busy: "The modem was busy with another request. The PIN was not sent; enter it again.") else { return }
        guard let sim, sim.state == .pin, let shown = sim.pinAttempts, shown >= 1 else { return }
        if let problem = pinProblem(pin) {
            setResult(problem, failure: true)
            return
        }
        setResult("Sending the PIN to the SIM…", failure: false)
        run(.pin, { $0.enterPin(pin, shownAttempts: shown) }) { outcome in
            self.running = nil
            let succeeded: Bool
            switch outcome {
            case .success(let checked):
                succeeded = checked.accepted  // a refused PIN is said as a failure
                self.setResult(pinSentence(checked), failure: !succeeded)
            case .failure(let failure):
                succeeded = false
                self.setResult(failure.message, failure: true)
            }
            self.finished(succeeded: succeeded, changed: true)
        }
    }

    private func setResult(_ line: String, failure: Bool) {
        result = line
        resultIsFailure = failure
    }
}

private func quitWaitLine(_ activity: ModemActivity) -> String {
    switch activity {
    case .radio, .profile: return "RMNet quits when the radio has been switched back on."
    case .mode: return "RMNet quits when the network mode has been changed."
    case .pin: return "RMNet quits when the PIN has been checked."
    case .reading: return "RMNet quits when the current request to the modem has finished."
    }
}
