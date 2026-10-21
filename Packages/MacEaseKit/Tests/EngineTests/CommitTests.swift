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

private func makeReplacementFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "MacEaseCommit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func replacing(_ original: URL, name: String, text: String) -> WorkItem {
    WorkItem(inputs: [original]) { context in
        let staged = try context.stagingURL(for: original, name: name)
        try write(text, to: staged)
        return .replace(original: original, output: StagedFile(url: staged, name: name, check: .text(.utf8)))
    }
}

@Suite(.serialized) struct CommitTests {
    @Test(arguments: ["note.txt", "note.json", "NOTE.txt"])
    func replacementSkipsOriginalEditedDuringTheJob(outputName: String) async throws {
        let folder = try makeReplacementFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let original = folder.appending(path: "note.txt")
        try write("old", to: original)
        let engine = try makeEngine()
        let workItem = WorkItem(inputs: [original]) { context in
            let staged = try context.stagingURL(for: original, name: outputName)
            try write("converted", to: staged)
            try write("saved by another app", to: original)
            return .replace(original: original, output: StagedFile(url: staged, name: outputName, check: .text(.utf8)))
        }

        let outcome = await engine.run(Batch(operation: .textLineEndings, items: [workItem]), settings: Settings()) {
            _ in
        }

        #expect(outcome.outcomes == [.skipped(.changedSinceScan)])
        #expect(try read(original) == "saved by another app")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["note.txt"])
        #expect(outcome.record == nil)
    }

    @Test func replacementSkipsSameSizeEditWithChangedModificationDate() async throws {
        let folder = try makeReplacementFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let original = folder.appending(path: "note.txt")
        try write("old", to: original)
        let engine = try makeEngine()
        let workItem = WorkItem(inputs: [original]) { context in
            let staged = try context.stagingURL(for: original, name: "note.txt")
            try write("replacement", to: staged)
            let stamp = try FileStamp(of: original)
            try write("new", to: original)
            try FileManager.default.setAttributes(
                [.modificationDate: stamp.modified.addingTimeInterval(1)], ofItemAtPath: original.path)
            return .replace(original: original, output: StagedFile(url: staged, name: "note.txt", check: .text(.utf8)))
        }

        let outcome = await engine.run(Batch(operation: .textLineEndings, items: [workItem]), settings: Settings()) {
            _ in
        }

        #expect(outcome.outcomes == [.skipped(.changedSinceScan)])
        #expect(try read(original) == "new")
        #expect(outcome.record == nil)
    }

