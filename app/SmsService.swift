// Text messages on the modem: lists, deletes and sends them over the spare AT port, with the model in
// SmsModel.swift doing all the reading and writing of PDUs. Each call opens the port, works and closes
// it, also on failure; a port is never used again after a failure other than the modem's own refusal (AtPort closes
// itself on a timeout). Calls are synchronous and must not be made on the main thread. Nothing here logs or stores
// message text or numbers on the Mac: they go only to the caller, and to the modem's own store.
//
// A message is sent from the modem's store (3GPP TS 27.005; Quectel's AT manual for the RM520N series, 8.10 and
// 8.11): each part is written with AT+CMGW (stored "unsent"), then sent with AT+CMSS, after which the modem keeps it
// as "sent". So a sent message is listed with the received ones (AT+CMGL), by the window and by `RMNet sms list`, and
// a part whose AT+CMSS failed stays stored as "unsent", for Retry (resend) or Delete. The modem gives a stored
// SMS-SUBMIT no time. When the modem lists one storage and writes to another (AT+CPMS: <mem1> differs from <mem2>), a
// stored message would never be listed, so the message is sent directly with AT+CMGS, as before, and not stored.
//
// The window deletes and sends again what it listed, by stored index; another program (`RMNet sms delete`, say) may
// have changed the store since, and the modem fills the lowest free index, so an index can hold another message by
// then. So a delete or a Retry from the window first checks, in the same session, that the module, the SIM and the
// storages are those of the listing and that every part is still there as listed (AT+CMGL=1, 2 and 3, which change no
// status: only an unread entry that is listed is made read, 8.6); if not, it does nothing and the window lists again.
//
// AT+CMGL and AT+CMGR have no mode that leaves an unread message unread in the RM520N's manual (8.6, 8.7: listing or
// reading a "REC UNREAD" entry makes it "REC READ"), so the background check for new messages never lists or reads one:
// countUnread counts the entries that are not unread (AT+CMGL=1, 2, 3) and takes them from the store's count.
import Foundation

/// The port the service talks to: AtPort, or a scripted port in the tests.
protocol SmsPort: AnyObject {
    func command(_ line: String, timeout: TimeInterval) -> Result<[String], AtError>
    func send(_ line: String, afterPrompt payload: String, timeout: TimeInterval) -> Result<[String], AtError>
    func close()
    /// The module the port is open on (AtPort.deviceSerial).
    var deviceSerial: String? { get }
}

extension AtPort: SmsPort {}

/// One open port and the failure that ended its use: after anything but the modem's own refusal nothing more is sent
/// on it (AtPort has closed itself after a timeout, and after an I/O error the port is not trusted); a later command
/// fails at once with that failure.
private final class SmsSession {
    let port: SmsPort
    private(set) var broken: AtError?

    init(_ port: SmsPort) { self.port = port }

    var usable: Bool { broken == nil }

    func command(_ line: String, timeout: TimeInterval) -> Result<[String], AtError> {
        note(broken.map { .failure($0) } ?? port.command(line, timeout: timeout))
    }

    func send(_ line: String, afterPrompt payload: String, timeout: TimeInterval) -> Result<[String], AtError> {
        note(broken.map { .failure($0) } ?? port.send(line, afterPrompt: payload, timeout: timeout))
    }

    private func note(_ result: Result<[String], AtError>) -> Result<[String], AtError> {
        if case .failure(let error) = result, broken == nil, !isModemRefusal(error) { broken = error }
        return result
    }
}

private func isModemRefusal(_ error: AtError) -> Bool {
    if case .modem = error { return true }
    return false
}

final class SmsService: SmsServing {
    private static let readTimeout: TimeInterval = 3
    private static let listTimeout: TimeInterval = 15    // up to 255 stored entries
    private static let deleteTimeout: TimeInterval = 10
    private static let writeTimeout: TimeInterval = 10   // AT+CMGW: the manual says 300 ms
    private static let sendTimeout: TimeInterval = 120   // per part: AT+CMGS and AT+CMSS, "120 s, determined by network"

    private let openPort: () -> Result<SmsPort, AtError>

    /// `waitForPort` false: a port another program holds fails as busy at once (AtPort.openWithoutWaiting), for the
    /// app's background count of new messages, which then tries again on a later turn.
    convenience init(waitForPort: Bool = true) {
        self.init(open: waitForPort ? { AtPort.open().map { $0 as SmsPort } }
                                    : { AtPort.openWithoutWaiting().map { $0 as SmsPort } })
    }

