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

let removalUnderWayLine = "The system is removing the driver; the removal finishes when the modem is unplugged or the Mac restarts. Install is available after that."

// The lines shown under the headline, most specific first; the last line is the warning, except
// while every listed entry is uninstalling, when it is `removalUnderWayLine` (after the two AT
// commands if the modem is not in QMI mode).
func advice(_ s: DriverStatus, bundledVersion: String) -> [String] {
    var lines: [String] = []
    if case .notQMI = s.modem {
        lines.append("The modem is attached but not in QMI mode. Send it these two AT commands, then wait for it to come back:")
        lines.append("AT+QCFG=\"usbnet\",0")
        lines.append("AT+CFUN=1,1")
    }
    // A listing made only of entries the system is removing: the removal is under way, and the
    // window says only that (no Remove to press, Install off until the entries are gone).
    if !s.entries.isEmpty && s.entries.allSatisfy({ $0.uninstalling }) {
        return lines + [removalUnderWayLine]
    }
    // From here at least one listed entry is not uninstalling (or none is listed). Switched off is
    // said only of a listing that shows a switched-off entry; more than one entry otherwise can be a
    // replacement still under way, and the listing is given as it is.
    if s.entries.contains(where: isSwitchedOff) {
        lines.append("The driver was switched off in System Settings, so the system keeps an old entry and refuses every new installation.")
    } else if s.entries.count > 1 {
        lines.append("The system lists more than one entry for the driver: \(describeListing(s.entries)). This can be a replacement still under way; while it lasts, the system refuses a new installation.")
    } else if let entry = s.entries.first {
        if entry.awaitingApproval {
            lines.append("Open System Settings, General, Login Items & Extensions, Driver Extensions, and turn RMNet on.")
        } else if !bundledVersion.isEmpty && compareVersions(bundledVersion, entry.version) != 0 {
            lines.append("\(installTitle(s, bundledVersion: bundledVersion)) will replace version \(entry.version) with version \(bundledVersion). The new build loads when the modem is next plugged in or the Mac restarts.")
        }
    }
    if s.entries.count == 1, !s.attached, case .qmi = s.modem, headline(s) == "Connecting" {
        lines.append("The modem is in QMI mode but the driver has not attached. If this lasts, unplug the modem and plug it in again.")
    }
    if !canActivate(s) {
        // Some entry is not uninstalling, so keptAppsLine names at least one kept app.
        lines.append("Install and Update are off until this is cleared. " + keptAppsLine(s.entries))
    }
    lines.append("Do not switch the driver off in System Settings while the modem is attached. Use Remove here.")
    return lines
}

// Deactivation works only from an app that embeds the installed version, and only with one entry,
// which the system is not already removing. Versions are compared as installTitle compares them, so
// 317.9 and 317.9.0 are the same version.
func canRemoveDirectly(_ s: DriverStatus, bundledVersion: String) -> Bool {
    s.entries.count == 1 && isBundled(s.entries[0], bundledVersion) && !s.entries[0].uninstalling
}

// True when the entry is the version this app carries (compared field by field, see compareVersions).
private func isBundled(_ e: ExtensionEntry, _ bundledVersion: String) -> Bool {
    compareVersions(e.version, bundledVersion) == 0
}

// Whether an activation may be sent. Not when the listing shows the stuck state: more than one
// entry, a switched-off entry or an uninstalling one. An activation then fails, or adds an entry
// that needs its own removal. One entry awaiting approval is fine (asking again is harmless).
func canActivate(_ s: DriverStatus) -> Bool {
    s.entries.count <= 1 && !s.entries.contains(where: { isSwitchedOff($0) || $0.uninstalling })
}

// Which kept app removes each listed version. Entries the system is already removing are left out:
// they need no Remove. Empty when no other entry is listed.
func keptAppsLine(_ entries: [ExtensionEntry]) -> String {
    let apps = entries.filter { !$0.uninstalling }.map { "\($0.version) from build/installed/RMNet-\($0.version).app" }
    if apps.isEmpty { return "" }
    return "Use Remove once for each listed version, from the app that carries it, kept in the project folder: "
        + apps.joined(separator: "; ") + "."
}

// Compares two versions such as "317.9.11" and "317.10.2" field by field (fields split on dots):
// two numeric fields compare as numbers, any other pair as text, and a missing field counts as "0".
// Returns -1 when `a` is older, 0 when equal, 1 when newer.
func compareVersions(_ a: String, _ b: String) -> Int {
    let x = a.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    let y = b.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : "0"
        let q = i < y.count ? y[i] : "0"
        if let m = Int(p), let n = Int(q) {
            if m != n { return m < n ? -1 : 1 }
        } else if p != q {
            return p < q ? -1 : 1
        }
    }
    return 0
}

// The install button's title, and the word the advice uses for it: Install when nothing is listed
// (entries the system is removing do not count), else by the bundled version against the listed
// one: Update when newer, Reinstall when equal, Replace when older. Update when the bundled version
// is unknown (the button is off then).
func installTitle(_ s: DriverStatus, bundledVersion: String) -> String {
    guard let listed = s.entries.first(where: { !$0.uninstalling }) else { return "Install" }
    if bundledVersion.isEmpty { return "Update" }
    switch compareVersions(bundledVersion, listed.version) {
    case 1: return "Update"
    case 0: return "Reinstall"
    default: return "Replace"
    }
}

// Whether the listing read again after an installation of `version` shows it installed: exactly one
// entry, of that version (compared as installTitle compares, so 317.9 and 317.9.0 are the same
// version), enabled.
func installConfirmed(_ entries: [ExtensionEntry], version: String) -> Bool {
    entries.count == 1 && compareVersions(entries[0].version, version) == 0 && entries[0].enabled
}