    @Test(arguments: [["first output", "second output"], ["one", "two"]])
    func concurrentReplacementsPreserveBackupsAndUndo(texts: [String]) async throws {
        let folder = try TestVolume.makeFolder()
        let original = folder.appending(path: "note.txt")
        try write("old", to: original)
        let engine = try makeEngine()
        let barrier = CommitBarrier()
        let workItems = texts.map { text in
            WorkItem(inputs: [original]) { context in
                let staged = try context.stagingURL(for: original, name: "note.txt")
                try write(text, to: staged)
                await barrier.arrive()
                return .replace(
                    original: original, output: StagedFile(url: staged, name: "note.txt", check: .text(.utf8)))
            }
        }

        let outcome = await engine.run(Batch(operation: .textLineEndings, items: workItems), settings: Settings()) {
            _ in
        }

        let expectedCommits = texts.first?.utf8.count == "old".utf8.count ? texts.count : 1
        #expect(outcome.outcomes.filter { $0 == .skipped(.changedSinceScan) }.count == texts.count - expectedCommits)
        #expect(outcome.outcomes.filter { if case .succeeded = $0 { true } else { false } }.count == expectedCommits)
        #expect(texts.contains(try read(original)))
        let record = try #require(outcome.record)
        #expect(record.items.count == expectedCommits)
        guard case .replaced(_, let trashed, _, _, _) = try #require(record.items.first) else {
            Issue.record("expected replaced record")
            return
        }
        #expect(try read(URL(fileURLWithPath: trashed)) == "old")
        #expect(try await engine.history.undo(record.id) == Array(repeating: .restored, count: expectedCommits))
        #expect(try read(original) == "old")
    }

    @Test func undoWaitsForTheCommitGateBeforeCheckingTheOutput() async throws {
        let folder = try TestVolume.makeFolder()
        let original = folder.appending(path: "race.txt")
        try write("original", to: original)
        let engine = try makeEngine()
        let first = await engine.run(
            Batch(operation: .textLineEndings, items: [replacing(original, name: "race.txt", text: "first")]),
            settings: Settings()
        ) { _ in }
        let firstRecord = try #require(first.record)
        let staged = folder.appending(path: "staged.txt")
        let cloneDirectory = folder.appending(path: "clones")
        try FileManager.default.createDirectory(at: cloneDirectory, withIntermediateDirectories: false)
        try write("second replacement", to: staged)
        let expectedStamp = try FileStamp(of: original)
        let (started, continuation) = AsyncStream<Void>.makeStream()
        try await engine.history.commitGate.acquire()
        let pendingUndo = Task {
            continuation.yield(())
            continuation.finish()
            return try await engine.undo(firstRecord.id)
        }
        for await _ in started { break }
        do {
            let replaced = try await FileCommitter().replace(
                original: original, with: StagedFile(url: staged, name: "race.txt", check: .text(.utf8)),
                cloneDirectory: cloneDirectory, expectedStamp: expectedStamp)
            let trashed = try #require(replaced.trashed)
            try await engine.history.record(
                [
                    .replaced(
                        original: original.path, trashed: trashed.url.path, output: replaced.output.path,
                        stamp: replaced.stamp, trashStamp: trashed.stamp)
                ],
                batch: UUID(), operation: .textLineEndings)
            await engine.history.commitGate.release()
        } catch {
            await engine.history.commitGate.release()
            _ = try await pendingUndo.value
            throw error
        }

        #expect(try await pendingUndo.value == [.skipped(.undoOutputChanged, path: original.path)])
        #expect(try read(original) == "second replacement")
        guard case .replaced(_, let firstBackup, _, _, _) = try #require(firstRecord.items.first) else {
            Issue.record("expected replaced record")
            return
        }
        #expect(try read(URL(fileURLWithPath: firstBackup)) == "original")
    }

    @Test func cancelledUndoCannotBypassTheHeldCommitGate() async throws {
        let folder = try makeReplacementFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let original = folder.appending(path: "before.txt")
        try write("keep", to: original)
        let engine = try makeEngine()
        let outcome = await engine.run(
            Batch(
                operation: .folderRename,
                items: [
                    WorkItem(inputs: [original]) { _ in .rename([RenamePlan(url: original, newName: "after.txt")]) }
                ]), settings: Settings()
        ) { _ in }
        try await engine.history.commitGate.acquire()
        let pendingUndo = Task { try await engine.undo(outcome.batchID) }
        pendingUndo.cancel()
        await #expect(throws: CancellationError.self) { try await pendingUndo.value }
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try read(folder.appending(path: "after.txt")) == "keep")
        await engine.history.commitGate.release()
        #expect(try await engine.undo(outcome.batchID) == [.restored])
    }

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
        guard case .replaced(_, let trashed, _, _, _) = try #require(record.items.first) else {
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

    @Test func caseOnlyReplacementCanBeUndone() async throws {
        let folder = try TestVolume.makeFolder()
        let original = folder.appending(path: "NOTE.txt")
        let output = folder.appending(path: "note.txt")
        try write("original", to: original)
        let engine = try makeEngine()
        let outcome = await engine.run(
            Batch(operation: .textLineEndings, items: [replacing(original, name: "note.txt", text: "converted")]),
            settings: Settings()
        ) { _ in }

        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: [])])
        #expect(try read(output) == "converted")
        let record = try #require(outcome.record)
        #expect(try await engine.history.undo(record.id) == [.restored])
        #expect(try read(original) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["NOTE.txt"])
    }

    @Test func folderInputWithUnreadableChildStillRunsBody() async throws {
        let folder = try makeReplacementFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let locked = folder.appending(path: ".locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            #expect(throws: Never.self) {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            }
        }
        let engine = try makeEngine()
        let workItem = WorkItem(inputs: [folder]) { _ in .text("folder report", .report) }

        let outcome = await engine.run(Batch(operation: .folderTree, items: [workItem]), settings: Settings()) { _ in }

        #expect(outcome.outcomes == [.succeeded(outputs: [], warnings: [])])
        #expect(outcome.reportText == "folder report")
    }

    @Test func derivedFolderWithUnreadableChildStillRecordsCommit() async throws {
        let folder = try makeReplacementFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let original = folder.appending(path: "archive.tar")
        let output = folder.appending(path: "extracted")
        let staged = folder.appending(path: "staged")
        try write("archive", to: original)
        defer {
            for candidate in [staged, output] where FileManager.default.fileExists(atPath: candidate.path) {
                #expect(throws: Never.self) {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o700], ofItemAtPath: candidate.appending(path: "locked").path)
                }
            }
        }
        let engine = try makeEngine()
        let workItem = WorkItem(inputs: [original]) { _ in
            let child = staged.appending(path: "locked")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try write("keep", to: child.appending(path: "child.txt"))
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: child.path)
            return .derived(nextTo: original, outputs: [StagedFile(url: staged, name: "extracted", check: .folder)])
        }

        let outcome = await engine.run(Batch(operation: .archiveExtract, items: [workItem]), settings: Settings()) {
            _ in
        }

        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: [])])
        let record = try #require(outcome.record)
        #expect(record.items.count == 1)
        #expect(try await engine.history.undo(record.id) == [.skipped(.undoOutputChanged, path: output.path)])
        #expect(FileManager.default.fileExists(atPath: output.path))
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
        guard case .replaced(_, _, _, let stamp, _) = try #require(record.items.first) else {
            Issue.record("expected replaced record")
            return
        }
        #expect(try #require(stamp).size == Int64("new".utf8.count))
        #expect(try await engine.history.undo(record.id) == [.skipped(.undoOutputChanged, path: original.path)])
        #expect(try read(original) == "edited by the user afterwards")
    }

    @Test(arguments: ["source.txt", "result.txt", "SOURCE.txt"])
    func returnedCommitStampsPreserveThePreEditOutput(replacementName: String) async throws {
        let folder = try TestVolume.makeFolder()
        let original = folder.appending(path: "source.txt")
        try write("source", to: original)
        let committer = FileCommitter()
        let staged = folder.appending(path: "staged.txt")
        let cloneDirectory = folder.appending(path: "clones")
        try FileManager.default.createDirectory(at: cloneDirectory, withIntermediateDirectories: false)
        try write("replacement", to: staged)

        let replaced = try await committer.replace(
            original: original, with: StagedFile(url: staged, name: replacementName, check: .text(.utf8)),
            cloneDirectory: cloneDirectory, expectedStamp: FileStamp(of: original))
        let trashed = try #require(replaced.trashed)
        let replacementStamp = try #require(replaced.stamp)
        #expect(replacementStamp.matches(replaced.output.path))
        try write("edited replacement after commit", to: replaced.output)
        #expect(!replacementStamp.matches(replaced.output.path))
        #expect(
            committer.undo(
                .replaced(
                    original: original.path, trashed: trashed.url.path, output: replaced.output.path,
                    stamp: replacementStamp, trashStamp: trashed.stamp))
                == .skipped(.undoOutputChanged, path: replaced.output.path))
        #expect(try read(replaced.output) == "edited replacement after commit")

        let derivedStage = folder.appending(path: "derived-stage.txt")
        try write("derived", to: derivedStage)
        let derived = try await committer.derive(
            StagedFile(url: derivedStage, name: "derived.txt", check: .text(.utf8)), nextTo: replaced.output)
        let derivedStamp = try #require(derived.stamp)
        #expect(derivedStamp.matches(derived.output.path))
        try write("edited derived after commit", to: derived.output)
        #expect(!derivedStamp.matches(derived.output.path))
        #expect(
            committer.undo(.derived(output: derived.output.path, stamp: derivedStamp))
                == .skipped(.undoOutputChanged, path: derived.output.path))
        #expect(try read(derived.output) == "edited derived after commit")

        let renamed = try committer.rename(derived.output, to: "renamed.txt")
        let renameStamp = try #require(renamed.stamp)
        #expect(renameStamp.matchesIdentity(renamed.output.path))
        try write("edited rename after commit", to: renamed.output)
        #expect(!renameStamp.matches(renamed.output.path))
        #expect(
            committer.undo(.renamed(from: derived.output.path, to: renamed.output.path, stamp: renameStamp))
                == .skipped(.undoOutputChanged, path: renamed.output.path))
        #expect(try read(renamed.output) == "edited rename after commit")
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

private actor CommitBarrier {
    private var arrival: CheckedContinuation<Void, Never>?

    func arrive() async {
        if let arrival {
            self.arrival = nil
            arrival.resume()
        } else {
            await withCheckedContinuation { arrival = $0 }
        }
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
