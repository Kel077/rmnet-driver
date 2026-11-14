// Text messages on the modem: lists, deletes and sends them over the spare AT port, with the model in
// SmsModel.swift doing all the reading and writing of PDUs. Each call opens the port, works and closes
// it, also on failure; a port is never used again after a failure (AtPort closes itself on a timeout).
// Calls are synchronous and must not be made on the main thread. Nothing here logs or stores message
// text or numbers: they go only to the caller.
import Foundation

final class SmsService: SmsServing {
    private static let listTimeout: TimeInterval = 15    // up to 255 stored entries
    private static let deleteTimeout: TimeInterval = 10
    private static let sendTimeout: TimeInterval = 60     // per part: the network's answer

    init() {}

    // The listing, then the store's use (AT+CPMS?) in the same session; if that answer cannot be read the
    // listing still succeeds, without it.
    func list() -> Result<SmsListing, SmsFailure> {
        let port: AtPort
        switch AtPort.open() {
        case .success(let p): port = p
        case .failure(let error): return .failure(SmsFailure(message: describe(error)))
        }
        defer { port.close() }
        if let failure = usePduMode(port) { return .failure(failure) }
        switch port.command("AT+CMGL=4", timeout: SmsService.listTimeout) {
        case .success(let lines):
            let messages = assemble(parseListing(lines).map(decodePart))
            var store: (used: Int, total: Int)? = nil
            if case .success(let answer) = port.command("AT+CPMS?") { store = parseStorage(answer) }
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
        let port: AtPort
        switch AtPort.open() {
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

    func send(to number: String, text: String) -> Result<Int, SmsFailure> {
        // The model checks the number and the length first, so a bad request never opens the port.
        let parts: [SubmitPdu]
        switch encodeSubmit(to: number, text: text, reference: UInt8.random(in: 0...255)) {
        case .success(let p): parts = p
        case .failure(let failure): return .failure(failure)
        }
        let port: AtPort
        switch AtPort.open() {
        case .success(let p): port = p
        case .failure(let error): return .failure(SmsFailure(message: "\(describe(error)) Nothing was sent."))
        }
        defer { port.close() }
        if let failure = usePduMode(port) {
            return .failure(SmsFailure(message: "\(failure.message) Nothing was sent."))
        }
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
        return .success(parts.count)
    }

    // Reads the message format and switches to PDU mode (0) if it is text mode (1); the setting is not
    // saved. Any other answer is a failure.
    private func usePduMode(_ port: AtPort) -> SmsFailure? {
        let lines: [String]
        switch port.command("AT+CMGF?") {
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
            if case .failure(let error) = port.command("AT+CMGF=0") {
                return SmsFailure(message: "The modem could not be put in PDU mode. \(describe(error))")
            }
            return nil
        default:
            return SmsFailure(message: "The modem did not say which message format it uses.")
        }
    }
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
        return "The modem is not attached."
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
