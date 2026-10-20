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
        var currentURL = url
        currentURL.removeAllCachedResourceValues()
        let values = try currentURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let modificationDate = values.contentModificationDate else {
            throw EngineError.commitFailed("missing modification date")
        }
        size = isDirectory ? nil : values.fileSize.map(Int64.init)
        modified = modificationDate
        directorySummary = isDirectory ? Self.snapshot(of: url) : nil
        identity =
            includingIdentity
            ? FileIdentity(device: UInt64(UInt32(bitPattern: metadata.st_dev)), inode: metadata.st_ino) : nil
    }

    fileprivate func matches(_ path: String) -> Bool {
        guard directorySummary?.unreadableCount == nil || directorySummary?.unreadableCount == 0 else {
            return false
        }
        do {
            return try FileStamp(of: URL(fileURLWithPath: path), includingIdentity: identity != nil) == self
        } catch {
            return false
        }
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
    case replaced(original: String, trashed: String, output: String, stamp: FileStamp?)
    case derived(output: String, stamp: FileStamp?)
    case renamed(from: String, to: String, stamp: FileStamp? = nil)
    case removed(original: String, trashed: String)
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
            case .replaced(_, _, let output, _), .derived(let output, _): output
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

public actor HistoryStore {
    public static let capacity = 100
    private static let formatVersion = 1
    private static let saveInterval: TimeInterval = 1

    private struct Stored: Codable {
        var version: Int
        var batches: [BatchRecord]
    }

    private let file: URL
    private let committer = FileCommitter()
    private let logger = Logger(category: "history")
    private var lastSave = Date.distantPast
    private var dirty = false
    public private(set) var records: [BatchRecord] = []
    /// Where an unreadable history file was moved.
    public private(set) var setAsideFile: URL?

    public init(supportDirectory: URL) {
        file = supportDirectory.appending(path: "history.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: file))
            guard stored.version == Self.formatVersion else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            records = stored.batches
        } catch {
            logger.error(
                "History unreadable: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
            do {
                setAsideFile = try PrivateFile.setAside(file)
            } catch {
                logger.fault(
                    "History could not be set aside: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public): \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    func record(_ newItems: [CommitRecord], batch id: UUID, operation: OperationID) throws {
        guard !newItems.isEmpty else { return }
        if let index = records.lastIndex(where: { $0.id == id }) {
            records[index].items += newItems
        } else {
            records.append(BatchRecord(id: id, operation: operation, date: Date(), items: newItems, undone: false))
            records = Array(records.suffix(Self.capacity))
        }
        dirty = true
        if Date().timeIntervalSince(lastSave) >= Self.saveInterval { try save() }
    }

    func flush() throws {
        if dirty { try save() }
    }

    public func clear() throws {
        records = []
        try save()
    }

    public func undo(_ id: UUID) throws -> [UndoOutcome] {
        guard let index = records.firstIndex(where: { $0.id == id }), !records[index].undone else { return [] }
        var outcomes: [UndoOutcome] = []
        var failed: [CommitRecord] = []
        for item in records[index].items.reversed() {
            let outcome = undo(item)
            outcomes.append(outcome)
            if case .failed = outcome { failed.insert(item, at: 0) }
        }
        records[index].items = failed
        records[index].undone = failed.isEmpty
        try save()
        return outcomes
    }

    private func undo(_ record: CommitRecord) -> UndoOutcome {
        let fileManager = FileManager.default
        do {
            switch record {
            case .replaced(let original, let trashed, let output, let stamp):
                guard fileManager.fileExists(atPath: trashed) else {
                    return .skipped(.undoTrashItemMissing, path: original)
                }
                guard let stamp, stamp.matches(output) else {
                    return .skipped(.undoOutputChanged, path: output)
                }
                let caseOnly = try FileCommitter.isCaseOnlyChange(
                    from: original, to: output, in: URL(fileURLWithPath: original).deletingLastPathComponent())
                if output != original, !caseOnly, fileManager.fileExists(atPath: original) {
                    return .skipped(.undoOriginalOccupied, path: original)
                }
                let trashedOutput = try committer.trash(URL(fileURLWithPath: output))
                do {
                    try committer.move(URL(fileURLWithPath: trashed), to: URL(fileURLWithPath: original))
                } catch {
                    try committer.move(trashedOutput, to: URL(fileURLWithPath: output))
                    throw error
                }
            case .derived(let output, let stamp):
                guard let stamp, stamp.matches(output) else {
                    return .skipped(.undoOutputChanged, path: output)
                }
                _ = try committer.trash(URL(fileURLWithPath: output))
            case .renamed(let from, let to, let stamp):
                guard let stamp, stamp.matches(to)
                else { return .skipped(.undoOutputChanged, path: to) }
                let caseOnly = try FileCommitter.isCaseOnlyChange(
                    from: from, to: to, in: URL(fileURLWithPath: from).deletingLastPathComponent())
                guard caseOnly || !fileManager.fileExists(atPath: from) else {
                    return .skipped(.undoOriginalOccupied, path: from)
                }
                try committer.move(URL(fileURLWithPath: to), to: URL(fileURLWithPath: from))
            case .removed(let original, let trashed):
                guard fileManager.fileExists(atPath: trashed) else {
                    return .skipped(.undoTrashItemMissing, path: original)
                }
                guard !fileManager.fileExists(atPath: original) else {
                    return .skipped(.undoOriginalOccupied, path: original)
                }
                try committer.move(URL(fileURLWithPath: trashed), to: URL(fileURLWithPath: original))
            }
        } catch {
            let path = Self.path(of: record)
            return .failed(EngineError.wrapping(error, path: path, otherwise: EngineError.commitFailed), path: path)
        }
        return .restored
    }

    private static func path(of record: CommitRecord) -> String {
        switch record {
        case .replaced(_, let trashed, _, _), .removed(_, let trashed): trashed
        case .derived(let output, _): output
        case .renamed(_, let to, _): to
        }
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try PrivateFile.write(encoder.encode(Stored(version: Self.formatVersion, batches: records)), to: file)
        lastSave = Date()
        dirty = false
    }
}