    init(open: @escaping () -> Result<SmsPort, AtError>) {
        openPort = open
    }

    // The listing, then the store's use and storages (AT+CPMS?) and the SIM (AT+CIMI) in the same session; if those
    // cannot be read the listing still succeeds, without them (its place is then not complete: nothing listed can be
    // deleted or sent again from the window until a listing has them).
    func list() -> Result<SmsListing, SmsFailure> {
        let port: SmsPort
        switch openPort() {
        case .success(let p): port = p
        case .failure(let error): return .failure(SmsFailure(message: describe(error)))
        }
        defer { port.close() }
        let session = SmsSession(port)
        if let failure = usePduMode(session) { return .failure(failure) }
        switch session.command("AT+CMGL=4", timeout: SmsService.listTimeout) {
        case .success(let lines):
            let parts = parseListing(lines)
            let messages = assemble(parts.map(decodePart))
            var store: (used: Int, total: Int)? = nil
            var place = SmsPlace(device: port.deviceSerial)
            switch readPlace(session) {
            case .success(let read):
                store = read.store
                place = read.place
            case .failure:
                place.complete = false
            }
            return .success(SmsListing(messages: messages, used: store?.used, total: store?.total, parts: parts,
                                       place: place))
        case .failure(let error):
            return .failure(SmsFailure(message: "The messages could not be listed. \(describe(error))"))
        }
    }

    // Each index once, the first of each kept; the count is of the deletes the modem answered "OK".
    func delete(indices given: [Int]) -> Result<Int, SmsFailure> {
        var seen = Set<Int>()
        let indices = given.filter { seen.insert($0).inserted }
        guard !indices.isEmpty else { return .success(0) }
        guard indices.allSatisfy({ $0 >= 0 }) else {
            return .failure(SmsFailure(message: "A stored index is negative. Nothing was deleted."))
        }
        let port: SmsPort
        switch openPort() {
        case .success(let p): port = p
        case .failure(let error): return .failure(SmsFailure(message: "\(describe(error)) Nothing was deleted."))
        }
        defer { port.close() }
        return deleteEach(indices, on: SmsSession(port))
    }

    /// The window's delete: every part checked first (checkListed), then deleted as `delete(indices:)` does.
    func delete(_ parts: [StoredPdu], listedFrom place: SmsPlace) -> Result<Int, SmsFailure> {
        var seen = Set<Int>()
        let targets = parts.filter { seen.insert($0.index).inserted }
        guard !targets.isEmpty else { return .success(0) }
        let port: SmsPort
        switch openPort() {
        case .success(let p): port = p
        case .failure(let error): return .failure(SmsFailure(message: "\(describe(error)) Nothing was deleted."))
        }
        defer { port.close() }
        let session = SmsSession(port)
        if let failure = usePduMode(session) ?? checkListed(targets, listedFrom: place, sending: false, on: session) {
            return .failure(failure.adding(" Nothing was deleted."))
        }
        return deleteEach(targets.map { $0.index }, on: session)
    }

    private func deleteEach(_ indices: [Int], on session: SmsSession) -> Result<Int, SmsFailure> {
        var deleted = 0
        for index in indices {
            if case .failure(let error) = session.command("AT+CMGD=\(index)", timeout: SmsService.deleteTimeout) {
                let before = "\(deleted) of \(indices.count) stored part(s) were deleted before it."
                // Only the modem's own refusal says the entry is still there; after no answer in time or an
                // I/O error the modem may have deleted it.
                if case .modem = error {
                    return .failure(SmsFailure(message: "Stored part \(index) could not be deleted. \(describe(error)) \(before)"))
                }
                return .failure(SmsFailure(message: "Deleting stored part \(index) failed. \(describe(error)) "
                                           + "It is not known whether it was deleted; \(before)"))
            }
            deleted += 1
        }
        return .success(deleted)
    }

