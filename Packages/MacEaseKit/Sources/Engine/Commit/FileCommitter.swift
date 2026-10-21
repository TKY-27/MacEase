import Darwin
import Foundation
import Synchronization
import os

/// Sole path that moves user files.
struct FileCommitter: Sendable {
    private static let namingLock = Mutex(())

    enum Failure: Error {
        case changedSinceScan
        case noTrash
    }

    struct Trashed: Sendable {
        let url: URL
        let stamp: FileStamp?
    }

    struct Replaced: Sendable {
        let output: URL
        let stamp: FileStamp?
        let trashed: Trashed?
        let warning: ItemWarning?
    }

    struct Committed: Sendable {
        let output: URL
        let stamp: FileStamp?
    }

    private let logger = Logger(category: "commit")

    func replace(
        original: URL, with output: StagedFile, cloneDirectory: URL, expectedStamp: FileStamp
    ) async throws -> Replaced {
        try await OutputVerifier.verify(output)
        return try Self.namingLock.withLock { _ in
            try Task.checkCancellation()
            let directory = original.deletingLastPathComponent()
            let keepsName = output.name == original.lastPathComponent
            let changesCase = try Self.isCaseOnlyChange(
                from: original.lastPathComponent, to: output.name, in: directory)
            let destination =
                keepsName
                ? original
                : changesCase
                    ? directory.appending(path: output.name)
                    : try AvailableName.url(for: output.name, in: directory)
            do {
                return try coordinate(replacing: original, destination: destination) { target, final in
                    try Task.checkCancellation()
                    guard try FileStamp(of: target) == expectedStamp else { throw Failure.changedSinceScan }
                    try FinderAttributes(of: target).apply(to: output.url)
                    if keepsName || changesCase {
                        let kept = try replaceKeepingName(
                            original: target, output: output, cloneDirectory: cloneDirectory)
                        if changesCase {
                            do {
                                try FileManager.default.moveItem(at: target, to: final)
                            } catch {
                                logger.error(
                                    "Case change failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public): \(error.localizedDescription, privacy: .private)"
                                )
                                return replaced(output: target, trashed: kept, warning: .outputNameUnchanged)
                            }
                        }
                        return replaced(output: final, trashed: kept, warning: nil)
                    }
                    try FileManager.default.moveItem(at: output.url, to: final)
                    do {
                        return replaced(output: final, trashed: try trashForHistory(target), warning: nil)
                    } catch let error as CocoaError where error.code == .featureUnsupported {
                        return replaced(output: final, trashed: nil, warning: .keptAsDerived)
                    } catch {
                        do {
                            try FileManager.default.moveItem(at: final, to: output.url)
                        } catch {
                            return replaced(output: final, trashed: nil, warning: .originalKept)
                        }
                        throw error
                    }
                }
            } catch Failure.noTrash {
                let derived = try AvailableName.url(for: output.name, in: directory)
                let committed = try coordinate(moving: output.url, to: derived)
                return Replaced(output: committed.output, stamp: committed.stamp, trashed: nil, warning: .keptAsDerived)
            }
        }
    }

    private func replaceKeepingName(original: URL, output: StagedFile, cloneDirectory: URL) throws -> Trashed {
        let clone = cloneDirectory.appending(path: original.lastPathComponent)
        try cloneOrCopy(original, to: clone)
        let trashed: Trashed
        do {
            trashed = try trashForHistory(clone)
        } catch let error as CocoaError where error.code == .featureUnsupported {
            try FileManager.default.removeItem(at: clone)
            throw Failure.noTrash
        }
        do {
            _ = try FileManager.default.replaceItemAt(original, withItemAt: output.url)
        } catch {
            logger.error("Replace failed; an extra copy of the original stays in the Trash")
            throw error
        }
        return trashed
    }

    private func replaced(output: URL, trashed: Trashed?, warning: ItemWarning?) -> Replaced {
        Replaced(output: output, stamp: outputStamp(of: output), trashed: trashed, warning: warning)
    }

