import Darwin
import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite(.serialized) struct SnapshotExportTests {
    @Test(arguments: [0, 2, 4, 11, 19])
    func stampsRemainCompatibleWithPersistedFoundationDates(_ offset: Int) throws {
        struct LegacyStamp: Encodable {
            let size: Int64
            let modified: Date
        }
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: source) } }
        try Data("original".utf8).write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_792_980_000 + Double(offset) / 31)],
            ofItemAtPath: source.path)
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let legacy = LegacyStamp(
            size: Int64(try #require(values.fileSize)), modified: try #require(values.contentModificationDate))
        let restored = try JSONDecoder().decode(FileStamp.self, from: JSONEncoder().encode(legacy))
        #expect(restored.matches(source.path))
    }

    @Test func exportRejectsSourceReplacedByFIFOBeforeRunning() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let source = folder.appending(path: "source.zip")
        try Data("original".utf8).write(to: source)
        let stamp = try FileStamp(of: source, includingIdentity: true)
        let work = WorkItem(inputs: [source]) { _ in
            Issue.record("Special inputs must be rejected before reading")
            return .skipped(.changedSinceScan)
        }
        try FileManager.default.removeItem(at: source)
        #expect(mkfifo(source.path, 0o600) == 0)
        #expect(!stamp.matches(source.path))

        let outcome = await engine.run(Batch(operation: .archiveBrowse, items: [work]), settings: Settings()) { _ in }

        #expect(outcome.outcomes == [.failed(.invalidInput(.unsupportedFileType))])
        #expect(outcome.record == nil)
    }

    @Test func exportRejectsAReplacedSourceWithMatchingSizeAndDate() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let source = folder.appending(path: "source.txt")
        let destination = folder.appending(path: "result.txt")
        try Data("old".utf8).write(to: source)
        let stamp = try FileStamp(of: source, includingIdentity: true)
        let work = WorkItem(inputs: [source]) { context in
            let staged = try context.stagingURL(for: destination, name: destination.lastPathComponent)
            try Data("preview result".utf8).write(to: staged)
            try Data("new".utf8).write(to: source, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: stamp.modified], ofItemAtPath: source.path)
            return .exported(
                from: source, stamp: stamp, to: destination,
                outputs: [StagedFile(url: staged, name: destination.lastPathComponent, check: .text(.utf8))])
        }

        let outcome = await engine.run(Batch(operation: .imageTraceSVG, items: [work]), settings: Settings()) { _ in }

        #expect(outcome.outcomes == [.skipped(.changedSinceScan)])
        #expect(outcome.record == nil)
        #expect(try String(contentsOf: source, encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func exportToAnotherFolderKeepsCollisionsAndSurvivesUndoRestart() async throws {
        let folder = try TestVolume.makeFolder()
        let support = folder.appending(path: "support")
        let source = folder.appending(path: "source.txt")
        let exports = folder.appending(path: "exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: false)
        let destination = exports.appending(path: "result.txt")
        let output = exports.appending(path: "result (2).txt")
        try Data("original".utf8).write(to: source)
        try Data("occupied".utf8).write(to: destination)
        let stamp = try FileStamp(of: source, includingIdentity: true)
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let work = WorkItem(inputs: [source]) { context in
            let staged = try context.stagingURL(for: exports, name: destination.lastPathComponent)
            try Data("preview result".utf8).write(to: staged)
            return .exported(
                from: source, stamp: stamp, to: destination,
                outputs: [StagedFile(url: staged, name: destination.lastPathComponent, check: .text(.utf8))])
        }

        let outcome = await engine.run(Batch(operation: .imageTraceSVG, items: [work]), settings: Settings()) { _ in }

        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: [])])
        #expect(try String(contentsOf: output, encoding: .utf8) == "preview result")
        #expect(stamp.matchesIdentity(source.path))
        let record = try #require(outcome.record)
        let reopened = try JobEngine(supportDirectory: support, concurrency: 1)
        #expect(try await reopened.undo(record.id) == [.restored])
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "occupied")
        #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    }
}
