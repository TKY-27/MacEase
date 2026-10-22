import AVFoundation
import Foundation
import MenuCatalog
import Synchronization
import Testing

@testable import Engine

@Suite(.serialized) struct OutputModeTests {
    @Test(arguments: [
        (OperationID.imageConvert, ImageOperation.convert(ImageConversion(format: .jpeg)), "photo.jpg"),
        (.imageResize, .resize(ImageResize(size: .percent(50))), "photo_resized.png"),
    ])
    func imageEditsKeepOriginal(op: OperationID, operation: ImageOperation, name: String) async throws {
        let source = try TestVolume.makeFolder().appending(path: "photo.png")
        try ImageFixtures.write([ImageFixtures.photo()], as: .png, to: source)
        let request = OperationRequest(op: op, options: .image(operation), inputs: [source])
        try await verifyNewFile(request, named: name) { output in
            let image = try ImageFixtures.image(output)
            #expect(image.width == (op == .imageResize ? 320 : 640))
            #expect(image.height == (op == .imageResize ? 240 : 480))
        }
    }

    @Test func videoRotationKeepsOriginal() async throws {
        let fixture = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac", withExtension: "mp4", subdirectory: "Resources"))
        let source = try TestVolume.makeFolder().appending(path: "clip.mp4")
        try FileManager.default.copyItem(at: fixture, to: source)
        let request = OperationRequest(
            op: .videoRotate, options: .video(.rotate(degrees: 90, fill: .black)), inputs: [source])
        try await verifyNewFile(request, named: "clip_rotated.mp4") { output in
            let originalTrack = try #require(try await AVURLAsset(url: source).loadTracks(withMediaType: .video).first)
            let rotatedTrack = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
            let originalTransform = try await originalTrack.load(.preferredTransform)
            #expect(try await rotatedTrack.load(.preferredTransform) != originalTransform)
        }
    }

    @Test func audioNormalizationKeepsOriginal() async throws {
        let source = try TestVolume.makeFolder().appending(path: "tone.wav")
        try await AudioSignals.write(AudioSignals.music().map { $0 / 10 }, to: source, format: .wav)
        let request = OperationRequest(
            op: .audioNormalize, options: .audio(.normalize(targetLoudness: -14)), inputs: [source])
        try await verifyNewFile(request, named: "tone_normalized.wav") { output in
            let originalSamples = try AudioSignals.decode(source).samples
            let normalizedSamples = try AudioSignals.decode(output).samples
            #expect(originalSamples != normalizedSamples)
        }
    }

    @Test func sameExtensionConversionUsesSuffix() async throws {
        let source = try TestVolume.makeFolder().appending(path: "tone.m4a")
        try await AudioSignals.write(AudioSignals.music(), to: source, format: .m4aALAC)
        let request = OperationRequest(op: .audioConvert, options: .audio(.convert(.m4aAAC)), inputs: [source])
        try await verifyNewFile(request, named: "tone_converted.m4a") { output in
            let originalFormat = try AudioInput(url: source).exactFormat
            let outputFormat = try AudioInput(url: output).exactFormat
            #expect(outputFormat == .m4aAAC)
            #expect(originalFormat == .m4aALAC)
        }
    }

    @Test(arguments: [
        (TextEncodingTarget.utf8, "utf8"), (.utf8BOM, "utf8bom"), (.utf16, "utf16"), (.shiftJIS, "sjis"),
    ])
    func textEncodingKeepsOriginal(target: TextEncodingTarget, suffix: String) async throws {
        let source = try TestVolume.makeFolder().appending(path: "notes.txt")
        let originalText = "日本語\n"
        if target == .utf8 {
            try (Data([0xEF, 0xBB, 0xBF]) + Data(originalText.utf8)).write(to: source)
        } else {
            try Data(originalText.utf8).write(to: source)
        }
        let request = OperationRequest(
            op: .textEncoding, options: .text(.encoding(target, source: nil)), inputs: [source])
        try await verifyNewFile(request, named: "notes_\(suffix).txt") { output in
            let decoded = try TextEncoding.decode(Data(contentsOf: output))
            #expect(decoded.text == originalText)
        }
    }

