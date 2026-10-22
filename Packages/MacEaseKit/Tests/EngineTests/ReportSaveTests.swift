import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite(.serialized) struct ReportSaveTests {
    @Test(arguments: ["txt", "md"])
    func savingKeepsCollisionsAndPersistsUndo(pathExtension: String) async throws {
        let folder = try TestVolume.makeFolder()
        let support = folder.appending(path: "support")
        let destination = folder.appending(path: "report.\(pathExtension)")
        let numbered = folder.appending(path: "report (2).\(pathExtension)")
        let output = folder.appending(path: "report (3).\(pathExtension)")
        try Data("original".utf8).write(to: destination)
        try Data("previous report".utf8).write(to: numbered)
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let operation: OperationID = pathExtension == "md" ? .folderAnalyze : .anyChecksum
        let report = "# Report\nUTF-8: 日本語\n"

        let outcome = await engine.saveReport(report, to: destination, operation: operation)

        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: [])])
        #expect(!outcome.historyFailed)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
        #expect(try String(contentsOf: numbered, encoding: .utf8) == "previous report")
        #expect(try String(contentsOf: output, encoding: .utf8) == report)
        let record = try #require(outcome.record)
        #expect(record.operation == operation)
        #expect(record.items == [.derived(output: output.path, stamp: try FileStamp(of: output))])

        let reopened = try JobEngine(supportDirectory: support, concurrency: 1)
        #expect(await reopened.history.records.contains(record))
        #expect(try await reopened.undo(record.id) == [.restored])
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
        #expect(try String(contentsOf: numbered, encoding: .utf8) == "previous report")
    }

    @Test func emptyReportFailsVerificationWithoutChangingDestination() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let destination = folder.appending(path: "report.txt")
        try Data("keep".utf8).write(to: destination)

        let outcome = await engine.saveReport("", to: destination, operation: .anyChecksum)

        #expect(outcome.outcomes == [.failed(.encodeFailed("empty output"))])
        #expect(outcome.record == nil)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "report (2).txt").path))
    }

    @Test func reportCanUseAnUnoccupiedDestination() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let destination = folder.appending(path: "report.txt")

        let outcome = await engine.saveReport("new report", to: destination, operation: .anyChecksum)

        #expect(outcome.outcomes == [.succeeded(outputs: [destination], warnings: [])])
        #expect(try String(contentsOf: destination, encoding: .utf8) == "new report")
        #expect(outcome.record?.items.count == 1)
        #expect(!outcome.historyFailed)
    }
}
