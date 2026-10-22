import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite struct U2SelectionPlannerTests {
    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MacEase-U2-\(UUID().uuidString)")
        TestTemporaryFolders.register(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test(arguments: [OperationID.videoTrim, .audioTrim, .pdfExtractPages, .imageCopyBase64])
    func staleMultiSelectionFailsBeforeReadingFiles(op: OperationID) async throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let suffix: String
        let options: OperationOptions
        switch op {
        case .videoTrim:
            suffix = "mov"
            options = .video(.trim(start: 0, end: 1, mode: .keyframe))
        case .audioTrim:
            suffix = "wav"
            options = .audio(.trim(start: 0, end: 1))
        case .pdfExtractPages:
            suffix = "pdf"
            options = .pdf(.extractPages(IndexSet(integer: 0)))
        case .imageCopyBase64:
            suffix = "png"
            options = .image(.copyBase64)
        default:
            Issue.record("Unexpected single-input operation")
            return
        }
        let inputs = ["first", "second"].map { directory.appending(path: "\($0).\(suffix)") }
        let request = OperationRequest(op: op, options: options, inputs: inputs)
        let batch = OperationPlanner.batch(for: request, settings: Settings())
        let rejected = try #require(batch.items.first)
        #expect(batch.items.count == 1)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: directory), progress: { _ in })
        do {
            _ = try await rejected.body(context)
            Issue.record("Expected selection rejection")
        } catch EngineError.invalidInput(.malformed(let explanation)) {
            #expect(!explanation.isEmpty)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func explicitExtractRateNeverRoundsToAnotherBitrate() async throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let fixture = try #require(
            Bundle.module.url(
                forResource: "ffmpeg-h264-aac", withExtension: "mp4", subdirectory: "Resources"))
        let source = directory.appending(path: "source.mp4")
        try FileManager.default.copyItem(at: fixture, to: source)
        let original = try Data(contentsOf: source)
        var settings = Settings()
        settings.audio.extractedAudioBitrate = 64
        let options = try #require(OperationPlanner.options(for: .videoExtractAudio, preset: "mp3", settings: settings))
        let request = OperationRequest(op: .videoExtractAudio, options: options, inputs: [source])
        let batch = OperationPlanner.batch(for: request, settings: settings)
        let planned = try #require(batch.items.first)
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: directory), progress: { _ in })
        await #expect(
            throws: EngineError.invalidInput(
                .malformed(
                    String(
                        localized: "The selected audio bitrate is unavailable for this format and source.",
                        comment: "Prevents silent bitrate changes")))
        ) { try await planned.body(context) }
        #expect(try Data(contentsOf: source) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["source.mp4"])
    }

    @Test func deriveTXTDecodesContentAndKeepsSource() async throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let source = directory.appending(path: "notes.md")
        let text = "# Notes\n日本語 **unchanged**\n"
        let encoded = Data([0xFF, 0xFE]) + Data(try #require(text.data(using: .utf16LittleEndian)))
        try encoded.write(to: source)
        let settings = Settings()
        let options = try #require(OperationPlanner.options(for: .textConvert, preset: "txt", settings: settings))
        let request = OperationRequest(op: .textConvert, options: options, inputs: [source])
        let batch = OperationPlanner.batch(for: request, settings: settings)
        let planned = try #require(batch.items.first)
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: directory), progress: { _ in })
        defer { context.removeStaging() }
        let result = try await planned.body(context)
        guard case .derived(let parent, let outputs) = result else {
            Issue.record("Expected derived TXT output")
            return
        }
        #expect(parent == source)
        let output = try #require(outputs.first)
        #expect(output.name == "notes.txt")
        #expect(try Data(contentsOf: output.url) == Data(text.utf8))
        #expect(try Data(contentsOf: source) == encoded)
    }

    @Test func ambiguousTXTConversionAcceptsExplicitSourceEncoding() async throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let source = directory.appending(path: "legacy.md")
        let encoded = Data([0xA4, 0xA2])
        #expect(String(data: encoded, encoding: TextEncoding.cp932) != nil)
        #expect(String(data: encoded, encoding: .japaneseEUC) == "あ")
        try encoded.write(to: source)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: directory), progress: { _ in })
        defer { context.removeStaging() }
        let automatic = OperationRequest(op: .textConvert, options: .text(.convert(.toTXT)), inputs: [source])
        let undecided = try #require(OperationPlanner.batch(for: automatic, settings: Settings()).items.first)
        await #expect(throws: EngineError.invalidInput(.textEncodingUndetected)) { try await undecided.body(context) }
        let explicit = OperationRequest(
            op: .textConvert,
            options: .text(.convert(.toTXT, source: .eucJP)), inputs: [source])
        let decided = try #require(OperationPlanner.batch(for: explicit, settings: Settings()).items.first)
        let result = try await decided.body(context)
        guard case .derived(_, let outputs) = result else {
            Issue.record("Expected decoded TXT output")
            return
        }
        let output = try #require(outputs.first)
        #expect(try Data(contentsOf: output.url) == Data("あ".utf8))
        #expect(try Data(contentsOf: source) == encoded)
    }

    @Test func textConversionRejectsStaleSourceFormats() async throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let source = directory.appending(path: "notes.txt")
        try Data("name,value\nfirst,second\n".utf8).write(to: source)
        let request = OperationRequest(op: .textConvert, options: .text(.convert(.csvToJSON)), inputs: [source])
        let batch = OperationPlanner.batch(for: request, settings: Settings())
        let planned = try #require(batch.items.first)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: directory), progress: { _ in })
        await #expect(throws: EngineError.invalidInput(.unsupportedFileType)) { try await planned.body(context) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["notes.txt"])
    }
}
