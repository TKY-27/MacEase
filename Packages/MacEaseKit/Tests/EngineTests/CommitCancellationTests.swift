import Foundation
import MenuCatalog
import Synchronization
import Testing

@testable import Engine

@Suite struct CommitCancellationTests {
    @Test func cancelledBatchRetainsEarlierRenameHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacEaseRename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        try makeTree(["first.txt": "first", "second.txt": "second", "third.txt": "third"], in: root)
        let names = ["first", "second", "third"]
        let urls = names.map { root.appending(path: "\($0).txt") }
        let workItem = WorkItem(inputs: urls) { _ in
            .rename(zip(urls, names).map { RenamePlan(url: $0, newName: "\($1)-renamed.txt") })
        }
        let batch = Batch(operation: .folderRename, items: [workItem])
        let engine = try JobEngine(supportDirectory: root.appending(path: "support"), concurrency: 1)
        let pending = Mutex<Task<BatchOutcome, Never>?>(nil)
        let presenter = CommitCancellationPresenter(url: root.appending(path: "second.txt")) {
            pending.withLock { $0?.cancel() }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let ready = AsyncStream<Void>.makeStream()
        let running = Task {
            for await _ in ready.stream { break }
            return await engine.run(batch, settings: Settings()) { _ in }
        }
        pending.withLock { $0 = running }
        ready.continuation.yield(())
        ready.continuation.finish()

        let outcome = await running.value
        #expect(outcome.wasCancelled)
        #expect(try String(contentsOf: root.appending(path: "first-renamed.txt"), encoding: .utf8) == "first")
        #expect(try String(contentsOf: root.appending(path: "second.txt"), encoding: .utf8) == "second")
        #expect(try String(contentsOf: root.appending(path: "third.txt"), encoding: .utf8) == "third")
        let record = try #require(outcome.record)
        #expect(record.items.count == 1)
        #expect(record.outputPaths == [root.appending(path: "first-renamed.txt").path])
    }

    @Test func cancellationDuringCoordinationKeepsOriginalName() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacEaseRename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let original = root.appending(path: "original.txt")
        try Data("keep".utf8).write(to: original)
        let pending = Mutex<Task<FileCommitter.Committed, any Error>?>(nil)
        let presenter = CommitCancellationPresenter(url: original) {
            pending.withLock { $0?.cancel() }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let ready = AsyncStream<Void>.makeStream()
        let renaming = Task.detached {
            for await _ in ready.stream { break }
            return try FileCommitter().rename(original, to: "renamed.txt")
        }
        pending.withLock { $0 = renaming }
        ready.continuation.yield(())
        ready.continuation.finish()

        await #expect(throws: CancellationError.self) { try await renaming.value }
        #expect(presenter.relinquished.withLock { $0 })
        #expect(try String(contentsOf: original, encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "renamed.txt").path))
    }

