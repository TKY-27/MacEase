import Darwin
import Foundation
import Synchronization
import Testing

@testable import Engine

@Suite struct HistoryJournalTests {
    @Test func legacySnapshotAndJournalPreserveBatchMetadataAndStamps() async throws {
        let folder = try Self.makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let id = UUID()
        let original = folder.appending(path: "original")
        let trashed = folder.appending(path: "trashed")
        try Data("backup".utf8).write(to: trashed)
        let entry = CommitRecord.removed(
            original: original.path, trashed: trashed.path,
            trashStamp: try FileStamp(of: trashed, includingIdentity: true))
        let legacy = """
            {"version":1,"batches":[{"id":"\(id.uuidString)","operation":"folder.rename",
            "date":0,"items":[],"undone":true}]}
            """
        try Data(legacy.utf8).write(to: folder.appending(path: "history.json"))
        let store = HistoryStore(supportDirectory: folder)
        try await store.record([entry], batch: id, operation: .folderRemoveDuplicates)
        let reloaded = HistoryStore(supportDirectory: folder)
        let batch = try #require(await reloaded.records.first)
        #expect(batch.id == id)
        #expect(batch.date == Date(timeIntervalSinceReferenceDate: 0))
        #expect(batch.operation == .folderRename)
        #expect(batch.items == [entry])
        #expect(!batch.undone)
        let outcomes = try await reloaded.undo(id)
        #expect(outcomes == [.restored])
        #expect(try String(contentsOf: original, encoding: .utf8) == "backup")
    }

