import Darwin
import Formats
import Foundation
import MenuCatalog
import Synchronization
import os

public struct ArchiveEntry: Identifiable, Sendable {
    public let id: Int
    public let path: String
    public let isDirectory: Bool
    public let size: Int64?
    public let isEncrypted: Bool

    init(_ entry: ZIPBrowserEntry) {
        id = entry.id
        path = entry.path
        isDirectory = entry.isDirectory
        size = entry.size
        isEncrypted = entry.isEncrypted
    }
}

public enum ArchiveBrowserError: LocalizedError, Equatable, Sendable {
    case closed
    case sourceChanged
    case invalidSelection
    case pathConflict
    case previewInUse
    case zip(ZIPBrowserError)

    public var errorDescription: String? {
        switch self {
        case .closed: String(localized: "The archive browser has closed.")
        case .sourceChanged: String(localized: "The archive changed since it was opened.")
        case .invalidSelection: String(localized: "The archive selection is unavailable.")
        case .pathConflict: String(localized: "Selected archive paths conflict.")
        case .previewInUse: String(localized: "Close the current preview before opening another.")
        case .zip(let cause):
            switch cause {
            case .invalidZIP, .corruptEntry: String(localized: "The ZIP archive is damaged or unsupported.")
            case .tooManyEntries: String(localized: "The ZIP archive exceeds the 100,000-entry limit.")
            case .namesTooLarge: String(localized: "ZIP entry metadata exceeds the 32 MiB limit.")
            case .pathTooDeep: String(localized: "ZIP paths cannot exceed 256 components.")
            case .unsafeEntry, .unsupportedEntry: String(localized: "The ZIP archive contains an unsafe entry.")
            case .selectionTooLarge: String(localized: "Preview files must be 256 MiB or smaller.")
            case .passwordRequired: String(localized: "A password is required for this entry.")
            case .wrongPassword: String(localized: "The archive password is incorrect.")
            }
        }
    }
}

public final class ArchiveBrowserSession: Sendable {
    private struct State {
        var closed = false
        var active = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        var entries: [ArchiveEntry]?
        var stamp: FileStamp?
        var previews: [Int: URL] = [:]
        var stagingRoot: URL?
    }

    private let source: URL
    private let staging: StagingArea
    private let state = Mutex(State())
    private let logger = Logger(category: "archive-browser")

    public init(source: URL, staging: StagingArea) {
        self.source = source
        self.staging = staging
    }

    public func entries() async throws -> [ArchiveEntry] {
        try checkOpen()
        try checkRegularSource()
        if let existing = state.withLock({ $0.entries }) {
            try checkStamp()
            return existing
        }
        try begin()
        let job = Task.detached { [self] in
            defer { end() }
            return try coordinatedRead {
                try checkRegularSource()
                let stamp = try FileStamp(of: source, includingIdentity: true)
                let listed = try ArchiveBrowserZIP.list(source, check: checkOpen).map(ArchiveEntry.init)
                guard stamp.matches(source.path) else { throw ArchiveBrowserError.sourceChanged }
                try state.withLock { state in
                    guard !state.closed else { throw ArchiveBrowserError.closed }
                    state.stamp = stamp
                    state.entries = listed
                }
                return listed
            }
        }
        do {
            return try await withTaskCancellationHandler {
                try await job.value
            } onCancel: {
                job.cancel()
            }
        } catch {
            throw mapped(error)
        }
    }

