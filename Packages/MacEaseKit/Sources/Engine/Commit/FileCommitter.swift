import Darwin
import Foundation
import Synchronization
import os

/// Sole path that moves user files.
struct FileCommitter: Sendable {
    private static let namingLock = Mutex(())

    enum Failure: Error {
        case changedSinceScan
        case destinationOccupied
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
            var nextCandidate = 1
            while true {
                try Task.checkCancellation()
                let destination =
                    keepsName
                    ? original
                    : changesCase
                        ? directory.appending(path: output.name)
                        : try AvailableName.url(for: output.name, in: directory, nextCandidate: &nextCandidate)
                do {
                    return try coordinate(replacing: original, destination: destination) { target, final in
                        guard try FileStamp(of: target) == expectedStamp else { throw Failure.changedSinceScan }
                        let attributes = try FinderAttributes(of: target)
                        try Task.checkCancellation()
                        try attributes.apply(to: output.url)
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
                        do {
                            try FileManager.default.moveItem(at: output.url, to: final)
                        } catch let error as CocoaError where error.code == .fileWriteFileExists {
                            throw Failure.destinationOccupied
                        }
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
                } catch Failure.destinationOccupied {
                    continue
                } catch Failure.noTrash {
                    let committed = try coordinatedMove(output.url, toAvailableNameIn: directory, named: output.name)
                    return Replaced(
                        output: committed.output, stamp: committed.stamp, trashed: nil, warning: .keptAsDerived)
                }
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

    func derive(
        _ output: StagedFile, nextTo original: URL, expectedStamp: FileStamp? = nil, attributeSource: URL? = nil,
        preservingAttributes: Bool = true
    ) async throws -> Committed {
        try await OutputVerifier.verify(output)
        if let sourceURL = attributeSource ?? (expectedStamp == nil ? nil : original) {
            return try Self.namingLock.withLock { _ in
                var nextCandidate = 1
                while true {
                    try Task.checkCancellation()
                    let destination = try AvailableName.url(
                        for: output.name, in: original.deletingLastPathComponent(), nextCandidate: &nextCandidate)
                    do {
                        return try coordinate(reading: sourceURL, writing: destination, options: .forReplacing) {
                            source, final in
                            if let expectedStamp {
                                guard expectedStamp.matches(source.path) else { throw Failure.changedSinceScan }
                            }
                            try Task.checkCancellation()
                            if preservingAttributes {
                                try FinderAttributes(of: source).apply(to: output.url)
                            }
                            do {
                                try FileManager.default.moveItem(at: output.url, to: final)
                            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                                throw Failure.destinationOccupied
                            }
                            return Committed(output: final, stamp: outputStamp(of: final))
                        }
                    } catch Failure.destinationOccupied {
                        continue
                    }
                }
            }
        }
        return try Self.namingLock.withLock { _ in
            try coordinatedMove(output.url, toAvailableNameIn: original.deletingLastPathComponent(), named: output.name)
        }
    }

    func deriveGroup(_ output: StagedFile, destination: URL, sources: [URL: FileStamp], attributeSource: URL?)
        async throws -> Committed
    {
        let cancellation = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await OutputVerifier.verify(output)
            guard destination.isFileURL, AvailableName.checkedName(destination.lastPathComponent), !sources.isEmpty
            else {
                throw EngineError.invalidInput(.malformed("Invalid grouped output destination"))
            }
            return try Self.namingLock.withLock { _ in
                var nextCandidate = 1
                while true {
                    try Task.checkCancellation()
                    let final = try AvailableName.url(
                        for: destination.lastPathComponent,
                        in: destination.deletingLastPathComponent(), nextCandidate: &nextCandidate)
                    let reads = sources.keys.sorted { $0.path < $1.path }.map {
                        NSFileAccessIntent.readingIntent(with: $0, options: .withoutChanges)
                    }
                    let write = NSFileAccessIntent.writingIntent(with: final, options: .forReplacing)
                    let completed = DispatchSemaphore(value: 0)
                    let result = Mutex<Result<Committed, any Error>?>(nil)
                    NSFileCoordinator(filePresenter: nil).coordinate(with: reads + [write], queue: OperationQueue()) {
                        error in
                        result.withLock { outcome in
                            outcome = Result {
                                if let error { throw error }
                                for read in reads {
                                    guard let stamp = sources[read.url], stamp.matchesIdentity(read.url.path) else {
                                        throw Failure.changedSinceScan
                                    }
                                }
                                try Task.checkCancellation()
                                if let attributeSource {
                                    guard sources[attributeSource] != nil else { throw Failure.changedSinceScan }
                                    try FinderAttributes(of: attributeSource).apply(to: output.url)
                                }
                                if cancellation.withLock({ $0 }) { throw CancellationError() }
                                if renamex_np(output.url.path, write.url.path, UInt32(RENAME_EXCL)) != 0 {
                                    if errno == EEXIST { throw Failure.destinationOccupied }
                                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                                }
                                return Committed(output: write.url, stamp: outputStamp(of: write.url))
                            }
                        }
                        completed.signal()
                    }
                    completed.wait()
                    do {
                        return try result.withLock {
                            guard let outcome = $0 else { throw EngineError.commitFailed("Coordination did not run") }
                            return try outcome.get()
                        }
                    } catch Failure.destinationOccupied {
                        continue
                    }
                }
            }
        } onCancel: {
            cancellation.withLock { $0 = true }
        }
    }

    func organize(
        _ plan: OrganizationMovePlan,
        createdFolder: (OrganizationFolderRecord) throws -> Void,
        beforeMove: (OrganizationMoveRecord) throws -> Void
    ) throws -> OrganizationMoveRecord {
        try Self.namingLock.withLock { _ in
            try OrganizationSafety.validate(plan)
            var directory = plan.root
            for component in plan.category.split(separator: "/") {
                let child = directory.appending(path: String(component), directoryHint: .isDirectory)
                try coordinate(writing: child, options: .forReplacing) { location in
                    try Task.checkCancellation()
                    try OrganizationSafety.validateDirectories(
                        to: directory, root: plan.root, identity: plan.rootIdentity)
                    if mkdir(location.path, 0o755) == 0 {
                        let record = OrganizationFolderRecord(
                            root: plan.root, rootIdentity: plan.rootIdentity,
                            url: location, identity: try OrganizationIdentity(of: location, directory: true))
                        try synchronizeOrganizationDirectory(directory)
                        try createdFolder(record)
                    } else if errno == EEXIST {
                        _ = try OrganizationIdentity(of: location, directory: true)
                    } else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    try OrganizationSafety.validateDirectories(
                        to: location, root: plan.root, identity: plan.rootIdentity)
                }
                directory = child
            }
            var nextCandidate = 1
            while true {
                let destination = try AvailableName.url(
                    for: plan.proposedName, in: directory, nextCandidate: &nextCandidate)
                do {
                    return try coordinate(replacing: plan.source, destination: destination, sourceOptions: .forMoving) {
                        source, target in
                        try Task.checkCancellation()
                        try OrganizationSafety.validate(plan)
                        try OrganizationSafety.validateDirectories(
                            to: directory, root: plan.root, identity: plan.rootIdentity)
                        guard source == plan.source, target == destination,
                            plan.sourceStamp.matchesIdentity(source.path)
                        else { throw Failure.changedSinceScan }
                        let record = OrganizationMoveRecord(
                            root: plan.root, rootIdentity: plan.rootIdentity,
                            from: source, to: target, stamp: plan.sourceStamp, category: plan.category)
                        try beforeMove(record)
                        try OrganizationSafety.validate(plan)
                        try OrganizationSafety.validateDirectories(
                            to: directory, root: plan.root, identity: plan.rootIdentity)
                        if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) != 0 {
                            if errno == EEXIST { throw Failure.destinationOccupied }
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        try synchronizeOrganizationDirectory(directory)
                        try synchronizeOrganizationDirectory(source.deletingLastPathComponent())
                        return record
                    }
                } catch Failure.destinationOccupied {
                    continue
                }
            }
        }
    }

    private func synchronizeOrganizationDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func rename(_ url: URL, to newName: String, requiresExactName: Bool = false) throws -> Committed {
        try Self.namingLock.withLock { _ in
            try Task.checkCancellation()
            let directory = url.deletingLastPathComponent()
            if try requiresExactName || Self.isCaseOnlyChange(from: url.lastPathComponent, to: newName, in: directory) {
                return try coordinate(
                    moving: url, to: directory.appending(path: newName), includingIdentity: true)
            }
            return try coordinatedMove(url, toAvailableNameIn: directory, named: newName, includingIdentity: true)
        }
    }

    /// `nil` after a permanent delete.
    func remove(_ url: URL, permanently: Bool, condition: RemovalCondition? = nil) throws -> Trashed? {
        try Self.namingLock.withLock { _ in
            try Task.checkCancellation()
            switch condition {
            case .duplicate(let kept):
                do {
                    return try coordinate(reading: kept, writing: url, options: .forDeleting) { retained, target in
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

    func undo(_ record: CommitRecord) async -> UndoOutcome {
        let cancellation = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            undoCoordinated(record, cancellation: cancellation)
        } onCancel: {
            cancellation.withLock { $0 = true }
        }
    }

    private func undoCoordinated(_ record: CommitRecord, cancellation: OSAllocatedUnfairLock<Bool>) -> UndoOutcome {
        do {
            return try Self.namingLock.withLock { _ in
                switch record {
                case .organized(let move):
                    return try coordinateUndo(paths: [move.from.path, move.to.path], cancellation: cancellation) {
                        urls, checkCancellation in
                        guard move.rootIdentity.matches(move.root, directory: true),
                            move.stamp.matchesIdentity(urls[1].path)
                        else {
                            return .skipped(.undoOutputChanged, path: move.to.path)
                        }
                        try OrganizationSafety.validateDirectories(
                            to: urls[0].deletingLastPathComponent(),
                            root: move.root, identity: move.rootIdentity)
                        try OrganizationSafety.validateDirectories(
                            to: urls[1].deletingLastPathComponent(),
                            root: move.root, identity: move.rootIdentity)
                        try checkCancellation()
                        guard renamex_np(urls[1].path, urls[0].path, UInt32(RENAME_EXCL)) == 0 else {
                            if errno == EEXIST { return .skipped(.undoOriginalOccupied, path: move.from.path) }
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        try synchronizeOrganizationDirectory(urls[0].deletingLastPathComponent())
                        try synchronizeOrganizationDirectory(urls[1].deletingLastPathComponent())
                        return .restored
                    }
                case .organizationFolder(let folder):
                    return try coordinateUndo(paths: [folder.url.path], cancellation: cancellation) {
                        urls, checkCancellation in
                        guard folder.rootIdentity.matches(folder.root, directory: true),
                            folder.identity.matches(urls[0], directory: true)
                        else {
                            return .skipped(.undoOutputChanged, path: folder.url.path)
                        }
                        try OrganizationSafety.validateDirectories(
                            to: urls[0], root: folder.root, identity: folder.rootIdentity)
                        try checkCancellation()
                        guard rmdir(urls[0].path) == 0 else {
                            if errno == ENOTEMPTY { return .skipped(.undoOutputChanged, path: folder.url.path) }
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        return .restored
                    }
                case .extractedInPlace(let output):
                    return .skipped(.undoOutputChanged, path: output)
                case .replaced(let original, let trashed, let output, let stamp, let trashStamp):
                    return try coordinateUndo(paths: [original, trashed, output], cancellation: cancellation) {
                        urls, checkCancellation in
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
                        try checkCancellation()
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
                    return try coordinateUndo(paths: [output], cancellation: cancellation) { urls, checkCancellation in
                        guard let stamp, stamp.matches(urls[0].path) else {
                            return .skipped(.undoOutputChanged, path: output)
                        }
                        try checkCancellation()
                        _ = try trashCoordinated(urls[0])
                        return .restored
                    }
                case .renamed(let from, let to, let stamp):
                    return try coordinateUndo(paths: [from, to], cancellation: cancellation) {
                        urls, checkCancellation in
                        guard let stamp, stamp.matches(urls[1].path) else {
                            return .skipped(.undoOutputChanged, path: to)
                        }
                        let caseOnly = try Self.isCaseOnlyChange(
                            from: urls[0].path, to: urls[1].path, in: urls[0].deletingLastPathComponent())
                        guard caseOnly || !FileManager.default.fileExists(atPath: urls[0].path) else {
                            return .skipped(.undoOriginalOccupied, path: from)
                        }
                        try checkCancellation()
                        try FileManager.default.moveItem(at: urls[1], to: urls[0])
                        return .restored
                    }
                case .removed(let original, let trashed, let trashStamp):
                    return try coordinateUndo(paths: [original, trashed], cancellation: cancellation) {
                        urls, checkCancellation in
                        guard let trashStamp, trashStamp.matchesIdentity(urls[1].path) else {
                            return .skipped(.undoTrashItemMissing, path: original)
                        }
                        guard !FileManager.default.fileExists(atPath: urls[0].path) else {
                            return .skipped(.undoOriginalOccupied, path: original)
                        }
                        try checkCancellation()
                        try FileManager.default.moveItem(at: urls[1], to: urls[0])
                        return .restored
                    }
                }
            }
        } catch {
            let path: String
            switch record {
            case .replaced(_, let trashed, _, _, _), .removed(_, let trashed, _): path = trashed
            case .derived(let output, _), .extractedInPlace(let output): path = output
            case .renamed(_, let to, _): path = to
            case .organized(let move): path = move.to.path
            case .organizationFolder(let folder): path = folder.url.path
            }
            return .failed(EngineError.wrapping(error, path: path, otherwise: EngineError.commitFailed), path: path)
        }
    }

    private func coordinateUndo(
        paths: [String], cancellation: OSAllocatedUnfairLock<Bool>,
        _ body: @escaping @Sendable ([URL], @Sendable () throws -> Void) throws -> UndoOutcome
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
                    return try body(references.map(\.url)) {
                        try Task.checkCancellation()
                        if cancellation.withLock({ $0 }) { throw CancellationError() }
                    }
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

    private func coordinatedMove(
        _ source: URL, toAvailableNameIn directory: URL, named name: String, includingIdentity: Bool = false
    ) throws -> Committed {
        var nextCandidate = 1
        while true {
            try Task.checkCancellation()
            let destination = try AvailableName.url(for: name, in: directory, nextCandidate: &nextCandidate)
            do {
                return try coordinate(
                    moving: source, to: destination, includingIdentity: includingIdentity, retryOnCollision: true)
            } catch Failure.destinationOccupied {
                continue
            }
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
        replacing original: URL, destination: URL, sourceOptions: NSFileCoordinator.WritingOptions = .forReplacing,
        _ body: (URL, URL) throws -> Value
    ) throws -> Value {
        if original == destination {
            return try coordinate(writing: original, options: .forReplacing) { try body($0, $0) }
        }
        var coordinationError: NSError?
        var result: Result<Value, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: original, options: sourceOptions,
            writingItemAt: destination, options: .forReplacing, error: &coordinationError
        ) { target, final in
            result = Result { try body(target, final) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw EngineError.commitFailed("Coordination did not run") }
        return try result.get()
    }

    private func coordinate<Value>(
        reading retained: URL, writing target: URL, options: NSFileCoordinator.WritingOptions,
        _ body: (URL, URL) throws -> Value
    ) throws -> Value {
        var coordinationError: NSError?
        var result: Result<Value, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: retained, options: .withoutChanges,
            writingItemAt: target, options: options, error: &coordinationError
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
        moving source: URL, to destination: URL,
        includingIdentity: Bool = false, retryOnCollision: Bool = false
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
                try Task.checkCancellation()
                do {
                    try FileManager.default.moveItem(at: from, to: to)
                } catch let error as CocoaError where retryOnCollision && error.code == .fileWriteFileExists {
                    throw Failure.destinationOccupied
                }
                return Committed(output: to, stamp: outputStamp(of: to, includingIdentity: includingIdentity))
            }
        }
        if let coordinationError {
            if retryOnCollision, result == nil, coordinationError.domain == NSCocoaErrorDomain,
                coordinationError.code == NSFileWriteFileExistsError
            {
                throw Failure.destinationOccupied
            }
            throw coordinationError
        }
        guard let result else { throw EngineError.commitFailed("Coordination did not run") }
        return try result.get()
    }
}

/// Finder-style ` (2)` suffixes.
enum AvailableName {
    private static let compoundExtensions = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"]

    static func url(for name: String, in directory: URL) throws -> URL {
        var nextCandidate = 1
        return try url(for: name, in: directory, nextCandidate: &nextCandidate)
    }

    static func url(for name: String, in directory: URL, nextCandidate: inout Int) throws -> URL {
        directory.appending(
            path: try available(name, nextCandidate: &nextCandidate) { candidate in
                try Task.checkCancellation()
                let path = directory.appending(path: candidate).path
                var metadata = stat()
                if lstat(path, &metadata) == 0 { return true }
                if errno == ENOENT { return false }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
            })
    }

    static func available(_ name: String, isTaken: (String) throws -> Bool) rethrows -> String {
        var nextCandidate = 1
        return try available(name, nextCandidate: &nextCandidate, isTaken: isTaken)
    }

    private static func available(
        _ name: String, nextCandidate: inout Int, isTaken: (String) throws -> Bool
    ) rethrows -> String {
        let (base, pathExtension) = split(name)
        while true {
            let candidate = nextCandidate == 1 ? base : "\(base) (\(nextCandidate))"
            nextCandidate += 1
            let numbered = pathExtension.isEmpty ? candidate : "\(candidate).\(pathExtension)"
            if try !isTaken(numbered) { return numbered }
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
