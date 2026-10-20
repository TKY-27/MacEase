import Darwin
import Foundation
import Synchronization
import os

/// Sole path that moves user files.
struct FileCommitter: Sendable {
    /// Name choice and move are atomic.
    private static let namingLock = Mutex(())

    struct Replaced: Sendable {
        let output: URL
        let trashed: URL?
        let warning: ItemWarning?
    }

    private let logger = Logger(category: "commit")

    func replace(original: URL, with output: StagedFile, cloneDirectory: URL) async throws -> Replaced {
        try await OutputVerifier.verify(output)
        try FinderAttributes(of: original).apply(to: output.url)
        let directory = original.deletingLastPathComponent()
        if output.name == original.lastPathComponent {
            return try replaceKeepingName(original: original, output: output, cloneDirectory: cloneDirectory)
        }
        if try Self.isCaseOnlyChange(from: original.lastPathComponent, to: output.name, in: directory) {
            let kept = try replaceKeepingName(original: original, output: output, cloneDirectory: cloneDirectory)
            let renamed = directory.appending(path: output.name)
            try coordinate(moving: kept.output, to: renamed)
            return Replaced(output: renamed, trashed: kept.trashed, warning: kept.warning)
        }
        let destination = try coordinatedMove(output.url, toAvailableNameIn: directory, named: output.name)
        do {
            return Replaced(output: destination, trashed: try trash(original), warning: nil)
        } catch let error as CocoaError where error.code == .featureUnsupported {
            return Replaced(output: destination, trashed: nil, warning: .keptAsDerived)
        } catch {
            do {
                try coordinate(moving: destination, to: output.url)
            } catch {
                return Replaced(output: destination, trashed: nil, warning: .originalKept)
            }
            throw error
        }
    }

    private func replaceKeepingName(original: URL, output: StagedFile, cloneDirectory: URL) throws -> Replaced {
        let clone = cloneDirectory.appending(path: original.lastPathComponent)
        try cloneOrCopy(original, to: clone)
        let trashed: URL
        do {
            trashed = try trash(clone)
        } catch let error as CocoaError where error.code == .featureUnsupported {
            try FileManager.default.removeItem(at: clone)
            let destination = try coordinatedMove(
                output.url,
                toAvailableNameIn: original.deletingLastPathComponent(),
                named: output.name
            )
            return Replaced(output: destination, trashed: nil, warning: .keptAsDerived)
        }
        do {
            try coordinate(writing: original, options: .forReplacing) { target in
                _ = try FileManager.default.replaceItemAt(target, withItemAt: output.url)
            }
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
        var trashed: NSURL?
        try coordinate(writing: url, options: .forDeleting) { target in
            try FileManager.default.trashItem(at: target, resultingItemURL: &trashed)
        }
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

    private func coordinate(
        writing url: URL,
        options: NSFileCoordinator.WritingOptions,
        _ body: (URL) throws -> Void
    ) throws {
        var coordinationError: NSError?
        var bodyError: (any Error)?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: options, error: &coordinationError
        ) {
            target in
            do { try body(target) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError { throw error }
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
        let (base, pathExtension) = split(name)
        var counter = 1
        while true {
            let candidate = counter == 1 ? base : "\(base) (\(counter))"
            let url = directory.appending(path: pathExtension.isEmpty ? candidate : "\(candidate).\(pathExtension)")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            counter += 1
        }
    }

    private static func split(_ name: String) -> (base: String, pathExtension: String) {
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
