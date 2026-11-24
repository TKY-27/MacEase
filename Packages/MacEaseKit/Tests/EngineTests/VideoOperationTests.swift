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

    private func run(
        _ op: OperationID, preset: String?, on url: URL, omittedStreams: Set<UnpreservedStream> = [],
        outputMode: Settings.OutputMode = .replace
    ) async throws -> ItemOutcome {
        let options = try #require(OperationPlanner.options(for: op, preset: preset, settings: Settings()))
        return try await run(op, options: options, on: url, omittedStreams: omittedStreams, outputMode: outputMode)
    }

    private func run(
        _ op: OperationID, options: OperationOptions, on url: URL, omittedStreams: Set<UnpreservedStream> = [],
        outputMode: Settings.OutputMode = .replace
    ) async throws -> ItemOutcome {
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseSupport-\(UUID().uuidString)")
        TestTemporaryFolders.register(support)
        let engine = try JobEngine(supportDirectory: support, concurrency: 2)
        var settings = Settings()
        settings.outputMode = outputMode
        let batch = OperationPlanner.batch(
            for: OperationRequest(op: op, options: options, inputs: [url], omittedStreams: omittedStreams),
            settings: settings)
        let outcome = await engine.run(batch, settings: settings) { _ in }
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
        TestTemporaryFolders.register(folder)
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

    private func patternedH264Video(transform: CGAffineTransform) async throws -> URL {
        let url = try TestVolume.makeFolder().appending(path: "patterned.mov")
        let width = 64
        let height = 48
        let frameDuration = Nanoseconds.perSecond / 12
        let encoding = VideoEncoding(
            codec: .h264, width: width, height: height, frameDuration: frameDuration, bitrate: nil)
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
                        pixels[offset] = x < width / 2 ? 0 : 255
                        pixels[offset + 1] = 0
                        pixels[offset + 2] = x < width / 2 ? 255 : 0
                        pixels[offset + 3] = 255
                    }
                }
            }
            packets += try encoder.encode(frame, timestamp: Int64(index) * frameDuration)
        }
        packets += try encoder.finish()
        let outputTrack = OutputTrack(track: encoder.track, format: encoder.formatDescription)
        var sink = try Sinks.make(.mov, url: url, tracks: [outputTrack], transform: transform)
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
        #expect(input.skippedStreams.contains(.track(3, kind: .subtitle)))
        for (operation, preset) in [
            (OperationID.videoRemoveAudio, nil), (.videoConvert, "mp4"), (.videoCompress, "quality-high"),
        ] {
            #expect(
                try await run(operation, preset: preset, on: url)
                    == .failed(.invalidInput(.unpreservedStreams([.subtitle]))))
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
        let expected: UnpreservedStream =
            switch stream {
            case .chapter: .chapter
            case .attachment: .attachment
            default: .data
            }
        bytes.append(contentsOf: contentID + [0x80])
        let size = bytes.count - sizeStart - segmentHeaderBytes
        for index in 1..<segmentHeaderBytes {
            bytes[sizeStart + index] = UInt8(size >> ((segmentHeaderBytes - 1 - index) * 8) & 0xFF)
        }
        try bytes.write(to: url)
        let input = try await MediaInput.open(url)
        #expect(input.skippedStreams.contains(stream))
        #expect(
            try await run(.videoConvert, preset: "mp4", on: url)
                == .failed(.invalidInput(.unpreservedStreams([expected]))))
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
        #expect(input.skippedStreams.contains(.track(2, kind: .subtitle)))
        #expect(
            try await run(.videoCompress, preset: "quality-high", on: url)
                == .failed(.invalidInput(.unpreservedStreams([.subtitle]))))
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

    @Test func resizeBakesHorizontalMirrorIntoPixels() async throws {
        let mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 64, ty: 0)
        let url = try await patternedH264Video(transform: mirror)
        let sourceTrack = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        #expect(try await sourceTrack.load(.preferredTransform).a == -1)
        let result = try output(try await run(.videoResize, preset: "percent-50", on: url))
        let asset = AVURLAsset(url: result)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.preferredTransform) == .identity)
        #expect(try await track.load(.naturalSize) == CGSize(width: 32, height: 24))
        let (picture, _) = try await AVAssetImageGenerator(asset: asset).image(at: .zero)
        let pixels = try PixelBuffer(cgImage: picture)
        let left = (pixels.height / 2 * pixels.width + pixels.width / 4) * 4
        let right = (pixels.height / 2 * pixels.width + pixels.width * 3 / 4) * 4
        #expect(pixels.rgba[left + 2] > 180 && pixels.rgba[left] < 80)
        #expect(pixels.rgba[right] > 180 && pixels.rgba[right + 2] < 80)
    }

    @Test func containerCopyPreservesHorizontalMirrorMatrix() async throws {
        let mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 64, ty: 0)
        let url = try await patternedH264Video(transform: mirror)
        let sourceTrack = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let sourceTransform = try await sourceTrack.load(.preferredTransform)
        let result = try output(try await run(.videoConvert, preset: "mp4", on: url))
        let outputTrack = try #require(try await AVURLAsset(url: result).loadTracks(withMediaType: .video).first)
        #expect(try await outputTrack.load(.preferredTransform) == sourceTransform)
    }

    @Test func resizeBakesDiagonalMirrorIntoPixels() async throws {
        let mirror = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        let url = try await patternedH264Video(transform: mirror)
        let result = try output(try await run(.videoResize, preset: "percent-50", on: url))
        let asset = AVURLAsset(url: result)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.preferredTransform) == .identity)
        #expect(try await track.load(.naturalSize) == CGSize(width: 24, height: 32))
        let (picture, _) = try await AVAssetImageGenerator(asset: asset).image(at: .zero)
        let pixels = try PixelBuffer(cgImage: picture)
        let top = (pixels.height / 4 * pixels.width + pixels.width / 2) * 4
        let bottom = (pixels.height * 3 / 4 * pixels.width + pixels.width / 2) * 4
        #expect(pixels.rgba[top] > 180 && pixels.rgba[top + 2] < 80)
        #expect(pixels.rgba[bottom + 2] > 180 && pixels.rgba[bottom] < 80)
    }

    @Test func acceptsOrthogonalVideoDisplayMatrices() throws {
        let orientations: [(CGAffineTransform, Bool)] = [
            (.identity, false),
            (CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 48, ty: 0), true),
            (CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 64), true),
            (CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 64, ty: 48), false),
            (CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 64, ty: 0), false),
            (CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 48), false),
            (CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0), true),
            (CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 48, ty: 64), true),
        ]
        for (transform, quarterTurned) in orientations {
            let orientation = try VideoDisplayOrientation(transform)
            let size = try FrameProcessor.outputSize(
                source: PixelSize(width: 64, height: 48), edit: FrameEdit(displayOrientation: orientation))
            #expect(size == (quarterTurned ? PixelSize(width: 48, height: 64) : PixelSize(width: 64, height: 48)))
        }
    }

    @Test func rejectsUnsupportedVideoDisplayMatrices() throws {
        let source = MediaTrack(number: 1, kind: .video(width: 64, height: 48), codec: .h264)
        let unsupported = [
            CGAffineTransform(a: 1, b: 0, c: 0.25, d: 1, tx: 0, ty: 0),
            CGAffineTransform(a: 1, b: 0, c: 0.0001, d: 1, tx: 0, ty: 0),
            CGAffineTransform(rotationAngle: .pi / 6),
            CGAffineTransform(rotationAngle: .pi / 180_000),
            CGAffineTransform(a: .infinity, b: 0, c: 0, d: 1, tx: 0, ty: 0),
        ]
        for transform in unsupported {
            let input = MediaInput(
                url: URL(filePath: "/unsupported.mov"), backend: .matroska, video: source, audio: nil,
                hasMultipleTracks: false, skippedStreams: [], duration: Nanoseconds.perSecond,
                transform: transform)
            #expect(throws: EngineError.videoDisplayTransformUnsupported) {
                try input.requirePreservableStreams()
            }
            #expect(throws: EngineError.videoDisplayTransformUnsupported) {
                try VideoEdits.plan(.resize(.percent(50)), input: input, source: source, settings: VideoSettings())
            }
        }
    }

    @Test func resizeKeepsHEVCAlphaPixels() async throws {
        let url = try await transparentVideo()
        let input = try await MediaInput.open(url)
        #expect(input.video?.hasAlpha == true)
        let result = try output(try await run(.videoResize, preset: "percent-50", on: url))
        #expect(result.pathExtension == "mov")
        try await expectTransparentVideo(result, width: 32)
    }

    @Test func arbitraryRotationOfAlphaMOVKeepsSourceAndCanvasTransparency() async throws {
        let source = try await transparentVideo()
        let original = try Data(contentsOf: source)
        var settings = Settings()
        settings.outputMode = .replace
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: source.deletingLastPathComponent()),
            progress: { _ in })
        defer { context.removeStaging() }
        guard
            case .replace(_, let staged) = try await VideoEdits.run(
                .rotate(degrees: 45, fill: .black), url: source, context: context)
        else {
            Issue.record("expected staged rotation")
            return
        }
        let output = try await MediaInput.open(staged.url)
        #expect(output.video?.hasAlpha == true)
        #expect(context.warnings.isEmpty)
        let sampler = try await FrameSampler(
            input: output, frameDuration: output.frameDuration, edit: FrameEdit(), start: 0, end: output.duration)
        let frame = try #require(try await sampler.next())
        let pixels = try PixelBuffer(cgImage: CGImage.make(from: frame.image))
        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            pixels.rgba[(y * pixels.width + x) * 4 + 3]
        }
        #expect(alpha(1, 1) < 16)
        #expect(alpha(pixels.width * 3 / 10, pixels.height / 2) < 16)
        #expect(alpha(pixels.width * 7 / 10, pixels.height / 2) > 240)
        #expect(try Data(contentsOf: source) == original)
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
        let options = OperationOptions.video(.edit(VideoEdit(start: 0.5, end: 1.5, trimMode: .exact)))
        let result = try output(try await run(.videoEdit, options: options, on: url))
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

    private func videoWithExtraTracks(
        includeTimecode: Bool = false, includeChapter: Bool = false, includeMetadata: Bool = false,
        includeClosedCaption: Bool = false, sourceURL: URL? = nil, timecodeRate: Int32 = 24, leadingSeconds: Double = 0,
        timecodeDuration: CMTime? = nil, associateTimecode: Bool = true
    ) async throws -> URL {
        let source = try sourceURL ?? fixture("ffmpeg-h264-aac.mp4")
        let asset = AVURLAsset(url: source)
        let videoTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = CMTimeAdd(
            try await asset.load(.duration), CMTime(seconds: leadingSeconds, preferredTimescale: 600))
        let url = try TestVolume.makeFolder().appending(path: "extra-tracks.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieTimeScale = timecodeDuration?.timescale ?? 600
        let reader = try AVAssetReader(asset: asset)

        var pairs: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
        for track in [videoTrack, audioTrack].compactMap({ $0 }) {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            let input = AVAssetWriterInput(
                mediaType: track.mediaType, outputSettings: nil,
                sourceFormatHint: try await track.load(.formatDescriptions).first)
            writer.add(input)
            pairs.append((output, input))
        }
        let videoIn = try #require(pairs.first?.input)

        var timecodePair: (AVAssetWriterInput, CMTimeCodeFormatDescription)?
        if includeTimecode {
            var timecodeFormat: CMTimeCodeFormatDescription?
            let frameDuration = CMTime(value: 1, timescale: timecodeRate)
            try #require(
                CMTimeCodeFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
                    frameDuration: frameDuration, frameQuanta: UInt32(timecodeRate), flags: 0, extensions: nil,
                    formatDescriptionOut: &timecodeFormat) == noErr)
            let tcFormat = try #require(timecodeFormat)
            let timecodeIn = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: tcFormat)
            timecodeIn.mediaTimeScale = timecodeDuration?.timescale ?? timecodeRate
            timecodeIn.languageCode = "jpn"
            timecodeIn.extendedLanguageTag = "ja-JP"
            timecodeIn.marksOutputTrackAsEnabled = false
            let title = AVMutableMetadataItem()
            title.identifier = .commonIdentifierTitle
            title.value = "Camera timecode" as NSString
            timecodeIn.metadata = [title]
            writer.add(timecodeIn)
            if associateTimecode,
                videoIn.canAddTrackAssociation(
                    withTrackOf: timecodeIn, type: AVAssetTrack.AssociationType.timecode.rawValue)
            {
                videoIn.addTrackAssociation(
                    withTrackOf: timecodeIn, type: AVAssetTrack.AssociationType.timecode.rawValue)
            }
            timecodePair = (timecodeIn, tcFormat)
        }

        var captionPair: (AVAssetWriterInput, CMFormatDescription)?
        if includeClosedCaption {
            var description: CMFormatDescription?
            try #require(
                CMFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault, mediaType: kCMMediaType_ClosedCaption,
                    mediaSubType: kCMClosedCaptionFormatType_CEA608, extensions: nil,
                    formatDescriptionOut: &description) == noErr)
            let format = try #require(description)
            let captionIn = AVAssetWriterInput(mediaType: .closedCaption, outputSettings: nil, sourceFormatHint: format)
            try #require(writer.canAdd(captionIn))
            writer.add(captionIn)
            captionPair = (captionIn, format)
        }

        var chapterPair: (AVAssetWriterInput, AVAssetWriterInputMetadataAdaptor, AVTimedMetadataGroup)?
        if includeChapter {
            let title = AVMutableMetadataItem()
            title.identifier = .commonIdentifierTitle
            title.extendedLanguageTag = "en"
            title.value = "Chapter 1" as NSString
            let group = AVTimedMetadataGroup(items: [title], timeRange: CMTimeRange(start: .zero, duration: duration))
            let chapterIn = AVAssetWriterInput(
                mediaType: .metadata, outputSettings: nil, sourceFormatHint: group.copyFormatDescription())
            let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: chapterIn)
            writer.add(chapterIn)
            if videoIn.canAddTrackAssociation(
                withTrackOf: chapterIn, type: AVAssetTrack.AssociationType.chapterList.rawValue)
            {
                videoIn.addTrackAssociation(
                    withTrackOf: chapterIn, type: AVAssetTrack.AssociationType.chapterList.rawValue)
            }
            chapterPair = (chapterIn, adaptor, group)
        }

        var metadataPair: (AVAssetWriterInput, AVAssetWriterInputMetadataAdaptor, AVTimedMetadataGroup)?
        if includeMetadata {
            let tag = AVMutableMetadataItem()
            tag.keySpace = .quickTimeMetadata
            tag.key = "com.apple.quicktime.camera.lens_model" as NSString
            tag.dataType = kCMMetadataBaseDataType_UTF8 as String
            tag.value = "Wide" as NSString
            let group = AVTimedMetadataGroup(items: [tag], timeRange: CMTimeRange(start: .zero, duration: duration))
            let metadataIn = AVAssetWriterInput(
                mediaType: .metadata, outputSettings: nil, sourceFormatHint: group.copyFormatDescription())
            let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataIn)
            writer.add(metadataIn)
            metadataPair = (metadataIn, adaptor, group)
        }

        try #require(reader.startReading())
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        if let (timecodeIn, tcFormat) = timecodePair {
            var frameNumber: Int32 = 0
            let payload = withUnsafeBytes(of: &frameNumber) { Data($0) }
            try await appendExtraSample(
                payload, format: tcFormat, to: timecodeIn, duration: timecodeDuration ?? duration)
        }
        if let (captionIn, format) = captionPair {
            let payload = Data([0, 0, 0, 10, 0x63, 0x64, 0x61, 0x74, 0x94, 0x20])
            try await appendExtraSample(payload, format: format, to: captionIn, duration: duration)
        }

        if let (chapterIn, adaptor, group) = chapterPair {
            while !chapterIn.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            try #require(adaptor.append(group))
            chapterIn.markAsFinished()
        }

        if let (metadataIn, adaptor, group) = metadataPair {
            while !metadataIn.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            try #require(adaptor.append(group))
            metadataIn.markAsFinished()
        }

        while !pairs.isEmpty {
            var remaining: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
            for (output, input) in pairs {
                if input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        continue
                    }
                    var shifted: CMSampleBuffer?
                    var timings = try sample.sampleTimingInfos()
                    let offset = CMTime(seconds: leadingSeconds, preferredTimescale: 600)
                    for index in timings.indices {
                        timings[index].presentationTimeStamp = CMTimeAdd(timings[index].presentationTimeStamp, offset)
                        if timings[index].decodeTimeStamp.isNumeric {
                            timings[index].decodeTimeStamp = CMTimeAdd(timings[index].decodeTimeStamp, offset)
                        }
                    }
                    try #require(
                        CMSampleBufferCreateCopyWithNewTiming(
                            allocator: kCFAllocatorDefault,
                            sampleBuffer: sample, sampleTimingEntryCount: timings.count, sampleTimingArray: &timings,
                            sampleBufferOut: &shifted) == noErr)
                    let written = try #require(shifted)
                    try #require(
                        CMSampleBufferSetOutputPresentationTimeStamp(
                            written,
                            newValue: CMTimeAdd(sample.outputPresentationTimeStamp, offset)) == noErr)
                    try #require(input.append(written))
                }
                remaining.append((output, input))
            }
            pairs = remaining
            if !pairs.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        }
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return url
    }

    @Test func nativeTimecodeKeepsIndependentRateAndAlphaDecodes() async throws {
        let alpha = try await transparentVideo()
        let source = try await videoWithExtraTracks(includeTimecode: true, sourceURL: alpha, timecodeRate: 30)
        let library = PresetLibrary(supportDirectory: FileManager.default.temporaryDirectory)
        var preset = try #require(library.bundled.first { $0.id == "discord" })
        preset.video?.formats = ["mov"]
        preset.video?.videoCodec = "hevc"
        preset.video?.maxBytes = nil
        let compression = VideoCompression(goal: .platform(preset))
        for operation in [VideoOperation.compress(compression), .rotate(degrees: 90, fill: RGBColor.black)] {
            let result = try output(
                try await run(.videoEdit, options: .video(operation), on: source, outputMode: .newFile))
            let asset = AVURLAsset(url: result)
            let timecode = try #require(try await asset.loadTracks(withMediaType: .timecode).first)
            let description = try #require(try await timecode.load(.formatDescriptions).first)
            #expect(CMTimeCodeFormatDescriptionGetFrameQuanta(description) == 30)
            #expect(
                CMTimeCompare(CMTimeCodeFormatDescriptionGetFrameDuration(description), CMTime(value: 1, timescale: 30))
                    == 0)
            let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let reader = try AssetTrackReader(asset: asset, track: video, number: 1, mode: .frames)
            var count = 0
            while let frame = try await reader.nextFrame() {
                let pixels = try PixelBuffer(cgImage: CGImage.make(from: frame.image))
                #expect(pixels.rgba.enumerated().contains { $0.offset % 4 == 3 && $0.element < 16 })
                #expect(pixels.rgba.enumerated().contains { $0.offset % 4 == 3 && $0.element > 240 })
                count += 1
            }
            #expect(count == 12)
        }
    }

    @Test func nativeCarryPreservesLeadingEmptyEditAndNonzeroStart() async throws {
        let source = try await videoWithExtraTracks(includeTimecode: true, timecodeRate: 30, leadingSeconds: 0.5)
        let sourceAsset = AVURLAsset(url: source)
        let sourceDuration = try await sourceAsset.load(.duration)
        #expect(abs(sourceDuration.seconds - 2.5) < 0.001)
        let sourceTrack = try #require(try await sourceAsset.loadTracks(withMediaType: .video).first)
        let sourceSegments = try await sourceTrack.load(.segments)
        #expect(sourceSegments.first(where: { !$0.isEmpty })?.timeMapping.target.start.seconds == 0.5)
        let library = PresetLibrary(supportDirectory: FileManager.default.temporaryDirectory)
        var preset = try #require(library.bundled.first { $0.id == "discord" })
        preset.video?.formats = ["mov"]
        preset.video?.maxBytes = nil
        let compression = VideoCompression(goal: .platform(preset))
        for operation in [VideoOperation.removeAudio, .compress(compression)] {
            let result = try output(
                try await run(.videoEdit, options: .video(operation), on: source, outputMode: .newFile))
            let asset = AVURLAsset(url: result)
            let duration = try await asset.load(.duration).seconds
            #expect(abs(duration - sourceDuration.seconds) < 1 / 24.0)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let segments = try await track.load(.segments)
            #expect(segments.first(where: { !$0.isEmpty })?.timeMapping.target.start.seconds == 0.5)
            #expect(segments.first?.isEmpty == true)
            let timecode = try #require(try await asset.loadTracks(withMediaType: .timecode).first)
            let format = try #require(try await timecode.load(.formatDescriptions).first)
            #expect(CMTimeCodeFormatDescriptionGetFrameQuanta(format) == 30)
        }
    }

    @Test(arguments: [true, false])
    func timecodeRetainsSourceAssociationAndTrackProperties(associated: Bool) async throws {
        let source = try await videoWithExtraTracks(includeTimecode: true, associateTimecode: associated)
        let result = try output(try await run(.videoRotate, preset: "right-90", on: source, outputMode: .newFile))
        let asset = AVURLAsset(url: result)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let tracks = try await asset.loadTracks(withMediaType: .timecode)
        let timecode = try #require(tracks.first)
        #expect(try await video.loadAssociatedTracks(ofType: .timecode).count == (associated ? 1 : 0))
        #expect(try await timecode.load(.languageCode) == "jpn")
        #expect(try await timecode.load(.extendedLanguageTag) == "ja-JP")
        #expect(try await timecode.load(.isEnabled) == false)
        let metadata = try await timecode.load(.metadata)
        #expect(metadata.count == 1)
        #expect(try await metadata.first?.load(.stringValue) == "Camera timecode")
    }

    @Test func timecodeKeepsFractionalTrackEndWithoutMovieScaleRounding() async throws {
        let duration = CMTime(value: 120_084, timescale: 60_000)
        let source = try await videoWithExtraTracks(includeTimecode: true, timecodeRate: 30, timecodeDuration: duration)
        let originalTrack = try #require(try await AVURLAsset(url: source).loadTracks(withMediaType: .timecode).first)
        #expect(CMTimeCompare(try await originalTrack.load(.timeRange).duration, duration) == 0)
        let result = try output(try await run(.videoRotate, preset: "right-90", on: source, outputMode: .newFile))
        let asset = AVURLAsset(url: result)
        let timecode = try #require(try await asset.loadTracks(withMediaType: .timecode).first)
        #expect(CMTimeCompare(try await timecode.load(.timeRange).duration, duration) == 0)
        let reader = try AssetTrackReader(asset: asset, track: timecode, number: 1, mode: .packets)
        while let sample = try await reader.nextSample() {
            if CMSampleBufferGetNumSamples(sample) > 0 {
                #expect(CMTimeCompare(sample.outputDuration, duration) == 0)
            }
        }
    }

    @Test func vp9AlphaAdditionalStreamsRequireConsent() async throws {
        let source = try await transparentVideo(in: .webm)
        let folder = source.deletingLastPathComponent()
        let subtitle = folder.appending(path: "cue.vtt")
        try "WEBVTT\n\n00:00:00.000 --> 00:00:00.500\nAlpha caption\n".write(
            to: subtitle, atomically: true, encoding: .utf8)
        let subtitled = folder.appending(path: "alpha-subtitled.webm")
        let tools = try mediaFixtureTools()
        _ = try await MediaToolProcess().run(
            executable: tools.ffmpeg,
            arguments: [
                "-v", "error", "-nostdin", "-i", source.path, "-i", subtitle.path,
                "-map", "0:v", "-map", "1:s", "-c", "copy", subtitled.path,
            ],
            directory: folder, tools: tools)
        let opened = try await MediaInput.open(subtitled)
        #expect(MediaInput.unpreservedStreams(from: opened.skippedStreams) == [.subtitle])
        #expect(opened.video?.hasAlpha == true)
        let plan = try await NativeTimecodePlan.make(for: opened, destination: .mkv, preservesTiming: true)
        #expect(!plan.carriesTimecode)
        #expect(plan.omittedKinds == [.subtitle])
    }

    private func appendExtraSample(
        _ payload: Data, format: CMFormatDescription, to input: AVAssetWriterInput, duration: CMTime
    ) async throws {
        var blockBuffer: CMBlockBuffer?
        try #require(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: payload.count, flags: 0, blockBufferOut: &blockBuffer) == noErr)
        let block = try #require(blockBuffer)
        try payload.withUnsafeBytes { raw in
            let base = try #require(raw.baseAddress)
            try #require(
                CMBlockBufferReplaceDataBytes(
                    with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count) == noErr)
        }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = payload.count
        var sample: CMSampleBuffer?
        try #require(
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
                refcon: nil, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                sampleBufferOut: &sample) == noErr)
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
        try #require(input.append(try #require(sample)))
        input.markAsFinished()
    }

    @Test(arguments: [Settings.OutputMode.replace, .newFile])
    func closedCaptionTrackRequiresMatchingConsent(mode: Settings.OutputMode) async throws {
        let input = try await videoWithExtraTracks(includeClosedCaption: true)
        let original = try Data(contentsOf: input)
        let folder = input.deletingLastPathComponent()
        let captionTracks = try await AVURLAsset(url: input).loadTracks(withMediaType: .closedCaption)
        #expect(captionTracks.count == 1)
        for consent: Set<UnpreservedStream> in [[], [.subtitle]] {
            #expect(
                try await run(.videoConvert, preset: "mp4", on: input, omittedStreams: consent, outputMode: mode)
                    == .failed(.invalidInput(.unpreservedStreams([.closedCaption]))))
            #expect(try Data(contentsOf: input) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
        }
        let result = try await run(
            .videoConvert, preset: "mp4", on: input, omittedStreams: [.closedCaption], outputMode: mode)
        guard case .succeeded(let outputs, let warnings) = result else {
            Issue.record("expected caption omission: \(result)")
            return
        }
        #expect(warnings.contains(.streamsOmitted([.closedCaption])))
        let output = try #require(outputs.first)
        #expect(try await AVURLAsset(url: output).loadTracks(withMediaType: .closedCaption).isEmpty)
        #expect(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).count == 1)
        if mode == .newFile { #expect(try Data(contentsOf: input) == original) }
    }

    @Test func unpreservableTimecodeRequiresVersionedOmissionConsent() async throws {
        let input = try await videoWithExtraTracks(includeTimecode: true)
        let original = try Data(contentsOf: input)
        let folder = input.deletingLastPathComponent()

        #expect(
            try await run(.videoConvert, preset: "mkv", on: input)
                == .failed(.invalidInput(.unpreservedStreams([.timecode]))))
        #expect(
            try await run(.videoSpeed, preset: "2", on: input)
                == .failed(.invalidInput(.unpreservedStreams([.timecode]))))
        #expect(try Data(contentsOf: input) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)

        let mp4Outcome = try await run(.videoConvert, preset: "mp4", on: input, outputMode: .newFile)
        #expect(mp4Outcome == .failed(.invalidInput(.unpreservedStreams([.timecode]))))

        let editorStaging = StagingArea(supportDirectory: folder)
        await #expect(throws: EngineError.invalidInput(.unpreservedStreams([.timecode]))) {
            _ = try await VideoEditorSource.open(input, staging: editorStaging)
        }
        let consent = StreamOmission(stamp: try MediaSourceStamp(url: input), streams: [.timecode])
        let openedEditor = try await VideoEditorSource.open(input, staging: editorStaging, omission: consent)
        await openedEditor.close()
        let replacement = try await videoWithExtraTracks(includeTimecode: true)
        try FileManager.default.removeItem(at: input)
        try FileManager.default.copyItem(at: replacement, to: input)
        await #expect(throws: EngineError.invalidInput(.unpreservedStreams([.timecode]))) {
            _ = try await VideoEditorSource.open(input, staging: editorStaging, omission: consent)
        }
        try FileManager.default.removeItem(at: input)
        try original.write(to: input)

        let derivedOutcome = try await run(
            .videoConvert, preset: "mkv", on: input, omittedStreams: [.timecode], outputMode: .newFile)
        guard case .succeeded(let derivedOutputs, let derivedWarnings) = derivedOutcome else {
            Issue.record("expected consented new-file convert to succeed, got \(derivedOutcome)")
            return
        }
        #expect(derivedOutputs.first?.pathExtension == "mkv")
        #expect(derivedWarnings.contains(.streamsOmitted([.timecode])))
        #expect(try Data(contentsOf: input) == original)

        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseSupport-\(UUID().uuidString)")
        TestTemporaryFolders.register(support)
        let engine = try JobEngine(supportDirectory: support, concurrency: 2)
        var replaceSettings = Settings()
        replaceSettings.outputMode = .replace
        let speedInput = try await videoWithExtraTracks(includeTimecode: true)
        let speedOriginal = try Data(contentsOf: speedInput)
        let speedOptions = try #require(
            OperationPlanner.options(for: .videoSpeed, preset: "2", settings: replaceSettings))
        let replaceBatch = OperationPlanner.batch(
            for: OperationRequest(
                op: .videoSpeed, options: speedOptions, inputs: [speedInput], omittedStreams: [.timecode]),
            settings: replaceSettings)
        let replaceOutcome = await engine.run(replaceBatch, settings: replaceSettings) { _ in }
        guard case .succeeded(let replaceOutputs, let replaceWarnings) = replaceOutcome.outcomes.first else {
            Issue.record("expected consented replace speed to succeed, got \(replaceOutcome.outcomes)")
            return
        }
        #expect(!replaceOutputs.isEmpty)
        #expect(replaceWarnings.contains(.streamsOmitted([.timecode])))
        let record = try #require(replaceOutcome.record)
        let undone = try await engine.undo(record.id)
        #expect(undone == [.restored])
        #expect(try Data(contentsOf: speedInput) == speedOriginal)
    }

    @Test func consentForOneStreamKindDoesNotCoverOtherKinds() async throws {
        let combined = try await videoWithExtraTracks(includeTimecode: true, includeChapter: true)
        let original = try Data(contentsOf: combined)

        #expect(
            try await run(.videoConvert, preset: "mp4", on: combined)
                == .failed(.invalidInput(.unpreservedStreams([.timecode, .chapter]))))
        #expect(
            try await run(.videoConvert, preset: "mp4", on: combined, omittedStreams: [.timecode])
                == .failed(.invalidInput(.unpreservedStreams([.chapter]))))
        #expect(try Data(contentsOf: combined) == original)

        let consented = try await run(
            .videoConvert, preset: "mp4", on: combined, omittedStreams: [.timecode, .chapter], outputMode: .newFile)
        guard case .succeeded(let outputs, let warnings) = consented else {
            Issue.record("expected fully consented convert to succeed, got \(consented)")
            return
        }
        #expect(outputs.first?.pathExtension == "mp4")
        #expect(warnings.contains(.streamsOmitted([.timecode, .chapter])))
    }

    @Test func matroskaSubtitleConsentSucceedsWithOmissionNote() async throws {
        let source = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../FormatsTests/Resources/ffmpeg-mpeg4-ac3-srt.mkv")
        let url = try TestVolume.makeFolder().appending(path: "subtitled-consent.mkv")
        try FileManager.default.copyItem(at: source, to: url)
        let original = try Data(contentsOf: url)

        #expect(
            try await run(.videoConvert, preset: "mp4", on: url, omittedStreams: [.timecode])
                == .failed(.invalidInput(.unpreservedStreams([.subtitle]))))
        #expect(try Data(contentsOf: url) == original)

        let consented = try await run(
            .videoConvert, preset: "mp4", on: url, omittedStreams: [.subtitle], outputMode: .newFile)
        guard case .succeeded(let outputs, let warnings) = consented else {
            Issue.record("expected consented subtitle convert to succeed, got \(consented)")
            return
        }
        #expect(outputs.first?.pathExtension == "mp4")
        #expect(warnings.contains(.streamsOmitted([.subtitle])))
    }

    @Test func timedMetadataTrackRequiresConsentAndReportsOmission() async throws {
        let input = try await videoWithExtraTracks(includeMetadata: true)
        let original = try Data(contentsOf: input)

        #expect(
            try await run(.videoConvert, preset: "mp4", on: input)
                == .failed(.invalidInput(.unpreservedStreams([.metadata]))))
        #expect(try Data(contentsOf: input) == original)

        let consented = try await run(
            .videoConvert, preset: "mp4", on: input, omittedStreams: [.metadata], outputMode: .newFile)
        guard case .succeeded(let outputs, let warnings) = consented else {
            Issue.record("expected consented metadata convert to succeed, got \(consented)")
            return
        }
        #expect(outputs.first?.pathExtension == "mp4")
        #expect(warnings.contains(.streamsOmitted([.metadata])))
    }
}
