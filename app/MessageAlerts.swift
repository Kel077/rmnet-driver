// New text messages while RMNet runs: when to list them, which ones are new, and what a notification says. The app's
// background turn (ModemPulse.swift) reads only the message store's count (AT+CPMS?) every 30 s; when it went up the
// messages are listed (SmsController), and each new one, unread, gets a notification (MessageNotifier.swift). The first
// listing after the app starts is the baseline: what is already there is not announced one by one, only the unread
// count, in one notification. A message is one notification, also when its parts come in at different times: it is
// known by its sender and the time of its earliest part (SmsModel.swift's assembly), which a later part does not
// change. Foundation only (tests/app/MessageAlertsTests.swift); nothing here logs or stores message text or numbers.
import Foundation

/// A message across listings for the notifications: its sender and its earliest part's time (its stored indices
/// without a time). A part that arrives later changes the indices (SmsMessageKey), not this.
struct SmsIdentity: Hashable {
    let sender: String
    let timestamp: Date?
    let indices: [Int]          // only when there is no time

    init(_ m: SmsMessage) {
        sender = m.sender
        timestamp = m.timestamp
        indices = m.timestamp == nil ? m.indices : []
    }
}

/// What a listing gives to announce: the unread messages already there when RMNet started (one summary), or a new one.
enum MessageAlert: Equatable {
    case summary(unread: Int)
    case message(SmsMessage)
}

struct NewMessageWatch: Equatable {
    private(set) var started = false            // the first listing (the baseline) has been seen
    private(set) var baseline: Int? = nil       // the store's count at the last listing
    private(set) var known: Set<SmsIdentity> = []

    /// After AT+CPMS?: whether to list the messages now: before the first listing, or when the count went up. A count
    /// that went down (messages deleted elsewhere) becomes the baseline. nil (not read): nothing.
    mutating func storeCount(_ used: Int?) -> Bool {
        guard let used else { return false }
        guard started, let baseline else { return true }
        if used < baseline { self.baseline = used }
        return used > baseline
    }

    /// After any listing (the background's or the Messages screen's): the first gives the summary of the unread
    /// messages (none when there are none); a later one each message not seen before that the modem listed unread,
    /// oldest first. Every message listed is known from then on.
    mutating func listed(_ messages: [SmsMessage], used: Int?) -> [MessageAlert] {
        defer {
            known.formUnion(messages.map(SmsIdentity.init))
            if let used { baseline = used }
            started = true
        }
        guard started else {
            let unread = messages.filter { $0.unread }.count
            return unread > 0 ? [.summary(unread: unread)] : []
        }
        let fresh = messages.filter { $0.unread && !known.contains(SmsIdentity($0)) }
        return fresh.reversed().map { .message($0) }     // the listing is newest first
    }
}

/// A notification's words: for a message its sender (or `Unknown sender`) and, with `showText`, the first two lines of
/// its text (at most 160 characters; `1 part missing` after it when one is), else `New message`; for the summary
/// `RMNet` and how many unread messages the modem has.
func alertContent(_ alert: MessageAlert, showText: Bool) -> (title: String, body: String) {
    switch alert {
    case .summary(let n):
        return ("RMNet", "\(n) unread \(n == 1 ? "message" : "messages") on the modem.")
    case .message(let m):
        let title = m.sender.isEmpty ? "Unknown sender" : m.sender
        guard showText, m.readable, !m.text.isEmpty else { return (title, "New message") }
        let lines = m.text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).prefix(2)
        var body = lines.joined(separator: "\n")
        if body.count > 160 { body = String(body.prefix(159)) + "…" }
        if m.missingParts > 0 { body += " (\(m.missingParts) \(m.missingParts == 1 ? "part" : "parts") missing)" }
        return (title, body)
    }
}

/// The menu bar panel's line: "1 unread message", "3 unread messages"; "" with none.
func unreadLine(_ n: Int) -> String {
    n > 0 ? "\(n) unread \(n == 1 ? "message" : "messages")" : ""
}
