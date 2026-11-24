import Foundation
import MenuCatalog
import Testing

@testable import Engine

struct UndoDeletedParentTests {
    @Test(arguments: ["derived", "renamed", "organized"])
    func undoAfterParentDeletionSkipsAndConsumesHistory(kind: String) async throws {
        let root = try TestVolume.makeFolder()
        let parent = root.appending(path: "parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let source = parent.appending(path: "original.txt")
        try Data("original\r\n".utf8).write(to: source)
        let engine = try JobEngine(supportDirectory: root.appending(path: "support"), concurrency: 1)
        let batch: Batch
        switch kind {
        case "derived":
            let request = OperationRequest(op: .textLineEndings, options: .text(.lineEndings(.lf)), inputs: [source])
            batch = OperationPlanner.batch(for: request, settings: Settings())
        case "renamed":
            let request = OperationRequest(
                op: .folderRename, options: .rename([RenamePlan(url: source, newName: "renamed.txt")]), inputs: [source]
            )
            batch = OperationPlanner.batch(for: request, settings: Settings())
        default:
            let plan = try OrganizationMovePlan(root: parent, source: source, category: "Documents")
            batch = Batch(operation: .folderOrganize, items: [WorkItem(inputs: [source]) { _ in .organize(plan) }])
        }
        let completed = await engine.run(batch, settings: Settings()) { _ in }
        let record = try #require(completed.record)
        let output = try #require(record.outputPaths.first)
        try FileManager.default.removeItem(at: parent)
        let undo = try await engine.undo(batch.id)
        #expect(undo.contains(.skipped(.undoOutputChanged, path: output)))
        #expect(!undo.contains { if case .failed = $0 { true } else { false } })
        #expect((await engine.history.records).first?.undone == true)
    }

}