    private func outputStamp(of url: URL, includingIdentity: Bool = false) -> FileStamp? {
        do {
            return try FileStamp(of: url, includingIdentity: includingIdentity)
        } catch {
            logger.error(
                "Undo stamp unavailable: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    func derive(_ output: StagedFile, nextTo original: URL) async throws -> Committed {
        try await OutputVerifier.verify(output)
        return try coordinatedMove(
            output.url, toAvailableNameIn: original.deletingLastPathComponent(), named: output.name)
    }

    func rename(_ url: URL, to newName: String) throws -> Committed {
        try Self.namingLock.withLock { _ in
            try Task.checkCancellation()
            let directory = url.deletingLastPathComponent()
            let destination =
                try Self.isCaseOnlyChange(from: url.lastPathComponent, to: newName, in: directory)
                ? directory.appending(path: newName)
                : try AvailableName.url(for: newName, in: directory)
            return try coordinate(
                moving: url, to: destination, beforeMove: Task.checkCancellation, includingIdentity: true)
        }
    }

    /// `nil` after a permanent delete.
    func remove(_ url: URL, permanently: Bool, condition: RemovalCondition? = nil) throws -> Trashed? {
        try Self.namingLock.withLock { _ in
            try Task.checkCancellation()
            switch condition {
            case .duplicate(let kept):
                do {
                    return try coordinate(reading: kept, deleting: url) { retained, target in
                        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
                        let retainedID = try retained.resourceValues(forKeys: key).fileResourceIdentifier
                        let targetID = try target.resourceValues(forKeys: key).fileResourceIdentifier
                        guard retainedID?.isEqual(targetID) == false,
                            FileManager.default.contentsEqual(atPath: retained.path, andPath: target.path)
                        else { throw Failure.changedSinceScan }
                        return try removeCoordinated(target, permanently: permanently)
                    }
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
                {
                    throw Failure.changedSinceScan
                }
            case .emptyFolder(let settings):
                return try coordinate(writing: url, options: .forDeleting) { target in
                    guard try EmptyFolderScanner.isEmpty(target, settings: settings) else {
                        throw Failure.changedSinceScan
                    }
                    return try removeCoordinated(target, permanently: permanently)
                }
            case nil:
                return try coordinate(writing: url, options: .forDeleting) {
                    try removeCoordinated($0, permanently: permanently)
                }
            }
        }
    }

    private func removeCoordinated(_ url: URL, permanently: Bool) throws -> Trashed? {
        try Task.checkCancellation()
        if permanently {
            try FileManager.default.removeItem(at: url)
            return nil
        }
        return try trashForHistory(url)
    }

    private func trashForHistory(_ url: URL) throws -> Trashed {
        let trashed = try trashCoordinated(url)
        do {
            return Trashed(url: trashed, stamp: try FileStamp(of: trashed, includingIdentity: true))
        } catch {
            logger.error(
                "Trash stamp unavailable: \(error.localizedDescription, privacy: .private)"
            )
            return Trashed(url: trashed, stamp: nil)
        }
    }

    private func trashCoordinated(_ url: URL) throws -> URL {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        guard let trashed else { throw EngineError.commitFailed("Trash returned no location") }
        return trashed as URL
    }

    func undo(_ record: CommitRecord) -> UndoOutcome {
        do {
            return try Self.namingLock.withLock { _ in
                switch record {
                case .replaced(let original, let trashed, let output, let stamp, let trashStamp):
                    return try coordinateUndo(paths: [original, trashed, output]) { urls in
                        let originalURL = urls[0]
                        let trashedURL = urls[1]
                        let outputURL = urls[2]
                        guard let trashStamp, trashStamp.matchesIdentity(trashedURL.path) else {
                            return .skipped(.undoTrashItemMissing, path: original)
                        }
                        guard let stamp, stamp.matches(outputURL.path) else {
                            return .skipped(.undoOutputChanged, path: output)
                        }
                        let caseOnly = try Self.isCaseOnlyChange(
                            from: originalURL.path, to: outputURL.path, in: originalURL.deletingLastPathComponent())
                        if outputURL != originalURL, !caseOnly,
                            FileManager.default.fileExists(atPath: originalURL.path)
                        {
                            return .skipped(.undoOriginalOccupied, path: original)
                        }
                        let trashedOutput = try trashCoordinated(outputURL)
                        do {
                            try FileManager.default.moveItem(at: trashedURL, to: originalURL)
                        } catch {
                            try FileManager.default.moveItem(at: trashedOutput, to: outputURL)
                            throw error
                        }
                        return .restored
                    }
                case .derived(let output, let stamp):
                    return try coordinateUndo(paths: [output]) { urls in
                        guard let stamp, stamp.matches(urls[0].path) else {
                            return .skipped(.undoOutputChanged, path: output)
                        }
                        _ = try trashCoordinated(urls[0])
                        return .restored
                    }
                case .renamed(let from, let to, let stamp):
                    return try coordinateUndo(paths: [from, to]) { urls in
                        guard let stamp, stamp.matches(urls[1].path) else {
                            return .skipped(.undoOutputChanged, path: to)
                        }
                        let caseOnly = try Self.isCaseOnlyChange(
                            from: urls[0].path, to: urls[1].path, in: urls[0].deletingLastPathComponent())
                        guard caseOnly || !FileManager.default.fileExists(atPath: urls[0].path) else {
                            return .skipped(.undoOriginalOccupied, path: from)
                        }
                        try FileManager.default.moveItem(at: urls[1], to: urls[0])
                        return .restored
                    }
                case .removed(let original, let trashed, let trashStamp):
                    return try coordinateUndo(paths: [original, trashed]) { urls in
                        guard let trashStamp, trashStamp.matchesIdentity(urls[1].path) else {
                            return .skipped(.undoTrashItemMissing, path: original)
                        }
                        guard !FileManager.default.fileExists(atPath: urls[0].path) else {
                            return .skipped(.undoOriginalOccupied, path: original)
                        }
                        try FileManager.default.moveItem(at: urls[1], to: urls[0])
                        return .restored
                    }
                }
            }
        } catch {
            let path: String
            switch record {
            case .replaced(_, let trashed, _, _, _), .removed(_, let trashed, _): path = trashed
            case .derived(let output, _): path = output
            case .renamed(_, let to, _): path = to
            }
            return .failed(EngineError.wrapping(error, path: path, otherwise: EngineError.commitFailed), path: path)
        }
    }

    private func coordinateUndo(
        paths: [String], _ body: @escaping @Sendable ([URL]) throws -> UndoOutcome
    ) throws -> UndoOutcome {
        var intents: [NSFileAccessIntent] = []
        let references = paths.map { path in
            if let existing = intents.first(where: { $0.url.path == path }) { return existing }
            let intent = NSFileAccessIntent.writingIntent(
                with: URL(fileURLWithPath: path), options: .forReplacing)
            intents.append(intent)
            return intent
        }
        let completed = DispatchSemaphore(value: 0)
        let result = Mutex<Result<UndoOutcome, any Error>?>(nil)
        let queue = OperationQueue()
        NSFileCoordinator(filePresenter: nil).coordinate(with: intents, queue: queue) { error in
            result.withLock { outcome in
                outcome = Result {
                    if let error { throw error }
                    return try body(references.map(\.url))
                }
            }
            completed.signal()
        }
        completed.wait()
        return try result.withLock { outcome in
            guard let outcome else { throw EngineError.commitFailed("Coordination did not run") }
            return try outcome.get()
        }
    }

    static func isCaseOnlyChange(from oldName: String, to newName: String, in directory: URL) throws -> Bool {
        guard oldName != newName, oldName.lowercased() == newName.lowercased() else { return false }
        let values = try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values.volumeSupportsCaseSensitiveNames == false
    }

    private func coordinatedMove(_ source: URL, toAvailableNameIn directory: URL, named name: String) throws
        -> Committed
    {
        try Self.namingLock.withLock { _ in
            let destination = try AvailableName.url(for: name, in: directory)
            return try coordinate(moving: source, to: destination)
        }
    }

    private func cloneOrCopy(_ source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, 0) == 0 { return }
        guard errno == ENOTSUP || errno == EXDEV else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func coordinate<Value>(
        writing url: URL,
        options: NSFileCoordinator.WritingOptions,
        _ body: (URL) throws -> Value
    ) throws -> Value {
        var coordinationError: NSError?
        var result: Result<Value, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: options, error: &coordinationError
        ) {
            target in
            result = Result { try body(target) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw EngineError.commitFailed("Coordination did not run") }
        return try result.get()
    }

    private func coordinate<Value>(
        replacing original: URL, destination: URL, _ body: (URL, URL) throws -> Value
    ) throws -> Value {
        if original == destination {
            return try coordinate(writing: original, options: .forReplacing) { try body($0, $0) }
        }
        var coordinationError: NSError?
        var result: Result<Value, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: original, options: .forReplacing,
            writingItemAt: destination, options: .forReplacing, error: &coordinationError
        ) { target, final in
            result = Result { try body(target, final) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw EngineError.commitFailed("Coordination did not run") }
        return try result.get()
    }

    private func coordinate<Value>(
        reading retained: URL, deleting target: URL, _ body: (URL, URL) throws -> Value
    ) throws -> Value {
        var coordinationError: NSError?
        var result: Result<Value, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: retained, options: .withoutChanges,
            writingItemAt: target, options: .forDeleting, error: &coordinationError
        ) { retained, target in
            result = Result {
                try Task.checkCancellation()
                return try body(retained, target)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw EngineError.commitFailed("Coordination did not run") }
        return try result.get()
    }

    private func coordinate(
        moving source: URL, to destination: URL, beforeMove: () throws -> Void = {},
        includingIdentity: Bool = false
    ) throws -> Committed {
        var coordinationError: NSError?
        var result: Result<Committed, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: source,
            options: .forMoving,
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { from, to in
            result = Result {
                try beforeMove()
                try FileManager.default.moveItem(at: from, to: to)
                return Committed(output: to, stamp: outputStamp(of: to, includingIdentity: includingIdentity))
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw EngineError.commitFailed("Coordination did not run") }
        return try result.get()
    }
}

/// Finder-style ` (2)` suffixes.
enum AvailableName {
    private static let compoundExtensions = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"]

    static func url(for name: String, in directory: URL) throws -> URL {
        directory.appending(
            path: available(name) { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) })
    }

    static func available(_ name: String, isTaken: (String) -> Bool) -> String {
        let (base, pathExtension) = split(name)
        var counter = 1
        while true {
            let candidate = counter == 1 ? base : "\(base) (\(counter))"
            let numbered = pathExtension.isEmpty ? candidate : "\(candidate).\(pathExtension)"
            if !isTaken(numbered) { return numbered }
            counter += 1
        }
    }

    static func split(_ name: String) -> (base: String, pathExtension: String) {
        let lowercased = name.lowercased()
        if let compound = compoundExtensions.first(where: { lowercased.hasSuffix(".\($0)") }) {
            let base = String(name.dropLast(compound.count + 1))
            return (base, String(name.suffix(compound.count)))
        }
        return ((name as NSString).deletingPathExtension, (name as NSString).pathExtension)
    }

    static func checkedName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".." && !name.contains("\u{0}")
    }
}
