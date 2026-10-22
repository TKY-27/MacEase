import Foundation
import MenuCatalog
import Testing

@testable import Engine

private func makeEngineWithBlockedJournal() throws -> (JobEngine, URL, URL) {
    let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseHistoryBarrier-\(UUID().uuidString)")
    TestTemporaryFolders.register(support)
    let engine = try JobEngine(supportDirectory: support, concurrency: 2)
    let journal = support.appending(path: "history.journal")
    try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
    return (engine, support, journal)
}

private func replacement(of original: URL, with text: String) -> WorkItem {
    WorkItem(inputs: [original]) { context in
        let staged = try context.stagingURL(for: original, name: original.lastPathComponent)
        try Data(text.utf8).write(to: staged)
        return .replace(
            original: original,
            output: StagedFile(url: staged, name: original.lastPathComponent, check: .text(.utf8)))
    }
}

private func contents(of url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

@Suite struct HistoryCommitRecoveryTests {
    @Test func failedReplaceRecordBlocksTheNextReplaceUntilPreflightRetrySucceeds() async throws {
        let folder = try TestVolume.makeFolder()
        let first = folder.appending(path: "first.txt")
        let second = folder.appending(path: "second.txt")
        try Data("first original".utf8).write(to: first)
        try Data("second original".utf8).write(to: second)
        let support = folder.appending(path: "support")
        let engine = try JobEngine(supportDirectory: support, concurrency: 2)
        let journal = support.appending(path: "history.journal")
        let (firstCompleted, continuation) = AsyncStream<Void>.makeStream()
        let orderedSecond = WorkItem(inputs: [second]) { context in
            for await _ in firstCompleted { break }
            let staged = try context.stagingURL(for: second, name: second.lastPathComponent)
            try Data("second replacement".utf8).write(to: staged)
            return .replace(
                original: second,
                output: StagedFile(url: staged, name: second.lastPathComponent, check: .text(.utf8)))
        }
        let batch = Batch(
            operation: .textLineEndings,
            items: [
                WorkItem(inputs: [first]) { context in
                    let staged = try context.stagingURL(for: first, name: first.lastPathComponent)
                    try Data("first replacement".utf8).write(to: staged)
                    try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
                    return .replace(
                        original: first,
                        output: StagedFile(url: staged, name: first.lastPathComponent, check: .text(.utf8)))
                }, orderedSecond,
            ])

        let failed = await engine.run(batch, settings: Settings()) { progress in
            if progress.completedItems == 1 {
                continuation.yield(())
                continuation.finish()
            }
        }

        #expect(failed.historyFailed)
        #expect(
            failed.outcomes == [
                .succeeded(outputs: [first], warnings: []),
                .failed(.historyPersistenceFailed),
            ])
        #expect(try contents(of: first) == "first replacement")
        #expect(try contents(of: second) == "second original")
        let pendingRecord = try #require(failed.record)
        #expect(pendingRecord.items.count == 1)
        guard case .replaced(let originalPath, let trashPath, _, _, _) = try #require(pendingRecord.items.first)
        else {
            Issue.record("expected first replacement record")
            return
        }
        #expect(originalPath == first.path)
        #expect(try contents(of: URL(fileURLWithPath: trashPath)) == "first original")

        try FileManager.default.removeItem(at: journal)
        let retried = await engine.run(
            Batch(operation: .textLineEndings, items: [replacement(of: second, with: "second replacement")]),
            settings: Settings()
        ) { _ in }

        #expect(!retried.historyFailed)
        #expect(retried.outcomes == [.succeeded(outputs: [second], warnings: [])])
        #expect(try contents(of: second) == "second replacement")
        let reloaded = try JobEngine(supportDirectory: support, concurrency: 1)
        let records = await reloaded.history.records
        #expect(records.map(\.id) == [batch.id, retried.batchID])
        #expect(records.map(\.items.count) == [1, 1])
        #expect(
            records.flatMap(\.items).compactMap { record in
                if case .replaced(let original, _, _, _, _) = record { return original }
                return nil
            } == [first.path, second.path])
    }

    @Test func failedHistoryBlocksRenameTrashPermanentRemovalAndDerivedOutput() async throws {
        let folder = try TestVolume.makeFolder()
        let seed = folder.appending(path: "seed.txt")
        let renamed = folder.appending(path: "rename.txt")
        let trashed = folder.appending(path: "trash.txt")
        let permanentlyRemoved = folder.appending(path: "permanent.txt")
        let source = folder.appending(path: "source.txt")
        for url in [seed, renamed, trashed, permanentlyRemoved, source] {
            try Data(url.lastPathComponent.utf8).write(to: url)
        }
        let (engine, _, _) = try makeEngineWithBlockedJournal()
        let failed = await engine.run(
            Batch(operation: .textLineEndings, items: [replacement(of: seed, with: "changed")]),
            settings: Settings()
        ) { _ in }
        #expect(failed.historyFailed)

        let rename = await engine.run(
            Batch(
                operation: .folderRename,
                items: [
                    WorkItem(inputs: [renamed]) { _ in
                        .rename([RenamePlan(url: renamed, newName: "after.txt")])
                    }
                ]), settings: Settings()
        ) { _ in }
        #expect(rename.outcomes == [.failed(.historyPersistenceFailed)])
        #expect(try contents(of: renamed) == "rename.txt")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "after.txt").path))

        let trash = await engine.run(
            Batch(
                operation: .folderRemoveDuplicates,
                items: [
                    WorkItem(inputs: [trashed]) { _ in .trash([trashed], permanently: false) }
                ]), settings: Settings()
        ) { _ in }
        #expect(trash.outcomes == [.failed(.historyPersistenceFailed)])
        #expect(try contents(of: trashed) == "trash.txt")

        let permanent = await engine.run(
            Batch(
                operation: .folderRemoveDuplicates,
                items: [
                    WorkItem(inputs: [permanentlyRemoved]) { _ in .trash([permanentlyRemoved], permanently: true) }
                ]), settings: Settings()
        ) { _ in }
        #expect(permanent.outcomes == [.failed(.historyPersistenceFailed)])
        #expect(try contents(of: permanentlyRemoved) == "permanent.txt")

        let derivedName = "source_derived.txt"
        let derived = await engine.run(
            Batch(
                operation: .textConvert,
                items: [
                    WorkItem(inputs: [source]) { context in
                        let staged = try context.stagingURL(for: source, name: derivedName)
                        try Data("derived".utf8).write(to: staged)
                        return .derived(
                            nextTo: source,
                            outputs: [StagedFile(url: staged, name: derivedName, check: .text(.utf8))])
                    }
                ]), settings: Settings()
        ) { _ in }
        #expect(derived.outcomes == [.failed(.historyPersistenceFailed)])
        #expect(try contents(of: source) == "source.txt")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: derivedName).path))
        #expect(await engine.history.records.count == 1)
    }

    @Test func failedFirstTrashRecordStopsTheSameWorkItemBeforeItsSecondRemoval() async throws {
        let folder = try TestVolume.makeFolder()
        let first = folder.appending(path: "first.txt")
        let second = folder.appending(path: "second.txt")
        try Data("first original".utf8).write(to: first)
        try Data("second original".utf8).write(to: second)
        let (engine, support, journal) = try makeEngineWithBlockedJournal()
        let batch = Batch(
            operation: .folderRemoveDuplicates,
            items: [
                WorkItem(inputs: [first, second]) { _ in .trash([first, second], permanently: false) }
            ])

        let outcome = await engine.run(batch, settings: Settings()) { _ in }

        #expect(outcome.historyFailed)
        #expect(outcome.outcomes == [.failed(.historyPersistenceFailed)])
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(try contents(of: second) == "second original")
        let record = try #require(outcome.record)
        #expect(record.items.count == 1)
        guard case .removed(let originalPath, let trashPath, _) = try #require(record.items.first) else {
            Issue.record("expected first removal record")
            return
        }
        #expect(originalPath == first.path)
        #expect(try contents(of: URL(fileURLWithPath: trashPath)) == "first original")

        try FileManager.default.removeItem(at: journal)
        let resumed = await engine.run(
            Batch(
                operation: .folderRemoveDuplicates,
                items: [
                    WorkItem(inputs: [second]) { _ in .trash([second], permanently: false) }
                ]), settings: Settings()
        ) { _ in }
        #expect(resumed.outcomes == [.succeeded(outputs: [], warnings: [])])
        #expect(!resumed.historyFailed)
        let reloaded = try JobEngine(supportDirectory: support, concurrency: 1)
        let records = await reloaded.history.records
        #expect(records.map(\.id) == [batch.id, resumed.batchID])
        #expect(records.map(\.items.count) == [1, 1])
        #expect(
            records.flatMap(\.items).compactMap { entry in
                if case .removed(let original, _, _) = entry { return original }
                return nil
            } == [first.path, second.path])
    }

    @Test func failedHistoryStillAllowsTextResultsAndSkips() async throws {
        let (engine, _, _) = try makeEngineWithBlockedJournal()
        await #expect(throws: (any Error).self) {
            try await engine.history.record(
                [.removed(original: "/original", trashed: "/trash")],
                batch: UUID(), operation: .folderRemoveDuplicates)
        }
        let outcome = await engine.run(
            Batch(
                operation: .textConvert,
                items: [
                    WorkItem(inputs: []) { _ in .text("clipboard result", .clipboard) },
                    WorkItem(inputs: []) { _ in .text("report result", .report) },
                    WorkItem(inputs: []) { _ in .skipped(.alreadyDone) },
                ]), settings: Settings()
        ) { _ in }
        #expect(outcome.historyFailed)
        #expect(
            outcome.outcomes == [
                .succeeded(outputs: [], warnings: []), .succeeded(outputs: [], warnings: []), .skipped(.alreadyDone),
            ])
        #expect(outcome.clipboardText == "clipboard result")
        #expect(outcome.reportText == "report result")
    }
}
