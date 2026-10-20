import Foundation
import MenuCatalog
import Testing

@testable import Engine

private func makeEngine(concurrency: Int = 2) throws -> JobEngine {
    let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseSupport-\(UUID().uuidString)")
    return try JobEngine(supportDirectory: support, concurrency: concurrency)
}

private func write(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
}

private func read(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

private func replacing(_ original: URL, name: String, text: String) -> WorkItem {
    WorkItem(inputs: [original]) { context in
        let staged = try context.stagingURL(for: original, name: name)
        try write(text, to: staged)
        return .replace(original: original, output: StagedFile(url: staged, name: name, check: .text(.utf8)))
    }
}

@Suite(.serialized) struct CommitTests {
    @Test func replaceWithSameNameTrashesOriginalAndUndoRestoresIt() async throws {
        let folder = try TestVolume.makeFolder()
        let original = folder.appending(path: "note.txt")
        try write("old", to: original)
        let engine = try makeEngine()

        let outcome = await engine.run(
            Batch(operation: .textLineEndings, items: [replacing(original, name: "note.txt", text: "new")]),
            settings: Settings()
        ) { _ in }

        #expect(outcome.outcomes == [.succeeded(outputs: [original], warnings: [])])
        #expect(try read(original) == "new")
        let record = try #require(outcome.record)
        guard case .replaced(_, let trashed, _, _) = try #require(record.items.first) else {
            Issue.record("expected replaced record")
            return
        }
        #expect(trashed.contains("/.Trashes/"))
        #expect(URL(fileURLWithPath: trashed).lastPathComponent == "note.txt")
        #expect(try read(URL(fileURLWithPath: trashed)) == "old")

        #expect(try await engine.history.undo(record.id) == [.restored])
        #expect(try read(original) == "old")
        #expect(!FileManager.default.fileExists(atPath: trashed))
    }

    @Test func replaceWithNewExtensionKeepsBothUntilTrashed() async throws {
        let folder = try TestVolume.makeFolder()
        let original = folder.appending(path: "data.csv")
        try write("a,b", to: original)
        let engine = try makeEngine()

        let outcome = await engine.run(
            Batch(operation: .textConvert, items: [replacing(original, name: "data.json", text: "[]")]),
            settings: Settings()
        ) { _ in }

        let output = folder.appending(path: "data.json")
        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: [])])
        #expect(!FileManager.default.fileExists(atPath: original.path))
        let record = try #require(outcome.record)
        _ = try await engine.history.undo(record.id)
        #expect(try read(original) == "a,b")
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func derivedOutputsGetNumberedNames() async throws {
        let folder = try TestVolume.makeFolder()
        let original = folder.appending(path: "clip.txt")
        try write("x", to: original)
        let engine = try makeEngine()
        let workItem = WorkItem(inputs: [original]) { context in
            let first = try context.stagingURL(for: original, name: "clip.txt")
            try write("one", to: first)
            return .derived(nextTo: original, outputs: [StagedFile(url: first, name: "clip.txt", check: .text(.utf8))])
        }

        let outcome = await engine.run(
            Batch(operation: .videoToGIF, items: [workItem, workItem]), settings: Settings()
        ) { _ in
        }

        let names = outcome.outcomes.flatMap { outcome -> [String] in
            if case .succeeded(let outputs, _) = outcome { outputs.map(\.lastPathComponent) } else { [] }
        }
        #expect(Set(names) == ["clip (2).txt", "clip (3).txt"])
        #expect(try read(original) == "x")
    }

    @Test func unverifiableOutputLeavesOriginalUntouched() async throws {
        let folder = try TestVolume.makeFolder()
        let original = folder.appending(path: "photo.png")
        try write("not really a png", to: original)
        let engine = try makeEngine()
        let workItem = WorkItem(inputs: [original]) { context in
            let staged = try context.stagingURL(for: original, name: "photo.png")
            try write("garbage", to: staged)
            return .replace(original: original, output: StagedFile(url: staged, name: "photo.png", check: .image))
        }

        let outcome = await engine.run(Batch(operation: .imageResize, items: [workItem]), settings: Settings()) { _ in }

        guard case .failed(.encodeFailed) = try #require(outcome.outcomes.first) else {
            Issue.record("expected encode failure, got \(outcome.outcomes)")
            return
        }
        #expect(try read(original) == "not really a png")
        #expect(outcome.record == nil)
    }

    @Test func oneFailureDoesNotStopTheBatch() async throws {
        let folder = try TestVolume.makeFolder()
        let good = folder.appending(path: "good.txt")
        try write("1", to: good)
        let failing = WorkItem(inputs: [good]) { _ in throw EngineError.unsupportedCodec("WMV") }
        let engine = try makeEngine()

        let outcome = await engine.run(
            Batch(operation: .textLineEndings, items: [failing, replacing(good, name: "good.txt", text: "2")]),
            settings: Settings()
        ) { _ in }

        #expect(outcome.outcomes.first == .failed(.unsupportedCodec("WMV")))
        #expect(try read(good) == "2")
    }

    @Test func cancellationRemovesStagingAndKeepsOriginals() async throws {
        let folder = try TestVolume.makeFolder()
        let original = folder.appending(path: "long.txt")
        try write("keep", to: original)
        let engine = try makeEngine()
        let stagingSeen = StagingProbe()
        let workItem = WorkItem(inputs: [original]) { context in
            let staged = try context.stagingURL(for: original, name: "long.txt")
            try write("partial", to: staged)
            await stagingSeen.record(staged)
            try await Task.sleep(for: .seconds(30))
            return .replace(original: original, output: StagedFile(url: staged, name: "long.txt", check: .text(.utf8)))
        }

        let task = Task {
            await engine.run(Batch(operation: .textLineEndings, items: [workItem]), settings: Settings()) { _ in }
        }
        while await stagingSeen.url == nil { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        let outcome = await task.value

        #expect(outcome.wasCancelled)
        #expect(try read(original) == "keep")
        let staged = try #require(await stagingSeen.url)
        #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    @Test func replacePreservesDatesAndTags() async throws {
        let folder = try TestVolume.makeFolder()
        var original = folder.appending(path: "tagged.txt")
        try write("old", to: original)
        let created = Date(timeIntervalSince1970: 1_000_000_000)
        var values = URLResourceValues()
        values.creationDate = created
        values.contentModificationDate = created
        try original.setResourceValues(values)
        try (original as NSURL).setResourceValue(["Red"], forKey: .tagNamesKey)
        let engine = try makeEngine()

        _ = await engine.run(
            Batch(operation: .textLineEndings, items: [replacing(original, name: "tagged.txt", text: "new")]),
            settings: Settings()
        ) { _ in }

        original.removeAllCachedResourceValues()
        let result = try original.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .tagNamesKey])
        #expect(result.creationDate == created)
        #expect(result.contentModificationDate == created)
        #expect(result.tagNames == ["Red"])
    }

    @Test func renameAndUndo() async throws {
        let folder = try TestVolume.makeFolder()
        let first = folder.appending(path: "a.txt")
        let second = folder.appending(path: "b.txt")
        try write("a", to: first)
        try write("b", to: second)
        let engine = try makeEngine()
        let workItem = WorkItem(inputs: [first, second]) { _ in
            .rename([RenamePlan(url: first, newName: "b.txt"), RenamePlan(url: second, newName: "c.txt")])
        }

        let outcome = await engine.run(Batch(operation: .folderRename, items: [workItem]), settings: Settings()) { _ in
        }

        #expect(try read(folder.appending(path: "b (2).txt")) == "a")
        #expect(try read(folder.appending(path: "c.txt")) == "b")
        let record = try #require(outcome.record)
        #expect(try await engine.history.undo(record.id) == [.restored, .restored])
        #expect(try read(first) == "a")
        #expect(try read(second) == "b")
    }

    @Test func undoSkipsOutputsEditedAfterCommit() async throws {
        let folder = try TestVolume.makeFolder()
        let original = folder.appending(path: "edit.txt")
        try write("old", to: original)
        let engine = try makeEngine()
        let outcome = await engine.run(
            Batch(operation: .textLineEndings, items: [replacing(original, name: "edit.txt", text: "new")]),
            settings: Settings()
        ) { _ in }
        try write("edited by the user afterwards", to: original)

        let record = try #require(outcome.record)
        #expect(try await engine.history.undo(record.id) == [.skipped(.undoOutputChanged, path: original.path)])
        #expect(try read(original) == "edited by the user afterwards")
    }

    @Test func trashedItemsCanBeRestored() async throws {
        let folder = try TestVolume.makeFolder()
        let duplicate = folder.appending(path: "copy.txt")
        try write("dup", to: duplicate)
        let engine = try makeEngine()
        let outcome = await engine.run(
            Batch(
                operation: .folderRemoveDuplicates,
                items: [WorkItem(inputs: [duplicate]) { _ in .trash([duplicate], permanently: false) }]),
            settings: Settings()
        ) { _ in }
        #expect(!FileManager.default.fileExists(atPath: duplicate.path))
        let record = try #require(outcome.record)
        #expect(try await engine.history.undo(record.id) == [.restored])
        #expect(try read(duplicate) == "dup")
    }

    @Test func historyKeepsTheLastHundredBatchesAcrossLaunches() async throws {
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseSupport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let store = HistoryStore(supportDirectory: support)
        for index in 0..<105 {
            try await store.record(
                [.renamed(from: "/a\(index)", to: "/b\(index)")], batch: UUID(), operation: .folderRename)
        }
        try await store.flush()
        let reloaded = HistoryStore(supportDirectory: support)
        let records = await reloaded.records
        #expect(records.count == 100)
        #expect(records.first?.items == [.renamed(from: "/a5", to: "/b5")])
        let mode = try FileManager.default.attributesOfItem(atPath: support.appending(path: "history.json").path)[
            .posixPermissions]
        #expect(mode as? Int == 0o600)
    }

    @Test func undoWorksAfterTheHistoryIsReloaded() async throws {
        let folder = try TestVolume.makeFolder()
        let original = folder.appending(path: "reload.txt")
        try write("old", to: original)
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseSupport-\(UUID().uuidString)")
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let outcome = await engine.run(
            Batch(operation: .textLineEndings, items: [replacing(original, name: "reload.txt", text: "new")]),
            settings: Settings()
        ) { _ in }
        let record = try #require(outcome.record)

        let relaunched = try JobEngine(supportDirectory: support, concurrency: 1)
        #expect(try await relaunched.history.undo(record.id) == [.restored])
        #expect(try read(original) == "old")
    }

    @Test func unreadableHistoryIsSetAsideNotFatal() async throws {
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseSupport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try write("{ not json", to: support.appending(path: "history.json"))
        let store = HistoryStore(supportDirectory: support)
        #expect(await store.records.isEmpty)
        let setAside = try #require(await store.setAsideFile)
        #expect(try read(setAside) == "{ not json")
    }

    @Test func caseOnlyRenameKeepsTheSameFile() async throws {
        let folder = try TestVolume.makeFolder()
        let original = folder.appending(path: "photo.JPG")
        try write("x", to: original)
        let engine = try makeEngine()
        let workItem = WorkItem(inputs: [original]) { _ in .rename([RenamePlan(url: original, newName: "photo.jpg")]) }
        _ = await engine.run(Batch(operation: .folderRename, items: [workItem]), settings: Settings()) { _ in }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names == ["photo.jpg"])
    }

    @Test func compoundExtensionsGetNumberedBeforeTheSuffix() throws {
        let folder = try TestVolume.makeFolder()
        try write("x", to: folder.appending(path: "backup.tar.gz"))
        #expect(try AvailableName.url(for: "backup.tar.gz", in: folder).lastPathComponent == "backup (2).tar.gz")
    }

    @Test func staleStagingCleanupOnlyTouchesStagingDirectories() throws {
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseSupport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let precious = try TestVolume.makeFolder()
        try write("keep", to: precious.appending(path: "file.txt"))
        let staging = StagingArea(supportDirectory: support)
        let stale = try staging.makeDirectory(for: precious.appending(path: "file.txt"))
        let registry = try JSONEncoder().encode([stale.path, precious.path])
        try registry.write(to: support.appending(path: "staging.json"))

        StagingArea(supportDirectory: support).removeStale()

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(try read(precious.appending(path: "file.txt")) == "keep")
    }
}

private actor StagingProbe {
    var url: URL?
    func record(_ url: URL) { self.url = url }
}

@Suite struct LaneGateTests {
    @Test func neverExceedsItsWidth() async throws {
        let gate = LaneGate(width: 3)
        let counter = ConcurrencyCounter()
        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await gate.acquire()
                    await counter.enter()
                    try await Task.sleep(for: .milliseconds(5))
                    await counter.leave()
                    await gate.release()
                }
            }
        }
        #expect(await counter.peak == 3)
    }
}

private actor ConcurrencyCounter {
    private var current = 0
    private(set) var peak = 0
    func enter() {
        current += 1
        peak = max(peak, current)
    }
    func leave() { current -= 1 }
}
