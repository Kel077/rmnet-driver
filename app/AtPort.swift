// The modem's spare AT port: USB interface 3 of 2c7c:0801, opened from user space with IOUSBHost.
// Sends one command at a time and collects the answer. Knows nothing about what the commands mean.
// Nothing that goes over the port is logged: it will carry message text and phone numbers.
import Foundation
import IOKit
import IOUSBHost

enum AtError: Error, Equatable {
    case modemNotAttached      // no 2c7c:0801 on USB
    case noAtInterface         // the modem is there but has no interface 3 with two bulk endpoints
    case busy                  // another program holds the interface
    case io(Int32)             // an IOKit status from a transfer or the open
    case timeout               // no final result (or no prompt) in time
    case modem(String)         // the modem's own error line: "ERROR", "+CME ERROR: 10", "+CMS ERROR: 500"
}

// Calls are synchronous, must not be made on the main thread, and must not be made from two threads
// at once. The class starts no threads of its own.
final class AtPort {
    private static let vendor = 0x2C7C
    private static let product = 0x0801
    private static let interfaceNumber = 3
    private static let readSize = 16384           // a multiple of every USB bulk packet size
    private static let pollInterval: TimeInterval = 0.1
    private static let drainInterval: TimeInterval = 0.05
    private static let maxDrainTransfers = 64
    private static let writeTimeout: TimeInterval = 2
    private static let ctrlZ: UInt8 = 0x1A
    private static let escape: UInt8 = 0x1B

    private var interface: IOUSBHostInterface?
    private var input: IOUSBHostPipe?
    private var output: IOUSBHostPipe?
    private var pending: [UInt8] = []  // bytes read but not yet split into lines

    private init(interface: IOUSBHostInterface, input: IOUSBHostPipe, output: IOUSBHostPipe) {
        self.interface = interface
        self.input = input
        self.output = output
    }

    deinit { close() }

    // MARK: Opening and closing

