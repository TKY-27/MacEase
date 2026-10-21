import Foundation
import MenuCatalog
import Synchronization
import Testing

@testable import Engine

struct BatchProgressTests {
    @Test func progressCountsFinishedItemsAndNamesTheNextOne() async throws {
        let folder = try TestVolume.makeFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let inputs = [folder.appending(path: "a.txt"), folder.appending(path: "b.txt")]
        let batch = Batch(
            operation: .anyChecksum,
            items: inputs.map { url in WorkItem(inputs: [url]) { _ in .skipped(.alreadyDone) } })
        let updates = Mutex<[BatchProgress]>([])

        _ = await engine.run(batch, settings: Settings()) { progress in
            updates.withLock { $0.append(progress) }
        }

        let reported = updates.withLock { $0 }
        #expect(reported.contains { $0.completedItems == 1 && $0.currentItem != nil })
        let last = try #require(reported.last)
        #expect(last.completedItems == 2)
        #expect(last.fraction == 1)
        #expect(last.currentItem == nil)
    }
}
