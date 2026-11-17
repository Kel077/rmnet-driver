// The window's SIM & APN tab: the SIM (Unlock… while it asks for its PIN), the data profiles, and an editor for
// the profile the driver dials (Apply…, Put Back…). ModemController (ModemController.swift) holds the state,
// reads the shown tab and runs one call at a time; the rows, questions and sentences come from
// ModemSettings.swift. Apply…, the profile's Put Back… and Unlock… ask first, with words taken when their
// confirmation opens (ModemViewParts.swift).
//
// Nothing here logs, prints or stores what is typed. The PIN is only in the SIM & APN tab's own state and
// is cleared as soon as its confirmation is confirmed or cancelled; the profile's password is only in the
// controller's form and is shown as dots.
import SwiftUI

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
    // The last-attempt checkbox (ruling R20): unticked each time it appears, and when the confirmation closes
    // (after every Unlock… or cancel) or the tab goes.
    @State private var lastAttempt = false

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
        .modifier(Confirmation(question: $question, controller: controller, perform: perform, closed: {
            pin = ""
            lastAttempt = false
        }))
        .onChange(of: controller.sim?.state == .pin) { _, asks in
            if !asks {
                pin = ""
                lastAttempt = false
            }
        }
        .onDisappear {
            pin = ""
            lastAttempt = false
        }
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
                    .disabled(!controller.pinEnabled
                              || !unlockAllowed(pin: pin, attempts: attempts, lastAttemptTicked: lastAttempt))
                Spacer()
            }
            if attempts == 1 {
                // The last attempt needs this extra step, as `RMNet sim unlock` needs --last-attempt (ruling R20).
                Toggle(lastAttemptChoice, isOn: $lastAttempt)
                    .toggleStyle(.checkbox)
                    .disabled(!controller.pinEnabled)
                    .onAppear { lastAttempt = false }
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
        guard controller.pinEnabled, let attempts = controller.sim?.pinAttempts,
              unlockAllowed(pin: pin, attempts: attempts, lastAttemptTicked: lastAttempt) else { return }
        let q = pinQuestion(attempts: attempts)
        ask(Question(action: .pin(attempts: attempts), title: q.title, message: q.message, confirm: "Send PIN",
                     destructive: attempts == 1, cancelIsDefault: true))
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
        return profileNumberProblem(id) ?? "The settings of profile \(id) could not be read."
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
            if let command = controller.undoCommand { PutBackCommand(command: command) }
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
