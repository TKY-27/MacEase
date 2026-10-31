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
            return await FileCommitter().undo(.derived(output: output.path, stamp: stamp))
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
