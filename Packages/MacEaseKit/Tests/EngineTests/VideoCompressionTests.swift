import AVFoundation
import CoreVideo
import Formats
import Foundation
import MenuCatalog
import Testing
import VideoToolbox

@testable import Engine

@Suite(.serialized) struct VideoCompressionTests {
    private static let targetBytes: Int64 = 200_000
    private static let clipWidth = 320
    private static let clipHeight = 180
    private static let clipFrames = 120
    private static let clipFPS: Int32 = 30
    private static let canEncodeHEVC: Bool = {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: 320, height: 180, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr && session != nil
    }()

    private func fixture() throws -> URL {
        let source = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac", withExtension: "mp4", subdirectory: "Resources"))
        let url = try TestVolume.makeFolder().appending(path: "clip.mp4")
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    private func run(_ compression: VideoCompression, on url: URL) async throws -> ItemOutcome {
        var settings = Settings()
        settings.outputMode = .replace
        let support = FileManager.default.temporaryDirectory.appending(path: "VideoCompression-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        let request = OperationRequest(op: .videoCompress, options: .video(.compress(compression)), inputs: [url])
        let batch = OperationPlanner.batch(for: request, settings: settings)
        #expect(batch.items.allSatisfy { $0.lane == .hardwareVideo })
        let result = await engine.run(batch, settings: settings) { _ in }
        return try #require(result.outcomes.first)
    }

    private func output(_ outcome: ItemOutcome) throws -> URL {
        guard case .succeeded(let urls, _) = outcome, let url = urls.first else {
            Issue.record("expected compression success, got \(outcome)")
            throw CancellationError()
        }
        return url
    }

    @Test func everyCompressionAndExtractionMenuPresetResolves() throws {
        for op in [OperationID.videoCompress, .videoExtractAudio] {
            for preset in op.presets {
                #expect(OperationPlanner.options(for: op, preset: preset, settings: Settings()) != nil)
            }
        }
        let options = try #require(OperationPlanner.options(for: .videoCompress, preset: "mb-10", settings: Settings()))
        guard case .video(.compress(let compression)) = options else {
            Issue.record("expected a compression target")
            return
        }
        #expect(compression.goal == .bytes(9_700_000))
    }

    @Test func bitrateCompressionMeetsByteBoundsAndDecodes() async throws {
        let url = try await texturedClip(in: TestVolume.makeFolder())
        let before = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(before > Self.targetBytes)
        let result = try output(try await run(VideoCompression(goal: .bytes(Self.targetBytes)), on: url))
        let bytes = try #require(try result.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(bytes <= Self.targetBytes)
        #expect(Double(bytes) >= Double(Self.targetBytes) * 0.92)
        let opened = try await MediaInput.open(result)
        #expect(opened.video?.codec == .hevc)
        #expect(opened.container == .mp4)
        guard case .asset(let asset, let video?, _) = opened.backend else {
            Issue.record("expected an MP4 video track")
            return
        }
        let descriptions = try await video.load(.formatDescriptions)
        #expect(descriptions.first.map(CMFormatDescriptionGetMediaSubType) == kCMVideoCodecType_HEVC)
        let reader = try AssetTrackReader(asset: asset, track: video, number: 1, mode: .frames)
        var count = 0
        while try await reader.nextFrame() != nil { count += 1 }
        #expect(count == Self.clipFrames)
    }

    @Test func stagedCompressionMeetsByteBoundsBeforeCommit() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "VideoStaging-\(UUID().uuidString)")
        TestTemporaryFolders.register(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try await texturedClip(in: folder)
        let original = try Data(contentsOf: url)
        let settings = Settings()
        let compression = VideoCompression(goal: .bytes(Self.targetBytes))
        let request = OperationRequest(op: .videoCompress, options: .video(.compress(compression)), inputs: [url])
        let batch = OperationPlanner.batch(for: request, settings: settings)
        let work = try #require(batch.items.first)
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let result = try await work.body(context)
        guard case .replace(_, let staged) = result else {
            Issue.record("expected a staged replacement")
            return
        }
        let bytes = try #require(try staged.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(bytes <= Self.targetBytes)
        #expect(Double(bytes) >= Double(Self.targetBytes) * 0.92)
        #expect(try Data(contentsOf: url) == original)
        let opened = try await MediaInput.open(staged.url)
        #expect(opened.video?.codec == .hevc)
    }

    @Test func unreachableTargetKeepsOriginalBytesAndReportsSmallest() async throws {
        let url = try fixture()
        let original = try Data(contentsOf: url)
        let result = try await run(VideoCompression(goal: .bytes(128)), on: url)
        guard case .failed(.targetUnreachable(let smallest)) = result else {
            Issue.record("expected targetUnreachable, got \(result)")
            return
        }
        #expect(smallest > 128)
        #expect(try Data(contentsOf: url) == original)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == [
                url.lastPathComponent
            ])
    }

    @Test func smallPlatformClipRemuxesWithoutReencodingVideo() async throws {
        let url = try fixture()
        let before = try await videoPayloads(url)
        let library = PresetLibrary(supportDirectory: FileManager.default.temporaryDirectory)
        let preset = try #require(library.bundled.first { $0.id == "discord" })
        let result = try output(try await run(VideoPlanner.compression(for: preset, settings: Settings()), on: url))
        #expect(try await videoPayloads(result) == before)
        let opened = try await MediaInput.open(result)
        #expect(opened.video?.codec == .h264)
        #expect(opened.audio?.codec == .aac)
    }

    @Test(.enabled(if: Self.canEncodeHEVC)) func editedPresetProducesMOVWithHEVC() async throws {
        let url = try fixture()
        let library = PresetLibrary(supportDirectory: FileManager.default.temporaryDirectory)
        var preset = try #require(library.bundled.first { $0.id == "discord" })
        preset.video?.formats = ["mov"]
        preset.video?.videoCodec = "hevc"
        let result = try output(try await run(VideoCompression(goal: .platform(preset)), on: url))
        let opened = try await MediaInput.open(result)
        #expect(result.pathExtension == "mov")
        #expect(opened.container == .mov)
        #expect(opened.video?.codec == .hevc)
        #expect(opened.audio?.codec == .aac)
        guard case .asset(_, let video?, _) = opened.backend else {
            Issue.record("expected MOV video track")
            return
        }
        let descriptions = try await video.load(.formatDescriptions)
        #expect(descriptions.first.map(CMFormatDescriptionGetMediaSubType) == kCMVideoCodecType_HEVC)
    }

    @Test func editedPresetKeepsListedSourceFormat() async throws {
        let url = try fixture()
        let library = PresetLibrary(supportDirectory: FileManager.default.temporaryDirectory)
        var preset = try #require(library.bundled.first { $0.id == "discord" })
        preset.video?.formats = ["mov", "mp4"]
        let result = try output(try await run(VideoCompression(goal: .platform(preset)), on: url))
        #expect(result.pathExtension == "mp4")
        #expect(try await MediaInput.open(result).container == .mp4)
    }

    @Test(arguments: [true, false]) func editedPresetProducesWebMWithVP9AndOpus(targeted: Bool) async throws {
        let url = try fixture()
        let library = PresetLibrary(supportDirectory: try TestVolume.makeFolder())
        var preset = try #require(library.bundled.first { $0.id == "discord" })
        preset.video?.formats = ["webm"]
        preset.video?.videoCodec = "vp9"
        preset.video?.audioCodec = "opus"
        if !targeted { preset.video?.maxBytes = nil }
        try library.save(preset)
        let edited = try #require(try library.preset(id: "discord"))
        let result = try output(try await run(VideoCompression(goal: .platform(edited)), on: url))
        let opened = try await MediaInput.open(result)
        #expect(result.pathExtension == "webm")
        #expect(opened.container == .webm)
        #expect(opened.video?.codec == .vp9)
        #expect(opened.audio?.codec == .opus)
    }

    @Test(arguments: [
        ([String](), "h264", "aac"),
        (["avi"], "h264", "aac"),
        (["webm"], "hevc", "opus"),
        (["mov", "webm"], "h264", "aac"),
        (["mkv"], "av1", "aac"),
        (["mkv"], "vp9", "mp3"),
    ])
    func unsupportedEditedPresetCannotBeSavedOrRun(formats: [String], videoCodec: String, audioCodec: String)
        async throws
    {
        let folder = try TestVolume.makeFolder()
        let library = PresetLibrary(supportDirectory: folder)
        var preset = try #require(library.bundled.first { $0.id == "discord" })
        preset.video?.formats = formats
        preset.video?.videoCodec = videoCodec
        preset.video?.audioCodec = audioCodec
        #expect(throws: EngineError.invalidInput(.unsupportedVideoPreset)) {
            try library.save(preset)
        }
        #expect(try library.overrides().isEmpty)

        let url = try fixture()
        let original = try Data(contentsOf: url)
        let result = try await run(VideoCompression(goal: .platform(preset)), on: url)
        #expect(result == .failed(.invalidInput(.unsupportedVideoPreset)))
        #expect(try Data(contentsOf: url) == original)
    }

    @Test(arguments: [
        AspectRange(min: AspectRatio(width: 2, height: 1), max: AspectRatio(width: 1, height: 1), fit: .crop),
        AspectRange(min: AspectRatio(width: .nan, height: 1), max: AspectRatio(width: 2, height: 1), fit: .crop),
    ])
    func malformedAspectPreservesOriginal(aspect: AspectRange) async throws {
        let url = try fixture()
        let original = try Data(contentsOf: url)
        let library = PresetLibrary(supportDirectory: FileManager.default.temporaryDirectory)
        var preset = try #require(library.bundled.first { $0.id == "instagram" })
        preset.video?.aspect = aspect

        let result = try await run(VideoCompression(goal: .platform(preset)), on: url)

        #expect(result == .failed(.invalidInput(.invalidNumericParameter)))
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func instagramCropsToPortraitWithoutStretching() async throws {
        let url = try fixture()
        let library = PresetLibrary(supportDirectory: FileManager.default.temporaryDirectory)
        let preset = try #require(library.bundled.first { $0.id == "instagram" })
        let result = try output(try await run(VideoPlanner.compression(for: preset, settings: Settings()), on: url))
        let opened = try await MediaInput.open(result)
        #expect(opened.displaySize == PixelSize(width: 54, height: 96))
        #expect(opened.video?.codec == .h264)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: result))
        let (frame, _) = try await generator.image(at: .zero)
        let pixels = try PixelBuffer(cgImage: frame)
        #expect(pixels.width == 54 && pixels.height == 96)
        let sourceGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: try fixture()))
        let (sourceFrame, _) = try await sourceGenerator.image(at: .zero)
        let sourcePixels = try PixelBuffer(cgImage: sourceFrame)
        let cropOrigin = (sourcePixels.width - 54) / 2
        func columnMeans(_ image: PixelBuffer, from origin: Int) -> [Double] {
            (0..<54).map { x in
                (0..<image.height).reduce(0.0) { sum, y in
                    sum + Double(image.rgba[(y * image.width + origin + x) * 4])
                } / Double(image.height)
            }
        }
        let difference =
            zip(columnMeans(pixels, from: 0), columnMeans(sourcePixels, from: cropOrigin))
            .map { abs($0 - $1) }.reduce(0, +) / 54
        // A stretched crop shifts the bars visibly.
        #expect(difference < 12, "mean column difference \(difference)")
    }

    @Test func lineOverFiveMinutesFailsBeforeReplacingOriginal() async throws {
        let source = try fixture()
        let input = try await MediaInput.open(source)
        let track = try #require(input.video)
        let stage = try await PacketCopyStage(input: input, track: track, number: 1, start: 0, end: input.duration)
        let packet = try #require(try await stage.pull().first)
        var longTrack = track
        let longDuration = 301 * Nanoseconds.perSecond
        longTrack.defaultDuration = longDuration
        let url = source.deletingLastPathComponent().appending(path: "long.mkv")
        var muxer = try MatroskaMuxer(url: url, tracks: [longTrack], webm: false)
        var longPacket = packet
        longPacket.timestamp = 0
        longPacket.duration = longDuration
        try muxer.write(longPacket)
        try muxer.finish()
        let original = try Data(contentsOf: url)
        let library = PresetLibrary(supportDirectory: FileManager.default.temporaryDirectory)
        let preset = try #require(library.bundled.first { $0.id == "line" })
        let result = try await run(VideoPlanner.compression(for: preset, settings: Settings()), on: url)
        #expect(result == .failed(.invalidInput(.tooLong(limitSeconds: 300))))
        #expect(try Data(contentsOf: url) == original)
    }

    private func videoPayloads(_ url: URL) async throws -> [Data] {
        let input = try await MediaInput.open(url)
        let track = try #require(input.video)
        let stage = try await PacketCopyStage(input: input, track: track, number: 1, start: 0, end: input.duration)
        var payloads: [Data] = []
        while stage.nextTime != nil { payloads += try await stage.pull().map(\.payload) }
        return payloads
    }

    private func texturedClip(in folder: URL) async throws -> URL {
        let url = folder.appending(path: "textured.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Self.clipWidth,
                AVVideoHeightKey: Self.clipHeight,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000],
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Self.clipWidth, kCVPixelBufferHeightKey as String: Self.clipHeight,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? EngineError.encodeFailed("fixture writer start") }
        writer.startSession(atSourceTime: .zero)
        var random: UInt64 = 1
        for index in 0..<Self.clipFrames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let pool = try #require(adaptor.pixelBufferPool)
            var created: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            #expect(status == kCVReturnSuccess)
            let frame = try #require(created)
            CVPixelBufferLockBaseAddress(frame, [])
            let base = try #require(CVPixelBufferGetBaseAddress(frame))
            let rowBytes = CVPixelBufferGetBytesPerRow(frame)
            for y in 0..<Self.clipHeight {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<Self.clipWidth {
                    random = random &* 6_364_136_223_846_793_005 &+ 1
                    let grain = Int(random >> 59)
                    let inSquare = (x + index * 3) % Self.clipWidth < 60 && y > 40 && y < 140
                    row[x * 4] = UInt8(clamping: (inSquare ? 220 : x * 255 / Self.clipWidth) + grain)
                    row[x * 4 + 1] = UInt8(clamping: y * 255 / Self.clipHeight + grain)
                    row[x * 4 + 2] = UInt8(clamping: (index * 2) % 255 + grain)
                    row[x * 4 + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(frame, [])
            guard adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: Self.clipFPS))
            else {
                throw writer.error ?? EngineError.encodeFailed("fixture append")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return url
    }
}