    @Test func everyTornTailPreservesCompletedRecordsAndAllowsNewCommits() async throws {
        let folder = try Self.makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let id = UUID()
        let store = HistoryStore(supportDirectory: folder)
        try await store.record([Self.removal(0)], batch: id, operation: .folderRemoveDuplicates)
        let journalURL = folder.appending(path: "history.journal")
        let prefix = try Data(contentsOf: journalURL)
        try await store.record([Self.removal(1)], batch: id, operation: .folderRemoveDuplicates)
        let complete = try Data(contentsOf: journalURL)
        for length in prefix.count..<complete.count {
            let recovery = folder.appending(path: "recovery-\(length)")
            try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: false)
            try complete.prefix(length).write(to: recovery.appending(path: "history.journal"))
            let recovered = HistoryStore(supportDirectory: recovery)
            #expect(await recovered.records.first?.items == [Self.removal(0)])
            try await recovered.record([Self.removal(2)], batch: id, operation: .folderRemoveDuplicates)
            let reopened = HistoryStore(supportDirectory: recovery)
            #expect(await reopened.records.first?.items == [Self.removal(0), Self.removal(2)])
        }
    }

    @Test func killBeforeCompactionPreservesEveryDurableAppend() async throws {
        let result = try await #require(processExitsWith: .signal(SIGKILL), observing: [\.standardOutputContent]) {
            try await Self.killAtCompaction(.beforePublication)
        }
        try await Self.verifyRecovery(result)
    }

    @Test func killAfterSnapshotPublicationDoesNotReplayTwice() async throws {
        let result = try await #require(processExitsWith: .signal(SIGKILL), observing: [\.standardOutputContent]) {
            try await Self.killAtCompaction(.afterPublication)
        }
        try await Self.verifyRecovery(result)
    }

    @Test func killAfterJournalResetPreservesSnapshot() async throws {
        let result = try await #require(processExitsWith: .signal(SIGKILL), observing: [\.standardOutputContent]) {
            try await Self.killAtCompaction(.afterReset)
        }
        try await Self.verifyRecovery(result)
    }

    @Test(arguments: ["{broken}\n", "{\"sequence\":3,\"batch\":null}\n"])
    func completeCorruptFramesBlockWritesWithoutDiscardingHistory(suffix: String) async throws {
        let folder = try Self.makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let store = HistoryStore(supportDirectory: folder)
        try await store.record([Self.removal(0)], batch: UUID(), operation: .folderRemoveDuplicates)
        let journalURL = folder.appending(path: "history.journal")
        var contents = try Data(contentsOf: journalURL)
        contents.append(Data(suffix.utf8))
        try contents.write(to: journalURL)
        let reloaded = HistoryStore(supportDirectory: folder)
        await #expect(throws: (any Error).self) { try await reloaded.checkAcceptingCommits() }
        await #expect(throws: (any Error).self) { try await reloaded.flush() }
        await #expect(throws: (any Error).self) { try await reloaded.clear() }
        #expect(try Data(contentsOf: journalURL) == contents)
    }

    @Test func sequenceGapsRefuseReplay() async throws {
        let folder = try Self.makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let store = HistoryStore(supportDirectory: folder)
        try await store.record([Self.removal(0)], batch: UUID(), operation: .folderRemoveDuplicates)
        let journalURL = folder.appending(path: "history.journal")
        let contents = try String(contentsOf: journalURL, encoding: .utf8)
            .replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":2")
        try Data(contents.utf8).write(to: journalURL)
        let reloaded = HistoryStore(supportDirectory: folder)
        await #expect(throws: CocoaError(.fileReadCorruptFile)) { try await reloaded.flush() }
        #expect(try String(contentsOf: journalURL, encoding: .utf8) == contents)
    }

    @Test func replayKeepsOnlyTheLastHundredBatches() async throws {
        let folder = try Self.makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let store = HistoryStore(supportDirectory: folder)
        let overflow = 5
        for index in 0..<(HistoryStore.capacity + overflow) {
            try await store.record([Self.removal(index)], batch: UUID(), operation: .folderRemoveDuplicates)
        }
        let expected = await store.records
        let reloaded = HistoryStore(supportDirectory: folder)
        #expect(await reloaded.records == expected)
        #expect(expected.count == HistoryStore.capacity)
        #expect(expected.first?.items == [Self.removal(overflow)])
        for name in ["history.json", "history.journal"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: folder.appending(path: name).path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)
        }
    }

    @Test func failedAppendRetriesPendingEntriesWithoutDuplication() async throws {
        let folder = try Self.makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let store = HistoryStore(supportDirectory: folder)
        let id = UUID()
        try await store.record([Self.removal(0)], batch: id, operation: .folderRemoveDuplicates)
        let journalURL = folder.appending(path: "history.journal")
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: journalURL.path)
        await #expect(throws: (any Error).self) {
            try await store.record([Self.removal(1)], batch: id, operation: .folderRemoveDuplicates)
        }
        await #expect(throws: EngineError.historyPersistenceFailed) { try await store.checkAcceptingCommits() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        let stream = try FileHandle(forWritingTo: journalURL)
        try stream.seekToEnd()
        try stream.write(contentsOf: Data("{torn".utf8))
        try stream.close()
        try await store.record([Self.removal(2)], batch: id, operation: .folderRemoveDuplicates)
        let reloaded = HistoryStore(supportDirectory: folder)
        #expect(await reloaded.records.first?.items == (0..<3).map(Self.removal))
    }

    @Test func failedClearMustPersistBeforeLaterAppends() async throws {
        let folder = try Self.makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let store = HistoryStore(supportDirectory: folder)
        let first = UUID()
        let second = UUID()
        try await store.record([Self.removal(0)], batch: first, operation: .folderRemoveDuplicates)
        let journalURL = folder.appending(path: "history.journal")
        let journalBeforeFailure = try Data(contentsOf: journalURL)
        let snapshotURL = folder.appending(path: "history.json")
        try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await store.clear() }
        #expect(try Data(contentsOf: journalURL) == journalBeforeFailure)
        try FileManager.default.removeItem(at: snapshotURL)
        try await store.record([Self.removal(1)], batch: second, operation: .folderRemoveDuplicates)
        let reloaded = HistoryStore(supportDirectory: folder)
        #expect(await reloaded.records.map(\.id) == [second])
        #expect(await reloaded.records.first?.items == [Self.removal(1)])
    }

    @Test func committedRecordsStayPendingWhilePersistenceRemainsUnavailable() async throws {
        let folder = try Self.makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let store = HistoryStore(supportDirectory: folder)
        let journalURL = folder.appending(path: "history.journal")
        try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: false)
        let id = UUID()
        for index in 0..<2 {
            await #expect(throws: (any Error).self) {
                try await store.record([Self.removal(index)], batch: id, operation: .folderRemoveDuplicates)
            }
        }
        #expect(await store.records.first?.items == [Self.removal(0), Self.removal(1)])
        await #expect(throws: EngineError.historyPersistenceFailed) { try await store.checkAcceptingCommits() }
        try FileManager.default.removeItem(at: journalURL)
        try await store.checkAcceptingCommits()
        let reloaded = HistoryStore(supportDirectory: folder)
        #expect(await reloaded.records.first?.items == [Self.removal(0), Self.removal(1)])
    }

    @Test func failedJournalResetLeavesPublishedSnapshotAndReplayableJournal() async throws {
        let folder = try Self.makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let store = HistoryStore(supportDirectory: folder)
        let id = UUID()
        try await store.record([Self.removal(0)], batch: id, operation: .folderRemoveDuplicates)
        let journalURL = folder.appending(path: "history.journal")
        let contents = try Data(contentsOf: journalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: journalURL.path)
        await #expect(throws: (any Error).self) { try await store.flush() }
        let published = try JSONDecoder().decode(
            HistorySnapshot.self, from: Data(contentsOf: folder.appending(path: "history.json")))
        #expect(published.batches.first?.items == [Self.removal(0)])
        #expect(published.sequence == 1)
        #expect(try Data(contentsOf: journalURL) == contents)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        try await store.record([Self.removal(1)], batch: id, operation: .folderRemoveDuplicates)
        let reloaded = HistoryStore(supportDirectory: folder)
        #expect(await reloaded.records.first?.items == [Self.removal(0), Self.removal(1)])
    }

    @Test func unreadableSnapshotWithJournalPreservesBothRecoveryFiles() async throws {
        let folder = try Self.makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let store = HistoryStore(supportDirectory: folder)
        try await store.record([Self.removal(0)], batch: UUID(), operation: .folderRemoveDuplicates)
        let journalURL = folder.appending(path: "history.journal")
        let contents = try Data(contentsOf: journalURL)
        let snapshotURL = folder.appending(path: "history.json")
        let corruptSnapshot = Data("{broken".utf8)
        try corruptSnapshot.write(to: snapshotURL)
        let reloaded = HistoryStore(supportDirectory: folder)
        await #expect(throws: (any Error).self) { try await reloaded.checkAcceptingCommits() }
        #expect(await reloaded.setAsideFile == nil)
        #expect(try Data(contentsOf: snapshotURL) == corruptSnapshot)
        #expect(try Data(contentsOf: journalURL) == contents)
    }

    @Test func undoAndCompactionPreserveConsumedAndPendingEntries() async throws {
        let folder = try Self.makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let store = HistoryStore(supportDirectory: folder)
        let undone = UUID()
        let retained = UUID()
        let original = folder.appending(path: "original")
        let renamed = folder.appending(path: "renamed")
        try Data("keep".utf8).write(to: renamed)
        try await store.record(
            [
                .renamed(
                    from: original.path, to: renamed.path, stamp: try FileStamp(of: renamed, includingIdentity: true))
            ],
            batch: undone, operation: .folderRename)
        try await store.record([Self.removal(0)], batch: retained, operation: .folderRemoveDuplicates)
        let presenter = HistoryCompactionPresenter(url: renamed, store: store)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }

        let outcomes = try await store.undo(undone)
        #expect(outcomes == [.restored])
        try #require(presenter.compacted.withLock { $0 }).get()
        let reloaded = HistoryStore(supportDirectory: folder)
        #expect(await reloaded.records.first?.undone == true)
        #expect(await reloaded.records.first?.items.isEmpty == true)
        #expect(await reloaded.records.last?.items == [Self.removal(0)])
        #expect(try await reloaded.undo(undone).isEmpty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "keep")
    }

    @Test func threeThousandDurableRecordsHaveLinearWriteVolume() async throws {
        await #expect(processExitsWith: .success) {
            let folder = try Self.makeFolder()
            defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
            let store = HistoryStore(supportDirectory: folder)
            let id = UUID()
            let recordCount = 3_000
            let maximumBytesPerRecord: UInt64 = 24 * 1024
            let before = try Self.writtenBytes()
            let started = ContinuousClock.now
            for index in 0..<recordCount {
                try await store.record([Self.removal(index)], batch: id, operation: .folderRemoveDuplicates)
            }
            try await store.flush()
            let elapsed = started.duration(to: .now)
            let written = try Self.writtenBytes() - before
            #expect(written > 0)
            #expect(written < UInt64(recordCount) * maximumBytesPerRecord)
            let reloaded = HistoryStore(supportDirectory: folder)
            #expect(await reloaded.records.first?.items == (0..<recordCount).map(Self.removal))
            Attachment.record(
                "\(recordCount) records, \(written) disk bytes, \(elapsed)", named: "history-write-volume.txt")
        }
    }

    private enum CompactionBoundary {
        case beforePublication, afterPublication, afterReset
    }

    private static func killAtCompaction(_ boundary: CompactionBoundary) async throws {
        let folder = try makeFolder()
        try FileHandle.standardOutput.write(contentsOf: Data(folder.path.utf8))
        let store = HistoryStore(supportDirectory: folder)
        let id = UUID()
        for index in 0..<3 {
            try await store.record([removal(index)], batch: id, operation: .folderRemoveDuplicates)
        }
        if boundary != .beforePublication {
            var journal = HistoryJournal(supportDirectory: folder)
            let snapshot = try journal.load()
            try journal.publish(snapshot)
            if boundary == .afterReset { try journal.reset() }
        }
        try #require(kill(getpid(), SIGKILL) == 0)
        while true { pause() }
    }

    private static func verifyRecovery(_ result: ExitTest.Result) async throws {
        let path = try #require(String(bytes: result.standardOutputContent, encoding: .utf8))
        let folder = URL(fileURLWithPath: path)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let expected = (0..<3).map(removal)
        for _ in 0..<3 {
            let store = HistoryStore(supportDirectory: folder)
            #expect(await store.records.count == 1)
            #expect(await store.records.first?.items == expected)
            try await store.flush()
        }
    }

    private static func writtenBytes() throws -> UInt64 {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        try #require(status == 0)
        return usage.ri_diskio_byteswritten
    }

    private static func removal(_ index: Int) -> CommitRecord {
        .removed(original: "/original-\(index)", trashed: "/trash-\(index)")
    }

    private static func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MacEaseJournal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }
}

private final class HistoryCompactionPresenter: NSObject, NSFilePresenter, Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    let compacted = Mutex<Result<Void, any Error>?>(nil)
    private let store: HistoryStore

    init(url: URL, store: HistoryStore) {
        presentedItemURL = url
        self.store = store
    }

    func relinquishPresentedItem(toWriter writer: @Sendable ((@Sendable () -> Void)?) -> Void) {
        let completed = DispatchSemaphore(value: 0)
        Task {
            do {
                try await store.flush()
                compacted.withLock { $0 = .success(()) }
            } catch {
                compacted.withLock { $0 = .failure(error) }
            }
            completed.signal()
        }
        completed.wait()
        writer(nil)
    }
}
