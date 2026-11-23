// Tests for app/SmsConversations.swift: which conversation a number belongs to, the conversations (one a number, the
// latest first, unread counts), the order within one (a sent message by the time RMNet sent it, else after the messages
// stored before it), the previews, the sent status words, the heading and the delete question. Built with swiftc by
// `make app-test` from app/SmsModel.swift, app/SmsConversations.swift and this file. Every number and text is made up.
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

func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    check(got == want, name, "got \(got)\nwant \(want)")
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func received(_ index: Int, _ from: String, at seconds: TimeInterval, _ text: String = "Made-up", unread: Bool = false) -> SmsMessage {
    SmsMessage(indices: [index], unread: unread, sender: from, timestamp: t0.addingTimeInterval(seconds), text: text,
               missingParts: 0, readable: true)
}

func sent(_ indices: [Int], to: String, _ text: String = "Made-up reply", box: SmsBox = .sent) -> SmsMessage {
    SmsMessage(indices: indices, unread: false, sender: to, timestamp: nil, text: text, missingParts: 0, readable: true,
               box: box, unsentIndices: box == .unsent ? indices : [])
}

@main
struct SmsConversationsTests {
    static func main() {
        keys()
        grouping()
        order()
        words()
        print("conversations: \(checks) checks passed")
    }

    static func keys() {
        equal(conversationKey("+15555550100"), "5555550100", "key: the last 10 digits")
        equal(conversationKey("5555550100"), "5555550100", "key: a national number")
        equal(conversationKey("+1 (555) 555-0100"), "5555550100", "key: spaces and punctuation")
        equal(conversationKey("55555"), "55555", "key: a short number")
        equal(conversationKey("T-Mobile"), "t-mobile", "key: a name, lower case")
        equal(conversationKey("12a34"), "12a34", "key: digits and letters is a name")
        equal(conversationKey(""), "", "key: none")
    }

    // One conversation a number (an international and a national form together), the latest first, unread counted.
    static func grouping() {
        let a1 = received(0, "+15555550100", at: 0, unread: true)
        let a2 = sent([1], to: "5555550100")
        let b1 = received(2, "T-Mobile", at: 500)
        let a3 = received(3, "+15555550100", at: 1000, unread: true)
        let unread: Set<SmsMessageKey> = [a1.key, a3.key]
        let list = conversations([a3, b1, a2, a1], unread: unread, sentAt: [:])
        equal(list.map { $0.id }, ["5555550100", "t-mobile"], "grouping: two conversations, the latest first")
        equal(list[0].messages, [a1, a2, a3], "grouping: received and sent together, in order")
        equal(list[0].unread, 2, "grouping: unread counted")
        equal(list[0].number, "+15555550100", "grouping: the latest message's number")
        equal(list[0].storedParts, 3, "grouping: stored parts")
        equal(list[1].unread, 0, "grouping: none unread")

        // A conversation of sent messages only, with no time: by its index among the rest.
        let lone = sent([9], to: "+15555550199")
        let withLone = conversations([a3, b1, lone, a1], unread: [], sentAt: [:])
        equal(withLone.map { $0.id }, ["5555550100", "t-mobile", "5555550199"], "grouping: no time at all goes last")
        let timed = conversations([a3, b1, lone, a1], unread: [], sentAt: [9: t0.addingTimeInterval(2000)])
        equal(timed.first?.id, "5555550199", "grouping: sent just now goes first")
        equal(conversations([], unread: [], sentAt: [:]), [], "grouping: none")
    }

    // Within one: by time; a sent message without one after the messages stored before it; by RMNet's time when known.
    static func order() {
        let r1 = received(2, "+15555550100", at: 100)
        let s1 = sent([3], to: "+15555550100", "First reply")
        let r2 = received(5, "+15555550100", at: 200)
        let s2 = sent([6], to: "+15555550100", "Second reply")
        let ordered = conversationOrder([s2, r2, s1, r1], sentAt: [:]).map { $0.message }
        equal(ordered, [r1, s1, r2, s2], "order: each reply after the message stored before it")

        // An index reused after a deletion: a reply stored at a low index, sent now, by RMNet's time.
        let early = sent([0], to: "+15555550100", "Sent now")
        let byTime = conversationOrder([r1, r2, early], sentAt: [0: t0.addingTimeInterval(300)]).map { $0.message }
        equal(byTime, [r1, r2, early], "order: the time RMNet sent it, not the index")
        let byIndex = conversationOrder([r1, r2, early], sentAt: [:]).map { $0.message }
        equal(byIndex, [early, r1, r2], "order: without a time, by the index (a known limit)")
        equal(messageTime(early, sentAt: [0: t0]), t0, "time: sent, known")
        check(messageTime(early, sentAt: [:]) == nil, "time: sent, not known")
        equal(messageTime(r1, sentAt: [2: t0.addingTimeInterval(9999)]), r1.timestamp, "time: received, its own")
    }

    static func words() {
        let c = SmsConversation(id: "x", number: "+15555550100",
                                messages: [received(0, "+15555550100", at: 0, "Line one\nLine two"), sent([1], to: "+15555550100", "Okay\nmore")],
                                unread: 0)
        equal(conversationPreview(c), "You: Okay", "preview: sent, first line")
        let r = SmsConversation(id: "x", number: "+15555550100", messages: [received(0, "+15555550100", at: 0, "Hi\nthere")],
                                unread: 1)
        equal(conversationPreview(r), "Hi", "preview: received")
        let empty = SmsConversation(id: "x", number: "", messages: [SmsMessage(indices: [0], unread: false, sender: "",
                                    timestamp: nil, text: "", missingParts: 0, readable: false)], unread: 0)
        equal(conversationPreview(empty), "Not readable", "preview: not readable")

        let fmt: (Date) -> String = { _ in "14:05" }
        check(sentStatusWords(received(0, "x", at: 0), sentAt: [:], time: fmt) == nil, "status: received, none")
        equal(sentStatusWords(sent([1], to: "x"), sentAt: [:], time: fmt), "Sent", "status: sent, no time")
        equal(sentStatusWords(sent([1], to: "x"), sentAt: [1: t0], time: fmt), "Sent 14:05", "status: sent, with the time")
        equal(sentStatusWords(sent([1], to: "x", box: .unsent), sentAt: [1: t0], time: fmt), "Not sent", "status: not sent")

        equal(conversationCountLine(count: 0, unread: 0), "", "heading: none")
        equal(conversationCountLine(count: 1, unread: 0), "1 conversation", "heading: one")
        equal(conversationCountLine(count: 3, unread: 2), "3 conversations · 2 unread", "heading: unread")

        let q = deleteConversationQuestion(c)
        equal(q.title, "Delete the conversation with +15555550100?", "delete: title")
        equal(q.message, "2 messages (2 stored parts) will be deleted from the modem. This cannot be undone.", "delete: message")
    }
}