// Why a press of the install button (`action` is its title) or of Remove sent nothing: the button was
// on when the window drew it, but by the press another request was running, the listing was no
// longer known, or the listing no longer allowed the request.
func notSentText(action: String, busy: Bool, known: Bool) -> String {
    if busy { return "Nothing was sent: another request is still running." }
    if !known {
        return "Nothing was sent: the system's listing is not known right now. Press \(action) again once the listing has refreshed."
    }
    return "Nothing was sent: the listing has changed. \(action) is available again only when the new listing allows it."
}

// The listing in words: "316.19.56 (enabled)", "none".
func describeListing(_ entries: [ExtensionEntry]) -> String {
    if entries.isEmpty { return "none" }
    return entries.map { e -> String in
        var flags = [e.enabled ? "enabled" : "not enabled"]
        if e.awaitingApproval { flags.append("awaiting approval") }
        if e.uninstalling { flags.append("uninstalling") }
        return "\(e.version) (\(flags.joined(separator: ", ")))"
    }.joined(separator: ", ")
}

// What Remove… sends for a listing, with this app carrying `bundledVersion`.
enum RemovalPlan: Equatable {
    case nothingListed           // nothing to remove (no entry, or every entry is uninstalling); the button is off
    case deactivate              // the bundled version is listed and not uninstalling: deactivate it
    case activateThenDeactivate  // one entry of another version: replace it with the bundled one first
    case cannot                  // stuck, and the bundled version is not listed apart from uninstalling: send nothing
}

func removalPlan(_ s: DriverStatus, bundledVersion: String) -> RemovalPlan {
    if s.entries.allSatisfy({ $0.uninstalling }) { return .nothingListed }  // true for no entry too
    if canRemoveDirectly(s, bundledVersion: bundledVersion) { return .deactivate }
    if !canActivate(s) {
        // An entry the system is already removing is never deactivated a second time.
        return s.entries.contains(where: { isBundled($0, bundledVersion) && !$0.uninstalling }) ? .deactivate : .cannot
    }
    return bundledVersion.isEmpty ? .cannot : .activateThenDeactivate
}

// Why Remove sends nothing when the plan is `.cannot`, and which kept apps can remove what is listed.
// With no bundled version the app has no driver to install first or to deactivate, whatever is listed.
func cannotRemoveText(_ s: DriverStatus, bundledVersion: String) -> String {
    if bundledVersion.isEmpty {
        return "This app carries no driver (the version of its embedded driver cannot be read), so it cannot remove the listed driver. "
            + keptAppsLine(s.entries)
    }
    let removing = s.entries.contains(where: { isBundled($0, bundledVersion) && $0.uninstalling })
    return "This app carries version \(bundledVersion), "
        + (removing ? "which the system is already removing" : "which is not listed")
        + ", and the listing does not allow installing it first. "
        + keptAppsLine(s.entries)
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
// is not "0", sorted by name (the counters; their list is not fixed here). Unless `listingKnown`
// (the system's last answer was a listing), the installed version is "unknown", not the entries
// last listed.
func tableRows(_ s: DriverStatus, bundledVersion: String, listingKnown: Bool) -> [TableRow] {
    let p = s.properties
    let listed = s.entries.map { $0.version }.joined(separator: ", ")
    let installed = !listingKnown ? "unknown" : listed.isEmpty ? "none" : listed
    var rows = [
        TableRow(name: "State", value: p["RMNetState"] ?? (s.attached ? "" : "not attached")),
        TableRow(name: "IPv4", value: p["RMNetIPv4"] ?? ""),
        TableRow(name: "IPv6", value: p["RMNetIPv6"] ?? ""),
        TableRow(name: "Profile", value: p["RMNetProfile"] ?? ""),
        TableRow(name: "Installed driver version", value: installed),
        TableRow(name: "Bundled version", value: bundledVersion.isEmpty ? "unknown" : bundledVersion),
    ]
    for key in p.keys.sorted() where !fixedProperties.contains(key) && p[key] != "0" {
        rows.append(TableRow(name: key, value: p[key]!))
    }
    return rows
}

// The status as one JSON object (`RMNet status --json`). Properties stay a flat object of strings
// under "properties"; scripts read RMNetState and the counters there. With `listingError` (the
// system gave no listing) the extension's state is unknown: the headline is "Unknown", "entries" is
// null, no button may act, and the error is under "error". The registry part is still read.
let unknownHeadline = "Unknown"

func statusJSON(_ s: DriverStatus, bundledVersion: String, listingError: String? = nil) -> [String: Any] {
    let known = listingError == nil
    var object: [String: Any] = [
        "headline": known ? headline(s) : unknownHeadline,
        "advice": known ? advice(s, bundledVersion: bundledVersion) : [],
        "entries": known ? s.entries.map {
            ["version": $0.version, "enabled": $0.enabled, "awaitingApproval": $0.awaitingApproval,
             "uninstalling": $0.uninstalling] as [String: Any]
        } as Any : NSNull(),
        "attached": s.attached,
        "bundledVersion": bundledVersion,
        "canActivate": known && canActivate(s),
        "canRemoveDirectly": known && canRemoveDirectly(s, bundledVersion: bundledVersion),
        "properties": s.properties,
    ]
    if let error = listingError { object["error"] = error }
    switch s.modem {
    case .absent: object["modem"] = "absent"
    case .notQMI: object["modem"] = "notQMI"
    case .qmi(let number):
        object["modem"] = "qmi"
        object["qmiInterface"] = number
    }
    return object
}
