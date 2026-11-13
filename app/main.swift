// RMNet host app: installs, removes and reports on the RMNet driver extension.
// Usage: RMNet activate | deactivate | status
// It must run from /Applications/RMNet.app for activate and deactivate (scripts/install-driver.sh).
import Foundation
import IOKit
import SystemExtensions

let driverID = "io.rmnetdriver.RMNet.driver"
let driverClass = "RMNetDriver"  // the driver's IOUserClass
let modemVendor = 0x2C7C
let modemProduct = 0x0801

// MARK: - Registry (read only; nothing is opened)

func properties(of entry: io_registry_entry_t) -> [String: Any] {
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dict = props?.takeRetainedValue() as? [String: Any] else { return [:] }
    return dict
}

// The first service of class `className` whose properties include all of `match`.
func firstService(_ className: String, withProperties match: [String: Any]) -> io_service_t {
    let matching = IOServiceMatching(className) as NSMutableDictionary
    matching[kIOPropertyMatchKey] = match
    return IOServiceGetMatchingService(kIOMainPortDefault, matching as CFDictionary)  // consumes `matching`
}

func intValue(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }

// Says whether the modem is attached and in QMI mode (an interface with class, subclass and
// protocol 0xff), so "not installed", "modem not in QMI mode" and "attached" can be told apart.
func printModem() {
    let device = firstService("IOUSBHostDevice", withProperties: ["idVendor": modemVendor, "idProduct": modemProduct])
    guard device != IO_OBJECT_NULL else {
        print("modem: 2c7c:0801 not attached")
        return
    }
    defer { IOObjectRelease(device) }

    var qmiInterface: Int?
    var children: io_iterator_t = 0
    if IORegistryEntryGetChildIterator(device, kIOServicePlane, &children) == KERN_SUCCESS {
        var child = IOIteratorNext(children)
        while child != IO_OBJECT_NULL {
            let p = properties(of: child)
            if intValue(p["bInterfaceClass"]) == 0xff, intValue(p["bInterfaceSubClass"]) == 0xff,
               intValue(p["bInterfaceProtocol"]) == 0xff {
                qmiInterface = intValue(p["bInterfaceNumber"])
            }
            IOObjectRelease(child)
            child = IOIteratorNext(children)
        }
        IOObjectRelease(children)
    }
    if let number = qmiInterface {
        print("modem: 2c7c:0801 attached, QMI interface \(number) (class, subclass, protocol ff)")
    } else {
        print("modem: 2c7c:0801 attached, no interface with class, subclass, protocol ff (not in QMI mode)")
    }
}

func printDriverEntry() {
    let entry = firstService("IOService", withProperties: ["IOUserClass": driverClass])
    guard entry != IO_OBJECT_NULL else {
        print("driver: no \(driverClass) registry entry (not attached)")
        return
    }
    defer { IOObjectRelease(entry) }
    print("driver: \(driverClass) attached")
    let props = properties(of: entry)
    for key in props.keys.filter({ $0.hasPrefix("RMNet") }).sorted() {
        print("  \(key) = \(props[key]!)")
    }
}

func printRegistry() {
    printModem()
    printDriverEntry()
}

// MARK: - System extension requests

enum Command: String { case activate, deactivate, status }

final class Delegate: NSObject, OSSystemExtensionRequestDelegate {
    let command: Command
    init(_ command: Command) { self.command = command }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        print("replacing version \(existing.bundleVersion) with \(ext.bundleVersion)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        print("waiting for approval in System Settings")
    }

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        if properties.isEmpty {
            print("driver extension: not installed")
        }
        for p in properties {
            var flags = [p.isEnabled ? "enabled" : "not enabled"]
            if p.isAwaitingUserApproval { flags.append("awaiting approval") }
            if p.isUninstalling { flags.append("uninstalling") }
            print("driver extension: \(p.bundleIdentifier) version \(p.bundleVersion) (\(p.bundleShortVersion)), "
                  + flags.joined(separator: ", "))
        }
        printRegistry()
        exit(0)
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed: print("\(command.rawValue): done")
        case .willCompleteAfterReboot: print("\(command.rawValue): done after a reboot")
        @unknown default: print("\(command.rawValue): finished with result \(result.rawValue)")
        }
        if command == .status { printRegistry() }
        exit(0)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let code = (error as NSError).code
        if command == .status {
            print("driver extension: unknown (\(error.localizedDescription), code \(code))")
            printRegistry()
        } else {
            print("\(command.rawValue) failed: \(error.localizedDescription) (code \(code))")
        }
        exit(1)
    }
}

let args = CommandLine.arguments
guard args.count == 2, let command = Command(rawValue: args[1]) else {
    print("usage: RMNet activate | deactivate | status")
    exit(2)
}

let request: OSSystemExtensionRequest
switch command {
case .activate:
    request = .activationRequest(forExtensionWithIdentifier: driverID, queue: .main)
case .deactivate:
    request = .deactivationRequest(forExtensionWithIdentifier: driverID, queue: .main)
case .status:
    request = .propertiesRequest(forExtensionWithIdentifier: driverID, queue: .main)
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
        print("driver extension: unknown (no answer from the system in 10 s)")
        printRegistry()
        exit(1)
    }
}
let delegate = Delegate(command)
request.delegate = delegate
OSSystemExtensionManager.shared.submitRequest(request)
dispatchMain()
