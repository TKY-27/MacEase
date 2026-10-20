import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite struct RemovalSafetyTests {
    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacEaseRemoval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func opposingDuplicateBatchesKeepOneCopy() async throws {
        let root = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        try makeTree(["first.txt": "precious", "second.txt": "precious"], in: root)
        let first = root.appending(path: "first.txt")
        let second = root.appending(path: "second.txt")
        var settings = Settings()
        settings.permanentDelete = true
        let confirmedSettings = settings
        let barrier = RemovalBarrier()
        let batches = [(first, second), (second, first)].map { kept, removed in
            let planned = FolderPlanner.batch(
                .removeDuplicates([DuplicateRemoval(kept: kept, removed: [removed])], permanently: true),
                op: .folderRemoveDuplicates, folders: [root], settings: confirmedSettings)
            return Batch(
                operation: planned.operation,
                items: planned.items.map { plannedItem in
                    WorkItem(inputs: plannedItem.inputs) { context in
                        let result = try await plannedItem.body(context)
                        await barrier.arrive()
                        return result
                    }
                })
        }
        let outcomes = try await withThrowingTaskGroup(of: BatchOutcome.self) { group in
            for batch in batches {
                let engine = try JobEngine(supportDirectory: root.appending(path: batch.id.uuidString), concurrency: 1)
                group.addTask { await engine.run(batch, settings: confirmedSettings) { _ in } }
            }
            var outcomes: [BatchOutcome] = []
            for try await outcome in group { outcomes.append(outcome) }
            return outcomes
        }
        let remaining = [first, second].filter { FileManager.default.fileExists(atPath: $0.path) }
        #expect(remaining.count == 1)
        #expect(try String(contentsOf: #require(remaining.first), encoding: .utf8) == "precious")
        #expect(outcomes.flatMap(\.outcomes).filter { $0 == .succeeded(outputs: [], warnings: []) }.count == 1)
        #expect(outcomes.flatMap(\.outcomes).filter { $0 == .skipped(.changedSinceScan) }.count == 1)
    }

    @Test func contentAddedAfterPlanningPreventsEmptyFolderDeletion() async throws {
        let root = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let candidate = root.appending(path: "empty")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        var settings = Settings()
        settings.permanentDelete = true
        let planned = FolderPlanner.batch(
            .removeEmpty([candidate], permanently: true), op: .folderRemoveEmpty, folders: [root], settings: settings)
        let plannedItem = try #require(planned.items.first)
        let lateFile = candidate.appending(path: "precious.txt")
        let workItem = WorkItem(inputs: plannedItem.inputs) { context in
            let result = try await plannedItem.body(context)
            try Data("keep".utf8).write(to: lateFile)
            return result
        }
        let engine = try JobEngine(supportDirectory: root.appending(path: "support"), concurrency: 1)
        let outcome = await engine.run(
            Batch(operation: .folderRemoveEmpty, items: [workItem]), settings: settings
        ) { _ in }
        #expect(outcome.outcomes == [.skipped(.changedSinceScan)])
        #expect(try String(contentsOf: lateFile, encoding: .utf8) == "keep")
    }

    @Test func metadataNamedDirectoryKeepsItsContents() async throws {
        let root = try makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        try makeTree(["A/.DS_Store/precious.txt": "keep"], in: root)
        var settings = Settings()
        settings.permanentDelete = true
        #expect(try EmptyFolderScanner.folders(in: [root], settings: settings.folder) { _ in }.isEmpty)
        let batch = FolderPlanner.batch(
            .removeEmpty([root.appending(path: "A")], permanently: true), op: .folderRemoveEmpty,
            folders: [root], settings: settings)
        let engine = try JobEngine(supportDirectory: root.appending(path: "support"), concurrency: 1)
        let outcome = await engine.run(batch, settings: settings) { _ in }
        #expect(outcome.outcomes == [.skipped(.changedSinceScan)])
        #expect(try String(contentsOf: root.appending(path: "A/.DS_Store/precious.txt"), encoding: .utf8) == "keep")
    }
}

private actor RemovalBarrier {
    private var waiting: CheckedContinuation<Void, Never>?

    func arrive() async {
        if let waiting {
            self.waiting = nil
            waiting.resume()
        } else {
            await withCheckedContinuation { waiting = $0 }
        }
    }
}
