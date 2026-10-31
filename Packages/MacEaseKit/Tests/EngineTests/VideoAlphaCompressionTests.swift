import AVFoundation
import CoreImage
import CoreVideo
import Formats
import Foundation
import Testing

@testable import Engine

@Suite(.serialized) struct VideoAlphaCompressionTests {
    private static let width = 64
    private static let height = 48
    private static let frameCount = 12
    private static let frameDuration = Nanoseconds.perSecond / 12
    private static let targetBytes: Int64 = 20_000
    private static let alphaTolerance: UInt8 = 8

    @Test func arbitraryRotationKeepsPartialAlphaAndTransparentCanvas() throws {
        let bounds = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 0.5)).cropped(to: bounds)
        var created: CVPixelBuffer?
        try #require(
            CVPixelBufferCreate(
                nil, Self.width, Self.height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created) == kCVReturnSuccess)
        let source = try #require(created)
        CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]).render(image, to: source)
        var edit = FrameEdit(rotation: 45)
        edit.preservesAlpha = true
        let output = try FrameProcessor(source: PixelSize(width: Self.width, height: Self.height), edit: edit)
            .process(source)
        let pixels = try PixelBuffer(cgImage: CGImage.make(from: output))
        let corner = pixels.rgba[(pixels.width + 1) * 4 + 3]
        let center = pixels.rgba[(pixels.height / 2 * pixels.width + pixels.width / 2) * 4 + 3]
        #expect(corner < Self.alphaTolerance)
        #expect(center > 110 && center < 145)

        edit.preservesAlpha = false
        let flattened = try FrameProcessor(source: PixelSize(width: Self.width, height: Self.height), edit: edit)
            .process(source)
        let flattenedPixels = try PixelBuffer(cgImage: CGImage.make(from: flattened))
        #expect(flattenedPixels.rgba[(flattenedPixels.width + 1) * 4 + 3] == 255)
    }

    @Test func joinedTransparencyFlattensWithAnExplicitWarning() async throws {
        let directory = try folder()
        let transparent = try await transparentClip(in: directory, container: .mov)
        let fixture = try #require(
            Bundle.module.url(
                forResource: "ffmpeg-h264-aac.mp4", withExtension: nil,
                subdirectory: "Resources"))
        let opaque = directory.appending(path: "opaque.mp4")
        try FileManager.default.copyItem(at: fixture, to: opaque)
        let originals = try [opaque, transparent].map { try Data(contentsOf: $0) }
        var edit = VideoEdit()
        var sources: [VideoEditSource] = []
        for url in [opaque, transparent] {
            let input = try await MediaInput.open(url)
            sources.append(
                VideoEditSource(
                    url: url, duration: Double(input.duration) / Double(Nanoseconds.perSecond),
                    stamp: try MediaSourceStamp(url: url)))
        }
        edit.sources = sources
        edit.segments = [VideoSegment(start: 0, end: 0.5), VideoSegment(start: 0, end: 0.5, sourceIndex: 1)]
        var settings = Settings()
        settings.outputMode = .replace
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: directory), progress: { _ in })
        defer { context.removeStaging() }
        let result = try await VideoEdits.run(.edit(edit), url: opaque, context: context)
        guard case .groupedDerived(_, let stamps, let output) = result else {
            Issue.record("joined alpha must preserve every original")
            return
        }
        #expect(stamps.count == 2)
        let input = try await MediaInput.open(output.url)
        #expect(input.video?.hasAlpha == false)
        #expect(context.warnings.contains(.videoTransparencyFlattened))
        let preview = AVAssetImageGenerator(asset: AVURLAsset(url: output.url))
        let (image, _) = try await preview.image(at: CMTime(seconds: 0.75, preferredTimescale: 600))
        #expect(try ImageFixtures.pixel(image, x: 0, y: 0)[3] == 255)
        for (url, original) in zip([opaque, transparent], originals) { #expect(try Data(contentsOf: url) == original) }
    }

    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "VideoAlpha-\(UUID().uuidString)")
        TestTemporaryFolders.register(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func transparentClip(in directory: URL, container: OutputContainer) async throws -> URL {
        let url = directory.appending(path: "transparent.\(container.fileExtension)")
        var encoding = VideoEncoding(
            codec: container == .mov ? .prores4444 : .vp9, width: Self.width, height: Self.height,
            frameDuration: Self.frameDuration, bitrate: nil)
        encoding.alpha = true
        var encoder = try VideoEncoders.make(encoding, track: 1)
        let bounds = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        let right = CGRect(x: Self.width / 2, y: 0, width: Self.width / 2, height: Self.height)
        let image = CIImage(color: .red).cropped(to: right)
            .composited(over: CIImage(color: .clear).cropped(to: bounds))
        let renderer = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        var created: CVPixelBuffer?
        try #require(
            CVPixelBufferCreate(
                nil, Self.width, Self.height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created) == kCVReturnSuccess)
        let frame = try #require(created)
        renderer.render(image, to: frame)
        var packets: [MediaPacket] = []
        for index in 0..<Self.frameCount {
            packets += try encoder.encode(frame, timestamp: Int64(index) * Self.frameDuration)
        }
        packets += try encoder.finish()
        var sink = try Sinks.make(
            container, url: url, tracks: [OutputTrack(track: encoder.track, format: encoder.formatDescription)],
            transform: .identity)
        for packet in packets { try await sink.write(packet) }
        try await sink.finish()
        return url
    }

    private func platform(container: OutputContainer, codec: String) throws -> PlatformPreset {
        let library = PresetLibrary(supportDirectory: FileManager.default.temporaryDirectory)
        var preset = try #require(library.bundled.first { $0.id == "discord" })
        preset.video?.formats = [container.rawValue]
        preset.video?.videoCodec = codec
        preset.video?.audioCodec = container == .webm ? "opus" : "aac"
        preset.video?.maxBytes = nil
        return preset
    }

    @Test(arguments: [OutputContainer.mov, .webm])
    func compressionRetainsTransparentAndOpaquePixels(container: OutputContainer) async throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let source = try await transparentClip(in: directory, container: container)
        let original = try Data(contentsOf: source)
        let preset = try platform(container: container, codec: container == .mov ? "hevc" : "vp9")
        let goals: [VideoCompression.Goal] = [.quality(0.65), .bytes(Self.targetBytes), .platform(preset)]
        for goal in goals {
            var settings = Settings()
            settings.outputMode = .replace
            let context = ItemContext(
                settings: settings, staging: StagingArea(supportDirectory: directory), progress: { _ in })
            defer { context.removeStaging() }
            let result = try await VideoCompressor.run(VideoCompression(goal: goal), url: source, context: context)
            guard case .replace(_, let staged) = result else {
                Issue.record("expected staged compression")
                return
            }
            let output = try await MediaInput.open(staged.url)
            #expect(output.container == container)
            #expect(output.video?.hasAlpha == true)
            #expect(context.warnings.isEmpty)
            let sampler = try await FrameSampler(
                input: output, frameDuration: output.frameDuration, edit: FrameEdit(), start: 0, end: output.duration)
            let decoded = try #require(try await sampler.next())
            let pixels = try PixelBuffer(cgImage: CGImage.make(from: decoded.image))
            let transparentAlpha = pixels.rgba[(Self.width / 4) * 4 + 3]
            let opaqueAlpha = pixels.rgba[(Self.width * 3 / 4) * 4 + 3]
            #expect(transparentAlpha < Self.alphaTolerance)
            #expect(opaqueAlpha > UInt8.max - Self.alphaTolerance)
            #expect(try Data(contentsOf: source) == original)
            if case .bytes(let target) = goal {
                #expect(try #require(staged.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) <= target)
            }
        }
    }

    @Test(arguments: [OutputContainer.mov, .webm, .mp4])
    func alphaEncodingPolicyPrecedesAllocation(container: OutputContainer) async throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        var track = MediaTrack(number: 1, kind: .video(width: Self.width, height: Self.height), codec: .vp9)
        track.hasAlpha = true
        let input = MediaInput(
            url: directory.appending(path: "transparent.webm"), backend: .matroska, video: track, audio: nil,
            hasMultipleTracks: false, skippedStreams: [], duration: Nanoseconds.perSecond, transform: .identity)
        let encoding = VideoEncoding(
            codec: container == .webm ? .vp9 : container == .mov ? .hevc : .h264,
            width: Self.width, height: Self.height, frameDuration: Self.frameDuration, bitrate: nil)
        let plan = TranscodePlan(container: container, video: .encode(encoding, FrameEdit()), audio: nil)
        let newFile = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: directory), progress: { _ in })
        let prepared = try await VideoProperties.prepare(plan, input: input, context: newFile)
        guard case .encode(let selected, let edit) = prepared.video else {
            Issue.record("expected video encoding")
            return
        }
        #expect(selected.alpha == (container != .mp4))
        #expect(edit.flattensAlpha == (container == .mp4))
        #expect(newFile.warnings == (container == .mp4 ? [.videoTransparencyFlattened] : []))
        if container == .mp4 {
            var settings = Settings()
            settings.outputMode = .replace
            let replacement = ItemContext(
                settings: settings, staging: StagingArea(supportDirectory: directory), progress: { _ in })
            await #expect(throws: EngineError.videoAlphaUnsupported) {
                _ = try await VideoProperties.prepare(plan, input: input, context: replacement)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func h264PlatformRefusesReplacementBeforeWriting() async throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let source = try await transparentClip(in: directory, container: .mov)
        let original = try Data(contentsOf: source)
        let compression = VideoCompression(goal: .platform(try platform(container: .mp4, codec: "h264")))
        var settings = Settings()
        settings.outputMode = .replace
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: directory), progress: { _ in })
        defer { context.removeStaging() }
        await #expect(throws: EngineError.videoAlphaUnsupported) {
            try await VideoCompressor.run(compression, url: source, context: context)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [source.lastPathComponent])
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(arguments: [OutputContainer.avi, .flv, .mp4])
    func opaqueConversionSelectsTheTargetCodec(container: OutputContainer) throws {
        var track = MediaTrack(number: 1, kind: .video(width: Self.width, height: Self.height), codec: .prores)
        track.hasAlpha = true
        let url = URL(filePath: "/transparent.mov")
        let input = MediaInput(
            url: url, backend: .asset(AVURLAsset(url: url), video: nil, audio: nil), video: track, audio: nil,
            hasMultipleTracks: false, skippedStreams: [], duration: Nanoseconds.perSecond, transform: .identity)
        let plan = try VideoEdits.plan(.convert(container), input: input, source: track, settings: VideoSettings())
        guard case .encode(let encoding, _) = plan.video else {
            Issue.record("expected conversion encoding")
            return
        }
        #expect(plan.container == container)
        #expect(!encoding.alpha)
        #expect(encoding.codec == (container == .avi ? .mjpeg : .h264))
    }

    @Test func h264PlatformWarnsAndFlattensNewFile() async throws {
        let directory = try folder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let source = try await transparentClip(in: directory, container: .mov)
        let original = try Data(contentsOf: source)
        let compression = VideoCompression(goal: .platform(try platform(container: .mp4, codec: "h264")))
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: directory), progress: { _ in })
        defer { context.removeStaging() }
        guard case .replace(_, let staged) = try await VideoCompressor.run(compression, url: source, context: context)
        else {
            Issue.record("expected staged opaque compression")
            return
        }
        #expect(context.warnings == [.videoTransparencyFlattened])
        let output = try await MediaInput.open(staged.url)
        #expect(output.video?.codec == .h264)
        #expect(output.video?.hasAlpha == false)
        let sampler = try await FrameSampler(
            input: output, frameDuration: output.frameDuration, edit: FrameEdit(), start: 0, end: output.duration)
        let decoded = try #require(try await sampler.next())
        let pixels = try PixelBuffer(cgImage: CGImage.make(from: decoded.image))
        let offset = Self.width / 4 * 4
        #expect(pixels.rgba[offset] < Self.alphaTolerance)
        #expect(pixels.rgba[offset + 1] < Self.alphaTolerance)
        #expect(pixels.rgba[offset + 2] < Self.alphaTolerance)
        #expect(pixels.rgba[offset + 3] == 255)
        #expect(try Data(contentsOf: source) == original)
    }
}
