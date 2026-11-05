import AVFoundation
import Formats
import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite struct AudioMetadataLossTests {
    @Test(arguments: [AudioFormat.mp3, .flac, .ogg, .opus, .m4aAAC], [Settings.OutputMode.replace, .newFile])
    func unsupportedMusicTagsRespectOutputMode(format: AudioFormat, mode: Settings.OutputMode) async throws {
        let folder = try TestVolume.makeFolder()
        let original = folder.appending(path: "original." + format.fileExtension)
        let source = folder.appending(path: "tagged." + format.fileExtension)
        let tags = AudioTags(title: "Song", artist: "Artist", album: "Album")
        try await AudioSignals.write(
            AudioSignals.music(seconds: 0.2), to: original, format: format, tags: tags)
        let root = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../..", directoryHint: .isDirectory).standardizedFileURL
        let tools = try MediaDownloadTools(directory: root.appending(path: "Vendor/build/media-tools/bin"))
        _ = try await MediaToolProcess().run(
            executable: tools.ffmpeg,
            arguments: [
                "-nostdin", "-v", "error", "-n", "-i", original.path, "-map", "0", "-c", "copy",
                "-metadata", "genre=Jazz", "-metadata", "date=2026", "-metadata", "track=3/12", source.path,
            ], directory: folder, tools: tools, captureOutput: false)
        #expect(try await AudioMetadataLoss.hasUnsupportedTags(source))
        let saved = try Data(contentsOf: source)
        var settings = Settings()
        settings.outputMode = mode
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let target: AudioFormat = format == .flac ? .m4aALAC : .flac
        let request = OperationRequest(op: .audioConvert, options: .audio(.convert(target)), inputs: [source])
        let outcome = await engine.run(
            OperationPlanner.batch(for: request, settings: settings), settings: settings
        ) { _ in }
        #expect(try Data(contentsOf: source) == saved)
        if mode == .replace {
            #expect(outcome.outcomes == [.failed(.audioMetadataUnsupported)])
            #expect(outcome.record == nil)
        } else {
            guard case .succeeded(let outputs, let warnings) = outcome.outcomes.first,
                let output = outputs.first
            else {
                Issue.record("Expected a new file with a metadata warning: \(outcome.outcomes)")
                return
            }
            #expect(warnings == [.metadataDropped])
            #expect(try await AudioInput(url: output).tags() == tags)
            #expect(try !AudioSignals.decode(output).samples.isEmpty)
        }
    }

    @Test(arguments: [AudioFormat.mp3, .flac, .ogg, .opus, .m4aAAC, .wav, .aiff, .aac, .cafPCM, .cafALAC])
    func supportedTagsAndEncodingProvenanceDoNotRefuseReplacement(format: AudioFormat) async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "source." + format.fileExtension)
        try await AudioSignals.write(
            AudioSignals.music(seconds: 0.2), to: source, format: format,
            tags: AudioTags(title: "Song", artist: "Artist", album: "Album"))
        let identifiers = try await AVURLAsset(url: source).load(.metadata).map { $0.identifier?.rawValue ?? "unknown" }
        #expect(try await !AudioMetadataLoss.hasUnsupportedTags(source), "Metadata: \(identifiers)")
    }
}
