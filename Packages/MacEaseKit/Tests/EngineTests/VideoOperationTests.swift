import AVFoundation
import Formats
import Foundation
import ImageIO
import MenuCatalog
import Testing

@testable import Engine

@Suite(.serialized) struct VideoOperationTests {
    private func fixture(_ name: String) throws -> URL {
        let source = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"))
        let copy = try TestVolume.makeFolder().appending(path: name)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    private func run(_ op: OperationID, preset: String?, on url: URL) async throws -> ItemOutcome {
        let options = try #require(OperationPlanner.options(for: op, preset: preset, settings: Settings()))
        return try await run(op, options: options, on: url)
    }

    private func run(_ op: OperationID, options: OperationOptions, on url: URL) async throws -> ItemOutcome {
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseSupport-\(UUID().uuidString)")
        let engine = try JobEngine(supportDirectory: support, concurrency: 2)
        let batch = OperationPlanner.batch(
            for: OperationRequest(op: op, options: options, inputs: [url]), settings: Settings())
        let outcome = await engine.run(batch, settings: Settings()) { _ in }
        return try #require(outcome.outcomes.first)
    }

    private func output(_ outcome: ItemOutcome) throws -> URL {
        guard case .succeeded(let outputs, _) = outcome, let first = outputs.first else {
            Issue.record("expected success, got \(outcome)")
            throw CancellationError()
        }
        return first
    }

    @Test func removeAudioKeepsVideoOnly() async throws {
        let url = try fixture("ffmpeg-h264-aac.mp4")
        let result = try output(try await run(.videoRemoveAudio, preset: nil, on: url))
        let asset = AVURLAsset(url: result)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await run(.videoRemoveAudio, preset: nil, on: result) == .skipped(.nothingToRemove))
    }

    @Test func rotateRightAngleInMOVOnlyChangesTheTransform() async throws {
        let url = try fixture("ffmpeg-h264-aac.mp4")
        let before = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let result = try output(try await run(.videoRotate, preset: "right-90", on: url))
        let track = try #require(try await AVURLAsset(url: result).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        #expect(abs(size.width) == 96 && abs(size.height) == 160)
        #expect(try #require(try result.resourceValues(forKeys: [.fileSizeKey]).fileSize) < before + 4096)
    }

    @Test func resizeHalvesAndRefusesUpscale() async throws {
        let url = try fixture("ffmpeg-h264-aac.mp4")
        let result = try output(try await run(.videoResize, preset: "percent-50", on: url))
        let track = try #require(try await AVURLAsset(url: result).loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 80, height: 48))
        #expect(try await run(.videoResize, preset: "1080p", on: result) == .skipped(.noUpscale))
    }

    @Test func convertsToEveryContainerThatHoldsTheStreams() async throws {
        for target in ["mkv", "mov", "m4v"] {
            let url = try fixture("ffmpeg-h264-aac.mp4")
            let result = try output(try await run(.videoConvert, preset: target, on: url))
            #expect(result.pathExtension == target)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func thumbnailAndAnimationsAreDerived() async throws {
        let url = try fixture("ffmpeg-rotated.mov")
        let still = try output(try await run(.videoThumbnail, preset: "middle", on: url))
        let image = try #require(CGImageSourceCreateWithURL(still as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 96)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 160)
        let picture = try #require(CGImageSourceCreateImageAtIndex(image, 0, nil))
        let pixels = try PixelBuffer(cgImage: picture)
        func isYellow(_ x: Int, _ y: Int) -> Bool {
            let base = (y * pixels.width + x) * 4
            return pixels.rgba[base] > 180 && pixels.rgba[base + 1] > 180 && pixels.rgba[base + 2] < 80
        }
        // ffmpeg shows rows 60–79 yellow.
        #expect(isYellow(48, 70))
        #expect(!isYellow(48, 90))
        #expect(FileManager.default.fileExists(atPath: url.path))

        let gif = try output(try await run(.videoToGIF, preset: "480-10", on: url))
        let gifSource = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(gifSource) == 20)
        let apng = try output(try await run(.videoToAPNG, preset: "480-15", on: url))
        let apngSource = try #require(CGImageSourceCreateWithURL(apng as CFURL, nil))
        #expect(CGImageSourceGetCount(apngSource) == 30)
    }

    @Test func exactTrimReencodesTheRange() async throws {
        let url = try fixture("ffmpeg-h264-aac.mp4")
        let options = OperationOptions.video(.trim(start: 0.5, end: 1.5, mode: .exact))
        let result = try output(try await run(.videoTrim, options: options, on: url))
        let duration = try await AVURLAsset(url: result).load(.duration).seconds
        #expect(abs(duration - 1) < 0.1)
    }
}