    static func open() -> Result<AtPort, AtError> {
        let device = matchingService("IOUSBHostDevice", ["idVendor": vendor, "idProduct": product])
        guard device != IO_OBJECT_NULL else { return .failure(.modemNotAttached) }
        defer { IOObjectRelease(device) }

        let service = childInterface(of: device, number: interfaceNumber)
        guard service != IO_OBJECT_NULL else { return .failure(.noAtInterface) }
        defer { IOObjectRelease(service) }

        let iface: IOUSBHostInterface
        do {
            iface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch {
            // An interface already open elsewhere (another process or this one) fails the open with
            // kIOReturnInternalError ("Failed [super init]"), measured on this Mac with the 27.0 SDK;
            // kIOReturnExclusiveAccess is the documented status for the same case.
            let status = ioStatus(error)
            let held = status == kIOReturnInternalError || status == kIOReturnExclusiveAccess
            return .failure(held ? .busy : .io(status))
        }

        guard let (inAddress, outAddress) = bulkEndpoints(of: iface) else {
            iface.destroy()
            return .failure(.noAtInterface)
        }
        do {
            let input = try iface.copyPipe(withAddress: Int(inAddress))
            let output = try iface.copyPipe(withAddress: Int(outAddress))
            return .success(AtPort(interface: iface, input: input, output: output))
        } catch {
            iface.destroy()
            return .failure(.io(ioStatus(error)))
        }
    }

    func close() {
        input = nil
        output = nil
        interface?.destroy()
        interface = nil
        pending = []
    }

    // MARK: Commands

    // Sends the line and returns the lines before the final "OK", without the echo and without empty lines.
    func command(_ line: String, timeout: TimeInterval = 3) -> Result<[String], AtError> {
        if let failure = discardUnsolicited() { return .failure(failure) }
        if let failure = write(Array(line.utf8) + [UInt8(ascii: "\r")]) { return .failure(failure) }
        return collectResult(echo: line, deadline: Date().addingTimeInterval(timeout))
    }

    // For AT+CMGS: sends `line`, waits for the "> " prompt, sends `payload` followed by Ctrl-Z (0x1A),
    // then returns the lines before the final "OK". If the prompt does not come, sends ESC (0x1B) and
    // fails with .timeout. `timeout` applies to the wait for the prompt and again to the wait for the
    // final result.
    func send(_ line: String, afterPrompt payload: String, timeout: TimeInterval) -> Result<[String], AtError> {
        if let failure = discardUnsolicited() { return .failure(failure) }
        if let failure = write(Array(line.utf8) + [UInt8(ascii: "\r")]) { return .failure(failure) }

        let promptDeadline = Date().addingTimeInterval(timeout)
        var sawPrompt = false
        while !sawPrompt {
            // Lines completed before the prompt: the echo, or an error if the modem refused the line.
            // Anything else (an "OK" included) is not the prompt; the wait goes on until the deadline.
            while let text = takeLine() {
                if let failure = finalFailure(text) { return .failure(failure) }
            }
            if promptPending() {
                pending = []
                sawPrompt = true
                break
            }
            switch readChunk(until: promptDeadline) {
            case .failure(.timeout):
                _ = write([AtPort.escape])  // cancels the half-entered command
                pending = []
                return .failure(.timeout)
            case .failure(let failure):
                return .failure(failure)
            case .success:
                continue
            }
        }
        if let failure = write(Array(payload.utf8) + [AtPort.ctrlZ]) { return .failure(failure) }
        return collectResult(echo: payload, deadline: Date().addingTimeInterval(timeout))
    }

    // MARK: Reading the answer

    // Reads lines until a final result. The first line equal to `echo` is the modem's echo and is dropped.
    private func collectResult(echo: String, deadline: Date) -> Result<[String], AtError> {
        var lines: [String] = []
        var echoSeen = false
        while true {
            while let text = takeLine() {
                if !echoSeen && text == echo {
                    echoSeen = true
                    continue
                }
                if text == "OK" { return .success(lines) }
                if let failure = finalFailure(text) { return .failure(failure) }
                lines.append(text)
            }
            if case .failure(let failure) = readChunk(until: deadline) { return .failure(failure) }
        }
    }

    private func finalFailure(_ text: String) -> AtError? {
        if text == "ERROR" || text.hasPrefix("+CME ERROR:") || text.hasPrefix("+CMS ERROR:") {
            return .modem(text)
        }
        return nil
    }

    // The next complete, non-empty line from `pending`, with control characters (the echoed Ctrl-Z)
    // and surrounding spaces removed. Input is split on CR and LF.
    private func takeLine() -> String? {
        while let end = pending.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }) {
            let bytes = pending[..<end].filter { $0 >= 0x20 || $0 == 0x09 }
            pending.removeSubrange(...end)
            let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }

