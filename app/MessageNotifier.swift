// The notifications for new text messages (MessageAlerts.swift decides which): posted with UNUserNotificationCenter,
// whose permission is asked the first time one is to be posted. A notification for a message carries only an opaque
// identifier; which message it was is kept in memory here, so that a click shows that message on the Messages screen
// (after the app restarts the identifier means nothing, and the click shows the Messages screen). Nothing here logs or
// stores message text or numbers: they go to the system's notification, which keeps it in Notification Center until it
// is cleared (Settings' Show message text in notifications leaves the text out).
import AppKit
import UserNotifications

final class MessageNotifier: NSObject, UNUserNotificationCenterDelegate {
    private var asked = false
    private var allowed = false
    private var waiting: [UNNotificationRequest] = []
    private var messages: [String: SmsIdentity] = [:]    // a notification's identifier → its message; memory only

    /// What a click does: show the window at the Messages screen, with the message (nil: the summary) selected.
    var open: (SmsIdentity?) -> Void = { _ in }

    /// Posts `alert`, with the message's first lines when `showText`; asks for permission the first time.
    func post(_ alert: MessageAlert, showText: Bool) {
        let words = alertContent(alert, showText: showText)
        let content = UNMutableNotificationContent()
        content.title = words.title
        content.body = words.body
        content.sound = .default
        content.threadIdentifier = "messages"
        let id = UUID().uuidString
        if case .message(let m) = alert { messages[id] = SmsIdentity(m) }
        content.userInfo = ["rmnet": id]
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        guard asked else {
            asked = true
            waiting.append(request)
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                DispatchQueue.main.async {
                    self.allowed = granted
                    if granted { self.waiting.forEach { UNUserNotificationCenter.current().add($0) } }
                    self.waiting = []
                }
            }
            return
        }
        if waiting.isEmpty && !allowed {
            // Asked before and not allowed (it may have been allowed in System Settings since): ask the system again.
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                DispatchQueue.main.async {
                    self.allowed = ok
                    if ok { UNUserNotificationCenter.current().add(request) }
                }
            }
            return
        }
        if allowed { UNUserNotificationCenter.current().add(request) } else { waiting.append(request) }
    }

    // Shown also while RMNet is the active app (its window may be on another screen than Messages).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["rmnet"] as? String
        DispatchQueue.main.async {
            self.open(id.flatMap { self.messages[$0] })
            completionHandler()
        }
    }
}
