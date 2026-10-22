import Foundation
import MenuCatalog
import Testing

@testable import Engine

struct HistorySafetyTests {
    @Test func derivedDirectoryUndoSkipsEditedChildWithUnchangedRootDate() async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let output = folder.appending(path: "output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let child = output.appending(path: "child.txt")
        try Data("old".utf8).write(to: child)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: output.path)
        let childDate = try FileStamp(of: child).modified
        let stamp = try FileStamp(of: output)
        let id = UUID()
        let store = HistoryStore(supportDirectory: folder)
        try await store.record([.derived(output: output.path, stamp: stamp)], batch: id, operation: .folderRename)

        try Data("new".utf8).write(to: child)
        try FileManager.default.setAttributes(
            [.modificationDate: childDate.addingTimeInterval(2)], ofItemAtPath: child.path)
        try FileManager.default.setAttributes(
            [.modificationDate: stamp.modified], ofItemAtPath: output.path)

        #expect(try FileStamp(of: output).modified == stamp.modified)
        #expect(try await store.undo(id) == [.skipped(.undoOutputChanged, path: output.path)])
        #expect(try String(contentsOf: child, encoding: .utf8) == "new")
    }

    @Test(arguments: ["added", "removed", "retyped"])
    func derivedDirectoryUndoSkipsChangedDescendants(change: String) async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let output = folder.appending(path: "output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let child = output.appending(path: "child.txt")
        try Data("old".utf8).write(to: child)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: output.path)
        let stamp = try FileStamp(of: output)
        let id = UUID()
        let store = HistoryStore(supportDirectory: folder)
        try await store.record([.derived(output: output.path, stamp: stamp)], batch: id, operation: .folderRename)

        switch change {
        case "added":
            try Data("added".utf8).write(to: output.appending(path: "extra.txt"))
        case "removed":
            try FileManager.default.removeItem(at: child)
        case "retyped":
            try FileManager.default.removeItem(at: child)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        default:
            Issue.record("unknown change")
            return
        }
        try FileManager.default.setAttributes(
            [.modificationDate: stamp.modified], ofItemAtPath: output.path)

        #expect(try FileStamp(of: output).modified == stamp.modified)
        #expect(try await store.undo(id) == [.skipped(.undoOutputChanged, path: output.path)])
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func directoryStampDoesNotFollowSymbolicLinks() throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let output = folder.appending(path: "output")
        let target = folder.appending(path: "target")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: output.appending(path: "link"), withDestinationURL: target)
        let stamp = try FileStamp(of: output)

        try Data("outside".utf8).write(to: target.appending(path: "new.txt"))

        #expect(try FileStamp(of: output) == stamp)
    }

    @Test func renamedFileUndoSkipsEditedDestination() async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let original = folder.appending(path: "before.txt")
        let destination = folder.appending(path: "after.txt")
        try Data("old".utf8).write(to: destination)
        let stamp = try FileStamp(of: destination, includingIdentity: true)
        let id = UUID()
        let store = HistoryStore(supportDirectory: folder)
        try await store.record(
            [.renamed(from: original.path, to: destination.path, stamp: stamp)],
            batch: id, operation: .folderRename)

        try Data("edited".utf8).write(to: destination)

        #expect(try await store.undo(id) == [.skipped(.undoOutputChanged, path: destination.path)])
        #expect(try String(contentsOf: destination, encoding: .utf8) == "edited")
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test func renamedFileUndoSkipsRecreatedDestinationWithMatchingSizeAndDate() async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let original = folder.appending(path: "before.txt")
        let destination = folder.appending(path: "after.txt")
        let replacement = folder.appending(path: "replacement.txt")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("old".utf8).write(to: destination)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: destination.path)
        let stamp = try FileStamp(of: destination, includingIdentity: true)
        let id = UUID()
        let store = HistoryStore(supportDirectory: folder)
        try await store.record(
            [.renamed(from: original.path, to: destination.path, stamp: stamp)],
            batch: id, operation: .folderRename)

        try Data("new".utf8).write(to: replacement)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: replacement.path)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: replacement, to: destination)
        let current = try FileStamp(of: destination)
        #expect(current.size == stamp.size)
        #expect(current.modified == stamp.modified)

        #expect(try await store.undo(id) == [.skipped(.undoOutputChanged, path: destination.path)])
        #expect(try String(contentsOf: destination, encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test func legacyHistoryLoadsButUnsafeUndoSkips() async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let output = folder.appending(path: "output")
        let original = folder.appending(path: "before.txt")
        let destination = folder.appending(path: "after.txt")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: output.appending(path: "child.txt"))
        try Data("keep".utf8).write(to: destination)
        let batch = BatchRecord(
            id: UUID(), operation: .folderRename, date: Date(),
            items: [
                .derived(output: output.path, stamp: try FileStamp(of: output)),
                .renamed(from: original.path, to: destination.path),
            ], undone: false)
        var batchJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(batch)) as? [String: Any])
        var items = try #require(batchJSON["items"] as? [[String: Any]])
        var derived = try #require(items[0]["derived"] as? [String: Any])
        var stamp = try #require(derived["stamp"] as? [String: Any])
        stamp.removeValue(forKey: "directorySummary")
        derived["stamp"] = stamp
        items[0]["derived"] = derived
        var renamed = try #require(items[1]["renamed"] as? [String: Any])
        renamed.removeValue(forKey: "stamp")
        items[1]["renamed"] = renamed
        batchJSON["items"] = items
        let support = folder.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        try JSONSerialization.data(withJSONObject: ["version": 1, "batches": [batchJSON]])
            .write(to: support.appending(path: "history.json"))

        let store = HistoryStore(supportDirectory: support)
        #expect(await store.records.count == 1)
        #expect(await store.setAsideFile == nil)
        #expect(
            try await store.undo(batch.id) == [
                .skipped(.undoOutputChanged, path: destination.path),
                .skipped(.undoOutputChanged, path: output.path),
            ])
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: output.appending(path: "child.txt").path))
    }

    @Test func directoryStampEncodingStaysBounded() throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let childCount = 512
        for index in 0..<childCount {
            try Data("child".utf8).write(to: folder.appending(path: "child-\(index).txt"))
        }

        let encoded = try JSONEncoder().encode(FileStamp(of: folder))
        let maximumStampBytes = 2_048
        #expect(encoded.count < maximumStampBytes)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let summary = try #require(object["directorySummary"] as? [String: Any])
        #expect(summary["descendantCount"] as? Int == childCount)
        #expect(object["descendants"] == nil)
    }

    @Test func directoryStampDetectsEditsBeforeLatestModification() throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let earlier = folder.appending(path: "earlier.txt")
        let latest = folder.appending(path: "latest.txt")
        try Data("old".utf8).write(to: earlier)
        try Data("new".utf8).write(to: latest)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: earlier.path)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate.addingTimeInterval(100)], ofItemAtPath: latest.path)
        let stamp = try FileStamp(of: folder)

        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate.addingTimeInterval(1)], ofItemAtPath: earlier.path)

        #expect(try FileStamp(of: folder) != stamp)
    }

    @Test func unreadableDirectoryStampPreservesHistoryAndRefusesUndo() async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let output = folder.appending(path: "output")
        let locked = output.appending(path: ".locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: locked.appending(path: "child.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            #expect(throws: Never.self) {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            }
        }
        let stamp = try FileStamp(of: output)
        let id = UUID()
        let support = folder.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        let store = HistoryStore(supportDirectory: support)
        try await store.record([.derived(output: output.path, stamp: stamp)], batch: id, operation: .archiveExtract)
        try await store.flush()
        let reloaded = HistoryStore(supportDirectory: support)

        #expect(await reloaded.records.count == 1)
        #expect(try await reloaded.undo(id) == [.skipped(.undoOutputChanged, path: output.path)])
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func missingCommitStampKeepsRecordAndSkipsUndo() async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let output = folder.appending(path: "output.txt")
        try Data("keep".utf8).write(to: output)
        let id = UUID()
        let store = HistoryStore(supportDirectory: folder)
        try await store.record([.derived(output: output.path, stamp: nil)], batch: id, operation: .textConvert)
        try await store.flush()
        let reloaded = HistoryStore(supportDirectory: folder)

        #expect(await reloaded.records.count == 1)
        #expect(try await reloaded.undo(id) == [.skipped(.undoOutputChanged, path: output.path)])
        #expect(try String(contentsOf: output, encoding: .utf8) == "keep")
    }

    @Test(arguments: [false, true])
    func undoRejectsReusedTrashPaths(replacing: Bool) async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let original = folder.appending(path: "original.txt")
        let trashed = folder.appending(path: "trashed.txt")
        try Data("old".utf8).write(to: trashed)
        let trashStamp = try FileStamp(of: trashed, includingIdentity: true)
        let entry: CommitRecord
        if replacing {
            try Data("new".utf8).write(to: original)
            entry = .replaced(
                original: original.path, trashed: trashed.path, output: original.path,
                stamp: try FileStamp(of: original), trashStamp: trashStamp)
        } else {
            entry = .removed(original: original.path, trashed: trashed.path, trashStamp: trashStamp)
        }
        let id = UUID()
        let store = HistoryStore(supportDirectory: folder)
        try await store.record([entry], batch: id, operation: .textConvert)
        let retained = folder.appending(path: "retained.txt")
        try FileManager.default.moveItem(at: trashed, to: retained)
        // Clones keep the date, not the inode.
        try FileManager.default.copyItem(at: retained, to: trashed)
        #expect(try FileStamp(of: trashed).size == trashStamp.size)
        #expect(try FileStamp(of: trashed).modified == trashStamp.modified)

        let reloaded = HistoryStore(supportDirectory: folder)
        #expect(try await reloaded.undo(id) == [.skipped(.undoTrashItemMissing, path: original.path)])
        #expect(try String(contentsOf: trashed, encoding: .utf8) == "old")
        if replacing {
            #expect(try String(contentsOf: original, encoding: .utf8) == "new")
        } else {
            #expect(!FileManager.default.fileExists(atPath: original.path))
        }
    }

    @Test func legacyTrashRecordsLoadButCannotRestore() async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let original = folder.appending(path: "original.txt")
        let trashed = folder.appending(path: "trashed.txt")
        try Data("keep".utf8).write(to: original)
        try Data("unrelated".utf8).write(to: trashed)
        let id = UUID()
        let legacy = """
            {"version":1,"batches":[{"id":"\(id.uuidString)","operation":"text.convert","date":0,"undone":false,
            "items":[{"removed":{"original":"\(original.path)","trashed":"\(trashed.path)"}},
            {"replaced":{"original":"\(original.path)","trashed":"\(trashed.path)","output":"\(original.path)"}}]}]}
            """
        try Data(legacy.utf8).write(to: folder.appending(path: "history.json"))
        let store = HistoryStore(supportDirectory: folder)
        #expect(await store.setAsideFile == nil)
        #expect(await store.records.count == 1)
        #expect(
            try await store.undo(id) == Array(repeating: .skipped(.undoTrashItemMissing, path: original.path), count: 2)
        )
        #expect(try String(contentsOf: original, encoding: .utf8) == "keep")
        #expect(try String(contentsOf: trashed, encoding: .utf8) == "unrelated")
    }

    @Test func appendingAfterUndoMakesNewEntriesUndoable() async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let store = HistoryStore(supportDirectory: folder)
        let id = UUID()
        let original = folder.appending(path: "original.txt")
        let destination = folder.appending(path: "destination.txt")
        for text in ["first", "second"] {
            try Data(text.utf8).write(to: destination)
            try await store.record(
                [
                    .renamed(
                        from: original.path, to: destination.path,
                        stamp: try FileStamp(of: destination, includingIdentity: true))
                ],
                batch: id, operation: .folderRename)
            #expect(await store.records.first?.undone == false)
            #expect(try await store.undo(id) == [.restored])
            #expect(try String(contentsOf: original, encoding: .utf8) == text)
            try FileManager.default.removeItem(at: original)
        }
    }

    @Test func runningBatchRefusesUndoUntilEveryItemFinishes() async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 2)
        let first = folder.appending(path: "first.txt")
        let second = folder.appending(path: "second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let firstCommitted = HistorySignal()
        let finishSecond = HistorySignal()
        let batch = Batch(
            operation: .folderRename,
            items: [
                WorkItem(inputs: [first]) { _ in .rename([RenamePlan(url: first, newName: "first-renamed.txt")]) },
                WorkItem(inputs: [second]) { _ in
                    await finishSecond.wait()
                    return .rename([RenamePlan(url: second, newName: "second-renamed.txt")])
                },
            ])
        let running = Task {
            await engine.run(batch, settings: Settings()) { progress in
                if progress.fraction >= 0.5 { Task { await firstCommitted.signal() } }
            }
        }
        await firstCommitted.wait()
        await #expect(throws: UndoFailure.batchRunning) { try await engine.undo(batch.id) }
        #expect(await engine.history.records.first?.items.count == 1)
        #expect(await engine.history.records.first?.undone == false)
        #expect(try String(contentsOf: folder.appending(path: "first-renamed.txt"), encoding: .utf8) == "first")
        await finishSecond.signal()
        let outcome = await running.value
        #expect(outcome.outcomes.count == 2)
        #expect(try await engine.undo(batch.id) == [.restored, .restored])
        #expect(try String(contentsOf: first, encoding: .utf8) == "first")
        #expect(try String(contentsOf: second, encoding: .utf8) == "second")
    }

    @Test func terminationFlushPersistsPendingRecordsAndSealsCommits() async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let support = folder.appending(path: "support")
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let first = UUID()
        let second = UUID()
        try await engine.history.record(
            [.renamed(from: "/first", to: "/first-renamed")], batch: first, operation: .folderRename)
        try await engine.history.record(
            [.renamed(from: "/second", to: "/second-renamed")], batch: second, operation: .folderRename)

        try await engine.prepareForTermination()

        let reloaded = HistoryStore(supportDirectory: support)
        #expect(await reloaded.records.map(\.id) == [first, second])
        let original = folder.appending(path: "original.txt")
        try Data("keep".utf8).write(to: original)
        let outcome = await engine.run(
            Batch(
                operation: .folderRename,
                items: [
                    WorkItem(inputs: [original]) { _ in .rename([RenamePlan(url: original, newName: "changed.txt")]) }
                ]), settings: Settings()
        ) { _ in }
        #expect(outcome.outcomes == [.failed(.cancelled)])
        #expect(try String(contentsOf: original, encoding: .utf8) == "keep")
        #expect(await engine.history.records.map(\.id) == [first, second])
    }

    @Test func cancelledTerminationCannotBypassTheHeldCommitGate() async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        try await engine.history.commitGate.acquire()
        let pendingTermination = Task { try await engine.prepareForTermination() }
        pendingTermination.cancel()
        await #expect(throws: CancellationError.self) { try await pendingTermination.value }
        await engine.history.commitGate.release()

        let original = folder.appending(path: "original.txt")
        let renamed = folder.appending(path: "renamed.txt")
        try Data("keep".utf8).write(to: original)
        let outcome = await engine.run(
            Batch(
                operation: .folderRename,
                items: [
                    WorkItem(inputs: [original]) { _ in .rename([RenamePlan(url: original, newName: "renamed.txt")]) }
                ]), settings: Settings()
        ) { _ in }
        #expect(outcome.outcomes == [.succeeded(outputs: [renamed], warnings: [])])
        try await engine.prepareForTermination()
        let reloaded = HistoryStore(supportDirectory: folder.appending(path: "support"))
        #expect(await reloaded.records.map(\.id) == [outcome.batchID])
    }

    @Test(arguments: [false, true])
    func backupRecordsPersistWithoutWaitingForTheThrottle(replacing: Bool) async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let store = HistoryStore(supportDirectory: folder)
        try await store.record([.renamed(from: "/before", to: "/after")], batch: UUID(), operation: .folderRename)
        let entry: CommitRecord =
            replacing
            ? .replaced(original: "/original", trashed: "/backup", output: "/output", stamp: nil)
            : .removed(original: "/original", trashed: "/backup")
        let id = UUID()
        try await store.record([entry], batch: id, operation: .textConvert)

        let reloaded = HistoryStore(supportDirectory: folder)
        #expect(await reloaded.records.last?.id == id)
        #expect(await reloaded.records.last?.items == [entry])
    }

    @Test func terminationFlushFailureCanBeRetried() async throws {
        let folder = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let support = folder.appending(path: "support")
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let historyFile = support.appending(path: "history.json")
        try FileManager.default.createDirectory(at: historyFile, withIntermediateDirectories: false)
        let id = UUID()
        await #expect(throws: (any Error).self) {
            try await engine.history.record(
                [.renamed(from: "/before", to: "/after")], batch: id, operation: .folderRename)
        }
        await #expect(throws: (any Error).self) { try await engine.prepareForTermination() }
        await #expect(throws: EngineError.historyPersistenceFailed) { try await engine.history.checkAcceptingCommits() }
        try FileManager.default.removeItem(at: historyFile)
        try await engine.history.checkAcceptingCommits()
        try await engine.prepareForTermination()
        let reloaded = HistoryStore(supportDirectory: support)
        #expect(await reloaded.records.map(\.id) == [id])
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MacEaseHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }
}

private actor HistorySignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        signalled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