    @Test(arguments: [
        (TextOperation.lineEndings(.lf), OperationID.textLineEndings, "notes_lf.txt", "a\nb\n", "a\r\nb\r\n"),
        (.lineEndings(.crlf), .textLineEndings, "notes_crlf.txt", "a\r\nb\r\n", "a\nb\n"),
        (.json(.pretty), .textJSON, "notes_pretty.json", "{\n  \"b\": 2,\n  \"a\": 1\n}\n", "{\"b\":2,\"a\":1}"),
        (.json(.minify), .textJSON, "notes_min.json", "{\"b\":2,\"a\":1}", "{ \"b\": 2, \"a\": 1 }"),
        (.json(.sortKeys), .textJSON, "notes_sorted.json", "{\n  \"a\": 1,\n  \"b\": 2\n}\n", "{\"b\":2,\"a\":1}"),
    ])
    func textEditsUseOperationSuffix(
        operation: TextOperation, op: OperationID, name: String, expected: String, original: String
    ) async throws {
        let source = try TestVolume.makeFolder().appending(path: op == .textJSON ? "notes.json" : "notes.txt")
        try Data(original.utf8).write(to: source)
        let request = OperationRequest(op: op, options: .text(operation), inputs: [source])
        try await verifyNewFile(request, named: name) { output in
            let text = try String(contentsOf: output, encoding: .utf8)
            #expect(text == expected)
        }
    }

    func verifyNewFile(
        _ request: OperationRequest, named name: String, verifyOutput: (URL) async throws -> Void
    ) async throws {
        let source = try #require(request.inputs.first)
        let original = try Data(contentsOf: source)
        let stamp = try FileStamp(of: source, includingIdentity: true)
        let creationDate = try source.resourceValues(forKeys: [.creationDateKey]).creationDate
        let engine = try ImageFixtures.engine()
        let settings = Settings()
        let output = source.deletingLastPathComponent().appending(path: name)
        let numbered = output.deletingLastPathComponent()
            .appending(path: output.deletingPathExtension().lastPathComponent + " (2)")
            .appendingPathExtension(output.pathExtension)
        var outcomes: [BatchOutcome] = []
        for expected in [output, numbered] {
            let batch = OperationPlanner.batch(for: request, settings: settings)
            let outcome = await engine.run(batch, settings: settings) { _ in }
            #expect(try ImageFixtures.output(of: outcome) == expected)
            #expect(!outcome.historyFailed)
            let record = try #require(outcome.record)
            #expect(record.items == [.derived(output: expected.path, stamp: try FileStamp(of: expected))])
            #expect(try Data(contentsOf: source) == original)
            #expect(try FileStamp(of: source, includingIdentity: true) == stamp)
            #expect(try source.resourceValues(forKeys: [.creationDateKey]).creationDate == creationDate)
            try await verifyOutput(expected)
            outcomes.append(outcome)
        }
        for outcome in outcomes.reversed() {
            #expect(try await engine.undo(outcome.batchID) == [.restored])
        }
        #expect(!FileManager.default.fileExists(atPath: numbered.path))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: source) == original)
        #expect(try FileStamp(of: source, includingIdentity: true) == stamp)
    }
}

