// Registry reads for the RMNet app: the modem on USB and the driver's RMNet* properties.
// Read only; nothing is opened.
import Foundation
import IOKit

let driverClass = "RMNetDriver"  // the driver's IOUserClass
let modemVendor = 0x2C7C
let modemProduct = 0x0801

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

// Whether the modem is attached, and in QMI mode (an interface with class, subclass and protocol
// 0xff), so "not installed", "modem not in QMI mode" and "attached" can be told apart.
func readModem() -> ModemState {
    let device = firstService("IOUSBHostDevice", withProperties: ["idVendor": modemVendor, "idProduct": modemProduct])
    guard device != IO_OBJECT_NULL else { return .absent }
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
    if let number = qmiInterface { return .qmi(interface: number) }
    return .notQMI
}

// The RMNet* properties of the driver's registry entry, as strings, or nil if it is not attached.
func readDriverProperties() -> [String: String]? {
    let entry = firstService("IOService", withProperties: ["IOUserClass": driverClass])
    guard entry != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(entry) }
    var result: [String: String] = [:]
    for (key, value) in properties(of: entry) where key.hasPrefix("RMNet") {
        result[key] = propertyString(value)
    }
    return result
}

// The status the window and `status --json` show, with the entries a properties request listed.
func readStatus(entries: [ExtensionEntry]) -> DriverStatus {
    let driver = readDriverProperties()
    return DriverStatus(entries: entries, modem: readModem(), attached: driver != nil, properties: driver ?? [:])
}
