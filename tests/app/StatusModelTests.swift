// Tests for app/StatusModel.swift: the headline, the advice, canRemoveDirectly, the removal texts,
// the install confirmation, the table rows and the JSON form. Built with swiftc by `make app-test`; needs no Xcode project and no hardware.
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

        // More than one entry with none switched off (a replacement under way, say): the listing in
        // words, not the switched-off line. A switched-off entry among them keeps the switched-off line.
        let moreThanOne = "The system lists more than one entry for the driver"
        let bothOn = advice(status([enabled, ExtensionEntry(version: "316.21.4", enabled: true, awaitingApproval: false, uninstalling: false)]),
                            bundledVersion: "316.19.56")
        check(!bothOn.contains { $0.contains("switched off") }, "advice: two enabled entries do not say switched off", "\(bothOn)")
        check(bothOn.contains("The system lists more than one entry for the driver: 316.19.56 (enabled), 316.21.4 (enabled). This can be a replacement still under way; while it lasts, the system refuses a new installation."),
              "advice: two enabled entries say the system lists more than one entry", "\(bothOn)")
        check(bothOn.last == alwaysLine, "advice: two enabled entries end with the standing line", "\(bothOn)")
        let replacing = advice(status([enabled, ExtensionEntry(version: "316.21.4", enabled: false, awaitingApproval: true, uninstalling: false)]),
                               bundledVersion: "316.21.4")
        check(!replacing.contains { $0.contains("switched off") } && replacing.contains { $0.hasPrefix(moreThanOne) },
              "advice: an enabled entry and one awaiting approval are not called switched off", "\(replacing)")
        check(two.contains { $0.contains("switched off in System Settings") } && !two.contains { $0.hasPrefix(moreThanOne) },
              "advice: one switched-off entry among two keeps the switched-off line only", "\(two)")

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
        // 317.9 and 317.9.0 are the same version, as installTitle sees them ("Reinstall").
        let short = ExtensionEntry(version: "317.9", enabled: true, awaitingApproval: false, uninstalling: false)
        check(canRemoveDirectly(status([short]), bundledVersion: "317.9.0"), "canRemoveDirectly: 317.9 listed, 317.9.0 bundled")
        check(removalPlan(status([short]), bundledVersion: "317.9.0") == .deactivate,
              "removalPlan: 317.9 listed, 317.9.0 bundled deactivates it")
        let shortOff = ExtensionEntry(version: "317.9", enabled: false, awaitingApproval: false, uninstalling: false)
        let other = ExtensionEntry(version: "317.10.17", enabled: true, awaitingApproval: false, uninstalling: false)
        check(removalPlan(status([shortOff, other]), bundledVersion: "317.9.0") == .deactivate,
              "removalPlan: stuck, 317.9 listed switched off, 317.9.0 bundled deactivates it")

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
        check(leavingAdvice == [removalUnderWayLine], "advice: only uninstalling entries gives only the removal line",
              "\(leavingAdvice)")
        check(!leavingAdvice.contains { $0.contains("build/installed/") || $0.contains("Use Remove") },
              "advice: uninstalling names no kept app and no Remove", "\(leavingAdvice)")
        let leavingNotQMI = advice(status([leaving], .notQMI), bundledVersion: "316.21.4")
        check(leavingNotQMI.contains("AT+QCFG=\"usbnet\",0") && leavingNotQMI.contains("AT+CFUN=1,1"),
              "advice: only uninstalling entries, modem not in QMI mode, still names the two AT commands", "\(leavingNotQMI)")
        check(leavingNotQMI.last == removalUnderWayLine
                && !leavingNotQMI.contains { $0.contains("build/installed/") || $0.contains("Use Remove") },
              "advice: only uninstalling entries, modem not in QMI mode, ends with the removal line and names no Remove",
              "\(leavingNotQMI)")

        // --- removalPlan, for an app carrying B = 316.21.4 (A = 316.19.56) --------------------
        let b = "316.21.4"
        let plans: [(String, [ExtensionEntry], RemovalPlan)] = [
            ("[A enabled]", [enabled], .activateThenDeactivate),
            ("[A switched off]", [switchedOff], .cannot),
            ("[A enabled, B enabled]", [enabled, bEnabled], .deactivate),
            ("[A switched off, B enabled]", [switchedOff, bEnabled], .deactivate),
            ("[B enabled]", [bEnabled], .deactivate),
            ("[A uninstalling]", [leaving], .nothingListed),
            ("no entry", [], .nothingListed),
        ]
        for (name, entries, want) in plans {
            let got = removalPlan(status(entries), bundledVersion: b)
            check(got == want, "removalPlan: \(name)", "want \(want), got \(got)")
        }
        check(removalPlan(status([enabled]), bundledVersion: "") == .cannot, "removalPlan: unknown bundled version")

        // --- a removal under way, for an app carrying B (A1) -------------------------------------
        let bLeaving = ExtensionEntry(version: b, enabled: true, awaitingApproval: false, uninstalling: true)
        struct Under { var name: String; var entries: [ExtensionEntry]; var plan: RemovalPlan
                       var canActivate: Bool; var canRemoveDirectly: Bool; var title: String }
        let under: [Under] = [
            Under(name: "[B enabled]", entries: [bEnabled], plan: .deactivate,
                  canActivate: true, canRemoveDirectly: true, title: "Reinstall"),
            Under(name: "[B uninstalling]", entries: [bLeaving], plan: .nothingListed,
                  canActivate: false, canRemoveDirectly: false, title: "Install"),
            Under(name: "[A uninstalling]", entries: [leaving], plan: .nothingListed,
                  canActivate: false, canRemoveDirectly: false, title: "Install"),
            Under(name: "[A enabled, B uninstalling]", entries: [enabled, bLeaving], plan: .cannot,
                  canActivate: false, canRemoveDirectly: false, title: "Update"),
        ]
        for u in under {
            let s = status(u.entries, attached: true, ["RMNetState": "up"])
            let plan = removalPlan(s, bundledVersion: b)
            check(plan == u.plan, "removal under way: plan for \(u.name)", "want \(u.plan), got \(plan)")
            check(canActivate(s) == u.canActivate, "removal under way: canActivate for \(u.name)")
            check(canRemoveDirectly(s, bundledVersion: b) == u.canRemoveDirectly, "removal under way: canRemoveDirectly for \(u.name)")
            let title = installTitle(s, bundledVersion: b)
            check(title == u.title, "removal under way: title for \(u.name)", "want \(u.title), got \(title)")
        }
        check(advice(status([bLeaving], attached: true, ["RMNetState": "up"]), bundledVersion: b) == [removalUnderWayLine],
              "advice: [B uninstalling] gives only the removal line")
        let mixed = advice(status([enabled, bLeaving]), bundledVersion: b)
        check(mixed.contains { $0.contains("build/installed/RMNet-316.19.56.app") }, "advice: [A enabled, B uninstalling] names A's kept app", "\(mixed)")
        check(!mixed.contains { $0.contains("RMNet-316.21.4.app") }, "advice: [A enabled, B uninstalling] leaves B out", "\(mixed)")
        check(keptAppsLine([bLeaving]) == "", "keptAppsLine: only uninstalling entries gives nothing")
        // Wherever Install is off and the advice is not only the removal line, at least one entry is
        // not uninstalling, so the can't-activate line names a kept app.
        let stuck: [(String, [ExtensionEntry])] = [
            ("[A switched off]", [switchedOff]), ("[A enabled, B enabled]", [enabled, bEnabled]),
            ("[A enabled, B uninstalling]", [enabled, bLeaving]), ("[A switched off, A uninstalling]", [switchedOff, leaving]),
        ]
        for (name, entries) in stuck {
            let line = advice(status(entries), bundledVersion: b).first { $0.hasPrefix("Install and Update are off") }
            let kept = keptAppsLine(entries)
            check(!kept.isEmpty && line == "Install and Update are off until this is cleared. " + kept,
                  "advice: the can't-activate line names the kept apps for \(name)", "\(line ?? "no line")")
        }

        // --- what Remove says when it can send nothing -------------------------------------------
        let cannotLeaving = cannotRemoveText(status([enabled, bLeaving]), bundledVersion: b)
        check(cannotLeaving.contains("version 316.21.4, which the system is already removing")
                && !cannotLeaving.contains("not listed") && cannotLeaving.contains("build/installed/RMNet-316.19.56.app"),
              "cannotRemoveText: the bundled version listed as uninstalling is said to be being removed", cannotLeaving)
        let cannotAbsent = cannotRemoveText(status([switchedOff]), bundledVersion: b)
        check(cannotAbsent.contains("version 316.21.4, which is not listed") && cannotAbsent.contains("build/installed/RMNet-316.19.56.app"),
              "cannotRemoveText: the bundled version not listed is said to be not listed", cannotAbsent)
        let cannotNoDriver = cannotRemoveText(status([enabled]), bundledVersion: "")
        check(cannotNoDriver.contains("carries no driver") && !cannotNoDriver.contains("not listed"),
              "cannotRemoveText: with no embedded driver, says the app carries none", cannotNoDriver)
        check(cannotNoDriver == "This app carries no driver (the version of its embedded driver cannot be read), so it cannot remove the listed one. "
                + keptAppsLine([enabled]),
              "cannotRemoveText: with no embedded driver, the reason then the kept app", cannotNoDriver)

        // --- versions and the install button's title (A2) ----------------------------------------
        let versions: [(String, String, Int)] = [
            ("317.10.2", "317.9.11", 1), ("317.9.11", "317.10.2", -1), ("317.9.11", "317.9.11", 0),
            ("317.9", "317.9.0", 0), ("317.9.1", "317.9", 1), ("317.9a", "317.9b", -1), ("318", "317.99.99", 1),
        ]
        for (x, y, want) in versions {
            check(compareVersions(x, y) == want, "compareVersions(\(x), \(y))", "want \(want), got \(compareVersions(x, y))")
        }
        let installed = ExtensionEntry(version: "317.9.11", enabled: true, awaitingApproval: false, uninstalling: false)
        let titles: [(String, String)] = [("317.10.2", "Update"), ("317.9.11", "Reinstall"), ("317.9.10", "Replace")]
        for (bundled, want) in titles {
            let got = installTitle(status([installed]), bundledVersion: bundled)
            check(got == want, "installTitle: bundled \(bundled) over 317.9.11", "want \(want), got \(got)")
            check(canActivate(status([installed])), "installTitle: the button stays on for \(want)")
        }
        check(installTitle(status([]), bundledVersion: "317.9.11") == "Install", "installTitle: nothing listed")
        check(installTitle(status([installed]), bundledVersion: "") == "Update", "installTitle: unknown bundled version")
        let older = advice(status([installed], attached: true, ["RMNetState": "up"]), bundledVersion: "317.9.10")
        check(older.contains { $0.hasPrefix("Replace will replace version 317.9.11 with version 317.9.10") },
              "advice: an older bundled version says Replace", "\(older)")
        let newer = advice(status([installed], attached: true, ["RMNetState": "up"]), bundledVersion: "317.10.2")
        check(newer.contains { $0.hasPrefix("Update will replace version 317.9.11 with version 317.10.2") },
              "advice: a newer bundled version says Update", "\(newer)")
        let same = advice(status([installed], attached: true, ["RMNetState": "up"]), bundledVersion: "317.9.11")
        check(same == [alwaysLine], "advice: the same version says nothing about replacing", "\(same)")

        // --- describeListing ---------------------------------------------------------------------
        check(describeListing([]) == "none", "describeListing: none")
        check(describeListing([switchedOff, bEnabled]) == "316.19.56 (not enabled), 316.21.4 (enabled)",
              "describeListing: two entries", describeListing([switchedOff, bEnabled]))

        // --- installConfirmed: the listing read after an installation ----------------------------
        check(installConfirmed([enabled], version: "316.19.56"), "installConfirmed: one enabled entry of the version")
        check(installConfirmed([short], version: "317.9.0"), "installConfirmed: 317.9 listed, 317.9.0 installed")
        check(!installConfirmed([switchedOff], version: "316.19.56"), "installConfirmed: one entry of the version, not enabled")
        check(!installConfirmed([waiting], version: "316.19.56"), "installConfirmed: one entry of the version, awaiting approval")
        check(!installConfirmed([enabled, bEnabled], version: "316.19.56"), "installConfirmed: two entries")
        check(!installConfirmed([enabled, enabled], version: "316.19.56"), "installConfirmed: two entries of the version")
        check(!installConfirmed([enabled], version: "316.21.4"), "installConfirmed: one enabled entry of another version")
        check(!installConfirmed([], version: "316.19.56"), "installConfirmed: nothing listed")

        // --- notSentText: why a button press sent nothing ----------------------------------------
        let busyText = "Nothing was sent: another request is still running."
        check(notSentText(action: "Remove", busy: true, known: true) == busyText, "notSentText: busy",
              notSentText(action: "Remove", busy: true, known: true))
        check(notSentText(action: "Remove", busy: true, known: false) == busyText, "notSentText: busy comes before an unknown listing",
              notSentText(action: "Remove", busy: true, known: false))
        check(notSentText(action: "Update", busy: false, known: false)
                == "Nothing was sent: the system's listing is not known right now. Press Update again once the listing has refreshed.",
              "notSentText: listing not known", notSentText(action: "Update", busy: false, known: false))
        check(notSentText(action: "Remove", busy: false, known: true)
                == "Nothing was sent: the listing has changed. Check it and press Remove again.",
              "notSentText: listing changed", notSentText(action: "Remove", busy: false, known: true))

        // --- table rows ------------------------------------------------------------------------
        let props = ["RMNetState": "up", "RMNetIPv4": "10.62.238.140/29 gw 10.62.238.141", "RMNetIPv6": "none",
                     "RMNetProfile": "1", "RMNetTxPackets": "12", "RMNetRxPackets": "7", "RMNetTxDropBusy": "0",
                     "RMNetSomethingNew": "abc"]
        let rows = tableRows(status([enabled], attached: true, props), bundledVersion: "316.21.4", listingKnown: true)
        let names = rows.map { $0.name }
        check(names == ["State", "IPv4", "IPv6", "Profile", "Installed driver version", "Bundled version",
                        "RMNetRxPackets", "RMNetSomethingNew", "RMNetTxPackets"],
              "tableRows: fixed rows, then non-zero counters and unknown keys sorted by name", "\(names)")
        check(rows[0].value == "up" && rows[1].value == "10.62.238.140/29 gw 10.62.238.141",
              "tableRows: state and IPv4 values", "\(rows)")
        check(rows[4].value == "316.19.56" && rows[5].value == "316.21.4", "tableRows: versions", "\(rows)")
        let unknownRows = tableRows(status([enabled], attached: true, props), bundledVersion: "316.21.4", listingKnown: false)
        check(unknownRows.map { $0.name } == names, "tableRows: the same rows when the listing is unknown", "\(unknownRows)")
        check(unknownRows[4].value == "unknown", "tableRows: the installed version is unknown when the listing is unknown",
              "\(unknownRows[4])")
        check(unknownRows[5].value == "316.21.4" && unknownRows[0].value == "up",
              "tableRows: the bundled version and the registry rows stay when the listing is unknown", "\(unknownRows)")
        let unknownNone = tableRows(status([]), bundledVersion: "316.21.4", listingKnown: false)
        check(unknownNone[4].value == "unknown", "tableRows: an unknown listing with no last entry says unknown, not none",
              "\(unknownNone[4])")

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
