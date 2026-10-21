import AVFoundation
import CoreVideo
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

    private func transparentVideo(in container: OutputContainer = .mov) async throws -> URL {
        let url = try TestVolume.makeFolder().appending(path: "transparent.\(container.fileExtension)")
        let width = 64
        let height = 48
        let frameDuration = Nanoseconds.perSecond / 12
        var encoding = VideoEncoding(
            codec: container == .webm ? .vp9 : .hevc, width: width, height: height, frameDuration: frameDuration,
            bitrate: nil)
        encoding.alpha = true
        var encoder = try VideoEncoders.make(encoding, track: 1)
        var packets: [MediaPacket] = []
        for index in 0..<12 {
            var image: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]] as CFDictionary
            try #require(
                CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &image)
                    == kCVReturnSuccess)
            let frame = try #require(image)
            try #require(CVPixelBufferLockBaseAddress(frame, []) == kCVReturnSuccess)
            do {
                defer { CVPixelBufferUnlockBaseAddress(frame, []) }
                let pixels = try #require(CVPixelBufferGetBaseAddress(frame)).assumingMemoryBound(to: UInt8.self)
                let rowBytes = CVPixelBufferGetBytesPerRow(frame)
                for y in 0..<height {
                    for x in 0..<width {
                        let offset = y * rowBytes + x * 4
                        pixels[offset] = x < width / 2 ? 0 : 240
                        pixels[offset + 1] = 0
                        pixels[offset + 2] = 0
                        pixels[offset + 3] = x < width / 2 ? 0 : 255
                    }
                }
            }
            packets += try encoder.encode(frame, timestamp: Int64(index) * frameDuration)
        }
        packets += try encoder.finish()
        let output = OutputTrack(track: encoder.track, format: encoder.formatDescription)
        var sink = try Sinks.make(container, url: url, tracks: [output], transform: .identity)
        for packet in packets.sorted(by: { ($0.decodeTimestamp ?? $0.timestamp) < ($1.decodeTimestamp ?? $1.timestamp) }
        ) {
            try await sink.write(packet)
        }
        sink.endTrack(1)
        try await sink.finish()
        return url
    }

    private func expectTransparentVideo(_ url: URL, width: Int) async throws {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(VideoFormat.containsAlpha(format))
        #expect(try await track.load(.naturalSize).width == Double(width))
        let (picture, _) = try await AVAssetImageGenerator(asset: asset).image(at: .zero)
        let pixels = try PixelBuffer(cgImage: picture)
        let left = (pixels.height / 2 * pixels.width + pixels.width / 4) * 4 + 3
        let right = (pixels.height / 2 * pixels.width + pixels.width * 3 / 4) * 4 + 3
        #expect(pixels.rgba[left] < 16)
        #expect(pixels.rgba[right] > 240)
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

    @Test func replacementsRefuseMatroskaSubtitleWithoutChangingOriginal() async throws {
        let source = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../FormatsTests/Resources/ffmpeg-mpeg4-ac3-srt.mkv")
        let url = try TestVolume.makeFolder().appending(path: "subtitled.mkv")
        try FileManager.default.copyItem(at: source, to: url)
        let original = try Data(contentsOf: url)
        let input = try await MediaInput.open(url)
        #expect(input.skippedStreams.contains(.track(3)))
        for (operation, preset) in [
            (OperationID.videoRemoveAudio, nil), (.videoConvert, "mp4"), (.videoCompress, "quality-high"),
        ] {
            #expect(try await run(operation, preset: preset, on: url) == .failed(.invalidInput(.unpreservedStreams)))
            #expect(try Data(contentsOf: url) == original)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).count == 1)
    }

    @Test(arguments: [SkippedMediaStream.chapter, .attachment, .unknown])
    func replacementRefusesLateMatroskaContent(stream: SkippedMediaStream) async throws {
        let url = try TestVolume.makeFolder().appending(path: "late-content.mkv")
        let video = MediaTrack(number: 1, kind: .video(width: 64, height: 48), codec: .vp9)
        var muxer = try MatroskaMuxer(url: url, tracks: [video], webm: false)
        try muxer.write(MediaPacket(track: 1, timestamp: 0, isKeyframe: true, payload: Data([1])))
        try muxer.finish()
        var bytes = try Data(contentsOf: url)
        let segmentID = Data([0x18, 0x53, 0x80, 0x67])
        let segmentStart = try #require(bytes.range(of: segmentID))
        let sizeStart = segmentStart.upperBound
        let segmentHeaderBytes = 8
        let contentID: [UInt8] =
            switch stream {
            case .chapter: [0x10, 0x43, 0xA7, 0x70]
            case .attachment: [0x19, 0x41, 0xA4, 0x69]
            default: [0x1A, 0x45, 0xDF, 0xA4]
            }
        bytes.append(contentsOf: contentID + [0x80])
        let size = bytes.count - sizeStart - segmentHeaderBytes
        for index in 1..<segmentHeaderBytes {
            bytes[sizeStart + index] = UInt8(size >> ((segmentHeaderBytes - 1 - index) * 8) & 0xFF)
        }
        try bytes.write(to: url)
        let input = try await MediaInput.open(url)
        #expect(input.skippedStreams.contains(stream))
        #expect(try await run(.videoConvert, preset: "mp4", on: url) == .failed(.invalidInput(.unpreservedStreams)))
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func replacementRefusesUnmappedAVIStream() async throws {
        let source = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../FormatsTests/Resources/ffmpeg-mpeg4-ac3.avi")
        let url = try TestVolume.makeFolder().appending(path: "unmapped.avi")
        var bytes = try Data(contentsOf: source)
        let marker = try #require(bytes.range(of: Data("auds".utf8)))
        bytes.replaceSubrange(marker, with: Data("txts".utf8))
        try bytes.write(to: url)
        let input = try await MediaInput.open(url)
        #expect(input.skippedStreams.contains(.track(2)))
        #expect(
            try await run(.videoCompress, preset: "quality-high", on: url)
                == .failed(.invalidInput(.unpreservedStreams)))
        #expect(try Data(contentsOf: url) == bytes)
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

    @Test func resizeKeepsHEVCAlphaPixels() async throws {
        let url = try await transparentVideo()
        let input = try await MediaInput.open(url)
        #expect(input.video?.hasAlpha == true)
        let result = try output(try await run(.videoResize, preset: "percent-50", on: url))
        #expect(result.pathExtension == "mov")
        try await expectTransparentVideo(result, width: 32)
    }

    @Test func alphaConversionToMP4FailsBeforeReplacement() async throws {
        let url = try await transparentVideo()
        let original = try Data(contentsOf: url)
        #expect(try await run(.videoConvert, preset: "mp4", on: url) == .failed(.videoAlphaUnsupported))
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func vp9AlphaRemuxesFromWebMToMatroska() async throws {
        let url = try await transparentVideo(in: .webm)
        let result = try output(try await run(.videoConvert, preset: "mkv", on: url))
        var demuxer = try MatroskaDemuxer(url: result)
        #expect(demuxer.tracks.first?.hasAlpha == true)
        #expect(try demuxer.nextPacket()?.additional != nil)
    }

    @Test func customContainerHEVCAlphaFailsBeforeEncoding() throws {
        var source = MediaTrack(number: 1, kind: .video(width: 64, height: 48), codec: .hevc)
        source.hasAlpha = true
        let input = MediaInput(
            url: URL(filePath: "/transparent.mkv"), backend: .matroska, video: source, audio: nil,
            hasMultipleTracks: false, skippedStreams: [], duration: Nanoseconds.perSecond, transform: .identity)
        for operation in [VideoOperation.resize(.percent(50)), .convert(.mov)] {
            #expect(throws: EngineError.videoAlphaUnsupported) {
                try VideoEdits.plan(operation, input: input, source: source, settings: VideoSettings())
            }
        }
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