    /// Writes every part to the store (AT+CMGW=<length>,2), then sends each from there (AT+CMSS=<index>). A part that
    /// could not be written leaves nothing sent: the parts written before it are deleted again while the port still
    /// works. A part whose send failed stays stored as unsent, with the parts after it (Retry, Delete). With <mem1> and
    /// <mem2> different, or AT+CPMS? refused or without names, the parts are sent with AT+CMGS and not stored. When
    /// AT+CPMS? got no answer the port is not used again: nothing has been sent, so a new port is opened once for it.
    func send(to number: String, text: String) -> Result<SmsSent, SmsFailure> {
        // The model checks the number and the length first, so a bad request never opens the port.
        let parts: [SubmitPdu]
        switch encodeSubmit(to: number, text: text, reference: UInt8.random(in: 0...255)) {
        case .success(let p): parts = p
        case .failure(let failure): return .failure(failure)
        }
        // Where the modem would store the parts: AT+CPMS? on a port in PDU mode. With no answer that port is not used
        // again; nothing has been sent, so one new port is opened for it.
        var port: SmsPort? = nil
        defer { port?.close() }
        var opened: SmsSession? = nil
        var stores: Bool? = nil
        var unanswered: AtError = .timeout
        for _ in 0..<2 {
            port?.close()
            switch openPort() {
            case .success(let p): port = p
            case .failure(let error):
                port = nil
                return .failure(SmsFailure(message: "\(describe(error)) Nothing was sent."))
            }
            let s = SmsSession(port!)
            opened = s
            if let failure = usePduMode(s) {
                return .failure(SmsFailure(message: "\(failure.message) Nothing was sent."))
            }
            switch s.command("AT+CPMS?", timeout: SmsService.readTimeout) {
            case .success(let lines): stores = parseStorageNames(lines).map { $0.read == $0.write } ?? false
            case .failure(let error): if isModemRefusal(error) { stores = false } else { unanswered = error }
            }
            if stores != nil { break }
        }
        guard let stores, let session = opened else {
            return .failure(SmsFailure(message: "Where the modem stores messages could not be read. "
                                       + "\(describe(unanswered)) Nothing was sent."))
        }
        guard stores else { return sendDirectly(parts, on: session) }

        var written: [(index: Int, hex: String)] = []
        for (n, part) in parts.enumerated() {
            let reason: String
            switch session.send("AT+CMGW=\(part.tpduLength),2", afterPrompt: part.hex, timeout: SmsService.writeTimeout) {
            case .success(let lines):
                if let index = parseStoreIndex(lines) {
                    written.append((index, part.hex))
                    continue
                }
                reason = "The modem did not say where it stored it (no +CMGW line)."
            case .failure(let error):
                reason = describe(error)
            }
            // Nothing was sent: the parts written so far go again, while the port works.
            var left = written.count
            if session.usable {
                for w in written {
                    if case .success = session.command("AT+CMGD=\(w.index)", timeout: SmsService.deleteTimeout) { left -= 1 }
                }
            }
            let which = parts.count == 1 ? "The message" : "Part \(n + 1) of \(parts.count)"
            var message = "\(which) could not be stored on the modem. \(reason) Nothing was sent."
            if left > 0 { message += " Parts already stored are listed as Not sent." }
            return .failure(SmsFailure(message: message))
        }
        return sendStored(written, on: session)
    }

    /// The window's Retry: the listed unsent parts checked first (checkListed: still unsent, as listed, where listed),
    /// then sent again from the store (AT+CMSS).
    func resend(_ parts: [StoredPdu], listedFrom place: SmsPlace) -> Result<SmsSent, SmsFailure> {
        var seen = Set<Int>()
        let targets = parts.filter { seen.insert($0.index).inserted }
        guard !targets.isEmpty, targets.allSatisfy({ $0.index >= 0 && $0.status == .unsent }) else {
            return .failure(SmsFailure(message: "There is nothing stored to send. Nothing was sent."))
        }
        let port: SmsPort
        switch openPort() {
        case .success(let p): port = p
        case .failure(let error): return .failure(SmsFailure(message: "\(describe(error)) Nothing was sent."))
        }
        defer { port.close() }
        let session = SmsSession(port)
        if let failure = usePduMode(session) ?? checkListed(targets, listedFrom: place, sending: true, on: session) {
            return .failure(failure.adding(" Nothing was sent."))
        }
        return sendStored(targets.map { ($0.index, $0.hex) }, on: session)
    }

