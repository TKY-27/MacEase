import ApplicationServices
import Engine
import Foundation
import Synchronization
import os

enum FinderWindowView: Equatable, Sendable {
    case icon, list, column, gallery, unknown

    var showsIconSizeSlider: Bool { self == .icon || self == .unknown }
}

@MainActor
final class FinderSelectionReader {
    struct Selection: Sendable {
        let windowID: UInt32
        let urls: [URL]
        /// Nil for Recents, searches and similar windows.
        var folder: URL? = nil
        var view: FinderWindowView = .unknown
    }

    enum Failure: Error {
        case automationDenied, timedOut, unavailable
    }

    // Finder.sdef ecvw enumerator codes.
    private enum ViewCode {
        static let icon: OSType = 0x6963_6E76
        static let list: OSType = 0x6C73_7677
        static let column: OSType = 0x636C_7677
        static let gallery: OSType = 0x666C_7677
    }

    private struct PendingRequest {
        let asking: Bool
        let isCurrent: @MainActor () -> Bool
        let completion: @MainActor (Result<Selection, Failure>) -> Void
    }

    private let requestConsent: @Sendable (Bool) -> Failure?
    private let readSelection: @Sendable () -> Result<Selection, Failure>
    private let queue = DispatchQueue(label: "io.github.tky27.MacEase.finder-selection", qos: .userInitiated)
    private var inFlight = false
    private var inFlightAsking = false
    private var pendingAsking: PendingRequest?
    private var authorized = false

    init() {
        let worker = ScriptWorker()
        requestConsent = { worker.requestConsent(asking: $0) }
        readSelection = { worker.read() }
    }

    init(
        requestConsent: @escaping @Sendable (Bool) -> Failure?,
        readSelection: @escaping @Sendable () -> Result<Selection, Failure>
    ) {
        self.requestConsent = requestConsent
        self.readSelection = readSelection
    }

    // Without asking, undetermined consent counts as denied.
    func read(
        asking: Bool, isCurrent: @escaping @MainActor () -> Bool,
        completion: @escaping @MainActor (Result<Selection, Failure>) -> Void
    ) {
        let request = PendingRequest(asking: asking, isCurrent: isCurrent, completion: completion)
        guard !inFlight else {
            // Never drop user-initiated consent behind silent polls.
            if asking, !inFlightAsking { pendingAsking = request }
            return
        }
        start(request)
    }

    private func start(_ request: PendingRequest) {
        inFlight = true
        inFlightAsking = request.asking
        Task {
            defer {
                inFlight = false
                inFlightAsking = false
                if let next = pendingAsking {
                    pendingAsking = nil
                    start(next)
                }
            }
            guard request.isCurrent() else { return }
            if !authorized {
                let failure = await withCheckedContinuation { continuation in
                    queue.async { [requestConsent] in
                        continuation.resume(returning: requestConsent(request.asking))
                    }
                }
                if let failure {
                    if request.isCurrent() { request.completion(.failure(failure)) }
                    return
                }
                authorized = true
                guard request.isCurrent() else { return }
            }
            let result = await withCheckedContinuation { continuation in
                queue.async { [readSelection] in continuation.resume(returning: readSelection()) }
            }
            if case .failure(.automationDenied) = result { authorized = false }
            if request.isCurrent() { request.completion(result) }
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

    nonisolated static func parse(_ response: NSAppleEventDescriptor) -> Result<Selection, Failure> {
        guard response.descriptorType == typeAEList, (3...4).contains(response.numberOfItems),
            let identifier = response.atIndex(1), identifier.int32Value > 0,
            let selection = response.atIndex(2), selection.descriptorType == typeAEList
        else { return .failure(.unavailable) }
        var urls: [URL] = []
        if selection.numberOfItems > 0 {
            for index in 1...selection.numberOfItems {
                guard let descriptor = selection.atIndex(index), let url = localFileURL(descriptor) else {
                    return .failure(.unavailable)
                }
                urls.append(url)
            }
        }
        // Recents and searches report no folder.
        let folder = response.atIndex(3).flatMap(localFileURL)
        let view = response.atIndex(4).map(windowView) ?? .unknown
        return .success(Selection(windowID: UInt32(identifier.int32Value), urls: urls, folder: folder, view: view))
    }

    nonisolated private static func localFileURL(_ descriptor: NSAppleEventDescriptor) -> URL? {
        guard let address = descriptor.stringValue, !address.isEmpty,
            let url = URL(string: address), url.isFileURL, !url.path.isEmpty,
            url.host == nil || url.host == "" || url.host == "localhost"
        else { return nil }
        return url
    }

    nonisolated static func windowView(_ descriptor: NSAppleEventDescriptor) -> FinderWindowView {
        if descriptor.descriptorType == typeEnumerated {
            switch descriptor.enumCodeValue {
            case ViewCode.icon: return .icon
            case ViewCode.list: return .list
            case ViewCode.column: return .column
            case ViewCode.gallery: return .gallery
            default: return .unknown
            }
        }
        switch descriptor.stringValue?.lowercased() {
        case "icnv", "icon view": return .icon
        case "lsvw", "list view": return .list
        case "clvw", "column view": return .column
        case "flvw", "flow view", "group view", "gallery view": return .gallery
        default: return .unknown
        }
    }

    private final class ScriptWorker: Sendable {
        private let script = Mutex<NSAppleScript?>(nil)
        private let loggedSilentDenial = Mutex(false)
        private let logger = Logger(category: "finder-preview")
        private static let deniedCodes = [Int(errAEEventNotPermitted), Int(errAEEventWouldRequireUserConsent)]
        private static let timeoutCode = Int(errAETimeout)
        private static let source = """
            with timeout of 2 seconds
                tell application id "com.apple.finder"
                    if (count of windows) is 0 then return {0, {}, "", ""}
                    set windowID to id of front window
                    set selectedURLs to {}
                    repeat with selectedFile in (get selection)
                        set end of selectedURLs to URL of selectedFile
                    end repeat
                    set folderURL to ""
                    try
                        set folderURL to URL of (target of front window)
                    end try
                    set viewMode to ""
                    try
                        set viewMode to current view of front window
                    end try
                    if windowID is not id of front window then return {0, {}, "", ""}
                    return {windowID, selectedURLs, folderURL, viewMode}
                end tell
            end timeout
            """

        func requestConsent(asking: Bool) -> Failure? {
            let permission = FinderSelectionReader.automationPermission(asking: asking)
            if permission == noErr {
                loggedSilentDenial.withLock { $0 = false }
                return nil
            }
            return rejected(Int(permission), silent: !asking)
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
                let parsed = FinderSelectionReader.parse(response)
                if case .failure = parsed {
                    logger.error("Finder returned an unusable selection response")
                }
                return parsed
            }
        }

        private func rejected(_ code: Int?, silent: Bool = false) -> Failure {
            let failure: Failure =
                switch code {
                case let code? where Self.deniedCodes.contains(code): .automationDenied
                case Self.timeoutCode: .timedOut
                default: .unavailable
                }
            if silent, failure == .automationDenied {
                let alreadyLogged = loggedSilentDenial.withLock { logged in
                    defer { logged = true }
                    return logged
                }
                if !alreadyLogged {
                    logger.error("Finder selection request failed: \(code ?? 0)")
                }
            } else {
                logger.error("Finder selection request failed: \(code ?? 0)")
            }
            return failure
        }
    }
}
