// Text messages on the modem: lists, deletes and sends them over the spare AT port, with the model in
// SmsModel.swift doing all the reading and writing of PDUs. Each call opens the port, works and closes
// it, also on failure; a port is never used again after a failure (AtPort closes itself on a timeout).
// Calls are synchronous and must not be made on the main thread. Nothing here logs or stores message
// text or numbers on the Mac: they go only to the caller, and to the modem's own store.
//
// A message is sent from the modem's store (3GPP TS 27.005; Quectel's AT manual for the RM520N series, 8.10 and
// 8.11): each part is written with AT+CMGW (stored "unsent"), then sent with AT+CMSS, after which the modem keeps it
// as "sent". So a sent message is listed with the received ones (AT+CMGL), by the window and by `RMNet sms list`, and
// a part whose AT+CMSS failed stays stored as "unsent", for Retry (resend) or Delete. The modem gives a stored
// SMS-SUBMIT no time. When the modem lists one storage and writes to another (AT+CPMS: <mem1> differs from <mem2>), a
// stored message would never be listed, so the message is sent directly with AT+CMGS, as before, and not stored.
import Foundation

/// The port the service talks to: AtPort, or a scripted port in the tests.
protocol SmsPort: AnyObject {
    func command(_ line: String, timeout: TimeInterval) -> Result<[String], AtError>
    func send(_ line: String, afterPrompt payload: String, timeout: TimeInterval) -> Result<[String], AtError>
    func close()
}

extension AtPort: SmsPort {}

final class SmsService: SmsServing {
    private static let readTimeout: TimeInterval = 3
    private static let listTimeout: TimeInterval = 15    // up to 255 stored entries
    private static let deleteTimeout: TimeInterval = 10
    private static let writeTimeout: TimeInterval = 10   // AT+CMGW: the manual says 300 ms
    private static let sendTimeout: TimeInterval = 60     // per part: the network's answer

    private let openPort: () -> Result<SmsPort, AtError>

    /// `waitForPort` false: a port another program holds fails as busy at once (AtPort.openWithoutWaiting), for the
    /// app's background listing of new messages, which then tries again on a later turn.
    convenience init(waitForPort: Bool = true) {
        self.init(open: waitForPort ? { AtPort.open().map { $0 as SmsPort } }
                                    : { AtPort.openWithoutWaiting().map { $0 as SmsPort } })
    }

    init(open: @escaping () -> Result<SmsPort, AtError>) {
        openPort = open
    }

