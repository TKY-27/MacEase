import Foundation
import MenuCatalog
import os

public struct FileStamp: Codable, Equatable, Sendable {
    public let size: Int64?
    public let modified: Date

    init(of url: URL) throws {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
        guard let modified = values.contentModificationDate else {
            throw EngineError.commitFailed("missing modification date")
        }
        self.size = values.isDirectory == true ? nil : values.fileSize.map(Int64.init)
        self.modified = modified
    }
}

public enum CommitRecord: Codable, Equatable, Sendable {
    case replaced(original: String, trashed: String, output: String, stamp: FileStamp)
    case derived(output: String, stamp: FileStamp)
    case renamed(from: String, to: String)
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
            case .renamed(_, let to): to
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
            logger.error("History unreadable: \(error.localizedDescription, privacy: .public)")
            do {
                setAsideFile = try PrivateFile.setAside(file)
            } catch {
                logger.fault("History could not be set aside: \(error.localizedDescription, privacy: .public)")
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
                guard (try? FileStamp(of: URL(fileURLWithPath: output))) == stamp else {
                    return .skipped(.undoOutputChanged, path: output)
                }
                if output != original, fileManager.fileExists(atPath: original) {
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
                guard (try? FileStamp(of: URL(fileURLWithPath: output))) == stamp else {
                    return .skipped(.undoOutputChanged, path: output)
                }
                _ = try committer.trash(URL(fileURLWithPath: output))
            case .renamed(let from, let to):
                guard fileManager.fileExists(atPath: to) else { return .skipped(.undoOutputChanged, path: to) }
                let caseOnly = from.lowercased() == to.lowercased()
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
        case .renamed(_, let to): to
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
