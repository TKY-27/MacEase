import Foundation
import MenuCatalog
import Synchronization
import Testing

@testable import Engine

private final class DuplicateCancellationPresenter: NSObject, NSFilePresenter, Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let cancel: @Sendable () -> Void

    init(url: URL, cancel: @escaping @Sendable () -> Void) {
        presentedItemURL = url
        self.cancel = cancel
    }

    func relinquishPresentedItem(toWriter writer: @Sendable ((@Sendable () -> Void)?) -> Void) {
        cancel()
        writer(nil)
    }
}

@Suite(.serialized) struct FolderFilterTests {
    @Test func legacyExcludedNamesRemainLiteral() {
        var settings = FolderSettings()
        settings.excludedNames = ["BUILD", "Project[1]"]
        let filter = FolderFilter(settings: settings, scope: .duplicates)
        let root = URL(fileURLWithPath: "/tmp")

        #expect(filter.excludes(root.appending(path: "build"), isFolder: true))
        #expect(filter.excludes(root.appending(path: "Project[1]"), isFolder: true))
        #expect(!filter.excludes(root.appending(path: "Project1"), isFolder: true))
    }

    @Test func exclusionGlobsShareCaseInsensitiveBasenameSemantics() {
        var settings = FolderSettings()
        settings.excludedNames = ["BUILD"]
        settings.scanExclusions = FolderExclusions(files: "Cache[0-9].*;*.bak", extensions: ".LOG\n.tmp")
        settings.treeExclusions = FolderExclusions(files: "private?.txt")
        let tree = FolderFilter(settings: settings, scope: .tree)
        let duplicates = FolderFilter(settings: settings, scope: .duplicates)
        #expect(tree.excludes(URL(fileURLWithPath: "/project/build"), isFolder: true))
        #expect(tree.excludes(URL(fileURLWithPath: "/project/CACHE7.txt"), isFolder: false))
        #expect(tree.excludes(URL(fileURLWithPath: "/project/test.LOG"), isFolder: false))
        #expect(tree.excludes(URL(fileURLWithPath: "/project/test.tmp"), isFolder: false))
        #expect(tree.excludes(URL(fileURLWithPath: "/project/private1.txt"), isFolder: false))
        #expect(!duplicates.excludes(URL(fileURLWithPath: "/project/private1.txt"), isFolder: false))
        #expect(!tree.excludes(URL(fileURLWithPath: "/project/cachex.txt"), isFolder: false))
    }

