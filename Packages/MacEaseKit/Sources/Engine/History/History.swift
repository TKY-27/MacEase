import CryptoKit
import Darwin
import Foundation
import MenuCatalog
import os

public struct FileStamp: Codable, Hashable, Sendable {
    public let size: Int64?
    public let modified: Date
    private let directorySummary: DirectorySummary?
    private let identity: FileIdentity?

    private struct FileIdentity: Codable, Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    private struct DirectorySummary: Codable, Hashable, Sendable {
        var descendantCount = 0
        var totalSize: Int64 = 0
        var latestModification = Date.distantPast
        var unreadableCount = 0
        var listingHash = Array(repeating: UInt8(0), count: SHA256.byteCount)

        mutating func include(_ entry: String) {
            let digest = SHA256.hash(data: Data(entry.utf8))
            for (index, byte) in digest.enumerated() { listingHash[index] ^= byte }
        }

        mutating func includeFailure(at path: String, error: Error) {
            unreadableCount += 1
            let failure = error as NSError
            include("error\0\(path)\0\(failure.domain)\0\(failure.code)")
        }
    }

    public init(of url: URL, includingIdentity: Bool = false) throws {
        let metadata = try Self.metadata(of: url)
        let isDirectory = metadata.st_mode & S_IFMT == S_IFDIR
        size = isDirectory ? nil : metadata.st_size
        modified = Date(
            timeIntervalSinceReferenceDate: TimeInterval(metadata.st_mtimespec.tv_sec)
                - Date.timeIntervalBetween1970AndReferenceDate
                + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000)
        directorySummary = isDirectory ? Self.snapshot(of: url) : nil
        identity =
            includingIdentity
            ? FileIdentity(device: UInt64(UInt32(bitPattern: metadata.st_dev)), inode: metadata.st_ino) : nil
    }

    func matches(_ path: String) -> Bool {
        guard directorySummary?.unreadableCount == nil || directorySummary?.unreadableCount == 0 else {
            return false
        }
        do {
            return try FileStamp(of: URL(fileURLWithPath: path), includingIdentity: identity != nil) == self
        } catch {
            return false
        }
    }

    func matchesIdentity(_ path: String) -> Bool {
        identity != nil && matches(path)
    }

    private static func metadata(of url: URL) throws -> stat {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return metadata
    }

    private static func modificationDate(of metadata: stat) -> Date {
        Date(
            timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec)
                + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    private static func snapshot(of root: URL) -> DirectorySummary {
        var summary = DirectorySummary()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard
            let entries = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil,
                errorHandler: { url, error in
                    summary.includeFailure(at: String(url.path.dropFirst(prefix.count)), error: error)
                    return true
                })
        else {
            summary.includeFailure(at: "", error: CocoaError(.fileReadUnknown))
            return summary
        }
        for case let child as URL in entries {
            let path = String(child.path.dropFirst(prefix.count))
            summary.descendantCount += 1
            do {
                let metadata = try metadata(of: child)
                let modification = modificationDate(of: metadata)
                summary.totalSize += metadata.st_size
                summary.latestModification = max(summary.latestModification, modification)
                summary.include(
                    "\(path)\0\(metadata.st_mode)\0\(metadata.st_size)\0\(metadata.st_mtimespec.tv_sec)\0\(metadata.st_mtimespec.tv_nsec)"
                )
            } catch {
                summary.includeFailure(at: path, error: error)
                entries.skipDescendants()
            }
        }
        return summary
    }
}

public enum CommitRecord: Codable, Equatable, Sendable {
    case organized(OrganizationMoveRecord)
    case organizationFolder(OrganizationFolderRecord)
    case extractedInPlace(output: String)
    case replaced(original: String, trashed: String, output: String, stamp: FileStamp?, trashStamp: FileStamp? = nil)
    case derived(output: String, stamp: FileStamp?)
    case renamed(from: String, to: String, stamp: FileStamp? = nil)
    case removed(original: String, trashed: String, trashStamp: FileStamp? = nil)
}

public struct BatchRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let operation: OperationID
    public let date: Date
    public internal(set) var recipeExecution: RecipeExecution? = nil
    /// Only failed items after a partial undo.
    public internal(set) var items: [CommitRecord]
    public internal(set) var undone: Bool

    public var canUndo: Bool { !items.contains { if case .extractedInPlace = $0 { true } else { false } } }

    public var outputPaths: [String] {
        items.compactMap { record in
            switch record {
            case .replaced(_, _, let output, _, _), .derived(let output, _), .extractedInPlace(let output): output
            case .renamed(_, let to, _): to
            case .organized(let move): move.to.path
            case .organizationFolder: nil
            case .removed: nil
            }
        }
    }
}

