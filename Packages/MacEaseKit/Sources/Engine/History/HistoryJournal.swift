import Darwin
import Foundation
import os

struct HistorySnapshot: Codable {
    static let formatVersion = 1
    var version = formatVersion
    var batches: [BatchRecord] = []
    var sequence: UInt64?
    var organizationSuppressions: [OrganizationSuppression]?
    var organizationIntents: [OrganizationMoveIntent]?

    mutating func append(_ batch: BatchRecord) {
        if let index = batches.lastIndex(where: { $0.id == batch.id }) {
            batches[index].items += batch.items
            batches[index].undone = false
        } else {
            batches.append(batch)
            if batches.count > HistoryStore.capacity {
                batches.removeFirst(batches.count - HistoryStore.capacity)
            }
        }
    }
}

struct HistoryJournal {
    struct Entry: Codable {
        let sequence: UInt64
        let batch: BatchRecord
    }

    let snapshotURL: URL
    let journalURL: URL
    let organizationIntentURL: URL
    private(set) var offset: UInt64 = 0
    private let logger = Logger(category: "history")
    private static let newline = UInt8(ascii: "\n")

    init(supportDirectory: URL) {
        organizationIntentURL = supportDirectory.appending(path: "organization-intent.json")
        snapshotURL = supportDirectory.appending(path: "history.json")
        journalURL = supportDirectory.appending(path: "history.journal")
    }

    mutating func load() throws -> HistorySnapshot {
        let decoder = JSONDecoder()
        var snapshot = HistorySnapshot()
        if FileManager.default.fileExists(atPath: snapshotURL.path) {
            snapshot = try decoder.decode(HistorySnapshot.self, from: Data(contentsOf: snapshotURL))
            guard snapshot.version == HistorySnapshot.formatVersion else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            snapshot.batches = Array(snapshot.batches.suffix(HistoryStore.capacity))
        }
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return snapshot }
        let contents = try Data(contentsOf: journalURL, options: .mappedIfSafe)
        var start = contents.startIndex
        var previousSequence: UInt64 = 0
        for end in contents.indices where contents[end] == Self.newline {
            let entry = try decoder.decode(Entry.self, from: contents[start..<end])
            guard entry.sequence > previousSequence, !entry.batch.undone, !entry.batch.items.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            previousSequence = entry.sequence
            let checkpoint = snapshot.sequence ?? 0
            if entry.sequence > checkpoint {
                guard checkpoint < UInt64.max, entry.sequence == checkpoint + 1 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                snapshot.append(entry.batch)
                snapshot.sequence = entry.sequence
            }
            start = end + 1
        }
        offset = UInt64(start)
        return snapshot
    }

    func loadOrganizationIntent() throws -> OrganizationMoveIntent? {
        guard FileManager.default.fileExists(atPath: organizationIntentURL.path) else { return nil }
        return try JSONDecoder().decode(OrganizationMoveIntent.self, from: Data(contentsOf: organizationIntentURL))
    }

    func publishOrganizationIntent(_ intent: OrganizationMoveIntent) throws {
        try PrivateFile.write(JSONEncoder().encode(intent), to: organizationIntentURL)
        let stream = try FileHandle(forWritingTo: organizationIntentURL)
        defer { close(stream) }
        try synchronize(stream)
        try synchronizeDirectory()
    }

    func clearOrganizationIntent() throws {
        if unlink(organizationIntentURL.path) != 0, errno != ENOENT {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        try synchronizeDirectory()
    }

    static func encoded(_ entry: Entry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var contents = try encoder.encode(entry)
        contents.append(newline)
        return contents
    }

    mutating func append(_ contents: Data) throws {
        let descriptor = open(journalURL.path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let stream = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { close(stream) }
        try stream.truncate(atOffset: offset)
        try stream.seek(toOffset: offset)
        try stream.write(contentsOf: contents)
        try synchronize(stream)
        try synchronizeDirectory()
        offset += UInt64(contents.count)
    }

    func publish(_ snapshot: HistorySnapshot) throws {
        let staged = snapshotURL.deletingLastPathComponent().appending(path: ".history-\(UUID().uuidString)")
        defer {
            if FileManager.default.fileExists(atPath: staged.path) {
                do {
                    try FileManager.default.removeItem(at: staged)
                } catch {
                    logger.error("History staging cleanup failed: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try PrivateFile.write(encoder.encode(snapshot), to: staged)
        let stream = try FileHandle(forWritingTo: staged)
        defer { close(stream) }
        try synchronize(stream)
        guard rename(staged.path, snapshotURL.path) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        try synchronizeDirectory()
    }

    mutating func reset() throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            offset = 0
            return
        }
        let stream = try FileHandle(forWritingTo: journalURL)
        defer { close(stream) }
        try stream.truncate(atOffset: 0)
        offset = 0
        try synchronize(stream)
    }

    private func synchronizeDirectory() throws {
        let descriptor = open(snapshotURL.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let directory = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { close(directory) }
        try synchronize(directory)
    }

    private func synchronize(_ stream: FileHandle) throws {
        guard fsync(stream.fileDescriptor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private func close(_ stream: FileHandle) {
        do {
            try stream.close()
        } catch {
            logger.error("History close failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
