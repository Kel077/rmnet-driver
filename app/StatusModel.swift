// What the RMNet app knows about the driver, and what it says about it. Foundation only: the window,
// `RMNet status --json` and `make app-test` all use these pure functions.
import Foundation

// One entry the system lists for the driver extension (a properties request).
struct ExtensionEntry {
    var version: String  // CFBundleVersion
    var enabled: Bool
    var awaitingApproval: Bool
    var uninstalling: Bool
}

// The modem on USB: 2c7c:0801 absent, attached without a QMI interface, or attached with one
// (the interface whose class, subclass and protocol are all 0xff).
enum ModemState {
    case absent, notQMI, qmi(interface: Int)
}

struct DriverStatus {
    var entries: [ExtensionEntry]
    var modem: ModemState
    var attached: Bool                 // a registry entry with IOUserClass RMNetDriver exists
    var properties: [String: String]   // that entry's RMNet* properties, as strings
}

// The driver's session states (driver/core_host.cpp) on the way up.
let startingStates: Set<String> = ["", "starting", "idle", "syncing", "configuring", "connecting"]
// The states in which the link is up: Refreshing re-reads the settings with the link kept up.
let upStates: Set<String> = ["up", "refreshing"]

// The headline, decided in this order (the first rule that applies):
//   no entry listed                                          -> Not installed
//   more than one entry, or the one entry is uninstalling,
//     or it is neither enabled nor awaiting approval          -> Needs attention
//   the one entry awaits approval                             -> Waiting for approval in System Settings
//   driver attached, RMNetState up or refreshing              -> Connected
//   driver attached, RMNetState missing, starting, idle,
//     syncing, configuring or connecting                      -> Connecting
//   driver attached, any other RMNetState (backoff,
//     usb failed, detached, anything new)                     -> Link down
//   driver not attached, modem absent                         -> Installed, modem not attached
//   driver not attached, modem not in QMI mode                -> Modem is not in QMI mode
//   driver not attached, modem in QMI mode                    -> Connecting (the driver is loading)
func headline(_ s: DriverStatus) -> String {
    guard let entry = s.entries.first else { return "Not installed" }
    if s.entries.count > 1 || entry.uninstalling || (!entry.enabled && !entry.awaitingApproval) {
        return "Needs attention"
    }
    if entry.awaitingApproval { return "Waiting for approval in System Settings" }
    if s.attached {
        let state = s.properties["RMNetState"] ?? ""
        if upStates.contains(state) { return "Connected" }
        if startingStates.contains(state) { return "Connecting" }
        return "Link down"
    }
    switch s.modem {
    case .absent: return "Installed, modem not attached"
    case .notQMI: return "Modem is not in QMI mode"
    case .qmi: return "Connecting"
    }
}

// True when the entry is installed but switched off: the state the owner reaches by turning the
// driver off in System Settings while the modem is attached.
private func isSwitchedOff(_ e: ExtensionEntry) -> Bool {
    !e.enabled && !e.awaitingApproval && !e.uninstalling
}

// The lines shown under the headline, most specific first; the last line is always the warning.
func advice(_ s: DriverStatus, bundledVersion: String) -> [String] {
    var lines: [String] = []
    if case .notQMI = s.modem {
        lines.append("The modem is attached but not in QMI mode. Send it these two AT commands, then wait for it to come back:")
        lines.append("AT+QCFG=\"usbnet\",0")
        lines.append("AT+CFUN=1,1")
    }
    if s.entries.count > 1 || s.entries.contains(where: isSwitchedOff) {
        let versions = s.entries.map { $0.version }.joined(separator: ", ")
        lines.append("The driver was switched off in System Settings, so the system keeps an old entry and refuses every new installation.")
        lines.append("To clear it, use Remove here once for each listed version (\(versions)), each time from an RMNet app that carries that version (build/installed/RMNet-<version>.app).")
    } else if let entry = s.entries.first {
        if entry.uninstalling {
            lines.append("The system is removing the driver; it goes when the modem is unplugged or the Mac restarts.")
        } else if entry.awaitingApproval {
            lines.append("Open System Settings, General, Login Items & Extensions, Driver Extensions, and turn RMNet on.")
        } else if !bundledVersion.isEmpty && entry.version != bundledVersion {
            lines.append("Update will replace version \(entry.version) with version \(bundledVersion). The new build loads when the modem is next plugged in or the Mac restarts.")
        }
    }
    if s.entries.count == 1, !s.attached, case .qmi = s.modem, headline(s) == "Connecting" {
        lines.append("The modem is in QMI mode but the driver has not attached. If this lasts, unplug the modem and plug it in again.")
    }
    lines.append("Do not switch the driver off in System Settings while the modem is attached. Use Remove here.")
    return lines
}

// Deactivation works only from an app that embeds the installed version, and only with one entry.
func canRemoveDirectly(_ s: DriverStatus, bundledVersion: String) -> Bool {
    s.entries.count == 1 && s.entries[0].version == bundledVersion
}

// A registry property as text: strings as they are, numbers in decimal, data as Foundation prints
// it. The same text `RMNet status` prints after "key = ".
func propertyString(_ value: Any) -> String {
    "\(value)"
}

struct TableRow {
    var name: String
    var value: String
}

let fixedProperties = ["RMNetState", "RMNetIPv4", "RMNetIPv6", "RMNetProfile"]

// The window's table: state, addresses, profile, the two versions, then every other property that
// is not "0", sorted by name (the counters; their list is not fixed here).
func tableRows(_ s: DriverStatus, bundledVersion: String) -> [TableRow] {
    let p = s.properties
    let installed = s.entries.map { $0.version }.joined(separator: ", ")
    var rows = [
        TableRow(name: "State", value: p["RMNetState"] ?? (s.attached ? "" : "not attached")),
        TableRow(name: "IPv4", value: p["RMNetIPv4"] ?? ""),
        TableRow(name: "IPv6", value: p["RMNetIPv6"] ?? ""),
        TableRow(name: "Profile", value: p["RMNetProfile"] ?? ""),
        TableRow(name: "Installed driver version", value: installed.isEmpty ? "none" : installed),
        TableRow(name: "Bundled version", value: bundledVersion.isEmpty ? "unknown" : bundledVersion),
    ]
    for key in p.keys.sorted() where !fixedProperties.contains(key) && p[key] != "0" {
        rows.append(TableRow(name: key, value: p[key]!))
    }
    return rows
}

// The status as one JSON object (`RMNet status --json`). Properties stay a flat object of strings
// under "properties"; scripts read RMNetState and the counters there.
func statusJSON(_ s: DriverStatus, bundledVersion: String) -> [String: Any] {
    var object: [String: Any] = [
        "headline": headline(s),
        "advice": advice(s, bundledVersion: bundledVersion),
        "entries": s.entries.map {
            ["version": $0.version, "enabled": $0.enabled, "awaitingApproval": $0.awaitingApproval,
             "uninstalling": $0.uninstalling] as [String: Any]
        },
        "attached": s.attached,
        "bundledVersion": bundledVersion,
        "canRemoveDirectly": canRemoveDirectly(s, bundledVersion: bundledVersion),
        "properties": s.properties,
    ]
    switch s.modem {
    case .absent: object["modem"] = "absent"
    case .notQMI: object["modem"] = "notQMI"
    case .qmi(let number):
        object["modem"] = "qmi"
        object["qmiInterface"] = number
    }
    return object
}
