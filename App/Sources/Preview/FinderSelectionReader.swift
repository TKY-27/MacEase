import ApplicationServices
import Engine
import Foundation
import Synchronization
import os

@MainActor
final class FinderSelectionReader {
    struct Selection: Sendable {
        let windowID: UInt32
        let urls: [URL]
    }

    enum Failure: Error {
        case automationDenied, timedOut, unavailable
    }

    private let worker = ScriptWorker()
    private let queue = DispatchQueue(label: "io.github.tky27.MacEase.finder-selection", qos: .userInitiated)
    private var inFlight = false
    private var authorized = false

    // Without asking, undetermined consent counts as denied.
    func read(
        asking: Bool, isCurrent: @escaping @MainActor () -> Bool,
        completion: @escaping @MainActor (Result<Selection, Failure>) -> Void
    ) {
        guard !inFlight else { return }
        inFlight = true
        Task {
            defer { inFlight = false }
            guard isCurrent() else { return }
            if !authorized {
                let failure = await withCheckedContinuation { continuation in
                    queue.async { [worker] in continuation.resume(returning: worker.requestConsent(asking: asking)) }
                }
                if let failure {
                    if isCurrent() { completion(.failure(failure)) }
                    return
                }
                authorized = true
                guard isCurrent() else { return }
            }
            let result = await withCheckedContinuation { continuation in
                queue.async { [worker] in continuation.resume(returning: worker.read()) }
            }
            if case .failure(.automationDenied) = result { authorized = false }
            if isCurrent() { completion(result) }
        }
    }

    // Blocks until Finder answers.
    nonisolated static func automationPermission(asking: Bool) -> OSStatus {
        let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        return withExtendedLifetime(finder) {
            guard let target = finder.aeDesc else { return OSStatus(paramErr) }
            return AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, asking)
        }
    }

    private final class ScriptWorker: Sendable {
        private let script = Mutex<NSAppleScript?>(nil)
        private let logger = Logger(category: "finder-preview")
        private static let deniedCodes = [Int(errAEEventNotPermitted), Int(errAEEventWouldRequireUserConsent)]
        private static let timeoutCode = Int(errAETimeout)
        private static let source = """
            with timeout of 2 seconds
                tell application id "com.apple.finder"
                    if (count of windows) is 0 then return {0, {}}
                    set windowID to id of front window
                    set selectedURLs to {}
                    repeat with selectedFile in (get selection)
                        set end of selectedURLs to URL of selectedFile
                    end repeat
                    if windowID is not id of front window then return {0, {}}
                    return {windowID, selectedURLs}
                end tell
            end timeout
            """

        func requestConsent(asking: Bool) -> Failure? {
            let permission = FinderSelectionReader.automationPermission(asking: asking)
            return permission == noErr ? nil : rejected(Int(permission))
        }

        func read() -> Result<Selection, Failure> {
            script.withLock { compiled in
                var failure: NSDictionary?
                if compiled == nil {
                    guard let candidate = NSAppleScript(source: Self.source), candidate.compileAndReturnError(&failure)
                    else { return .failure(rejected((failure?[NSAppleScript.errorNumber] as? NSNumber)?.intValue)) }
                    compiled = candidate
                }
                guard let compiled else { return .failure(.unavailable) }
                let response = compiled.executeAndReturnError(&failure)
                if let failure {
                    let code = (failure[NSAppleScript.errorNumber] as? NSNumber)?.intValue
                    return .failure(rejected(code))
                }
                guard response.numberOfItems == 2, let identifier = response.atIndex(1),
                    identifier.int32Value > 0, let selection = response.atIndex(2),
                    selection.descriptorType == typeAEList
                else {
                    logger.error("Finder returned no stable front window")
                    return .failure(.unavailable)
                }
                var urls: [URL] = []
                if selection.numberOfItems > 0 {
                    for index in 1...selection.numberOfItems {
                        guard let address = selection.atIndex(index)?.stringValue,
                            let url = URL(string: address), url.isFileURL,
                            url.host == nil || url.host == "" || url.host == "localhost"
                        else {
                            logger.error("Finder returned an invalid file URL")
                            return .failure(.unavailable)
                        }
                        urls.append(url)
                    }
                }
                return .success(Selection(windowID: UInt32(identifier.int32Value), urls: urls))
            }
        }

        private func rejected(_ code: Int?) -> Failure {
            logger.error("Finder selection request failed: \(code ?? 0)")
            switch code {
            case let code? where Self.deniedCodes.contains(code): return .automationDenied
            case Self.timeoutCode: return .timedOut
            default: return .unavailable
            }
        }
    }
}