    /// AT+CMSS for each stored part in turn; after each that went, its stored status is made "sent" (markSent). A part
    /// the modem refused was not sent; after any other failure it is not known (sendFailure). Either way it and the
    /// parts after it stay stored as unsent. What became of each part is in the result's record.
    private func sendStored(_ stored: [(index: Int, hex: String)], on session: SmsSession) -> Result<SmsSent, SmsFailure> {
        var record = SmsSendRecord()
        for (n, part) in stored.enumerated() {
            let reason: String
            let known: Bool
            switch session.command("AT+CMSS=\(part.index)", timeout: SmsService.sendTimeout) {
            case .success(let lines):
                if parseStoredSendReference(lines) != nil {
                    let marked = markSent(part.index, written: part.hex, on: session)
                    if let sent = marked.sent { record.sent.append(sent) }
                    if let still = marked.stillUnsent { record.stillUnsent.append(still) }
                    continue
                }
                reason = "The modem did not confirm it with a +CMSS line."
                known = false
            case .failure(let error):
                reason = describe(error)
                known = isModemRefusal(error)
            }
            if !known { record.unknown.append(StoredPart(index: part.index, hex: part.hex)) }
            return .failure(SmsFailure(message: sendFailure(part: n, of: stored.count, reason: reason, known: known)
                                       + " It is kept on the modem as Not sent: Retry sends it, Delete removes it.",
                                       record: record))
        }
        return .success(SmsSent(parts: stored.count, indices: record.sent.map { $0.index }, record: record))
    }

    /// The modem should list a part it sent from its store as "sent". One that still says "unsent" (AT+CMGR) is deleted
    /// and written again as sent (AT+CMGD, then AT+CMGW=<length>,3: the delete frees the place the copy needs), so it is
    /// never offered for Retry. `sent`: where the part is stored as sent now (nil: its copy could not be written, so it
    /// is no longer stored); `stillUnsent`: the part is still stored as unsent, or that is not known (its status could
    /// not be read, or the delete failed), though it was sent.
    private func markSent(_ index: Int, written: String, on session: SmsSession) -> (sent: StoredPart?, stillUnsent: StoredPart?) {
        guard case .success(let lines) = session.command("AT+CMGR=\(index)", timeout: SmsService.readTimeout),
              let entry = parseReadEntry(lines) else {
            let part = StoredPart(index: index, hex: written)
            return (part, part)
        }
        let part = StoredPart(index: index, hex: entry.hex)
        guard entry.status == .unsent, let length = submitLength(entry.hex) else { return (part, nil) }
        guard case .success = session.command("AT+CMGD=\(index)", timeout: SmsService.deleteTimeout) else {
            return (part, part)
        }
        guard case .success(let answer) = session.send("AT+CMGW=\(length),3", afterPrompt: entry.hex,
                                                       timeout: SmsService.writeTimeout),
              let copy = parseStoreIndex(answer) else { return (nil, nil) }
        return (StoredPart(index: copy, hex: entry.hex), nil)
    }

    /// AT+CMGS for each part, as before stored sending: when the modem would store where it does not list.
    private func sendDirectly(_ parts: [SubmitPdu], on session: SmsSession) -> Result<SmsSent, SmsFailure> {
        for (n, part) in parts.enumerated() {
            let result = session.send("AT+CMGS=\(part.tpduLength)", afterPrompt: part.hex, timeout: SmsService.sendTimeout)
            // A refusal from the modem means this part did not go; any other failure (no answer in time, an
            // I/O error, an "OK" without "+CMGS:") may come after the modem took the part, so it is not known.
            let reason: String
            let known: Bool
            switch result {
            case .success(let lines):
                if parseSendReference(lines) != nil { continue }
                reason = "The modem did not confirm it with a +CMGS line."
                known = false
            case .failure(let error):
                reason = describe(error)
                known = isModemRefusal(error)
            }
            return .failure(SmsFailure(message: sendFailure(part: n, of: parts.count, reason: reason, known: known)))
        }
        return .success(SmsSent(parts: parts.count, indices: [], stored: false))
    }