public enum UndoOutcome: Equatable, Sendable {
    case restored
    case skipped(SkipReason, path: String)
    case failed(EngineError, path: String)
}

public enum UndoFailure: Error, Equatable {
    case batchRunning
}

public actor HistoryStore {
    let commitGate = LaneGate(width: 1)
    private var runningBatches: Set<UUID> = []
    private var terminating = false
    public static let capacity = 100
    private static let saveInterval: TimeInterval = 1

    private enum PersistenceState {
        case clean, appended, retryRequired
    }

    private var journal: HistoryJournal
    private var snapshot = HistorySnapshot()
    private var pending: [HistoryJournal.Entry] = []
    private var loadFailure: Error?
    private var organizationIntent: OrganizationMoveIntent?
    private let committer = FileCommitter()
    private let logger = Logger(category: "history")
    private var lastSave = Date.distantPast
    private var persistenceState = PersistenceState.clean
    public var records: [BatchRecord] { snapshot.batches }
    public var organizationSuppressions: [OrganizationSuppression] { snapshot.organizationSuppressions ?? [] }
    /// Where an unreadable history file was moved.
    public private(set) var setAsideFile: URL?

    public init(supportDirectory: URL) {
        var persistence = HistoryJournal(supportDirectory: supportDirectory)
        do {
            snapshot = try persistence.load()
            if FileManager.default.fileExists(atPath: persistence.journalURL.path) {
                persistenceState = .retryRequired
                do {
                    try persistence.publish(snapshot)
                    try persistence.reset()
                    persistenceState = .clean
                } catch {
                    logger.error("History compaction failed: \(error.localizedDescription, privacy: .private)")
                }
            }
        } catch {
            logger.error("History unreadable: \(error.localizedDescription, privacy: .private)")
            if FileManager.default.fileExists(atPath: persistence.journalURL.path) {
                loadFailure = error
            } else {
                do {
                    setAsideFile = try PrivateFile.setAside(persistence.snapshotURL)
                } catch {
                    loadFailure = error
                    logger.fault("History could not be set aside: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
        journal = persistence
        if loadFailure == nil {
            do {
                if let intent = try journal.loadOrganizationIntent() {
                    snapshot.organizationIntents = (snapshot.organizationIntents ?? []) + [intent]
                }
                try Self.recoverOrganizationIntents(snapshot: &snapshot, journal: &journal)
            } catch {
                loadFailure = error
                logger.error("Organization recovery failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    func record(
        _ newItems: [CommitRecord], batch id: UUID, operation: OperationID, recipeExecution: RecipeExecution? = nil
    ) throws {
        try checkAcceptingWork()
        guard !newItems.isEmpty else { return }
        let previousSequence = snapshot.sequence ?? 0
        guard previousSequence < UInt64.max else { throw CocoaError(.fileWriteOutOfSpace) }
        let date = records.last(where: { $0.id == id })?.date ?? Date()
        let batch = BatchRecord(
            id: id, operation: operation, date: date, recipeExecution: recipeExecution, items: newItems, undone: false)
        snapshot.append(batch)
        let sequence = previousSequence + 1
        snapshot.sequence = sequence
        pending.append(HistoryJournal.Entry(sequence: sequence, batch: batch))
        if persistenceState != .retryRequired { persistenceState = .appended }
        let needsDurableBackup = newItems.contains { record in
            switch record {
            case .replaced, .removed, .organized, .organizationFolder: true
            case .derived, .renamed, .extractedInPlace: false
            }
        }
        do {
            if persistenceState == .retryRequired {
                try save()
            } else if needsDurableBackup {
                var contents = Data()
                for entry in pending { contents.append(try HistoryJournal.encoded(entry)) }
                try journal.append(contents)
                pending.removeAll(keepingCapacity: true)
                lastSave = Date()
            } else if Date().timeIntervalSince(lastSave) >= Self.saveInterval {
                try save()
            }
        } catch {
            persistenceState = .retryRequired
            throw error
        }
    }

    func organize(_ plan: OrganizationMovePlan, batch: Batch) throws -> URL {
        try checkAcceptingCommits()
        let completed = try committer.organize(plan) { folder in
            try record([.organizationFolder(folder)], batch: batch.id, operation: batch.operation)
            try flush()
        } beforeMove: { move in
            let intent = OrganizationMoveIntent(
                id: UUID(), batchID: batch.id, operation: batch.operation, date: Date(), move: move)
            organizationIntent = intent
            try journal.publishOrganizationIntent(intent)
        }
        try record([.organized(completed)], batch: batch.id, operation: batch.operation)
        try journal.clearOrganizationIntent()
        organizationIntent = nil
        return completed.to
    }

    private static func recoverOrganizationIntents(snapshot: inout HistorySnapshot, journal: inout HistoryJournal)
        throws
    {
        guard let intents = snapshot.organizationIntents, !intents.isEmpty else { return }
        for intent in intents {
            let move = intent.move
            guard move.rootIdentity.matches(move.root, directory: true),
                OrganizationSafety.contains(move.from, in: move.root),
                OrganizationSafety.contains(move.to, in: move.root)
            else { throw EngineError.commitFailed("Organization recovery needs its original root") }
            let sourceMatches = move.stamp.matchesIdentity(move.from.path)
            let destinationMatches = move.stamp.matchesIdentity(move.to.path)
            guard !sourceMatches || !destinationMatches else {
                throw EngineError.commitFailed("Organization recovery has matching files at both paths")
            }
            if destinationMatches {
                try OrganizationSafety.validateDirectories(
                    to: move.to.deletingLastPathComponent(), root: move.root, identity: move.rootIdentity)
                let commit = CommitRecord.organized(move)
                if !snapshot.batches.contains(where: { $0.id == intent.batchID && $0.items.contains(commit) }) {
                    snapshot.append(
                        BatchRecord(
                            id: intent.batchID, operation: intent.operation, date: intent.date,
                            items: [commit], undone: false))
                }
            } else if !sourceMatches {
                throw EngineError.commitFailed("Organization recovery needs review; neither path matches")
            }
        }
        snapshot.organizationIntents = []
        try journal.publish(snapshot)
        try journal.reset()
        try journal.clearOrganizationIntent()
    }

    func flush() throws {
        if let loadFailure { throw loadFailure }
        if persistenceState != .clean { try save() }
    }

    func beginBatch(_ id: UUID) {
        runningBatches.insert(id)
    }

    func endBatch(_ id: UUID) {
        runningBatches.remove(id)
    }

    func checkAcceptingWork() throws {
        if let loadFailure { throw loadFailure }
        if terminating { throw CancellationError() }
    }

    func checkAcceptingCommits() throws {
        try checkAcceptingWork()
        if let organizationIntent {
            snapshot.organizationIntents = [organizationIntent]
            try Self.recoverOrganizationIntents(snapshot: &snapshot, journal: &journal)
            self.organizationIntent = nil
            pending.removeAll(keepingCapacity: true)
            persistenceState = .clean
        }
        if persistenceState == .retryRequired {
            do {
                try save()
            } catch {
                throw EngineError.historyPersistenceFailed
            }
        }
    }

    func prepareForTermination() async throws {
        try await commitGate.acquire()
        do {
            terminating = true
            try flush()
            await commitGate.release()
        } catch {
            terminating = false
            await commitGate.release()
            throw error
        }
    }

    public func clear() throws {
        try checkAcceptingCommits()
        snapshot.batches = []
        try save()
    }

    public func undo(_ id: UUID) async throws -> [UndoOutcome] {
        try await commitGate.acquire()
        do {
            try checkAcceptingCommits()
            guard !runningBatches.contains(id) else { throw UndoFailure.batchRunning }
            let outcomes = try await undoRecordedBatch(id)
            await commitGate.release()
            return outcomes
        } catch {
            await commitGate.release()
            throw error
        }
    }

    private func undoRecordedBatch(_ id: UUID) async throws -> [UndoOutcome] {
        guard let index = records.firstIndex(where: { $0.id == id }), !records[index].undone else { return [] }
        let batch = records[index]
        guard batch.canUndo else { return [] }
        let suppressions = batch.items.compactMap { record -> OrganizationSuppression? in
            guard case .organized(let move) = record else { return nil }
            return OrganizationSuppression(path: move.from.path, stamp: move.stamp)
        }
        if !suppressions.isEmpty {
            snapshot.organizationSuppressions = (snapshot.organizationSuppressions ?? []) + suppressions
            try save()
        }
        var outcomes: [UndoOutcome] = []
        var failed: [CommitRecord] = []
        for entry in batch.items.reversed() {
            let outcome = await committer.undo(entry)
            outcomes.append(outcome)
            if case .failed = outcome { failed.insert(entry, at: 0) }
        }
        guard let currentIndex = records.firstIndex(where: { $0.id == id && $0.date == batch.date }),
            records[currentIndex].items.starts(with: batch.items)
        else {
            return outcomes
        }
        let appended = records[currentIndex].items.dropFirst(batch.items.count)
        snapshot.batches[currentIndex].items = failed + appended
        snapshot.batches[currentIndex].undone = snapshot.batches[currentIndex].items.isEmpty
        try save()
        return outcomes
    }

    private func save() throws {
        persistenceState = .retryRequired
        try journal.publish(snapshot)
        pending.removeAll(keepingCapacity: true)
        try journal.reset()
        lastSave = Date()
        persistenceState = .clean
    }
}
