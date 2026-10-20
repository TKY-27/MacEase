import Foundation
import Synchronization
import Testing

@testable import Engine

@Suite struct RenameCancellationTests {
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
        let presenter = RenameCancellationPresenter(url: root.appending(path: "second.txt")) {
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
        let pending = Mutex<Task<URL, any Error>?>(nil)
        let presenter = RenameCancellationPresenter(url: original) {
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
}

private final class RenameCancellationPresenter: NSObject, NSFilePresenter, Sendable {
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
}
