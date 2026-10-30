import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite(.serialized) struct HatchExtractionTests {
    private var executable: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Vendor/build/macease-hatchzip")
    }

    @Test func extractedContentSurvivesUndoAndHistoryClear() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "payload.txt")
        try Data("independently written payload".utf8).write(to: source)
        let archive = folder.appending(path: "bundle.zip")
        let writer = Process()
        writer.executableURL = URL(filePath: "/usr/bin/ditto")
        writer.arguments = ["-c", "-k", source.path, archive.path]
        try writer.run()
        writer.waitUntilExit()
        #expect(writer.terminationStatus == 0)
        let support = folder.appending(path: "support")
        let store = HatchExtractionStore(supportDirectory: support, executableURL: executable)
        let engine = try JobEngine(supportDirectory: support, concurrency: 1, hatchExtractions: store)
        let batch = OperationPlanner.batch(
            for: OperationRequest(
                op: .archiveHatchExtract, options: .archive(.hatchExtract(password: nil)), inputs: [archive]),
            settings: Settings())
        let result = await engine.run(batch, settings: Settings()) { _ in }
        let record = try #require(result.record)
        #expect(!record.canUndo)
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        let output = URL(filePath: try #require(record.outputPaths.first)).appending(path: "payload.txt")
        #expect(try Data(contentsOf: output) == Data("independently written payload".utf8))
        #expect(try await engine.undo(batch.id).isEmpty)
        try await engine.history.clear()
        #expect(try Data(contentsOf: output) == Data("independently written payload".utf8))
        let reopened = HatchExtractionStore(supportDirectory: support, executableURL: executable)
        let session = try #require(reopened.sessions().first)
        #expect(session.state == "finished")
        #expect(session.output.path == output.deletingLastPathComponent().path)
    }

    @Test func encryptedArchiveRequestsPasswordWithoutRetainingFailedSession() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "secret.txt")
        try Data("encrypted fixture content".utf8).write(to: source)
        let archive = folder.appending(path: "encrypted.zip")
        let writer = Process()
        writer.executableURL = URL(filePath: "/usr/bin/zip")
        writer.arguments = ["-q", "-j", "-P", "fixture-password", archive.path, source.path]
        try writer.run()
        writer.waitUntilExit()
        #expect(writer.terminationStatus == 0)
        let original = try Data(contentsOf: archive)
        let support = folder.appending(path: "support")
        let store = HatchExtractionStore(supportDirectory: support, executableURL: executable)
        let engine = try JobEngine(supportDirectory: support, concurrency: 1, hatchExtractions: store)
        for (password, expected) in [(nil, InvalidInput.passwordRequired), ("incorrect", .wrongPassword)] {
            let batch = ArchivePlanner.batch(
                .hatchExtract(password: password), op: .archiveHatchExtract, archives: [archive])
            let result = await engine.run(batch, settings: Settings()) { _ in }
            #expect(result.outcomes == [.failed(.invalidInput(expected))])
            #expect(try Data(contentsOf: archive) == original)
            #expect(try store.sessions().isEmpty)
        }
        let batch = ArchivePlanner.batch(
            .hatchExtract(password: "fixture-password"), op: .archiveHatchExtract, archives: [archive])
        let result = await engine.run(batch, settings: Settings()) { _ in }
        guard case .succeeded(let outputs, _) = result.outcomes.first else {
            Issue.record("The correct password did not extract the archive")
            return
        }
        let output = try #require(outputs.first).appending(path: "secret.txt")
        #expect(try Data(contentsOf: output) == Data(contentsOf: source))
    }

    @Test func selectedSplitVolumesProduceOneExtraction() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "payload.txt")
        try Data("selected split archive payload".utf8).write(to: source)
        let archive = folder.appending(path: "split.zip")
        let writer = Process()
        writer.executableURL = URL(filePath: "/usr/bin/ditto")
        writer.arguments = ["-c", "-k", source.path, archive.path]
        try writer.run()
        writer.waitUntilExit()
        #expect(writer.terminationStatus == 0)
        let bytes = try Data(contentsOf: archive)
        let first = archive.appendingPathExtension("001")
        let second = archive.appendingPathExtension("002")
        try bytes.prefix(bytes.count / 2).write(to: first)
        try bytes.suffix(from: bytes.count / 2).write(to: second)
        try FileManager.default.removeItem(at: archive)
        let support = folder.appending(path: "support")
        let store = HatchExtractionStore(supportDirectory: support, executableURL: executable)
        let engine = try JobEngine(supportDirectory: support, concurrency: 2, hatchExtractions: store)
        let batch = ArchivePlanner.batch(
            .hatchExtract(password: nil), op: .archiveHatchExtract, archives: [second, first, second])
        #expect(batch.items.count == 1)
        #expect(batch.items.first?.inputs == [first])
        let result = await engine.run(batch, settings: Settings()) { _ in }
        guard case .succeeded(let outputs, _) = result.outcomes.first else {
            Issue.record("The selected split set did not extract")
            return
        }
        #expect(result.outcomes.count == 1)
        #expect(try store.sessions().count == 1)
        let output = try #require(outputs.first).appending(path: "payload.txt")
        #expect(try Data(contentsOf: output) == Data(contentsOf: source))
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test func cloudFolderAliasIsRejectedBeforeOpeningArchive() async throws {
        let folder = try TestVolume.makeFolder()
        let cloud = folder.appending(path: "Library/Mobile Documents/CloudDocs")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let original = Data("untouched cloud fixture".utf8)
        try original.write(to: cloud.appending(path: "archive.zip"))
        let alias = folder.appending(path: "Desktop")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: cloud)
        let support = folder.appending(path: "support")
        let store = HatchExtractionStore(supportDirectory: support, executableURL: executable)
        do {
            _ = try await store.extract(input: alias.appending(path: "archive.zip")) { _ in }
            Issue.record("A cloud-folder alias unexpectedly reached extraction")
        } catch let error as EngineError {
            #expect(error == .unexpected("Cloud and network locations cannot be extracted in place"))
        }
        #expect(try Data(contentsOf: cloud.appending(path: "archive.zip")) == original)
        #expect(try store.sessions().isEmpty)
    }

    @Test func corruptArchiveDoesNotChangeSource() async throws {
        let folder = try TestVolume.makeFolder()
        let archive = folder.appending(path: "invalid.zip")
        let original = Data("PK not an archive".utf8)
        try original.write(to: archive)
        let support = folder.appending(path: "support")
        let store = HatchExtractionStore(supportDirectory: support, executableURL: executable)
        let engine = try JobEngine(supportDirectory: support, concurrency: 1, hatchExtractions: store)
        let batch = ArchivePlanner.batch(.hatchExtract(password: nil), op: .archiveHatchExtract, archives: [archive])
        let result = await engine.run(batch, settings: Settings()) { _ in }
        guard case .failed = result.outcomes.first else {
            Issue.record("An invalid archive unexpectedly succeeded")
            return
        }
        #expect(try Data(contentsOf: archive) == original)
        #expect(result.record == nil)
        #expect(try store.sessions().isEmpty)
    }
}