@Suite struct OutputModeSafetyTests {
    @Test func retriesWhenAnotherWriterTakesTheReservedName() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "notes.txt")
        let staged = folder.appending(path: "staged.txt")
        let occupied = folder.appending(path: "notes_lf.txt")
        try Data("original".utf8).write(to: source)
        try Data("converted".utf8).write(to: staged)
        let stamp = try FileStamp(of: source)
        let presenter = OutputCollisionPresenter(source: source, destination: occupied)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let committed = try await FileCommitter().derive(
            StagedFile(url: staged, name: "notes_lf.txt", check: .text(.utf8)), nextTo: source, expectedStamp: stamp)
        try #require(presenter.creation.withLock { $0 }).get()
        #expect(committed.output.lastPathComponent == "notes_lf (2).txt")
        #expect(try String(contentsOf: occupied, encoding: .utf8) == "other writer")
        #expect(try String(contentsOf: committed.output, encoding: .utf8) == "converted")
        #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    }

    @Test func plannedModeSurvivesSettingsChangeAndConcurrentCollisions() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "notes.txt")
        let occupied = folder.appending(path: "notes_lf.txt")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
        try Data("original\r\n".utf8).write(to: source)
        let settings = Settings()
        let request = OperationRequest(op: .textLineEndings, options: .text(.lineEndings(.lf)), inputs: [source])
        let firstBatch = OperationPlanner.batch(for: request, settings: settings)
        let secondBatch = OperationPlanner.batch(for: request, settings: settings)
        var changedSettings = settings
        changedSettings.outputMode = .replace
        let firstEngine = try ImageFixtures.engine()
        let secondEngine = try ImageFixtures.engine()
        async let firstRun = firstEngine.run(firstBatch, settings: changedSettings) { _ in }
        async let secondRun = secondEngine.run(secondBatch, settings: changedSettings) { _ in }
        let outcomes = await [firstRun, secondRun]
        let outputs = try outcomes.map { try ImageFixtures.output(of: $0) }
        #expect(Set(outputs.map(\.lastPathComponent)) == ["notes_lf (2).txt", "notes_lf (3).txt"])
        #expect(try String(contentsOf: source, encoding: .utf8) == "original\r\n")
        #expect(try occupied.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        #expect(try await firstEngine.undo(firstBatch.id) == [.restored])
        #expect(try await secondEngine.undo(secondBatch.id) == [.restored])
        #expect(outputs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func undoPreservesAnEditedNewFile() async throws {
        let source = try TestVolume.makeFolder().appending(path: "notes.txt")
        try Data("original\r\n".utf8).write(to: source)
        let settings = Settings()
        let engine = try ImageFixtures.engine()
        let request = OperationRequest(op: .textLineEndings, options: .text(.lineEndings(.lf)), inputs: [source])
        let outcome = await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) {
            _ in
        }
        let output = try ImageFixtures.output(of: outcome)
        let edited = "edited after conversion\n"
        try Data(edited.utf8).write(to: output)
        #expect(try await engine.undo(outcome.batchID) == [.skipped(.undoOutputChanged, path: output.path)])
        #expect(try String(contentsOf: output, encoding: .utf8) == edited)
        #expect(try String(contentsOf: source, encoding: .utf8) == "original\r\n")
    }

    @Test(arguments: [false, true])
    func refusesChangedInputAndInvalidOutput(invalidOutput: Bool) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "notes.txt")
        try Data("original".utf8).write(to: source)
        var workItem = WorkItem(inputs: [source]) { context in
            let staged = try context.stagingURL(for: source, name: "notes.txt")
            try Data(invalidOutput ? [0xFF] : Array("output".utf8)).write(to: staged)
            if !invalidOutput { try Data("changed after scan".utf8).write(to: source) }
            return .replace(original: source, output: StagedFile(url: staged, name: "notes.txt", check: .text(.utf8)))
        }
        workItem.newFileNaming = .edit("lf")
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let outcome = await engine.run(
            Batch(operation: .textLineEndings, items: [workItem]), settings: Settings()
        ) { _ in }
        if invalidOutput {
            #expect(outcome.outcomes == [.failed(.encodeFailed("output text is not valid in its encoding"))])
        } else {
            #expect(outcome.outcomes == [.skipped(.changedSinceScan)])
        }
        #expect(outcome.record == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "notes_lf.txt").path))
        #expect(try String(contentsOf: source, encoding: .utf8) == (invalidOutput ? "original" : "changed after scan"))
    }
}

private final class OutputCollisionPresenter: NSObject, NSFilePresenter, Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    let creation = Mutex<Result<Void, any Error>?>(nil)
    private let destination: URL

    init(source: URL, destination: URL) {
        presentedItemURL = source
        self.destination = destination
    }

    func relinquishPresentedItem(toReader reader: @Sendable ((@Sendable () -> Void)?) -> Void) {
        creation.withLock { result in
            guard result == nil else { return }
            result = Result { try Data("other writer".utf8).write(to: destination, options: .withoutOverwriting) }
        }
        reader(nil)
    }
}
