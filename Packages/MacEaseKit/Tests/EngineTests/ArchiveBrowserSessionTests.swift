import Darwin
import Formats
import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite(.serialized) struct ArchiveBrowserSessionTests {
    private func fixture() throws -> (URL, URL, JobEngine) {
        let root = FileManager.default.temporaryDirectory.appending(path: "archive-session-\(UUID().uuidString)")
        TestTemporaryFolders.register(root)
        let content = root.appending(path: "content", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: content.appending(path: "first.txt"))
        try Data("second".utf8).write(to: content.appending(path: "second.txt"))
        try Data().write(to: content.appending(path: "empty.txt"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640, .modificationDate: Date(timeIntervalSince1970: 1_000_000_000)],
            ofItemAtPath: content.appending(path: "first.txt").path)
        let source = root.appending(path: "content.zip")
        try ArchiveWriter.write([content], to: source, format: .zip, progress: { _ in }, skipping: { _ in false })
        let engine = try JobEngine(supportDirectory: root.appending(path: "support"), concurrency: 1)
        return (root, source, engine)
    }

    private func customZIP(_ body: String) throws -> (URL, URL, JobEngine) {
        let root = FileManager.default.temporaryDirectory.appending(path: "archive-custom-\(UUID().uuidString)")
        TestTemporaryFolders.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "custom.zip")
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = [
            "-c", "import sys, zipfile\nwith zipfile.ZipFile(sys.argv[1], 'w') as archive:\n" + body, source.path,
        ]
        python.standardError = FileHandle.nullDevice
        try python.run()
        python.waitUntilExit()
        guard python.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        let engine = try JobEngine(supportDirectory: root.appending(path: "support"), concurrency: 1)
        return (root, source, engine)
    }

    @Test func previewMaterializesOnlySelectedFileAndCloseIsIdempotent() async throws {
        let (_, source, engine) = try fixture()
        let quarantine = Array("0081;fixture".utf8)
        #expect(setxattr(source.path, "com.apple.quarantine", quarantine, quarantine.count, 0, 0) == 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source.path)
        let session = ArchiveBrowserSession(source: source, staging: engine.staging)
        let listed = try await session.entries()
        let first = try #require(listed.first(where: { $0.path == "content/first.txt" }))
        let preview = try await session.preview(entryID: first.id, password: nil)
        #expect(try String(contentsOf: preview, encoding: .utf8) == "first")
        #expect(getxattr(preview.path, "com.apple.quarantine", nil, 0, 0, 0) == quarantine.count)
        #expect(
            !FileManager.default.fileExists(
                atPath: preview.deletingLastPathComponent().appending(path: "second.txt").path))
        await session.releasePreview(entryID: first.id)
        #expect(!FileManager.default.fileExists(atPath: preview.path))
        await session.close()
        await session.close()
        await #expect(throws: ArchiveBrowserError.closed) { try await session.entries() }
    }

    @Test func folderBatchCommitsBeneathChosenParentAndCanUndo() async throws {
        let (root, source, engine) = try fixture()
        let destination = root.appending(path: "exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let quarantine = Array("0081;fixture".utf8)
        #expect(setxattr(source.path, "com.apple.quarantine", quarantine, quarantine.count, 0, 0) == 0)
        let session = ArchiveBrowserSession(source: source, staging: engine.staging)
        let listed = try await session.entries()
        let folder = try #require(listed.first(where: { $0.path == "content" && $0.isDirectory }))
        let batch = try await session.batch(
            entryIDs: [folder.id], password: nil, to: destination, operation: .archiveExtract)
        let outcome = await engine.run(batch, settings: Settings()) { _ in }
        guard case .succeeded(let outputs, _) = try #require(outcome.outcomes.first),
            let output = outputs.first
        else { Issue.record("Folder export did not commit"); return }
        #expect(output.deletingLastPathComponent() == destination)
        #expect(output.lastPathComponent == "content_selected")
        #expect(try String(contentsOf: output.appending(path: "content/first.txt"), encoding: .utf8) == "first")
        #expect(try String(contentsOf: output.appending(path: "content/second.txt"), encoding: .utf8) == "second")
        #expect(FileManager.default.fileExists(atPath: source.path))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: output.appending(path: "content/first.txt").path)
        #expect(attributes[.posixPermissions] as? Int == 0o640)
        #expect(attributes[.modificationDate] as? Date == Date(timeIntervalSince1970: 1_000_000_000))
        #expect(
            getxattr(output.appending(path: "content/first.txt").path, "com.apple.quarantine", nil, 0, 0, 0)
                == quarantine.count)
        let record = try #require(outcome.record)
        _ = try await engine.undo(record.id)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        await session.close()
    }

    @Test func emptyMemberCanExportToExactChosenFileName() async throws {
        let (root, source, engine) = try fixture()
        let session = ArchiveBrowserSession(source: source, staging: engine.staging)
        let listed = try await session.entries()
        let empty = try #require(listed.first(where: { $0.path == "content/empty.txt" }))
        let destination = root.appending(path: "renamed.txt")
        let batch = try await session.batch(
            entryIDs: [empty.id], password: nil, to: destination, operation: .archiveExtract)
        let outcome = await engine.run(batch, settings: Settings()) { _ in }
        guard case .succeeded(let outputs, _) = try #require(outcome.outcomes.first) else {
            Issue.record("Empty member export did not commit")
            return
        }
        #expect(outputs == [destination])
        #expect(try Data(contentsOf: destination).isEmpty)
        await session.close()
    }

    @Test func implicitFolderPreservesHierarchy() async throws {
        let (root, source, engine) = try customZIP("    archive.writestr('nested/file.txt', 'nested')\n")
        let destination = root.appending(path: "exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let session = ArchiveBrowserSession(source: source, staging: engine.staging)
        let file = try #require(try await session.entries().first(where: { $0.path == "nested/file.txt" }))
        let batch = try await session.batch(
            entryIDs: [file.id], password: nil, to: destination,
            operation: .archiveExtract, exportsFolder: true)
        let outcome = await engine.run(batch, settings: Settings()) { _ in }
        guard case .succeeded(let outputs, _) = try #require(outcome.outcomes.first),
            let output = outputs.first
        else { Issue.record("Implicit folder export did not commit"); return }
        #expect(output.deletingLastPathComponent() == destination)
        #expect(try String(contentsOf: output.appending(path: "nested/file.txt"), encoding: .utf8) == "nested")
        await session.close()
    }

    @Test func duplicatePathsRejectGroupedExportWithoutOverwriting() async throws {
        let (root, source, engine) = try customZIP(
            "    archive.writestr('same.txt', 'first')\n    archive.writestr('same.txt', 'second')\n")
        let session = ArchiveBrowserSession(source: source, staging: engine.staging)
        let listed = try await session.entries()
        #expect(listed.map(\.id) == [0, 1])
        await #expect(throws: ArchiveBrowserError.pathConflict) {
            _ = try await session.batch(
                entryIDs: [0, 1], password: nil, to: root,
                operation: .archiveExtract)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "custom_selected").path))
        await session.close()
    }

    @Test func duplicateDirectoryRecordsExportOnceAndRemainUndoable() async throws {
        let (root, source, engine) = try customZIP(
            "    archive.writestr('tree/', '')\n    archive.writestr('tree/', '')\n    archive.writestr('tree/child.txt', 'child')\n"
        )
        let destination = root.appending(path: "exports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let session = ArchiveBrowserSession(source: source, staging: engine.staging)
        let listed = try await session.entries()
        #expect(listed.map(\.id) == [0, 1, 2])
        #expect(listed[0].path == "tree" && listed[1].path == "tree")
        let batch = try await session.batch(
            entryIDs: [0, 1], password: nil, to: destination, operation: .archiveExtract)
        let outcome = await engine.run(batch, settings: Settings()) { _ in }
        guard case .succeeded(let outputs, _) = try #require(outcome.outcomes.first),
            let output = outputs.first
        else { Issue.record("Duplicate directory export did not commit"); return }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["tree"])
        #expect(try String(contentsOf: output.appending(path: "tree/child.txt"), encoding: .utf8) == "child")
        let record = try #require(outcome.record)
        _ = try await engine.undo(record.id)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        await session.close()
    }

    @Test func fileDirectoryCollisionRemainsRefused() async throws {
        let (root, source, engine) = try customZIP(
            "    archive.writestr('tree/', '')\n    archive.writestr('tree', 'file')\n")
        let session = ArchiveBrowserSession(source: source, staging: engine.staging)
        #expect(try await session.entries().map(\.id) == [0, 1])
        await #expect(throws: ArchiveBrowserError.pathConflict) {
            _ = try await session.batch(
                entryIDs: [0, 1], password: nil, to: root, operation: .archiveExtract)
        }
        await session.close()
    }

    @Test func closingDuringActivePreviewStopsWritingAndCleansStaging() async throws {
        let expandedBytes = 160 * 1024 * 1024
        let (root, source, engine) = try customZIP(
            "    archive.writestr('large.bin', b'X' * \(expandedBytes), compress_type=zipfile.ZIP_DEFLATED)\n")
        let session = ArchiveBrowserSession(source: source, staging: engine.staging)
        let file = try #require(try await session.entries().first(where: { $0.path == "large.bin" }))
        let pending = Task { try await session.preview(entryID: file.id, password: nil) }
        let registry = root.appending(path: "support/staging.json")
        var sawPartialOutput = false
        for _ in 0..<1_000 {
            if let tracked = try? JSONDecoder().decode([String].self, from: Data(contentsOf: registry)),
                let directory = tracked.first,
                let names = try? FileManager.default.contentsOfDirectory(atPath: directory),
                let name = names.first,
                let size = try? URL(fileURLWithPath: directory).appending(path: name)
                    .resourceValues(forKeys: [.fileSizeKey]).fileSize,
                size > 0, size < expandedBytes
            {
                sawPartialOutput = true
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(sawPartialOutput)
        await session.close()
        switch await pending.result {
        case .success(let preview):
            #expect(!FileManager.default.fileExists(atPath: preview.path))
        case .failure(let error):
            #expect(error as? ArchiveBrowserError == .closed)
        }
        let tracked = try JSONDecoder().decode([String].self, from: Data(contentsOf: registry))
        #expect(tracked.isEmpty)
    }

    @Test func longArchiveLeafStillPreviewsWithUsableExtension() async throws {
        let leaf = String(repeating: "x", count: 230) + ".txt"
        let (_, source, engine) = try customZIP("    archive.writestr('\(leaf)', 'long')\n")
        let session = ArchiveBrowserSession(source: source, staging: engine.staging)
        let entry = try #require(try await session.entries().first(where: { $0.path == leaf }))
        let preview = try await session.preview(entryID: entry.id, password: nil)
        #expect(preview.lastPathComponent.utf8.count < 255)
        #expect(preview.pathExtension == "txt")
        #expect(try String(contentsOf: preview, encoding: .utf8) == "long")
        await session.releasePreview(entryID: entry.id)
        await session.close()
    }

    @Test func namedPipeSourceDoesNotBlockListing() async throws {
        let (root, _, engine) = try fixture()
        let pipe = root.appending(path: "pipe.zip")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        let session = ArchiveBrowserSession(source: pipe, staging: engine.staging)
        let start = ContinuousClock.now
        await #expect(throws: ArchiveBrowserError.zip(.invalidZIP)) { try await session.entries() }
        #expect(start.duration(to: .now) < .seconds(2))
        await session.close()
    }

    @Test func changedSourceAfterPlanningNeverCommitsExport() async throws {
        let (root, source, engine) = try fixture()
        let session = ArchiveBrowserSession(source: source, staging: engine.staging)
        let first = try #require(try await session.entries().first(where: { $0.path == "content/first.txt" }))
        let destination = root.appending(path: "changed-output.txt")
        let batch = try await session.batch(
            entryIDs: [first.id], password: nil, to: destination, operation: .archiveExtract)
        let writer = try FileHandle(forWritingTo: source)
        try writer.seekToEnd()
        try writer.write(contentsOf: [0])
        try writer.close()
        let outcome = await engine.run(batch, settings: Settings()) { _ in }
        guard case .failed = try #require(outcome.outcomes.first) else {
            Issue.record("Changed source was accepted")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        await session.close()
    }

    @Test func changedSourceRefusesPreview() async throws {
        let (_, source, engine) = try fixture()
        let session = ArchiveBrowserSession(source: source, staging: engine.staging)
        let listed = try await session.entries()
        let first = try #require(listed.first(where: { $0.path == "content/first.txt" }))
        let output = try FileHandle(forWritingTo: source)
        try output.seekToEnd()
        try output.write(contentsOf: [0])
        try output.close()
        await #expect(throws: ArchiveBrowserError.sourceChanged) {
            _ = try await session.preview(entryID: first.id, password: nil)
        }
        await session.close()
    }
}
