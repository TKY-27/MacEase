import CryptoKit
import Darwin
import Foundation
import MenuCatalog
import os

public struct FileStamp: Codable, Equatable, Sendable {
    public let size: Int64?
    public let modified: Date
    private let directorySummary: DirectorySummary?
    private let identity: FileIdentity?

    private struct FileIdentity: Codable, Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    private struct DirectorySummary: Codable, Equatable, Sendable {
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

    init(of url: URL, includingIdentity: Bool = false) throws {
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
    case replaced(original: String, trashed: String, output: String, stamp: FileStamp?, trashStamp: FileStamp? = nil)
    case derived(output: String, stamp: FileStamp?)
    case renamed(from: String, to: String, stamp: FileStamp? = nil)
    case removed(original: String, trashed: String, trashStamp: FileStamp? = nil)
}

public struct BatchRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let operation: OperationID
    public let date: Date
    /// Only failed items after a partial undo.
    public internal(set) var items: [CommitRecord]
    public internal(set) var undone: Bool

    public var outputPaths: [String] {
        items.compactMap { record in
            switch record {
            case .replaced(_, _, let output, _, _), .derived(let output, _): output
            case .renamed(_, let to, _): to
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
    private let committer = FileCommitter()
    private let logger = Logger(category: "history")
    private var lastSave = Date.distantPast
    private var persistenceState = PersistenceState.clean
    public var records: [BatchRecord] { snapshot.batches }
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
    }

    func record(_ newItems: [CommitRecord], batch id: UUID, operation: OperationID) throws {
        try checkAcceptingWork()
        guard !newItems.isEmpty else { return }
        let previousSequence = snapshot.sequence ?? 0
        guard previousSequence < UInt64.max else { throw CocoaError(.fileWriteOutOfSpace) }
        let date = records.last(where: { $0.id == id })?.date ?? Date()
        let batch = BatchRecord(id: id, operation: operation, date: date, items: newItems, undone: false)
        snapshot.append(batch)
        let sequence = previousSequence + 1
        snapshot.sequence = sequence
        pending.append(HistoryJournal.Entry(sequence: sequence, batch: batch))
        if persistenceState != .retryRequired { persistenceState = .appended }
        let needsDurableBackup = newItems.contains { record in
            switch record {
            case .replaced, .removed: true
            case .derived, .renamed: false
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
