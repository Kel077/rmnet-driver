// The window's Network and SIM & APN tabs. Network: what the modem says about the network, the radio
// (Radio Off…, Radio On) and the network mode (Change…, Put Back). SIM & APN: the SIM (Unlock… while it
// asks for its PIN), the data profiles, and an editor for the profile the driver dials (Apply…, Put
// Back…). ModemController (ModemController.swift) holds the state, reads the shown tab and runs one call
// at a time; the rows, questions and sentences come from ModemNetwork.swift and ModemSettings.swift. Each
// change asks first, with words taken when its confirmation opens.
//
// Nothing here logs, prints or stores what is typed. The PIN is only in the SIM & APN tab's own state and
// is cleared as soon as its confirmation is confirmed or cancelled; the profile's password is only in the
// controller's form and is shown as dots.
import SwiftUI

/// The profile the driver dials: its RMNetProfile registry property; nil when it is not attached.
func driverProfileNumber() -> Int? {
    readDriverProperties()?["RMNetProfile"].flatMap { Int($0) }
}

/// The modem tab a window tab is; nil for the Driver and Messages tabs.
func modemTab(_ tab: WindowTab) -> ModemTab? {
    switch tab {
    case .network: return .network
    case .simAndApn: return .simAndApn
    case .driver, .messages: return nil
    }
}

// MARK: - Shared pieces

private let readTimeFormat: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm:ss"
    return f
}()

/// The tab's first line: "Updated HH:mm:ss." after a read that succeeded; after one that failed, its
/// sentence, and when values from an earlier read are on screen, that they may be out of date; before
/// the first read, `reading`.
private func readStatusLine(at: Date?, failure: String?, valuesShown: Bool, reading: String) -> String {
    let time = at.map { readTimeFormat.string(from: $0) }
    switch (failure, time) {
    case (nil, nil): return reading
    case (nil, let t?): return "Updated \(t)."
    case (let f?, let t?) where valuesShown: return "\(f) The values below may be out of date; they were read at \(t)."
    case (let f?, _): return valuesShown ? "\(f) The values below may be out of date." : f
    }
}

/// The read line (orange after a failed read) and Refresh.
private struct ReadStatus: View {
    let text: String
    let failed: Bool
    @ObservedObject var controller: ModemController

    var body: some View {
        HStack(alignment: .top) {
            Text(verbatim: text)
                .foregroundStyle(failed ? Color.orange : Color.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Refresh") { controller.refresh() }
                .disabled(!controller.refreshEnabled)
        }
    }
}

/// The result of the last change (or what runs or waits now), red on failure. A read never changes it.
private struct ResultLine: View {
    @ObservedObject var controller: ModemController

