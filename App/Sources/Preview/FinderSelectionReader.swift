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

    func read(_ completion: @escaping @MainActor (Result<Selection, Failure>) -> Void) {
        guard !inFlight else { return }
        inFlight = true
        queue.async { [worker, weak self] in
            let result = worker.read()
            Task { @MainActor in
                self?.inFlight = false
                completion(result)
            }
        }
    }

    private final class ScriptWorker: Sendable {
        private let script = Mutex<NSAppleScript?>(nil)
        private let logger = Logger(category: "finder-preview")
        private static let deniedCode = -1743
        private static let timeoutCode = -1712
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

        func read() -> Result<Selection, Failure> {
            script.withLock { compiled in
                var failure: NSDictionary?
                if compiled == nil {
                    guard let candidate = NSAppleScript(source: Self.source), candidate.compileAndReturnError(&failure)
                    else { return rejected(failure) }
                    compiled = candidate
                }
                guard let compiled else { return .failure(.unavailable) }
                let response = compiled.executeAndReturnError(&failure)
                if let failure { return rejected(failure) }
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

        private func rejected(_ failure: NSDictionary?) -> Result<Selection, Failure> {
            let code = (failure?[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            logger.error("Finder selection request failed: \(code ?? 0)")
            switch code {
            case Self.deniedCode: return .failure(.automationDenied)
            case Self.timeoutCode: return .failure(.timedOut)
            default: return .failure(.unavailable)
            }
        }
    }
}