    // The prompt is "> " with no line end after it.
    private func promptPending() -> Bool {
        String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .whitespaces) == ">"
    }

    // Reads what the modem sent unasked (or late, after an earlier timeout) and throws it away.
    // Stops after a quiet interval, or after a bounded number of transfers if the modem never goes quiet.
    private func discardUnsolicited() -> AtError? {
        pending = []
        for _ in 0..<AtPort.maxDrainTransfers {
            switch readOnce(timeout: AtPort.drainInterval) {
            case .success(let count) where count > 0:
                continue
            case .success, .failure(.timeout):
                pending = []
                return nil
            case .failure(let failure):
                return failure
            }
        }
        pending = []
        return nil
    }

    // Reads one transfer into `pending`, waiting at most until `deadline`. `.success` once bytes
    // arrived, `.timeout` if the deadline passed without any.
    private func readChunk(until deadline: Date) -> Result<Void, AtError> {
        while true {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return .failure(.timeout) }
            switch readOnce(timeout: min(left, AtPort.pollInterval)) {
            case .success(let count) where count > 0:
                return .success(())
            case .success, .failure(.timeout):
                continue
            case .failure(let failure):
                return .failure(failure)
            }
        }
    }

    // One bulk IN transfer, appended to `pending`. Returns the byte count; a transfer that ends by its
    // timeout is `.timeout`.
    private func readOnce(timeout: TimeInterval) -> Result<Int, AtError> {
        guard let input else { return .failure(.io(kIOReturnNotOpen)) }
        let buffer = NSMutableData(length: AtPort.readSize)!
        var count = 0
        do {
            // A timeout of 0 would mean "never"; the shortest wait is 1 ms.
            try input.__sendIORequest(with: buffer, bytesTransferred: &count, completionTimeout: max(timeout, 0.001))
        } catch {
            let status = AtPort.ioStatus(error)
            return .failure(status == kIOReturnTimeout ? .timeout : .io(status))
        }
        pending.append(contentsOf: UnsafeRawBufferPointer(start: buffer.bytes, count: count))
        return .success(count)
    }

    private func write(_ bytes: [UInt8]) -> AtError? {
        guard let output else { return .io(kIOReturnNotOpen) }
        let buffer = NSMutableData(bytes: bytes, length: bytes.count)
        var count = 0
        do {
            try output.__sendIORequest(with: buffer, bytesTransferred: &count, completionTimeout: AtPort.writeTimeout)
        } catch {
            let status = AtPort.ioStatus(error)
            return status == kIOReturnTimeout ? .timeout : .io(status)
        }
        return count == bytes.count ? nil : .io(kIOReturnUnderrun)
    }

    // MARK: Finding the interface

    // The IOKit status in an error thrown by IOUSBHost (its code is the IOReturn).
    private static func ioStatus(_ error: Error) -> Int32 {
        Int32(truncatingIfNeeded: (error as NSError).code)
    }

    private static func matchingService(_ className: String, _ properties: [String: Any]) -> io_service_t {
        let matching = IOServiceMatching(className) as NSMutableDictionary
        matching[kIOPropertyMatchKey] = properties
        return IOServiceGetMatchingService(kIOMainPortDefault, matching as CFDictionary)  // consumes `matching`
    }

    // The device's IOUSBHostInterface child with the given bInterfaceNumber, retained, or IO_OBJECT_NULL.
    private static func childInterface(of device: io_service_t, number: Int) -> io_service_t {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &children) == KERN_SUCCESS else {
            return IO_OBJECT_NULL
        }
        defer { IOObjectRelease(children) }
        var child = IOIteratorNext(children)
        while child != IO_OBJECT_NULL {
            let value = IORegistryEntryCreateCFProperty(child, "bInterfaceNumber" as CFString, kCFAllocatorDefault, 0)
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
               (value?.takeRetainedValue() as? NSNumber)?.intValue == number {
                return child
            }
            IOObjectRelease(child)
            child = IOIteratorNext(children)
        }
        return IO_OBJECT_NULL
    }

    // The addresses of the interface's bulk IN and bulk OUT endpoints, from its descriptors.
    private static func bulkEndpoints(of iface: IOUSBHostInterface) -> (UInt8, UInt8)? {
        let config = iface.configurationDescriptor
        let ifdesc = iface.interfaceDescriptor
        var bulkIn: UInt8?
        var bulkOut: UInt8?
        var current = UnsafeRawPointer(ifdesc).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        while let endpoint = IOUSBGetNextEndpointDescriptor(config, ifdesc, current) {
            current = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
            let address = endpoint.pointee.bEndpointAddress
            guard endpoint.pointee.bmAttributes & 0x03 == 2 else { continue }  // bulk only
            if address & 0x80 != 0 {
                if bulkIn == nil { bulkIn = address }
            } else if bulkOut == nil {
                bulkOut = address
            }
        }
        guard let bulkIn, let bulkOut else { return nil }
        return (bulkIn, bulkOut)
    }
}
