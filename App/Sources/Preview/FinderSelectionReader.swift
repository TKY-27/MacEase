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
                let parsed = FinderSelectionReader.parse(response)
                if case .failure = parsed {
                    logger.error("Finder returned an unusable selection response")
                }
                return parsed
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
