// RMNet host app: installs, removes and reports on the RMNet driver extension.
// Usage: RMNet activate | deactivate | status [--json]
//        RMNet (no argument, or opened from the Finder): the status window.
// It must run from /Applications/RMNet.app for activate and deactivate (scripts/install-driver.sh).
// With a verb it prints exactly the lines it always has (scripts read them), opens no window and
// exits by itself.
import Foundation

// MARK: - Command-line output

func printModem(_ modem: ModemState) {
    switch modem {
    case .absent:
        print("modem: 2c7c:0801 not attached")
    case .qmi(let number):
        print("modem: 2c7c:0801 attached, QMI interface \(number) (class, subclass, protocol ff)")
    case .notQMI:
        print("modem: 2c7c:0801 attached, no interface with class, subclass, protocol ff (not in QMI mode)")
    }
}

func printDriverEntry(_ driver: [String: String]?) {
    guard let props = driver else {
        print("driver: no \(driverClass) registry entry (not attached)")
        return
    }
    print("driver: \(driverClass) attached")
    for key in props.keys.sorted() {
        print("  \(key) = \(props[key]!)")
    }
}

func printRegistry() {
    printModem(readModem())
    printDriverEntry(readDriverProperties())
}

// With `error` (the system gave no listing) the headline is "Unknown" and "error" says why.
func printJSON(_ entries: [ExtensionEntry], error: String? = nil) {
    let object = statusJSON(readStatus(entries: entries), bundledVersion: bundledDriverVersion() ?? "",
                            listingError: error)
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

func outcomeWords(_ outcome: RequestOutcome) -> String {
    switch outcome {
    case .completed: return "completed"
    case .willCompleteAfterReboot: return "completes after a reboot"
    case .other(let raw): return "result \(raw)"
    case .failed(let error): return describe(error)
    }
}

// MARK: - Verbs

enum Command: String { case activate, deactivate, status }

func runActivate(_ manager: ExtensionManager) {
    manager.activate(
        replacing: { old, new in print("replacing version \(old) with \(new)") },
        needsApproval: { print("waiting for approval in System Settings") },
        completion: { finished(.activate, $0) })
}

func runDeactivate(_ manager: ExtensionManager) {
    manager.deactivate(needsApproval: { print("waiting for approval in System Settings") },
                       completion: { finished(.deactivate, $0) })
}

func finished(_ command: Command, _ outcome: RequestOutcome) {
    switch outcome {
    case .completed: print("\(command.rawValue): done")
    case .willCompleteAfterReboot: print("\(command.rawValue): done after a reboot")
    case .other(let raw): print("\(command.rawValue): finished with result \(raw)")
    case .failed(let error):
        print("\(command.rawValue) failed: \(error.localizedDescription) (code \((error as NSError).code))")
        exit(1)
    }
    exit(0)
}

func runStatus(_ manager: ExtensionManager, json: Bool) {
    manager.properties { result in
        switch result {
        case .listed(let found):
            if json {
                printJSON(found.map(ExtensionEntry.init))
                exit(0)
            }
            if found.isEmpty {
                print("driver extension: not installed")
            }
            for p in found {
                var flags = [p.isEnabled ? "enabled" : "not enabled"]
                if p.isAwaitingUserApproval { flags.append("awaiting approval") }
                if p.isUninstalling { flags.append("uninstalling") }
                print("driver extension: \(p.bundleIdentifier) version \(p.bundleVersion) (\(p.bundleShortVersion)), "
                      + flags.joined(separator: ", "))
            }
            printRegistry()
            exit(0)
        case .notListed(.failed(let error)):
            let code = (error as NSError).code
            if json {
                printJSON([], error: "\(error.localizedDescription) (code \(code))")
            } else {
                print("driver extension: unknown (\(error.localizedDescription), code \(code))")
                printRegistry()
            }
            exit(1)
        case .notListed(let outcome):
            // Finished without a listing. The plain verb prints what it printed before the window.
            if json {
                printJSON([], error: "the system finished without listing the driver (\(outcomeWords(outcome)))")
                exit(1)
            }
            switch outcome {
            case .willCompleteAfterReboot: print("status: done after a reboot")
            case .other(let raw): print("status: finished with result \(raw)")
            default: print("status: done")
            }
            printRegistry()
            exit(0)
        case .noAnswer:
            break  // no timeout is passed here; the one below answers
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
        if json {
            printJSON([], error: "no answer from the system in 10 s")
        } else {
            print("driver extension: unknown (no answer from the system in 10 s)")
            printRegistry()
        }
        exit(1)
    }
}

// MARK: - Entry point

let args = CommandLine.arguments
// The Finder (and `open`) may pass a process serial number argument; that still means the window.
let verbs = args.dropFirst().filter { !$0.hasPrefix("-psn_") }

if verbs.isEmpty {
    MainActor.assumeIsolated { RMNetApp.main() }
    exit(0)
}

guard let command = Command(rawValue: verbs.first!),
      verbs.count == 1 || (command == .status && verbs.count == 2 && verbs.last == "--json") else {
    print("usage: RMNet activate | deactivate | status [--json]")
    exit(2)
}

let manager = ExtensionManager()
switch command {
case .activate: runActivate(manager)
case .deactivate: runDeactivate(manager)
case .status: runStatus(manager, json: verbs.count == 2)
}
dispatchMain()