    // The listing, then the store's use (AT+CPMS?) in the same session; if that answer cannot be read the
    // listing still succeeds, without it.
    func list() -> Result<SmsListing, SmsFailure> {
        let port: SmsPort
        switch openPort() {
        case .success(let p): port = p
        case .failure(let error): return .failure(SmsFailure(message: describe(error)))
        }
        defer { port.close() }
        if let failure = usePduMode(port) { return .failure(failure) }
        switch port.command("AT+CMGL=4", timeout: SmsService.listTimeout) {
        case .success(let lines):
            let messages = assemble(parseListing(lines).map(decodePart))
            var store: (used: Int, total: Int)? = nil
            if case .success(let answer) = port.command("AT+CPMS?", timeout: SmsService.readTimeout) {
                store = parseStorage(answer)
            }
            return .success(SmsListing(messages: messages, used: store?.used, total: store?.total))
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
        var deleted = 0
        for index in indices {
            if case .failure(let error) = port.command("AT+CMGD=\(index)", timeout: SmsService.deleteTimeout) {
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
    /// could not be written leaves nothing sent: the parts written before it are deleted again. A part whose send
    /// failed stays stored as unsent, with the parts after it (Retry, Delete). With <mem1> and <mem2> different, or
    /// AT+CPMS? not read, the parts are sent with AT+CMGS and not stored.
    func send(to number: String, text: String) -> Result<SmsSent, SmsFailure> {
        // The model checks the number and the length first, so a bad request never opens the port.
        let parts: [SubmitPdu]
        switch encodeSubmit(to: number, text: text, reference: UInt8.random(in: 0...255)) {
        case .success(let p): parts = p
        case .failure(let failure): return .failure(failure)
        }
        let port: SmsPort
        switch openPort() {
        case .success(let p): port = p
        case .failure(let error): return .failure(SmsFailure(message: "\(describe(error)) Nothing was sent."))
        }
        defer { port.close() }
        if let failure = usePduMode(port) {
            return .failure(SmsFailure(message: "\(failure.message) Nothing was sent."))
        }
        guard storesWhereItLists(port) else { return sendDirectly(parts, on: port) }

        var stored: [Int] = []
        for (n, part) in parts.enumerated() {
            let reason: String
            let known: Bool
            switch port.send("AT+CMGW=\(part.tpduLength),2", afterPrompt: part.hex, timeout: SmsService.writeTimeout) {
            case .success(let lines):
                if let index = parseStoreIndex(lines) {
                    stored.append(index)
                    continue
                }
                reason = "The modem did not say where it stored it (no +CMGW line)."
                known = false
            case .failure(let error):
                reason = describe(error)
                if case .modem = error { known = true } else { known = false }
            }
            // Nothing was sent: the parts written so far go again (on a port that still works).
            if known { for index in stored { _ = port.command("AT+CMGD=\(index)", timeout: SmsService.deleteTimeout) } }
            let which = parts.count == 1 ? "The message" : "Part \(n + 1) of \(parts.count)"
            return .failure(SmsFailure(message: "\(which) could not be stored on the modem. \(reason) Nothing was sent."
                                       + (known || stored.isEmpty ? "" : " Parts already stored are listed as Not sent.")))
        }
        return sendStored(stored, on: port)
    }

    /// Sends stored parts again (AT+CMSS), as a Retry of a message listed as not sent.
    func resend(indices: [Int]) -> Result<SmsSent, SmsFailure> {
        guard !indices.isEmpty, indices.allSatisfy({ $0 >= 0 }) else {
            return .failure(SmsFailure(message: "There is nothing stored to send. Nothing was sent."))
        }
        let port: SmsPort
        switch openPort() {
        case .success(let p): port = p
        case .failure(let error): return .failure(SmsFailure(message: "\(describe(error)) Nothing was sent."))
        }
        defer { port.close() }
        if let failure = usePduMode(port) {
            return .failure(SmsFailure(message: "\(failure.message) Nothing was sent."))
        }
        return sendStored(indices, on: port)
    }

    /// AT+CMSS for each stored part in turn; after each that went, its stored status is made "sent" (markSent). A part
    /// the modem refused was not sent; after any other failure it is not known (sendFailure). Either way it and the
    /// parts after it stay stored as unsent.
    private func sendStored(_ indices: [Int], on port: SmsPort) -> Result<SmsSent, SmsFailure> {
        var sent: [Int] = []
        for (n, index) in indices.enumerated() {
            let reason: String
            let known: Bool
            switch port.command("AT+CMSS=\(index)", timeout: SmsService.sendTimeout) {
            case .success(let lines):
                if parseStoredSendReference(lines) != nil {
                    sent.append(markSent(index, on: port))
                    continue
                }
                reason = "The modem did not confirm it with a +CMSS line."
                known = false
            case .failure(let error):
                reason = describe(error)
                if case .modem = error { known = true } else { known = false }
            }
            return .failure(SmsFailure(message: sendFailure(part: n, of: indices.count, reason: reason, known: known)
                                       + " It is kept on the modem as Not sent: Retry sends it, Delete removes it."))
        }
        return .success(SmsSent(parts: indices.count, indices: sent))
    }

    /// The modem should list a part it sent from its store as "sent"; one that still says "unsent" (AT+CMGR) is written
    /// again as sent and the unsent copy deleted, so it is never offered for Retry. Its index, new or not; any failure
    /// on the way leaves it as it was.
    private func markSent(_ index: Int, on port: SmsPort) -> Int {
        guard case .success(let lines) = port.command("AT+CMGR=\(index)", timeout: SmsService.readTimeout),
              let entry = parseReadEntry(lines), entry.status == .unsent,
              let pdu = submitLength(entry.hex) else { return index }
        guard case .success(let written) = port.send("AT+CMGW=\(pdu),3", afterPrompt: entry.hex,
                                                     timeout: SmsService.writeTimeout),
              let copy = parseStoreIndex(written) else { return index }
        _ = port.command("AT+CMGD=\(index)", timeout: SmsService.deleteTimeout)
        return copy
    }

    /// AT+CMGS for each part, as before stored sending: when the modem would store where it does not list.
    private func sendDirectly(_ parts: [SubmitPdu], on port: SmsPort) -> Result<SmsSent, SmsFailure> {
        for (n, part) in parts.enumerated() {
            let result = port.send("AT+CMGS=\(part.tpduLength)", afterPrompt: part.hex, timeout: SmsService.sendTimeout)
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
                if case .modem = error { known = true } else { known = false }
            }
            return .failure(SmsFailure(message: sendFailure(part: n, of: parts.count, reason: reason, known: known)))
        }
        return .success(SmsSent(parts: parts.count, indices: [], stored: false))
    }

    /// AT+CPMS?: the modem writes to the storage it lists (<mem2> is <mem1>).
    private func storesWhereItLists(_ port: SmsPort) -> Bool {
        guard case .success(let lines) = port.command("AT+CPMS?", timeout: SmsService.readTimeout),
              let names = parseStorageNames(lines) else { return false }
        return names.read == names.write
    }

    // Reads the message format and switches to PDU mode (0) if it is text mode (1); the setting is not
    // saved. Any other answer is a failure.
    private func usePduMode(_ port: SmsPort) -> SmsFailure? {
        let lines: [String]
        switch port.command("AT+CMGF?", timeout: SmsService.readTimeout) {
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
            if case .failure(let error) = port.command("AT+CMGF=0", timeout: SmsService.readTimeout) {
                return SmsFailure(message: "The modem could not be put in PDU mode. \(describe(error))")
            }
            return nil
        default:
            return SmsFailure(message: "The modem did not say which message format it uses.")
        }
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