    var body: some View {
        if !controller.result.isEmpty {
            Text(verbatim: controller.result)
                .foregroundStyle(controller.resultIsFailure ? Color.red : Color.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Label and value in two columns; the values can be selected.
private struct RowsGrid: View {
    let rows: [(label: String, value: String)]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(verbatim: row.label)
                        .foregroundStyle(.secondary)
                    Text(verbatim: row.value)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A confirmation's words, taken when it opens (so a read that lands while it is open does not change
/// what the owner is asked), and the change it confirms.
private struct Question<Action> {
    let action: Action
    let title: String
    let message: String
    let confirm: String   // the confirm button's title
    var destructive = false
}

/// Shows `question` as a confirmation. The tab calls `setConfirming(true)` when it opens one. Confirming
/// calls `perform` first and then `setConfirming(false)`, so the change starts at once rather than after
/// the read that may be due (ruling R12); the confirm button is never turned off. Confirmed, cancelled or
/// dismissed, `closed` runs (the SIM & APN tab clears the PIN there).
private struct Confirmation<Action>: ViewModifier {
    @Binding var question: Question<Action>?
    let controller: ModemController
    let perform: (Action) -> Void
    let closed: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(question?.title ?? "",
                                isPresented: Binding(get: { question != nil }, set: { if !$0 { question = nil } }),
                                titleVisibility: .visible,
                                presenting: question) { q in
                Button(q.confirm, role: q.destructive ? .destructive : nil) {
                    perform(q.action)
                    closed()
                    controller.setConfirming(false)
                }
                Button("Cancel", role: .cancel) {
                    closed()
                    controller.setConfirming(false)
                }
            } message: { q in
                Text(verbatim: q.message)
            }
            // However it closed (also without a button): the PIN cleared, and the controller reads again.
            .onChange(of: question == nil) { _, isClosed in
                if isClosed {
                    closed()
                    controller.setConfirming(false)
                }
            }
    }
}

// MARK: - The Network tab

private enum NetworkAction { case radioOff, changeMode, putBack }

/// The radio's state as the Network tab's control shows it.
private func radioStateWords(_ radio: RadioState) -> String {
    switch radio {
    case .on: return "on"
    case .airplane: return "off (airplane mode)"
    case .minimum: return "minimum functionality"
    case .other(let n): return "AT+CFUN \(n)"
    }
}

struct NetworkTab: View {
    // The process's one controller, owned by the app delegate.
    @ObservedObject var controller: ModemController
    @State private var question: Question<NetworkAction>? = nil

    /// The picker's modes: the window's choices, then the modem's mode (or the pick) if it is another.
    private var modeChoices: [String] {
        var choices = networkModeChoices
        for mode in [controller.info?.mode, controller.pickedMode].compactMap({ $0 }) where !choices.contains(mode) {
            choices.append(mode)
        }
        return choices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReadStatus(text: readStatusLine(at: controller.infoAt, failure: controller.infoFailure,
                                      valuesShown: controller.info != nil, reading: "Reading the network…"),
                       failed: controller.infoFailure != nil, controller: controller)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let info = controller.info {
                        RowsGrid(rows: networkRows(info))
                        Divider()
                    }
                    radioControl
                    modeControl
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 14)  // room for the scroll bar
            }
            ResultLine(controller: controller)
        }
        .padding()
        .frame(minWidth: 480, minHeight: 420)
        .modifier(Confirmation(question: $question, controller: controller, perform: perform, closed: {}))
    }

    @ViewBuilder private var radioControl: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Radio")
                .font(.headline)
            if let radio = controller.info?.radio {
                Text(verbatim: radioStateWords(radio))
                Spacer()
                if radio == .on {
                    Button("Radio Off…") {
                        let q = radioOffQuestion()
                        ask(Question(action: .radioOff, title: q.title, message: q.message, confirm: "Switch Off",
                                     destructive: true))
                    }
                    .disabled(!controller.refreshEnabled)
                } else {
                    Button("Radio On") { controller.setRadio(on: true) }
                        .disabled(!controller.refreshEnabled)
                }
            } else {
                Text("not read")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    @ViewBuilder private var modeControl: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Network mode")
                .font(.headline)
            if controller.pickedMode != nil {
                Picker("Network mode", selection: $controller.pickedMode) {
                    ForEach(modeChoices, id: \.self) { mode in
                        Text(verbatim: modeWords(mode)).tag(Optional(mode))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!controller.refreshEnabled)
                Spacer()
                Button("Change…") {
                    guard let picked = controller.pickedMode else { return }
                    let q = modeQuestion(from: controller.info?.mode, to: picked)
                    ask(Question(action: .changeMode, title: q.title, message: q.message, confirm: "Change"))
                }
                .disabled(!controller.modeChangeEnabled)
            } else {
                Text("not read")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        if case .mode(let before)? = controller.undo {
            HStack {
                Spacer()
                Button("Put Back to \(modeWords(before))…") {
                    let from = controller.info?.mode.map { "The modem changes from \(modeWords($0)) back to \(modeWords(before)) at once" }
                        ?? "The current mode could not be read. The modem changes back to \(modeWords(before)) at once"
                    ask(Question(action: .putBack, title: "Put the network mode back to \(modeWords(before))?",
                                 message: "\(from); the connection can drop while it finds a network. "
                                    + "The modem keeps this setting, also after a restart.",
                                 confirm: "Put Back"))
                }
                .disabled(!controller.refreshEnabled)
            }
        }
    }

    private func ask(_ q: Question<NetworkAction>) {
        question = q
        controller.setConfirming(true)
    }

    private func perform(_ action: NetworkAction) {
        switch action {
        case .radioOff: controller.setRadio(on: false)
        case .changeMode: controller.changeMode()
        case .putBack: controller.putBack()
        }
    }
}

// MARK: - The SIM & APN tab

private enum SettingsAction {
    case apply
    case putBack
    case pin(attempts: Int)   // the attempts left the confirmation showed (ruling R13)
}

private func typeLabel(_ t: PdpType) -> String {
    switch t {
    case .ipv4: return "IPv4"
    case .ipv6: return "IPv6"
    case .ipv4v6: return "IPv4v6"
    }
}

private func authLabel(_ a: AuthMethod) -> String {
    switch a {
    case .none: return "None"
    case .pap: return "PAP"
    case .chap: return "CHAP"
    case .papOrChap: return "PAP or CHAP"
    }
}

/// The data profiles: id (the driver's marked), type, APN, authentication, user and whether a password
/// is set (never the password); "—" where a profile's settings were not read (the type then as
/// AT+CGDCONT? lists it).
private struct ProfilesTable: View {
    let profiles: [DataProfile]
    let driverProfile: Int

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                ForEach(["Profile", "Type", "APN", "Authentication", "User", "Password"], id: \.self) { title in
                    Text(verbatim: title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            ForEach(profiles, id: \.id) { p in
                let driver = p.id == driverProfile
                GridRow {
                    cell(driver ? "\(p.id) (driver's)" : "\(p.id)", driver)
                    cell(p.settings.map { typeLabel($0.type) } ?? p.pdpType, driver)
                    cell(p.apn.isEmpty ? "(none)" : p.apn, driver)
                    cell(p.settings.map { authLabel($0.auth) } ?? "—", driver)
                    cell(p.settings.map { $0.user.isEmpty ? "none" : modemTextSafe($0.user) } ?? "—", driver)
                    cell(p.settings.map { $0.password.isEmpty ? "none" : "set" } ?? "—", driver)
                }
            }
        }
    }

    private func cell(_ text: String, _ driver: Bool) -> some View {
        Text(verbatim: text)
            .fontWeight(driver ? .semibold : .regular)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SimApnTab: View {
    // The process's one controller, owned by the app delegate.
    @ObservedObject var controller: ModemController
    @State private var question: Question<SettingsAction>? = nil
    @State private var pin = ""   // only here; cleared when the confirmation closes or the tab goes

    private static let blockedSentence = "The SIM is blocked: it needs its PUK from the carrier, and RMNet does not enter PUKs."
    private static let applyWarning = "A wrong APN breaks the connection. Apply switches the radio off and on again "
        + "(a redial); the connection drops for about 10 to 30 seconds."

    /// A settings read has finished (succeeded or not), so the driver's profile number is known.
    private var settingsRead: Bool { controller.settingsAt != nil || controller.settingsFailure != nil }

    /// The driver's profile's settings in the last read.
    private var listedSettings: ProfileSettings? {
        controller.profiles.first(where: { $0.id == controller.profileID })?.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReadStatus(text: readStatusLine(at: controller.settingsAt, failure: controller.settingsFailure,
                                      valuesShown: controller.sim != nil || !controller.profiles.isEmpty,
                                      reading: "Reading the SIM and the data profiles…"),
                       failed: controller.settingsFailure != nil, controller: controller)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    simSection
                    Divider()
                    profilesSection
                    Divider()
                    editorSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 14)  // room for the scroll bar
            }
            ResultLine(controller: controller)
        }
        .padding()
        .frame(minWidth: 480, minHeight: 420)
        .modifier(Confirmation(question: $question, controller: controller, perform: perform, closed: { pin = "" }))
        .onChange(of: controller.sim?.state == .pin) { _, asks in
            if !asks { pin = "" }
        }
        .onDisappear { pin = "" }
    }

    // MARK: SIM

    @ViewBuilder private var simSection: some View {
        Text("SIM")
            .font(.headline)
        if let sim = controller.sim {
            RowsGrid(rows: simRows(sim))
            switch sim.state {
            case .pin: pinEntry(sim)
            case .puk: note(SimApnTab.blockedSentence)
            default: EmptyView()
            }
        } else {
            note(settingsRead ? "The SIM has not been read." : "Reading the SIM…")
        }
    }

    @ViewBuilder private func pinEntry(_ sim: SimInfo) -> some View {
        if let attempts = sim.pinAttempts, attempts >= 1 {
            HStack {
                SecureField("PIN", text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .frame(width: 140)
                    .disabled(!controller.pinEnabled)
                Button("Unlock…") { askPin() }
                    .disabled(!controller.pinEnabled || pinProblem(pin) != nil)
                Spacer()
            }
            if !pin.isEmpty, let problem = pinProblem(pin) {
                Text(verbatim: problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } else if sim.pinAttempts == nil {
            note("The attempts left could not be read; RMNet does not send a PIN without them.")
        } else {
            note(pinQuestion(attempts: 0).message)
        }
    }

    private func askPin() {
        guard controller.pinEnabled, let attempts = controller.sim?.pinAttempts, pinProblem(pin) == nil else { return }
        let q = pinQuestion(attempts: attempts)
        ask(Question(action: .pin(attempts: attempts), title: q.title, message: q.message, confirm: "Send PIN",
                     destructive: attempts == 1))
    }

    // MARK: Data profiles

    @ViewBuilder private var profilesSection: some View {
        Text("Data profiles")
            .font(.headline)
        if !controller.profiles.isEmpty {
            ProfilesTable(profiles: controller.profiles, driverProfile: controller.profileID)
        } else {
            note(settingsRead ? "The data profiles have not been read." : "Reading the data profiles…")
        }
        if settingsRead {
            note(controller.driverAttached
                 ? "The driver dials profile \(controller.profileID)."
                 : "The driver is not attached; it dials profile 1 unless set otherwise.")
        }
    }

    // MARK: The driver's profile

    /// A binding to one field of the controller's form (the editor is shown only while there is one).
    private func field<T>(_ key: WritableKeyPath<ProfileSettings, T>, _ empty: T) -> Binding<T> {
        Binding(get: { controller.form?[keyPath: key] ?? empty },
                set: { controller.form?[keyPath: key] = $0 })
    }

    /// Why there is no form for the driver's profile.
    private var noFormSentence: String {
        let id = controller.profileID
        if !settingsRead { return "Reading the settings of profile \(id)…" }
        if controller.profiles.isEmpty { return "The settings of profile \(id) have not been read." }
        guard controller.profiles.contains(where: { $0.id == id }) else { return "The modem does not list profile \(id)." }
        let empty = ProfileSettings(type: .ipv4v6, apn: "", user: "", password: "", auth: .none)
        return profileProblem(id, empty) ?? "The settings of profile \(id) could not be read."
    }

    @ViewBuilder private var editorSection: some View {
        Text("Profile \(controller.profileID), which the driver dials")
            .font(.headline)
        if let form = controller.form {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("APN")
                    TextField("APN", text: field(\.apn, ""), prompt: Text("none: the network chooses"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                GridRow {
                    Text("Type")
                    Picker("Type", selection: field(\.type, .ipv4v6)) {
                        ForEach(PdpType.allCases, id: \.self) { Text(verbatim: typeLabel($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Authentication")
                    Picker("Authentication", selection: field(\.auth, .none)) {
                        ForEach(AuthMethod.allCases, id: \.self) { Text(verbatim: authLabel($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("User")
                    TextField("User", text: field(\.user, ""), prompt: Text("none"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                GridRow {
                    Text("Password")
                    SecureField("Password", text: field(\.password, ""), prompt: Text("none"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
            }
            .disabled(!controller.refreshEnabled)
            note(SimApnTab.applyWarning)
            if let problem = profileProblem(controller.profileID, form) {
                Text(verbatim: problem)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Revert") { controller.revertForm() }
                    .disabled(!controller.formEdited || !controller.refreshEnabled)
                Button("Apply…") { askApply() }
                    .disabled(!controller.applyEnabled)
            }
        } else {
            note(noFormSentence)
        }
        if case .profile(let id, let before)? = controller.undo {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "Before the last change, profile \(id) was \(profileWords(before)).")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Put Back…") { askPutBack() }
                    .disabled(!controller.refreshEnabled)
            }
        }
    }

    private func askApply() {
        guard controller.applyEnabled, let form = controller.form else { return }
        let q = profileQuestion(id: controller.profileID, before: listedSettings, after: form)
        ask(Question(action: .apply, title: q.title, message: q.message, confirm: "Apply"))
    }

    private func askPutBack() {
        guard case .profile(let id, let before)? = controller.undo else { return }
        let now = controller.profiles.first(where: { $0.id == id })?.settings
        let q = profileQuestion(id: id, before: now, after: before)
        ask(Question(action: .putBack, title: "Put profile \(id) back?", message: q.message, confirm: "Put Back"))
    }

    // MARK: Confirmations

    private func ask(_ q: Question<SettingsAction>) {
        question = q
        controller.setConfirming(true)
    }

    private func perform(_ action: SettingsAction) {
        switch action {
        case .apply: controller.applyProfile()
        case .putBack: controller.putBack()
        case .pin(let attempts): controller.enterPin(pin, shownAttempts: attempts)
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