    @Test(arguments: [false, true])
    func cancellationDuringDerivedCoordinationKeepsStagedOutput(checksSource: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacEaseDerive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let original = root.appending(path: "original.txt")
        let staging = root.appending(path: "staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let staged = staging.appending(path: "derived.txt")
        try Data("original".utf8).write(to: original)
        try Data("derived".utf8).write(to: staged)
        let expectedStamp = checksSource ? try FileStamp(of: original) : nil
        let pending = Mutex<Task<FileCommitter.Committed, any Error>?>(nil)
        let presenter = CommitCancellationPresenter(url: checksSource ? original : staged) {
            pending.withLock { $0?.cancel() }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let ready = AsyncStream<Void>.makeStream()
        let deriving = Task.detached {
            for await _ in ready.stream { break }
            return try await FileCommitter().derive(
                StagedFile(url: staged, name: "derived.txt", check: .text(.utf8)), nextTo: original,
                expectedStamp: expectedStamp)
        }
        pending.withLock { $0 = deriving }
        ready.continuation.yield(())
        ready.continuation.finish()

        await #expect(throws: CancellationError.self) { try await deriving.value }
        #expect(presenter.relinquished.withLock { $0 })
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "derived")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "derived.txt").path))
    }

    @Test func cancellationDuringGroupedCoordinationKeepsStagedOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacEaseGroupedCancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let original = root.appending(path: "original.txt")
        let staged = root.appending(path: "staged.txt")
        let destination = root.appending(path: "combined.txt")
        try Data("original".utf8).write(to: original)
        try Data("combined".utf8).write(to: staged)
        let stamp = try FileStamp(of: original, includingIdentity: true)
        let pending = Mutex<Task<FileCommitter.Committed, any Error>?>(nil)
        let presenter = CommitCancellationPresenter(url: original) { pending.withLock { $0?.cancel() } }
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let ready = AsyncStream<Void>.makeStream()
        let deriving = Task.detached {
            for await _ in ready.stream { break }
            return try await FileCommitter().deriveGroup(
                StagedFile(url: staged, name: "combined.txt", check: .text(.utf8)), destination: destination,
                sources: [original: stamp], attributeSource: original)
        }
        pending.withLock { $0 = deriving }
        ready.continuation.yield(())
        ready.continuation.finish()
        await #expect(throws: CancellationError.self) { try await deriving.value }
        #expect(presenter.relinquished.withLock { $0 })
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "combined")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func cancellationDuringUndoCoordinationPreservesDerivedOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacEaseUndo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let output = root.appending(path: "derived.txt")
        try Data("derived".utf8).write(to: output)
        let stamp = try FileStamp(of: output)
        let pending = Mutex<Task<UndoOutcome, Never>?>(nil)
        let presenter = CommitCancellationPresenter(url: output) {
            pending.withLock { $0?.cancel() }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let ready = AsyncStream<Void>.makeStream()
        let undoing = Task.detached {
            for await _ in ready.stream { break }
            return await FileCommitter().undo(
                .derived(output: output.path, stamp: stamp))
        }
        pending.withLock { $0 = undoing }
        ready.continuation.yield(())
        ready.continuation.finish()

        #expect(await undoing.value == .failed(.cancelled, path: output.path))
        #expect(presenter.relinquished.withLock { $0 })
        #expect(try String(contentsOf: output, encoding: .utf8) == "derived")
    }

    @Test func clearingHistoryDuringUndoDoesNotRestoreTheRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacEaseUndo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: root) } }
        let support = root.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        let output = root.appending(path: "derived.txt")
        try Data("derived".utf8).write(to: output)
        let store = HistoryStore(supportDirectory: support)
        let batchID = UUID()
        try await store.record(
            [.derived(output: output.path, stamp: FileStamp(of: output))], batch: batchID,
            operation: .textLineEndings)
        let presenter = ClearHistoryPresenter(url: output, store: store)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }

        #expect(try await store.undo(batchID) == [.restored])
        #expect(presenter.relinquished.withLock { $0 })
        try #require(presenter.clearResult.withLock { $0 }).get()
        #expect(await store.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
    @Test(arguments: [false, true])
    func movePublicationCollisionRetriesWithoutOverwriting(crossVolume: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacEaseMoveRace-\(UUID().uuidString)")
        TestTemporaryFolders.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = crossVolume ? try TestVolume.makeFolder() : root.appending(path: "destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let source = root.appending(path: "report.txt")
        try Data("original".utf8).write(to: source)
        let collision = destination.appending(path: "report.txt")
        let occupied = Mutex(false)
        let presenter = CommitCancellationPresenter(url: source) {
            occupied.withLock { created in
                if !created {
                    #expect(throws: Never.self) {
                        try Data("concurrent".utf8).write(to: collision, options: .withoutOverwriting)
                    }
                    created = true
                }
            }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let engine = try JobEngine(supportDirectory: root.appending(path: "support"), concurrency: 1)
        let entry = try MoveItem.capture(source)
        let request = OperationRequest(
            op: .filesMove, options: .move(MovePlan(items: [entry], destination: destination)), inputs: [source])
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: Settings()), settings: Settings())
        { _ in }
        let numbered = destination.appending(path: "report (2).txt")
        #expect(outcome.outcomes == [.succeeded(outputs: [numbered], warnings: [])])
        #expect(presenter.relinquished.withLock { $0 })
        #expect(try String(contentsOf: collision, encoding: .utf8) == "concurrent")
        #expect(try String(contentsOf: numbered, encoding: .utf8) == "original")
        NSFileCoordinator.removeFilePresenter(presenter)
        #expect(try await engine.undo(outcome.batchID) == Array(repeating: .restored, count: crossVolume ? 2 : 1))
        #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    }

    @Test func moveHistoryIsDurableBeforeTrashingAndUndoKeepsEditedOutput() async throws {
        let destination = try TestVolume.makeFolder()
        let root = FileManager.default.temporaryDirectory.appending(path: "MacEaseMoveHistory-\(UUID().uuidString)")
        TestTemporaryFolders.register(root)
        let support = root.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let source = root.appending(path: "original.txt")
        try Data("original bytes".utf8).write(to: source)
        let presenter = MoveHistoryPresenter(source: source, support: support)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let cut = try MoveItem.capture(source)
        let request = OperationRequest(
            op: .filesMove,
            options: .move(MovePlan(items: [cut], destination: destination)), inputs: [source])
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: Settings()), settings: Settings())
        { _ in }
        #expect(presenter.durableBeforeTrash.withLock { $0 })
        let output = destination.appending(path: "original.txt")
        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: [])])
        NSFileCoordinator.removeFilePresenter(presenter)
        try Data("edited output".utf8).write(to: output)
        #expect(try await engine.undo(outcome.batchID) == [.restored, .skipped(.undoOutputChanged, path: output.path)])
        #expect(try Data(contentsOf: source) == Data("original bytes".utf8))
        #expect(try Data(contentsOf: output) == Data("edited output".utf8))
    }

    @Test func cancelledCrossVolumeUndoKeepsMovedCopyAndHistoryRetryable() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MacEaseUndoMove-\(UUID().uuidString)")
        TestTemporaryFolders.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = try TestVolume.makeFolder()
        let source = root.appending(path: "original.txt")
        try Data("original".utf8).write(to: source)
        let entry = try MoveItem.capture(source)
        let engine = try JobEngine(supportDirectory: root.appending(path: "support"), concurrency: 1)
        let request = OperationRequest(
            op: .filesMove, options: .move(MovePlan(items: [entry], destination: destination)), inputs: [source])
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: Settings()), settings: Settings())
        { _ in }
        let record = try #require(outcome.record)
        let moved = destination.appending(path: "original.txt")
        let pending = Mutex<Task<[UndoOutcome], any Error>?>(nil)
        let trashed = try #require(
            record.items.compactMap { entry -> String? in
                if case .removed(_, let path, _) = entry { return path }
                return nil
            }.first)
        let presenter = CommitCancellationPresenter(url: URL(fileURLWithPath: trashed)) {
            pending.withLock { $0?.cancel() }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        let ready = AsyncStream<Void>.makeStream()
        let undoing = Task {
            for await _ in ready.stream { break }
            return try await engine.undo(record.id)
        }
        pending.withLock { $0 = undoing }
        ready.continuation.yield(())
        ready.continuation.finish()
        #expect(try await undoing.value == [.failed(.cancelled, path: trashed), .failed(.cancelled, path: moved.path)])
        NSFileCoordinator.removeFilePresenter(presenter)
        #expect(try String(contentsOf: moved, encoding: .utf8) == "original")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try await engine.undo(record.id) == [.restored, .restored])
        #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    }

}