    @Test func duplicateFiltersKeepExactProof() throws {
        let root = try TestVolume.makeFolder()
        try makeTree(
            [
                "a/same.txt": "matching", "b/SAME.TXT": "matching", "c/other.txt": "matching",
                "d/same.txt": "matching", "e/same.txt": "changed!", "a/zero.txt": "", "b/zero.txt": "",
                "a/small.txt": "x", "b/small.txt": "x",
            ], in: root)
        let sameTime = Date(timeIntervalSince1970: 1_700_000_000.2)
        let laterTime = Date(timeIntervalSince1970: 1_700_000_001.2)
        for path in ["a/same.txt", "b/SAME.TXT", "c/other.txt", "e/same.txt"] {
            try FileManager.default.setAttributes(
                [.modificationDate: sameTime], ofItemAtPath: root.appending(path: path).path)
        }
        try FileManager.default.setAttributes(
            [.modificationDate: laterTime], ofItemAtPath: root.appending(path: "d/same.txt").path)
        var settings = FolderSettings()
        settings.duplicateMinimumBytes = 2
        settings.duplicatesMatchNames = true
        settings.duplicatesMatchModificationSecond = true

        let groups = try DuplicateScanner.groups(in: [root], settings: settings) { _ in }
        #expect(groups.count == 1)
        #expect(groups[0].files.map(\.lastPathComponent) == ["same.txt", "SAME.TXT"])
        #expect(groups[0].reclaimableBytes == 8)

        settings.duplicateMinimumBytes = 0
        settings.duplicatesIgnoreEmpty = false
        let withZero = try DuplicateScanner.groups(in: [root], settings: settings) { _ in }
        #expect(withZero.count == 3)
        #expect(withZero.contains { $0.bytesPerFile == 0 })
        settings.duplicateMinimumBytes = -1
        #expect(throws: EngineError.self) {
            try DuplicateScanner.groups(in: [root], settings: settings) { _ in }
        }
    }

    @Test(arguments: [DuplicateKeepPolicy.oldest, .newest])
    func automaticKeepUsesTrashHistoryAndUndo(_ policy: DuplicateKeepPolicy) async throws {
        let root = try TestVolume.makeFolder()
        try makeTree(["first.txt": "precious", "last.txt": "precious", "other.txt": "unique"], in: root)
        let first = root.appending(path: "first.txt")
        let last = root.appending(path: "last.txt")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: first.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: last.path)
        var settings = Settings()
        settings.folder.duplicateKeepPolicy = policy
        settings.permanentDelete = true
        let options = try #require(
            OperationPlanner.options(for: .folderRemoveDuplicates, preset: nil, settings: settings))
        let batch = OperationPlanner.batch(
            for: OperationRequest(
                op: .folderRemoveDuplicates, options: options, inputs: [URL(fileURLWithPath: root.path)]),
            settings: settings)
        let support = root.appending(path: "support")
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)

        let outcome = await engine.run(batch, settings: settings) { _ in }

        #expect(outcome.outcomes == [.succeeded(outputs: [], warnings: [])])
        let kept = policy == .oldest ? first : last
        let removed = policy == .oldest ? last : first
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!FileManager.default.fileExists(atPath: removed.path))
        let record = try #require(outcome.record)
        #expect(record.items.count == 1)
        guard case .removed(let original, let trashed, _) = record.items[0] else {
            Issue.record("expected Trash history")
            return
        }
        #expect(original == removed.path)
        #expect(FileManager.default.fileExists(atPath: trashed))
        let restored = try await engine.undo(batch.id)
        #expect(restored.count == 1)
        #expect(FileManager.default.fileExists(atPath: removed.path))
    }

    @Test func automaticDuplicateCancellationKeepsDurableUndoForMovedFiles() async throws {
        let root = try TestVolume.makeFolder()
        try makeTree(["keep.txt": "same", "first.txt": "same", "second.txt": "same", "third.txt": "same"], in: root)
        let kept = root.appending(path: "keep.txt")
        let first = root.appending(path: "first.txt")
        let second = root.appending(path: "second.txt")
        let third = root.appending(path: "third.txt")
        let support = root.appending(path: "support")
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let permission = AsyncStream<Void>.makeStream()
        let work = WorkItem(inputs: [root]) { _ in
            for await _ in permission.stream { break }
            return .trashDuplicates([DuplicateRemoval(kept: kept, removed: [first, second, third])])
        }
        let batch = Batch(operation: .folderRemoveDuplicates, items: [work])
        let running = Mutex<Task<BatchOutcome, Never>?>(nil)
        let observedJournal = Mutex<Result<Data, any Error>?>(nil)
        let presenter = DuplicateCancellationPresenter(url: third) {
            observedJournal.withLock { result in
                result = Result { try Data(contentsOf: support.appending(path: "history.journal")) }
            }
            running.withLock { $0?.cancel() }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let pending = Task { await engine.run(batch, settings: Settings()) { _ in } }
        running.withLock { $0 = pending }
        permission.continuation.yield(())
        permission.continuation.finish()

        let outcome = await pending.value
        #expect(outcome.wasCancelled)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(FileManager.default.fileExists(atPath: third.path))
        let journal = try #require(observedJournal.withLock { $0 }).get()
        let entries = try journal.split(separator: UInt8(ascii: "\n")).map {
            try JSONDecoder().decode(HistoryJournal.Entry.self, from: Data($0))
        }
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.batch.items.count == 1 })

        let reloaded = try JobEngine(supportDirectory: support, concurrency: 1)
        let record = try #require(await reloaded.history.records.first)
        #expect(record.id == batch.id)
        #expect(record.items.count == 2)
        #expect(try await reloaded.undo(batch.id) == [.restored, .restored])
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(FileManager.default.fileExists(atPath: third.path))
    }

    @Test func automaticDuplicateHistoryFailureStopsFurtherMoves() async throws {
        let root = try TestVolume.makeFolder()
        try makeTree(["keep.txt": "same", "first.txt": "same", "second.txt": "same"], in: root)
        let kept = root.appending(path: "keep.txt")
        let first = root.appending(path: "first.txt")
        let second = root.appending(path: "second.txt")
        let support = root.appending(path: "support")
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let journal = support.appending(path: "history.journal")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        let work = WorkItem(inputs: [root]) { _ in
            .trashDuplicates([DuplicateRemoval(kept: kept, removed: [first, second])])
        }
        let batch = Batch(operation: .folderRemoveDuplicates, items: [work])

        let outcome = await engine.run(batch, settings: Settings()) { _ in }
        #expect(outcome.historyFailed)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        try FileManager.default.removeItem(at: journal)
        try await engine.history.flush()
        let reloaded = try JobEngine(supportDirectory: support, concurrency: 1)
        #expect(await reloaded.history.records.first?.items.count == 1)
        #expect(try await reloaded.undo(batch.id) == [.restored])
        #expect(FileManager.default.fileExists(atPath: first.path))
    }

    @Test func globsApplyAcrossOperationsWithoutErasingExcludedChildren() throws {
        let root = try TestVolume.makeFolder()
        try makeTree(
            [
                "Keep/excluded.log": "secret", "Keep/.DS_Store": "metadata", "Keep/visible.txt": "read",
                "Copies/a.txt": "repeat", "Copies/b.txt": "repeat", "Copies/skip.tmp": "repeat",
                "Hide/sub/file.txt": "hidden", "Legacy/file.txt": "hidden", "Empty/": "",
            ], in: root)
        var settings = FolderSettings()
        settings.excludedNames.append("lEgAcY")
        settings.scanExclusions = FolderExclusions(folders: "hIdE*", extensions: ".LOG")
        settings.treeExclusions = FolderExclusions(files: "VISIBLE.*")
        settings.analyzeExclusions = FolderExclusions(files: "skip.*")
        settings.duplicateExclusions = FolderExclusions(extensions: "tmp")
        settings.emptyExclusions = FolderExclusions(files: ".DS_Store")
        settings.renameExclusions = FolderExclusions(files: "skip.*")

        let tree = try FolderTree.text(of: root, settings: settings)
        #expect(!tree.contains("Hide"))
        #expect(!tree.contains("Legacy"))
        #expect(!tree.contains("excluded.log"))
        #expect(!tree.contains("visible.txt"))
        let analysis = try FolderAnalysis.scan(root, settings: settings) { _ in }
        #expect(analysis.fileCount == 4)
        let duplicates = try DuplicateScanner.groups(in: [root], settings: settings) { _ in }
        #expect(duplicates.count == 1)
        #expect(duplicates[0].files.map(\.lastPathComponent) == ["a.txt", "b.txt"])
        let empty = try EmptyFolderScanner.folders(in: [root], settings: settings) { _ in }
        #expect(empty.map(\.lastPathComponent) == ["Empty"])
        #expect(!(try EmptyFolderScanner.isEmpty(root.appending(path: "Keep"), settings: settings)))
        let renameTargets = try RenameRules.targets(for: [root.appending(path: "Copies")], settings: settings)
        #expect(renameTargets.map(\.lastPathComponent) == ["a.txt", "b.txt"])
    }

    @Test func excludedMetadataKeepsItsParent() throws {
        let root = try TestVolume.makeFolder()
        try makeTree(["OnlyMetadata/.DS_Store": "metadata"], in: root)
        var settings = FolderSettings()
        settings.emptyExclusions.files = ".DS_Store"

        #expect(try EmptyFolderScanner.folders(in: [root], settings: settings) { _ in }.isEmpty)
        #expect(!(try EmptyFolderScanner.isEmpty(root.appending(path: "OnlyMetadata"), settings: settings)))
    }

    @Test func selectedExcludedRootIsNotTraversed() throws {
        let root = try TestVolume.makeFolder()
        try makeTree([".git/sub/a.txt": "repeat", ".git/sub/b.txt": "repeat", ".git/empty/": ""], in: root)
        let excluded = root.appending(path: ".git")
        let nested = excluded.appending(path: "sub")
        let alias = root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: excluded)
        let settings = FolderSettings()

        #expect(try DuplicateScanner.groups(in: [excluded, nested, alias], settings: settings) { _ in }.isEmpty)
        #expect(try EmptyFolderScanner.folders(in: [excluded], settings: settings) { _ in }.isEmpty)
        #expect(!(try EmptyFolderScanner.isEmpty(excluded.appending(path: "empty"), settings: settings)))
        #expect(try RenameRules.targets(for: [excluded], settings: settings).isEmpty)
        #expect(try RenameRules.targets(for: [nested], settings: settings).isEmpty)
        #expect(try RenameRules.targets(for: [alias], settings: settings).isEmpty)
        #expect(try FolderTree.text(of: excluded, settings: settings) == ".git")
        #expect(try FolderAnalysis.scan(excluded, settings: settings) { _ in }.fileCount == 0)
    }

    @Test func excludedRegularFilePreventsCommitTimeEmptyRemoval() async throws {
        let root = try TestVolume.makeFolder()
        try makeTree(["OnlyExcluded/secret.log": "keep"], in: root)
        let candidate = root.appending(path: "OnlyExcluded")
        var settings = Settings()
        settings.folder.emptyExclusions.files = "*.log"

        #expect(try EmptyFolderScanner.folders(in: [root], settings: settings.folder) { _ in }.isEmpty)
        let outcome = try await runOperation(
            .folderRemoveEmpty, .folder(.removeEmpty([candidate], permanently: false)), inputs: [root],
            settings: settings)
        #expect(outcome.outcomes == [.skipped(.changedSinceScan)])
        #expect(try String(contentsOf: candidate.appending(path: "secret.log"), encoding: .utf8) == "keep")
    }
}
