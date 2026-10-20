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

    private func multitrackMatroska(duplicateVideo: Bool) throws -> URL {
        let folder = try multitrackFolder()
        let url = folder.appending(path: "multiple.mkv")
        let video = MediaTrack(number: 1, kind: .video(width: 64, height: 48), codec: .vp9)
        let audio = MediaTrack(number: 2, kind: .audio(sampleRate: 48_000, channels: 2), codec: .opus)
        var duplicate = duplicateVideo ? video : audio
        duplicate.number = 3
        var muxer = try MatroskaMuxer(url: url, tracks: [video, audio, duplicate], webm: false)
        try muxer.write(MediaPacket(track: 1, timestamp: 0, isKeyframe: true, payload: Data([1])))
        try muxer.write(MediaPacket(track: 2, timestamp: 0, isKeyframe: true, payload: Data([2])))
        try muxer.write(MediaPacket(track: 3, timestamp: 0, isKeyframe: true, payload: Data([3])))
        try muxer.finish()
        return url
    }

    private func multitrackFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MacEaseMultiTrack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test(arguments: [true, false])
    func replacementPreservesMultiTrackMatroska(duplicateVideo: Bool) async throws {
        let url = try multitrackMatroska(duplicateVideo: duplicateVideo)
        defer {
            #expect(throws: Never.self) { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
        let original = try Data(contentsOf: url)
        #expect(try await run(.videoRemoveAudio, preset: nil, on: url) == .failed(.invalidInput(.multipleTracks)))
        #expect(
            try await run(.videoCompress, preset: "quality-high", on: url) == .failed(.invalidInput(.multipleTracks)))
        #expect(try Data(contentsOf: url) == original)
    }

    @Test(arguments: [true, false])
    func replacementPreservesMultiTrackAVAsset(duplicateVideo: Bool) async throws {
        let folder = try multitrackFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "ffmpeg-h264-aac.mp4")
        let fixture = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac", withExtension: "mp4", subdirectory: "Resources"))
        try FileManager.default.copyItem(at: fixture, to: source)
        let asset = AVURLAsset(url: source)
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        for mediaType in [AVMediaType.video, .audio] {
            let original = try #require(try await asset.loadTracks(withMediaType: mediaType).first)
            let copies = (mediaType == .video) == duplicateVideo ? 2 : 1
            for _ in 0..<copies {
                let track = try #require(
                    composition.addMutableTrack(
                        withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid))
                try track.insertTimeRange(range, of: original, at: .zero)
            }
        }
        let url = source.deletingLastPathComponent().appending(path: "multiple.mov")
        let exporter = try #require(
            AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await exporter.export(to: url, as: .mov)
        let multi = AVURLAsset(url: url)
        let kind: AVMediaType = duplicateVideo ? .video : .audio
        #expect(try await multi.loadTracks(withMediaType: kind).count == 2)
        let original = try Data(contentsOf: url)
        #expect(try await run(.videoRemoveAudio, preset: nil, on: url) == .failed(.invalidInput(.multipleTracks)))
        #expect(try Data(contentsOf: url) == original)
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

    @Test func previewReportsDurationSizeAndScaledFrames() async throws {
        let url = try fixture("ffmpeg-h264-aac.mp4")
        let preview = try await MediaPreview(videoAt: url)
        #expect(preview.durationSeconds > 1)
        #expect(preview.displayWidth == 160 && preview.displayHeight == 96)
        let frames = try await preview.frames(at: [0, preview.durationSeconds], width: 80)
        #expect(frames.map(\.width) == [80, 80])
    }
}
