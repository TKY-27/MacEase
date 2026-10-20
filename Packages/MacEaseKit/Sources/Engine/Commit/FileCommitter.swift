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

    struct Replaced: Sendable {
        let output: URL
        let trashed: URL?
        let warning: ItemWarning?
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
                        if changesCase { try FileManager.default.moveItem(at: target, to: final) }
                        return Replaced(output: final, trashed: kept.trashed, warning: kept.warning)
                    }
                    try FileManager.default.moveItem(at: output.url, to: final)
                    do {
                        return Replaced(output: final, trashed: try trashCoordinated(target), warning: nil)
                    } catch let error as CocoaError where error.code == .featureUnsupported {
                        return Replaced(output: final, trashed: nil, warning: .keptAsDerived)
                    } catch {
                        do {
                            try FileManager.default.moveItem(at: final, to: output.url)
                        } catch {
                            return Replaced(output: final, trashed: nil, warning: .originalKept)
                        }
                        throw error
                    }
                }
            } catch Failure.noTrash {
                let derived = try AvailableName.url(for: output.name, in: directory)
                try coordinate(moving: output.url, to: derived)
                return Replaced(output: derived, trashed: nil, warning: .keptAsDerived)
            }
        }
    }

    private func replaceKeepingName(original: URL, output: StagedFile, cloneDirectory: URL) throws -> Replaced {
        let clone = cloneDirectory.appending(path: original.lastPathComponent)
        try cloneOrCopy(original, to: clone)
        let trashed: URL
        do {
            trashed = try trashCoordinated(clone)
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
        return Replaced(output: original, trashed: trashed, warning: nil)
    }

    func derive(_ output: StagedFile, nextTo original: URL) async throws -> URL {
        try await OutputVerifier.verify(output)
        return try coordinatedMove(
            output.url, toAvailableNameIn: original.deletingLastPathComponent(), named: output.name)
    }

    func rename(_ url: URL, to newName: String) throws -> URL {
        try Self.namingLock.withLock { _ in
            let directory = url.deletingLastPathComponent()
            let destination =
                try Self.isCaseOnlyChange(from: url.lastPathComponent, to: newName, in: directory)
                ? directory.appending(path: newName)
                : try AvailableName.url(for: newName, in: directory)
            try coordinate(moving: url, to: destination)
            return destination
        }
    }

    /// `nil` after a permanent delete.
    func remove(_ url: URL, permanently: Bool) throws -> URL? {
        if permanently {
            try coordinate(writing: url, options: .forDeleting) { try FileManager.default.removeItem(at: $0) }
            return nil
        }
        return try trash(url)
    }

    func trash(_ url: URL) throws -> URL {
        try coordinate(writing: url, options: .forDeleting) { try trashCoordinated($0) }
    }

    private func trashCoordinated(_ url: URL) throws -> URL {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        guard let trashed else { throw EngineError.commitFailed("Trash returned no location") }
        return trashed as URL
    }

    func move(_ source: URL, to destination: URL) throws {
        try coordinate(moving: source, to: destination)
    }

    private static func isCaseOnlyChange(from oldName: String, to newName: String, in directory: URL) throws -> Bool {
        guard oldName != newName, oldName.lowercased() == newName.lowercased() else { return false }
        let values = try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values.volumeSupportsCaseSensitiveNames == false
    }

    private func coordinatedMove(_ source: URL, toAvailableNameIn directory: URL, named name: String) throws -> URL {
        try Self.namingLock.withLock { _ in
            let destination = try AvailableName.url(for: name, in: directory)
            try coordinate(moving: source, to: destination)
            return destination
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

    private func coordinate(moving source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var bodyError: (any Error)?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: source,
            options: .forMoving,
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { from, to in
            do { try FileManager.default.moveItem(at: from, to: to) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError { throw error }
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