    /// The background count: the store's entries (AT+CPMS?) less those that are read, unsent or sent (AT+CMGL=1, 2, 3)
    /// are the unread ones, none of which is listed or read (so none is made read). The store's count read again after
    /// the lists must be the same (a message that came in meanwhile is counted on a later turn).
    func countUnread() -> Result<SmsStoreCount, SmsFailure> {
        let port: SmsPort
        switch openPort() {
        case .success(let p): port = p
        case .failure(let error): return .failure(SmsFailure(message: describe(error)))
        }
        defer { port.close() }
        let session = SmsSession(port)
        if let failure = usePduMode(session) { return .failure(failure) }
        func used() -> Result<Int, SmsFailure> {
            switch session.command("AT+CPMS?", timeout: SmsService.readTimeout) {
            case .success(let lines):
                guard let store = parseStorage(lines) else {
                    return .failure(SmsFailure(message: "The modem did not say how full its message store is."))
                }
                return .success(store.used)
            case .failure(let error):
                return .failure(SmsFailure(message: "The message store could not be read. \(describe(error))"))
            }
        }
        let before: Int
        switch used() {
        case .success(let n): before = n
        case .failure(let f): return .failure(f)
        }
        var counts: [Int] = []
        for stat in 1...3 {
            switch session.command("AT+CMGL=\(stat)", timeout: SmsService.listTimeout) {
            case .success(let lines): counts.append(listedCount(lines))
            case .failure(let error):
                return .failure(SmsFailure(message: "The messages could not be counted. \(describe(error))"))
            }
        }
        guard case .success(let after) = used(), after == before else {
            return .failure(SmsFailure(message: "The message store changed while it was counted."))
        }
        let unread = before - counts.reduce(0, +)
        guard unread >= 0 else { return .failure(SmsFailure(message: "The message store's count does not add up.")) }
        return .success(SmsStoreCount(used: before, received: unread + counts[0], unread: unread))
    }

    // MARK: Checking what was listed

    /// The store's use and storages (AT+CPMS?) and the SIM's IMSI (AT+CIMI: refused, as with no SIM, is none); a
    /// failure when either got no answer or AT+CPMS? was refused. Without storage names the place is not complete.
    private func readPlace(_ session: SmsSession) -> Result<(place: SmsPlace, store: (used: Int, total: Int)?), AtError> {
        let storage: [String]
        switch session.command("AT+CPMS?", timeout: SmsService.readTimeout) {
        case .success(let lines): storage = lines
        case .failure(let error): return .failure(error)
        }
        var sim: String? = nil
        switch session.command("AT+CIMI", timeout: SmsService.readTimeout) {
        case .success(let lines): sim = parseImsi(lines)
        case .failure(let error): if !isModemRefusal(error) { return .failure(error) }
        }
        let names = parseStorageNames(storage)
        var place = SmsPlace(device: session.port.deviceSerial, sim: sim, listsFrom: names?.read, writesTo: names?.write)
        place.complete = names != nil
        return .success((place, parseStorage(storage)))
    }

    /// Whether the listed `parts` are still where and what they were: the same module, SIM and storages (and, to send
    /// again, <mem2> the same as <mem1>: AT+CMSS sends from <mem2>), and each part at its index with the same status
    /// (a received one is read by now: the listing made it read) and the same PDU. nil when so; else why not, with
    /// listingChanged set when the listing is out of date.
    private func checkListed(_ parts: [StoredPdu], listedFrom listed: SmsPlace, sending: Bool,
                             on session: SmsSession) -> SmsFailure? {
        let changed = "The messages on the modem changed since they were listed:"
        guard listed.complete else {
            return SmsFailure(message: "Where the messages are stored was not known when they were listed. List them again.",
                              listingChanged: true)
        }
        guard session.port.deviceSerial == listed.device else {
            return SmsFailure(message: "\(changed) another modem is attached.", listingChanged: true)
        }
        let now: SmsPlace
        switch readPlace(session) {
        case .success(let read): now = read.place
        case .failure(let error):
            return SmsFailure(message: "The modem could not be checked before the change. \(describe(error))")
        }
        guard now.complete, now.listsFrom == listed.listsFrom, now.writesTo == listed.writesTo else {
            return SmsFailure(message: "\(changed) it stores them in another place now.", listingChanged: true)
        }
        guard now.sim == listed.sim else {
            return SmsFailure(message: "\(changed) another SIM is in use.", listingChanged: true)
        }
        if sending, now.listsFrom != now.writesTo {
            return SmsFailure(message: "The modem sends from another storage than the one it lists, so a listed part "
                              + "cannot be sent again.")
        }
        // Where each part may be now: a received one read (1); an unsent one unsent (2), or, for a delete, sent (3)
        // (its send was confirmed late); a sent one sent.
        func allowed(_ status: SmsStatus) -> [SmsStatus] {
            switch status {
            case .unread, .read: return [.read]
            case .unsent: return sending ? [.unsent] : [.unsent, .sent]
            case .sent: return [.sent]
            }
        }
        let wanted = Set(parts.flatMap { allowed($0.status) })
        var found: [Int: StoredPdu] = [:]
        for status in [SmsStatus.read, .unsent, .sent] where wanted.contains(status) {
            switch session.command("AT+CMGL=\(status.rawValue)", timeout: SmsService.listTimeout) {
            case .success(let lines):
                for entry in parseListing(lines) where entry.status == status { found[entry.index] = entry }
            case .failure(let error):
                return SmsFailure(message: "The stored messages could not be checked. \(describe(error))")
            }
        }
        for part in parts {
            guard let now = found[part.index], allowed(part.status).contains(now.status),
                  pduSignature(now.hex) == pduSignature(part.hex) else {
                return SmsFailure(message: "\(changed) stored part \(part.index) is not the one listed.",
                                  listingChanged: true)
            }
        }
        return nil
    }

