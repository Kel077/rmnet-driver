// The app's settings besides the menu bar icon's (MenuBarIconPreference, MenuBarStatus.swift), each on until it is
// turned off in the Settings window (SettingsView.swift): switching SIM slots by itself (SimSlotWatch.swift), notifying
// about new text messages and showing their text in the notifications (MessageAlerts.swift). Kept in the app's user
// defaults; a change is in effect at once. Foundation only, so `make app-test` tests it.
import Combine
import Foundation

final class AppSettings: ObservableObject {
    static let simAutoSwitchKey = "simAutoSwitch"
    static let notifyMessagesKey = "notifyNewMessages"
    static let notificationTextKey = "notificationShowsText"

    private let defaults: UserDefaults

    /// Switch SIM slots automatically: when the slot in use has no usable SIM, try the other one once a modem attach.
    @Published var simAutoSwitch: Bool { didSet { defaults.set(simAutoSwitch, forKey: AppSettings.simAutoSwitchKey) } }
    /// Notify about new messages: check for them while RMNet runs, and post a notification for each.
    @Published var notifyMessages: Bool { didSet { defaults.set(notifyMessages, forKey: AppSettings.notifyMessagesKey) } }
    /// Show message text in notifications: the first lines of the text; off, only who sent it.
    @Published var notificationShowsText: Bool {
        didSet { defaults.set(notificationShowsText, forKey: AppSettings.notificationTextKey) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        func on(_ key: String) -> Bool { (defaults.object(forKey: key) as? Bool) ?? true }
        simAutoSwitch = on(AppSettings.simAutoSwitchKey)
        notifyMessages = on(AppSettings.notifyMessagesKey)
        notificationShowsText = on(AppSettings.notificationTextKey)
    }
}
