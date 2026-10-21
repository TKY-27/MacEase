import Darwin
import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite struct InputValidationTests {
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MacEaseInput-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test(arguments: [OperationID.anyChecksum, .audioConvert, .folderRename], [false, true])
    func refusesFIFOWithoutWriter(op: OperationID, throughSymlink: Bool) async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fifo = folder.appending(path: "pipe.opus")
        let permissions = mode_t(S_IRUSR | S_IWUSR)
        try #require(mkfifo(fifo.path, permissions) == 0)
        let input: URL
        if throughSymlink {
            input = folder.appending(path: "link.opus")
            try FileManager.default.createSymbolicLink(at: input, withDestinationURL: fifo)
        } else {
            input = fifo
        }
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let clock = ContinuousClock()
        let started = clock.now
        #expect(throws: EngineError.invalidInput(.unsupportedFileType)) {
            try OperationPlanner.validateInput(input)
        }
        #expect(throws: EngineError.invalidInput(.unsupportedFileType)) {
            try ContentSniffer.matches(input, kind: op.kind)
        }
        let options: OperationOptions
        switch op {
        case .anyChecksum: options = .checksum(.sha256)
        case .audioConvert: options = .audio(.convert(.wav))
        case .folderRename: options = .rename([RenamePlan(url: input, newName: "renamed.opus")])
        default:
            Issue.record("Unexpected test operation")
            return
        }
        let request = OperationRequest(op: op, options: options, inputs: [input])

        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: Settings()), settings: Settings())
        {
            _ in
        }

        // Blocked opens never return; load only slows.
        let promptReturnLimit = Duration.seconds(30)
        #expect(started.duration(to: clock.now) < promptReturnLimit)
        #expect(outcome.outcomes == [.failed(.invalidInput(.unsupportedFileType))])
        #expect(outcome.record == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "renamed.opus").path))
    }

    @Test func refusesCharacterDevices() {
        let device = URL(filePath: "/dev/null")
        #expect(throws: EngineError.invalidInput(.unsupportedFileType)) {
            try OperationPlanner.validateInput(device)
        }
        #expect(throws: EngineError.invalidInput(.unsupportedFileType)) {
            try ContentSniffer.matches(device, kind: .any)
        }
    }

    @Test func keepsMixedChecksumInputsInOneBatch() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fifo = folder.appending(path: "pipe.txt")
        let permissions = mode_t(S_IRUSR | S_IWUSR)
        try #require(mkfifo(fifo.path, permissions) == 0)
        let file = folder.appending(path: "hello.txt")
        try Data("hello".utf8).write(to: file)
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let request = OperationRequest(op: .anyChecksum, options: .checksum(.sha256), inputs: [fifo, file])

        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: Settings()), settings: Settings())
        {
            _ in
        }

        #expect(outcome.inputs == [[fifo], [file]])
        #expect(
            outcome.outcomes == [.failed(.invalidInput(.unsupportedFileType)), .succeeded(outputs: [], warnings: [])])
        #expect(outcome.clipboardText == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824  hello.txt")
    }

    @Test func refusesFIFOInEXIFRenamePreview() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fifo = folder.appending(path: "photo.jpg")
        let permissions = mode_t(S_IRUSR | S_IWUSR)
        try #require(mkfifo(fifo.path, permissions) == 0)
        let targets = try RenameRules.targets(for: [folder])
        #expect(targets == [fifo])
        let rules = RenameRules(date: .exif)
        let clock = ContinuousClock()
        let started = clock.now

        #expect(throws: EngineError.invalidInput(.unsupportedFileType)) {
            try rules.plans(for: targets)
        }

        let promptReturnLimit = Duration.seconds(2)
        #expect(started.duration(to: clock.now) < promptReturnLimit)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [fifo.lastPathComponent])
    }

    @Test func rejectsAFileReplacedByFIFOBeforePreview() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "preview.txt")
        try Data("preview".utf8).write(to: file)
        try OperationPlanner.validateInput(file)
        try FileManager.default.removeItem(at: file)
        let permissions = mode_t(S_IRUSR | S_IWUSR)
        try #require(mkfifo(file.path, permissions) == 0)

        #expect(throws: EngineError.invalidInput(.unsupportedFileType)) {
            try OperationPlanner.validateInput(file)
        }
        #expect(throws: EngineError.invalidInput(.unsupportedFileType)) {
            try ContentSniffer.matches(file, kind: .text)
        }
    }

    @Test func acceptsRegularFilesAndDirectoriesThroughSymlinks() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "plain.txt")
        try Data("plain text".utf8).write(to: file)
        let fileLink = folder.appending(path: "file.txt")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: file)
        let directoryLink = folder.appending(path: "directory")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: folder)

        for input in [file, fileLink, folder, directoryLink] { try OperationPlanner.validateInput(input) }
        #expect(try ContentSniffer.matches(fileLink, kind: .text))
        #expect(try ContentSniffer.matches(directoryLink, kind: .folder))
        #expect(try !ContentSniffer.matches(directoryLink, kind: .any))
    }
}