    // Reads the message format and switches to PDU mode (0) if it is text mode (1); the setting is not
    // saved. Any other answer is a failure.
    private func usePduMode(_ session: SmsSession) -> SmsFailure? {
        let lines: [String]
        switch session.command("AT+CMGF?", timeout: SmsService.readTimeout) {
        case .success(let l): lines = l
        case .failure(let error):
            return SmsFailure(message: "The message format could not be read. \(describe(error))")
        }
        let mode = lines.lazy
            .filter { $0.hasPrefix("+CMGF:") }
            .compactMap { Int($0.dropFirst("+CMGF:".count).trimmingCharacters(in: .whitespaces)) }
            .first
        switch mode {
        case 0:
            return nil
        case 1:
            if case .failure(let error) = session.command("AT+CMGF=0", timeout: SmsService.readTimeout) {
                return SmsFailure(message: "The modem could not be put in PDU mode. \(describe(error))")
            }
            return nil
        default:
            return SmsFailure(message: "The modem did not say which message format it uses.")
        }
    }
}

private extension SmsFailure {
    func adding(_ tail: String) -> SmsFailure {
        SmsFailure(message: message + tail, listingChanged: listingChanged, record: record)
    }
}


/// The TPDU length of a stored PDU (its octets after the service centre field), as AT+CMGW takes it.
private func submitLength(_ hex: String) -> Int? {
    guard hex.count % 2 == 0, hex.count >= 2, let sc = Int(hex.prefix(2), radix: 16) else { return nil }
    let tpdu = hex.count / 2 - 1 - sc
    return tpdu > 0 ? tpdu : nil
}

// `part` counts from 0. Parts before it were confirmed by the modem. When it is not known whether the
// part went, the sentence warns that sending again may deliver it twice: the text is kept and Send works
// again, and each send costs the owner a fee.
private func sendFailure(part: Int, of total: Int, reason: String, known: Bool) -> String {
    let which = total == 1 ? "The message" : "Part \(part + 1) of \(total)"
    let state: String
    if known {
        state = part == 0 ? "Nothing was sent."
            : "\(part) of \(total) parts were sent; the message is incomplete at the receiver."
    } else if total == 1 {
        state = "It is not known whether it was sent."
    } else if part == 0 {
        state = "It is not known whether that part was sent; no other part was sent."
    } else {
        state = "It is not known whether that part was sent; \(part) of \(total) parts were sent before it, "
            + "so the message is incomplete at the receiver."
    }
    if known { return "\(which) was refused. \(reason) \(state)" }
    return "\(which) failed. \(reason) \(state) It may have been delivered; sending it again may deliver it twice."
}

// One sentence for each way the AT port can fail.
func describe(_ error: AtError) -> String {
    switch error {
    case .modemNotAttached:
        return "The RM520N-GL (USB 2c7c:0801) is not attached."
    case .noAtInterface:
        return "The modem has no spare AT port."
    case .busy:
        return "Another program is using the modem's spare AT port."
    case .timeout:
        return "The modem did not answer in time."
    case .modem(let line):
        return "The modem refused the command (\(line))."
    case .io(let status):
        return "An I/O error occurred on the modem's spare AT port (code \(String(format: "0x%08x", UInt32(bitPattern: status))))."
    }
}
