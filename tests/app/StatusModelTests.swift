// Tests for app/StatusModel.swift: the headline, the advice, canRemoveDirectly, the table rows and
// the JSON form. Built with swiftc by `make app-test`; needs no Xcode project and no hardware.
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

let enabled = ExtensionEntry(version: "316.19.56", enabled: true, awaitingApproval: false, uninstalling: false)
let attached4 = ModemState.qmi(interface: 4)

func status(_ entries: [ExtensionEntry], _ modem: ModemState = attached4, attached: Bool = false,
            _ properties: [String: String] = [:]) -> DriverStatus {
    DriverStatus(entries: entries, modem: modem, attached: attached, properties: properties)
}

func expectHeadline(_ s: DriverStatus, _ want: String, _ name: String) {
    let got = headline(s)
    check(got == want, "headline: \(name)", "want \"\(want)\", got \"\(got)\"")
}

let alwaysLine = "Do not switch the driver off in System Settings while the modem is attached. Use Remove here."

@main
struct StatusModelTests {
    static func main() {
        // --- headline: one check per value ---------------------------------------------------
        expectHeadline(status([]), "Not installed", "no entry")
        expectHeadline(status([ExtensionEntry(version: "1", enabled: false, awaitingApproval: true, uninstalling: false)]),
                       "Waiting for approval in System Settings", "awaiting approval")
        expectHeadline(status([enabled], .absent), "Installed, modem not attached", "modem absent")
        expectHeadline(status([enabled], .notQMI), "Modem is not in QMI mode", "modem not in QMI mode")
        expectHeadline(status([enabled], attached: true, ["RMNetState": "starting"]), "Connecting", "state starting")
        expectHeadline(status([enabled], attached: true, ["RMNetState": "up"]), "Connected", "state up")
        expectHeadline(status([enabled], attached: true, ["RMNetState": "usb failed"]), "Link down", "state usb failed")
        expectHeadline(status([enabled, ExtensionEntry(version: "316.20.1", enabled: true, awaitingApproval: false, uninstalling: false)]),
                       "Needs attention", "two entries")

        // --- headline: the other mapped inputs ------------------------------------------------
        expectHeadline(status([ExtensionEntry(version: "1", enabled: false, awaitingApproval: false, uninstalling: false)]),
                       "Needs attention", "installed, not enabled")
        expectHeadline(status([ExtensionEntry(version: "1", enabled: true, awaitingApproval: false, uninstalling: true)]),
                       "Needs attention", "uninstalling")
        expectHeadline(status([enabled], attached: false), "Connecting", "QMI modem, driver not attached yet")
        expectHeadline(status([enabled], attached: true), "Connecting", "attached, no state published yet")
        for s in ["idle", "syncing", "configuring", "connecting"] {
            expectHeadline(status([enabled], attached: true, ["RMNetState": s]), "Connecting", "state \(s)")
        }
        expectHeadline(status([enabled], attached: true, ["RMNetState": "refreshing"]), "Connected", "state refreshing")
        for s in ["backoff", "detached", "something new"] {
            expectHeadline(status([enabled], attached: true, ["RMNetState": s]), "Link down", "state \(s)")
        }
        expectHeadline(status([enabled], .absent, attached: true, ["RMNetState": "up"]), "Connected",
                       "attached wins over a stale modem reading")

        // --- advice ----------------------------------------------------------------------------
        let plain = advice(status([enabled], attached: true, ["RMNetState": "up"]), bundledVersion: "316.19.56")
        check(plain == [alwaysLine], "advice: connected, same version gives only the standing line", "\(plain)")

        let notQMI = advice(status([enabled], .notQMI), bundledVersion: "316.19.56")
        check(notQMI.contains("AT+QCFG=\"usbnet\",0"), "advice: notQMI names AT+QCFG=\"usbnet\",0", "\(notQMI)")
        check(notQMI.contains("AT+CFUN=1,1"), "advice: notQMI names AT+CFUN=1,1", "\(notQMI)")
        check(notQMI.last == alwaysLine, "advice: notQMI ends with the standing line", "\(notQMI)")

        let two = advice(status([enabled, ExtensionEntry(version: "316.20.1", enabled: false, awaitingApproval: false, uninstalling: false)]),
                         bundledVersion: "316.19.56")
        check(two.contains { $0.contains("switched off in System Settings") }, "advice: two entries says it was switched off", "\(two)")
        check(two.contains { $0.contains("Use Remove once for each listed version") }, "advice: two entries says Remove once per version", "\(two)")
        check(two.contains { $0.contains("Install and Update are off") }, "advice: two entries says Install and Update are off", "\(two)")
        check(two.contains { $0.contains("build/installed/RMNet-316.19.56.app") && $0.contains("build/installed/RMNet-316.20.1.app") },
              "advice: two entries names the kept app for each version", "\(two)")
        check(two[two.count - 2].hasPrefix("Install and Update are off"), "advice: the can't-activate line comes just before the standing line", "\(two)")
        check(two.last == alwaysLine, "advice: two entries ends with the standing line", "\(two)")

        let off = advice(status([ExtensionEntry(version: "316.19.56", enabled: false, awaitingApproval: false, uninstalling: false)]),
                         bundledVersion: "316.19.56")
        check(off.contains { $0.contains("switched off in System Settings") }, "advice: installed, not enabled says it was switched off", "\(off)")

        let differs = advice(status([enabled], attached: true, ["RMNetState": "up"]), bundledVersion: "316.21.4")
        check(differs.contains { $0.contains("Update will replace version 316.19.56 with version 316.21.4") },
              "advice: differing version says Update will replace it", "\(differs)")
        check(differs.contains { $0.contains("next plugged in") }, "advice: differing version says when the new build loads", "\(differs)")
        check(differs.last == alwaysLine, "advice: differing version ends with the standing line", "\(differs)")
        check(!advice(status([enabled]), bundledVersion: "").contains { $0.contains("Update will replace") },
              "advice: an unknown bundled version says nothing about Update")

        let none = advice(status([]), bundledVersion: "316.19.56")
        check(none.last == alwaysLine, "advice: not installed ends with the standing line", "\(none)")

        // --- canRemoveDirectly -----------------------------------------------------------------
        check(canRemoveDirectly(status([enabled]), bundledVersion: "316.19.56"), "canRemoveDirectly: one matching entry")
        check(!canRemoveDirectly(status([enabled]), bundledVersion: "316.21.4"), "canRemoveDirectly: one differing entry")
        check(!canRemoveDirectly(status([enabled, enabled]), bundledVersion: "316.19.56"), "canRemoveDirectly: two entries")
        check(!canRemoveDirectly(status([]), bundledVersion: "316.19.56"), "canRemoveDirectly: no entry")

        // --- canActivate -----------------------------------------------------------------------
        let switchedOff = ExtensionEntry(version: "316.19.56", enabled: false, awaitingApproval: false, uninstalling: false)
        let waiting = ExtensionEntry(version: "316.19.56", enabled: false, awaitingApproval: true, uninstalling: false)
        let leaving = ExtensionEntry(version: "316.19.56", enabled: true, awaitingApproval: false, uninstalling: true)
        let bEnabled = ExtensionEntry(version: "316.21.4", enabled: true, awaitingApproval: false, uninstalling: false)
        check(canActivate(status([])), "canActivate: no entry")
        check(canActivate(status([enabled])), "canActivate: one enabled entry")
        check(canActivate(status([waiting])), "canActivate: one entry awaiting approval")
        check(!canActivate(status([switchedOff])), "canActivate: one switched-off entry")
        check(!canActivate(status([enabled, bEnabled])), "canActivate: two entries")
        check(!canActivate(status([leaving])), "canActivate: an uninstalling entry")
        check(!advice(status([enabled]), bundledVersion: "316.19.56").contains { $0.contains("Install and Update are off") },
              "advice: no can't-activate line when activation is allowed")
        let leavingAdvice = advice(status([leaving]), bundledVersion: "316.21.4")
        check(leavingAdvice.contains { $0.contains("build/installed/RMNet-316.19.56.app") },
              "advice: uninstalling names the kept app", "\(leavingAdvice)")

        // --- removalPlan, for an app carrying B = 316.21.4 (A = 316.19.56) --------------------
        let b = "316.21.4"
        let plans: [(String, [ExtensionEntry], RemovalPlan)] = [
            ("[A enabled]", [enabled], .activateThenDeactivate),
            ("[A switched off]", [switchedOff], .cannot),
            ("[A enabled, B enabled]", [enabled, bEnabled], .deactivate),
            ("[A switched off, B enabled]", [switchedOff, bEnabled], .deactivate),
            ("[B enabled]", [bEnabled], .deactivate),
            ("[A uninstalling]", [leaving], .cannot),
            ("no entry", [], .nothingListed),
        ]
        for (name, entries, want) in plans {
            let got = removalPlan(status(entries), bundledVersion: b)
            check(got == want, "removalPlan: \(name)", "want \(want), got \(got)")
        }
        check(removalPlan(status([enabled]), bundledVersion: "") == .cannot, "removalPlan: unknown bundled version")

        // --- describeListing ---------------------------------------------------------------------
        check(describeListing([]) == "none", "describeListing: none")
        check(describeListing([switchedOff, bEnabled]) == "316.19.56 (not enabled), 316.21.4 (enabled)",
              "describeListing: two entries", describeListing([switchedOff, bEnabled]))

        // --- table rows ------------------------------------------------------------------------
        let props = ["RMNetState": "up", "RMNetIPv4": "10.62.238.140/29 gw 10.62.238.141", "RMNetIPv6": "none",
                     "RMNetProfile": "1", "RMNetTxPackets": "12", "RMNetRxPackets": "7", "RMNetTxDropBusy": "0",
                     "RMNetSomethingNew": "abc"]
        let rows = tableRows(status([enabled], attached: true, props), bundledVersion: "316.21.4")
        let names = rows.map { $0.name }
        check(names == ["State", "IPv4", "IPv6", "Profile", "Installed driver version", "Bundled version",
                        "RMNetRxPackets", "RMNetSomethingNew", "RMNetTxPackets"],
              "tableRows: fixed rows, then non-zero counters and unknown keys sorted by name", "\(names)")
        check(rows[0].value == "up" && rows[1].value == "10.62.238.140/29 gw 10.62.238.141",
              "tableRows: state and IPv4 values", "\(rows)")
        check(rows[4].value == "316.19.56" && rows[5].value == "316.21.4", "tableRows: versions", "\(rows)")

        // --- property strings ------------------------------------------------------------------
        check(propertyString(NSNumber(value: 0)) == "0", "propertyString: number 0")
        check(propertyString(NSNumber(value: 4736)) == "4736", "propertyString: number")
        check(propertyString("up" as NSString) == "up", "propertyString: string")

        // --- JSON ------------------------------------------------------------------------------
        let json = statusJSON(status([enabled], attached: true, ["RMNetState": "up", "RMNetRxBytes": "5"]),
                              bundledVersion: "316.19.56")
        check(JSONSerialization.isValidJSONObject(json), "statusJSON: valid JSON object")
        check(json["headline"] as? String == "Connected", "statusJSON: headline")
        check((json["properties"] as? [String: String])?["RMNetState"] == "up", "statusJSON: flat properties of strings")
        check((json["properties"] as? [String: String])?["RMNetRxBytes"] == "5", "statusJSON: counters as strings")
        check(json["modem"] as? String == "qmi" && json["qmiInterface"] as? Int == 4, "statusJSON: modem", "\(json)")
        check(json["canActivate"] as? Bool == true && json["error"] == nil, "statusJSON: canActivate, no error", "\(json)")
        let unknown = statusJSON(status([], attached: true, ["RMNetState": "up"]), bundledVersion: "316.19.56",
                                 listingError: "no answer from the system in 10 s")
        check(JSONSerialization.isValidJSONObject(unknown), "statusJSON unknown: valid JSON object")
        check(unknown["headline"] as? String == "Unknown", "statusJSON unknown: headline is Unknown, not Not installed", "\(unknown)")
        check(unknown["entries"] is NSNull, "statusJSON unknown: entries null", "\(unknown)")
        check(unknown["error"] as? String == "no answer from the system in 10 s", "statusJSON unknown: error kept")
        check(unknown["canActivate"] as? Bool == false && unknown["canRemoveDirectly"] as? Bool == false,
              "statusJSON unknown: no button may act", "\(unknown)")
        check((unknown["properties"] as? [String: String])?["RMNetState"] == "up", "statusJSON unknown: registry still read")

        print("app-test: \(checks) checks passed")
    }
}
