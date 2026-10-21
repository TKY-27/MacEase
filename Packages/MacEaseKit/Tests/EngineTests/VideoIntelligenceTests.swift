import AVFoundation
import Formats
import Foundation
import MenuCatalog
import Speech
import Testing

@testable import Engine

@Suite(.serialized) struct VideoIntelligenceTests {
    private func fixture(_ name: String) throws -> URL {
        let source = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"))
        let copy = try TestVolume.makeFolder().appending(path: name)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    private func run(_ op: OperationID, preset: String, on url: URL) async throws -> URL {
        let options = try #require(OperationPlanner.options(for: op, preset: preset, settings: Settings()))
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseSupport-\(UUID().uuidString)")
        TestTemporaryFolders.register(support)
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let batch = OperationPlanner.batch(
            for: OperationRequest(op: op, options: options, inputs: [url]), settings: Settings())
        let outcome = await engine.run(batch, settings: Settings()) { _ in }
        guard case .succeeded(let outputs, _) = outcome.outcomes.first, let output = outputs.first else {
            Issue.record("expected success, got \(String(describing: outcome.outcomes.first))")
            throw CancellationError()
        }
        return output
    }

    @Test func greenBackgroundReplacesEverythingWithoutAPerson() async throws {
        let url = try fixture("ffmpeg-h264-aac.mp4")
        let output = try await run(.videoBackground, preset: "green", on: url)
        #expect(output.lastPathComponent == "ffmpeg-h264-aac (background removed).mp4")
        let (frame, _) = try await AVAssetImageGenerator(asset: AVURLAsset(url: output)).image(at: .zero)
        let pixels = try PixelBuffer(cgImage: frame)
        let center = (pixels.height / 2 * pixels.width + pixels.width / 2) * 4
        let green = RGBColor.chromaGreen
        #expect(abs(Int(pixels.rgba[center + 1]) - Int(green.green)) < 20)
        #expect(abs(Int(pixels.rgba[center]) - Int(green.red)) < 20)
    }

    @Test func removalWritesHEVCWithAlphaInMOV() async throws {
        let url = try fixture("ffmpeg-h264-aac.mp4")
        let output = try await run(.videoBackground, preset: "remove", on: url)
        #expect(output.pathExtension == "mov")
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        let alpha = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel)
        #expect(alpha as? Bool == true)
    }

    @Test(.requires(.speechAssets) { SpeechTranscriber.isAvailable })
    func subtitlesTranscribeTheSoundtrack() async throws {
        let folder = try TestVolume.makeFolder()
        let speech = folder.appending(path: "speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", speech.path, "The weather is nice today."]
        try say.run()
        say.waitUntilExit()
        let video = try fixture("ffmpeg-h264-aac.mp4")
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let speechAsset = AVURLAsset(url: speech)
        let speechTrack = try #require(try await speechAsset.loadTracks(withMediaType: .audio).first)
        let videoTrack = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
        let duration = try await speechAsset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(
                CMTimeRange(start: .zero, duration: try await videoAsset.load(.duration)), of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: speechTrack, at: .zero)
        let clip = folder.appending(path: "talk.mp4")
        let export = try #require(
            AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        try await export.export(to: clip, as: .mp4)

        let subtitles = try await run(.videoSubtitles, preset: "srt", on: clip)
        #expect(subtitles.lastPathComponent == "talk.srt")
        let text = try String(contentsOf: subtitles, encoding: .utf8)
        #expect(text.hasPrefix("1\n00:00:0"))
        #expect(text.lowercased().contains("weather"))
    }
}