private final class CommitCancellationPresenter: NSObject, NSFilePresenter, Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    let relinquished = Mutex(false)
    private let cancel: @Sendable () -> Void

    init(url: URL, cancel: @escaping @Sendable () -> Void) {
        presentedItemURL = url
        self.cancel = cancel
    }

    func relinquishPresentedItem(toWriter writer: @Sendable ((@Sendable () -> Void)?) -> Void) {
        relinquished.withLock { $0 = true }
        cancel()
        writer(nil)
    }

    func relinquishPresentedItem(toReader reader: @Sendable ((@Sendable () -> Void)?) -> Void) {
        relinquished.withLock { $0 = true }
        cancel()
        reader(nil)
    }
}

private final class ClearHistoryPresenter: NSObject, NSFilePresenter, Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    let relinquished = Mutex(false)
    let clearResult = Mutex<Result<Void, any Error>?>(nil)
    private let store: HistoryStore

    init(url: URL, store: HistoryStore) {
        presentedItemURL = url
        self.store = store
    }

    func relinquishPresentedItem(toWriter writer: @Sendable ((@Sendable () -> Void)?) -> Void) {
        relinquished.withLock { $0 = true }
        let completed = DispatchSemaphore(value: 0)
        Task {
            do {
                try await store.clear()
                clearResult.withLock { $0 = .success(()) }
            } catch {
                clearResult.withLock { $0 = .failure(error) }
            }
            completed.signal()
        }
        completed.wait()
        writer(nil)
    }
}

private final class MoveHistoryPresenter: NSObject, NSFilePresenter, Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    let durableBeforeTrash = Mutex(false)
    private let writes = Mutex(0)
    private let support: URL

    init(source: URL, support: URL) {
        presentedItemURL = source
        self.support = support
    }

    func relinquishPresentedItem(toWriter writer: @Sendable ((@Sendable () -> Void)?) -> Void) {
        let count = writes.withLock {
            $0 += 1; return $0
        }
        if count == 2 {
            do {
                let snapshot = try JSONDecoder().decode(
                    HistorySnapshot.self,
                    from: Data(contentsOf: support.appending(path: "history.json")))
                let paths = snapshot.batches.flatMap(\.outputPaths)
                let source = try #require(presentedItemURL)
                #expect(try Data(contentsOf: source) == Data("original bytes".utf8))
                #expect(paths.count == 1)
                if let path = paths.first {
                    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("original bytes".utf8))
                    durableBeforeTrash.withLock { $0 = true }
                }
            } catch { Issue.record(error) }
        }
        writer(nil)
    }
}