    public func preview(entryID: Int, password: String?) async throws -> URL {
        try checkOpen()
        let listed = try await entries()
        guard let entry = listed.first(where: { $0.id == entryID && !$0.isDirectory }) else {
            throw ArchiveBrowserError.invalidSelection
        }
        if let existing = state.withLock({ $0.previews[entryID] }) { return existing }
        try begin()
        let job = Task.detached { [self] in
            defer { end() }
            return try coordinatedRead {
                try checkStamp()
                let root = try previewRoot()
                let fileExtension = URL(fileURLWithPath: entry.path).pathExtension
                let suffix = fileExtension.utf8.count <= 16 && !fileExtension.isEmpty ? "." + fileExtension : ""
                let output = root.appending(path: UUID().uuidString + suffix)
                do {
                    try ArchiveBrowserZIP.extract(
                        source, ordinal: entryID, to: output, password: password,
                        limit: ArchiveBrowserZIP.previewLimit, check: checkOpen)
                    try ArchivePlanner.propagateQuarantine(from: source, to: output)
                    try checkStamp()
                    return try state.withLock { state in
                        guard !state.closed else { throw ArchiveBrowserError.closed }
                        guard state.previews.isEmpty else { throw ArchiveBrowserError.previewInUse }
                        state.previews[entryID] = output
                        return output
                    }
                } catch {
                    removePreviewFile(output)
                    throw mapped(error)
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    public func releasePreview(entryID: Int) async {
        let url = state.withLock { $0.previews.removeValue(forKey: entryID) }
        if let url { removePreviewFile(url) }
    }

    public func batch(
        entryIDs: Set<Int>, password: String?, to destination: URL, operation: OperationID,
        exportsFolder: Bool = false
    ) async throws -> Batch {
        let listed = try await entries()
        try checkStamp()
        guard !entryIDs.isEmpty, entryIDs.isSubset(of: Set(listed.map(\.id))) else {
            throw ArchiveBrowserError.invalidSelection
        }
        let selectedDirectories = Set(listed.filter { entryIDs.contains($0.id) && $0.isDirectory }.map(\.path))
        let selected = listed.filter { entry in
            if entryIDs.contains(entry.id) { return true }
            var ancestor = ""
            for part in entry.path.split(separator: "/").dropLast() {
                ancestor += ancestor.isEmpty ? String(part) : "/" + part
                if selectedDirectories.contains(ancestor) { return true }
            }
            return false
        }
        let outputs = try normalizedOutputPaths(selected)
        let files = outputs.filter { !$0.isDirectory }
        let directFile = !exportsFolder && entryIDs.count == 1 && outputs.count == 1 && files.count == 1
        let stamp = try state.withLock { state -> FileStamp in
            guard !state.closed else { throw ArchiveBrowserError.closed }
            guard let stamp = state.stamp else { throw ArchiveBrowserError.sourceChanged }
            return stamp
        }
        let outputName =
            directFile ? destination.lastPathComponent : source.deletingPathExtension().lastPathComponent + "_selected"
        let outputParent = directFile ? destination.deletingLastPathComponent() : destination
        guard destination.isFileURL, AvailableName.checkedName(outputName) else {
            throw ArchiveBrowserError.invalidSelection
        }
        let source = self.source
        let work = WorkItem(inputs: [source]) { [self] context in
            try begin()
            defer { end() }
            try checkStamp()
            let root = try context.stagingDirectory(for: outputParent)
            let staged = root.appending(path: outputName, directoryHint: directFile ? .notDirectory : .isDirectory)
            if !directFile { try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false) }
            do {
                try coordinatedRead {
                    let outputLimit = ExtractionLimits.standard.limit(forArchiveBytes: stamp.size ?? 0)
                    var destinations: [Int: URL] = [:]
                    for entry in files {
                        try checkOpen()
                        let target = directFile ? staged : staged.appending(path: entry.path)
                        if !directFile {
                            try FileManager.default.createDirectory(
                                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        }
                        destinations[entry.id] = target
                    }
                    if !destinations.isEmpty {
                        try ArchiveBrowserZIP.extract(
                            source, selections: destinations, password: password,
                            limit: outputLimit, preserveAttributes: true, check: checkOpen)
                    }
                    for entry in outputs where entry.isDirectory && !directFile {
                        try FileManager.default.createDirectory(
                            at: staged.appending(path: entry.path), withIntermediateDirectories: true)
                    }
                    try ArchivePlanner.propagateQuarantine(from: source, to: staged)
                    try checkStamp()
                }
                try checkOpen()
            } catch {
                throw engineError(error)
            }
            return .exported(
                from: source, stamp: stamp, to: outputParent.appending(path: outputName),
                outputs: [
                    StagedFile(
                        url: staged, name: outputName, check: directFile ? .archiveMember : .archiveSelectionFolder)
                ],
                preservingAttributes: false)
        }
        return Batch(operation: operation, items: [work])
    }

    public func close() async {
        let waiting = state.withLock { state -> Bool in
            state.closed = true
            return state.active > 0
        }
        if waiting {
            await withCheckedContinuation { continuation in
                let resume = state.withLock { state -> Bool in
                    if state.active == 0 { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if resume { continuation.resume() }
            }
        }
        let root = state.withLock { state -> URL? in
            state.previews.removeAll()
            defer { state.stagingRoot = nil }
            return state.stagingRoot
        }
        if let root { staging.remove(root) }
    }

    private func normalizedOutputPaths(_ selected: [ArchiveEntry]) throws -> [ArchiveEntry] {
        var paths: [String: ArchiveEntry] = [:]
        var files = Set<String>()
        var outputs: [ArchiveEntry] = []
        for entry in selected {
            let path = entry.path.precomposedStringWithCanonicalMapping.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if let existing = paths[path] {
                guard existing.isDirectory, entry.isDirectory, existing.path == entry.path else {
                    throw ArchiveBrowserError.pathConflict
                }
                continue
            }
            paths[path] = entry
            outputs.append(entry)
            if !entry.isDirectory { files.insert(path) }
        }
        for path in paths.keys {
            let parts = path.split(separator: "/")
            for depth in 1..<parts.count where files.contains(parts.prefix(depth).joined(separator: "/")) {
                throw ArchiveBrowserError.pathConflict
            }
        }
        return outputs
    }

    private func begin() throws {
        try state.withLock { state in
            guard !state.closed else { throw ArchiveBrowserError.closed }
            state.active += 1
        }
    }

    private func end() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.active -= 1
            guard state.active == 0 else { return [] }
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    private func checkOpen() throws {
        try Task.checkCancellation()
        guard !state.withLock({ $0.closed }) else { throw ArchiveBrowserError.closed }
    }

    private func checkRegularSource() throws {
        var metadata = stat()
        guard lstat(source.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw ArchiveBrowserError.zip(.invalidZIP)
        }
    }

    private func checkStamp() throws {
        try checkOpen()
        try checkRegularSource()
        guard let stamp = state.withLock({ $0.stamp }), stamp.matches(source.path) else {
            throw ArchiveBrowserError.sourceChanged
        }
    }

    private func previewRoot() throws -> URL {
        try state.withLock { state in
            guard !state.closed else { throw ArchiveBrowserError.closed }
            if let root = state.stagingRoot { return root }
            let local = FileManager.default.temporaryDirectory
            let root = try staging.makeDirectory(for: local)
            state.stagingRoot = root
            return root
        }
    }

    private func coordinatedRead<T>(_ body: () throws -> T) throws -> T {
        try checkRegularSource()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, any Error>?
        coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { _ in
            result = Result { try body() }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ArchiveBrowserError.sourceChanged }
        return try result.get()
    }

    private func removePreviewFile(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            let failure = error as NSError
            logger.error(
                "Preview removal failed: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)"
            )
        }
    }

    private func engineError(_ error: any Error) -> EngineError {
        if let zip = error as? ZIPBrowserError {
            switch zip {
            case .passwordRequired: return .invalidInput(.passwordRequired)
            case .wrongPassword: return .invalidInput(.wrongPassword)
            case .selectionTooLarge:
                let limit = ExtractionLimits.standard.limit(forArchiveBytes: state.withLock { $0.stamp?.size ?? 0 })
                return .invalidInput(.archiveExpandsTooMuch(limitBytes: limit))
            default: return .invalidInput(.malformed(ArchiveBrowserError.zip(zip).localizedDescription))
            }
        }
        if let browser = error as? ArchiveBrowserError {
            if browser == .closed { return .cancelled }
            return .invalidInput(.malformed(browser.localizedDescription))
        }
        return EngineError.wrapping(error, path: source.path)
    }

    private func mapped(_ error: any Error) -> any Error {
        if let zip = error as? ZIPBrowserError { return ArchiveBrowserError.zip(zip) }
        return error
    }
}
