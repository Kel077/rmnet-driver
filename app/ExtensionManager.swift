// System extension requests for the RMNet app: activation, deactivation and the properties request,
// each with completion handlers called on the main queue. Used by the window and the command-line
// verbs alike.
import Foundation
import SystemExtensions

let driverID = "io.rmnetdriver.RMNet.driver"

// The CFBundleVersion of the driver embedded in this app, or nil if this binary is not running
// from an app bundle that carries one.
func bundledDriverVersion() -> String? {
    let url = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Library/SystemExtensions/\(driverID).dext")
    return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
}

extension ExtensionEntry {
    init(_ p: OSSystemExtensionProperties) {
        self.init(version: p.bundleVersion, enabled: p.isEnabled, awaitingApproval: p.isAwaitingUserApproval,
                  uninstalling: p.isUninstalling)
    }
}

// The system's answer to an activation or deactivation request.
enum RequestOutcome {
    case completed
    case willCompleteAfterReboot
    case other(Int)        // a result this code does not know, by its raw value
    case failed(Error)
}

// The system's answer to a properties request.
enum PropertiesAnswer {
    case listed([OSSystemExtensionProperties])
    case notListed(RequestOutcome)  // finished or failed without a listing
    case noAnswer                   // no answer within the timeout
}

// How a removal ended.
enum RemoveResult {
    case notSent(String)                   // nothing was sent; why
    case activationEnded(RequestOutcome)   // the install-first step ended other than completed
    case listingAfterActivation(String)    // after it, the listing did not allow the removal
    case deactivation(RequestOutcome)      // the system's answer to the deactivation
}

// The system's own words for an error, and its code.
func describe(_ error: Error) -> String {
    "\(error.localizedDescription) (code \((error as NSError).code))"
}

final class ExtensionManager {
    // Requests in flight keep their delegates here until they finish.
    private var delegates: [ObjectIdentifier: RequestDelegate] = [:]

    // Lists the system's entries for the driver. With a timeout, a request that has not answered by
    // then reports `.noAnswer`, and a later answer is ignored.
    func properties(timeout: TimeInterval? = nil, completion: @escaping (PropertiesAnswer) -> Void) {
        let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: driverID, queue: .main)
        let d = RequestDelegate()
        var answered = false
        let answer = { (a: PropertiesAnswer) in
            guard !answered else { return }
            answered = true
            completion(a)
        }
        d.onProperties = { answer(.listed($0)) }
        // A properties request normally answers with properties; a finish without them is not a listing.
        d.onFinish = { answer(.notListed($0)) }
        submit(request, d)
        if let timeout = timeout {
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { answer(.noAnswer) }
        }
    }

    // Activates the embedded driver, replacing any installed version. `replacing` and
    // `needsApproval` report the system's questions; `completion` its answer.
    func activate(replacing: @escaping (_ old: String, _ new: String) -> Void = { _, _ in },
                  needsApproval: @escaping () -> Void = {},
                  completion: @escaping (RequestOutcome) -> Void) {
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: driverID, queue: .main)
        let d = RequestDelegate()
        d.onReplace = replacing
        d.onNeedsApproval = needsApproval
        d.onFinish = completion
        submit(request, d)
    }

    // Deactivates the installed driver. The system asks the owner for an administrator password, and
    // refuses unless the installed version is the one this app embeds.
    func deactivate(needsApproval: @escaping () -> Void = {}, completion: @escaping (RequestOutcome) -> Void) {
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: driverID, queue: .main)
        let d = RequestDelegate()
        d.onNeedsApproval = needsApproval
        d.onFinish = completion
        submit(request, d)
    }

    // Removes the driver, following `removalPlan`:
    //   .deactivate: asks for the deactivation (the system asks for an administrator password).
    //   .activateThenDeactivate: activates the bundled version first (a replacement of the one
    //     listed entry); only if that completes, lists again, and deactivates only if the listing
    //     now holds exactly the bundled version. Any other answer stops here and is reported.
    //   .cannot, .nothingListed: sends nothing.
    // `step` reports what is being asked.
    func remove(status: DriverStatus, bundledVersion: String, step: @escaping (String) -> Void,
                completion: @escaping (RemoveResult) -> Void) {
        let deactivateNow = {
            step("Asking the system to remove the driver; macOS asks for an administrator password.")
            self.deactivate { completion(.deactivation($0)) }
        }
        switch removalPlan(status, bundledVersion: bundledVersion) {
        case .nothingListed:
            completion(.notSent("The system lists no driver it is not already removing; there is nothing to remove."))
        case .cannot:
            completion(.notSent(cannotRemoveText(status, bundledVersion: bundledVersion)))
        case .deactivate:
            deactivateNow()
        case .activateThenDeactivate:
            step("Installing version \(bundledVersion) first, so that this app can remove it.")
            activate(needsApproval: { step("Waiting for approval in System Settings before removing.") }) { outcome in
                guard case .completed = outcome else {
                    completion(.activationEnded(outcome))
                    return
                }
                step("The system accepted version \(bundledVersion); reading the listing again.")
                self.properties(timeout: 10) { answer in
                    guard case .listed(let found) = answer else {
                        completion(.listingAfterActivation("the system did not list the driver"))
                        return
                    }
                    let entries = found.map(ExtensionEntry.init)
                    let now = DriverStatus(entries: entries, modem: status.modem, attached: status.attached,
                                           properties: status.properties)
                    if canRemoveDirectly(now, bundledVersion: bundledVersion) {
                        deactivateNow()
                    } else {
                        completion(.listingAfterActivation("the system lists " + describeListing(entries)))
                    }
                }
            }
        }
    }

    private func submit(_ request: OSSystemExtensionRequest, _ d: RequestDelegate) {
        let id = ObjectIdentifier(d)
        let finish = d.onFinish
        let found = d.onProperties
        d.onFinish = { [weak self] outcome in
            self?.delegates[id] = nil
            finish?(outcome)
        }
        if let found = found {
            d.onProperties = { [weak self, weak d] props in
                self?.delegates[id] = nil
                d?.onFinish = nil  // answered; a later result for the same request is ignored
                found(props)
            }
        }
        delegates[id] = d
        request.delegate = d
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

private final class RequestDelegate: NSObject, OSSystemExtensionRequestDelegate {
    var onReplace: ((String, String) -> Void)?
    var onNeedsApproval: (() -> Void)?
    var onProperties: (([OSSystemExtensionProperties]) -> Void)?
    var onFinish: ((RequestOutcome) -> Void)?

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        onReplace?(existing.bundleVersion, ext.bundleVersion)
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onNeedsApproval?()
    }

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let found = onProperties
        onProperties = nil
        found?(properties)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let finish = onFinish
        onFinish = nil
        switch result {
        case .completed: finish?(.completed)
        case .willCompleteAfterReboot: finish?(.willCompleteAfterReboot)
        @unknown default: finish?(.other(result.rawValue))
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let finish = onFinish
        onFinish = nil
        finish?(.failed(error))
    }
}
