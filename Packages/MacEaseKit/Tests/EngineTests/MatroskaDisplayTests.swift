import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import Engine
@testable import Formats

@Suite(.serialized) struct MatroskaDisplayTests {
    private static let displayWidthID: UInt32 = 0x54B0
    private static let displayHeightID: UInt32 = 0x54BA
    private static let displayUnitID: UInt32 = 0x54B2
    private static let cropTopID: UInt32 = 0x54BB
    private static let cropBottomID: UInt32 = 0x54AA
    private static let cropLeftID: UInt32 = 0x54CC
    private static let cropRightID: UInt32 = 0x54DD
    private static let croppedDisplay: [(UInt32, UInt64)] = [
        (displayWidthID, 112), (displayHeightID, 36), (cropTopID, 8), (cropBottomID, 4),
        (cropLeftID, 4), (cropRightID, 4),
    ]

    @Test func removeAudioRetainsAnamorphicDisplayAndEveryVideoPacket() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = try fixture(
            folder: folder, width: 720, height: 576,
            fields: [(Self.displayWidthID, 1024), (Self.displayHeightID, 576)], audio: true)
        let original = try Data(contentsOf: source)
        let context = context(folder: folder, mode: .replace)
        defer { context.removeStaging() }
        let output = try staged(try await VideoEdits.run(.removeAudio, url: source, context: context))
        let written = try await MediaInput.open(output)
        #expect(written.codedSize == PixelSize(width: 720, height: 576))
        #expect(written.displaySize == PixelSize(width: 1024, height: 576))
        #expect(written.audio == nil)
        #expect(context.warnings.isEmpty)
        #expect(try videoPackets(output) == videoPackets(source))
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func nativeCopyRetainsCropAndPixelAspect() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = try fixture(folder: folder, fields: Self.croppedDisplay)
        let context = context(folder: folder, mode: .replace)
        defer { context.removeStaging() }
        let output = try staged(try await VideoEdits.run(.convert(.mov), url: source, context: context))
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(
            CMVideoFormatDescriptionGetCleanAperture(format, originIsAtTopLeft: true)
                == CGRect(x: 4, y: 8, width: 56, height: 36))
        let presentation = CMVideoFormatDescriptionGetPresentationDimensions(
            format, usePixelAspectRatio: true, useCleanAperture: true)
        #expect(abs(presentation.width / presentation.height - 112.0 / 36) < 0.0001)
        #expect(context.warnings.isEmpty)
    }

    @Test(arguments: [UInt64(0), 1, 2, 3])
    func reencodingCropsBeforeStretchingAndFlipping(displayUnit: UInt64) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = try fixture(folder: folder, fields: Self.croppedDisplay + [(Self.displayUnitID, displayUnit)])
        let context = context(folder: folder, mode: .replace)
        defer { context.removeStaging() }
        let output = try staged(try await VideoEdits.run(.flip(horizontally: true), url: source, context: context))
        let written = try await MediaInput.open(output)
        #expect(written.codedSize == PixelSize(width: 112, height: 36))
        let sampler = try await FrameSampler(
            input: written, frameDuration: written.frameDuration, edit: FrameEdit(), start: 0, end: written.duration)
        let frame = try #require(try await sampler.next())
        let pixels = try PixelBuffer(cgImage: CGImage.make(from: frame.image))
        let left = (pixels.height / 2 * pixels.width + pixels.width / 4) * 4
        let right = (pixels.height / 2 * pixels.width + pixels.width * 3 / 4) * 4
        #expect(pixels.rgba[left + 2] > 180 && pixels.rgba[left] < 80)
        #expect(pixels.rgba[right] > 180 && pixels.rgba[right + 2] < 80)
        for y in [2, pixels.height - 3] {
            let edge = (y * pixels.width + pixels.width / 4) * 4
            #expect(pixels.rgba[edge + 1] < 80)
        }
        #expect(context.warnings.isEmpty)
    }

    @Test func targetCompressionCopiesAnamorphicVideoWithoutResizing() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let fixture = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac", withExtension: "mp4", subdirectory: "Resources"))
        let remuxed = folder.appending(path: "plain.mkv")
        try await Transcoder.run(
            MediaInput.open(fixture), plan: TranscodePlan(container: .mkv, video: .copy, audio: nil), to: remuxed
        ) { _ in }
        var demuxer = try MatroskaDemuxer(url: remuxed)
        var track = try #require(demuxer.tracks.first)
        guard case .video(let width, let height) = track.kind else {
            Issue.record("expected video track")
            return
        }
        track.displayGeometry = VideoDisplayGeometry(displayWidth: width * 2, displayHeight: height)
        let source = folder.appending(path: "anamorphic.mkv")
        var muxer = try MatroskaMuxer(url: source, tracks: [track], webm: false)
        while let packet = try demuxer.nextPacket() { try muxer.write(packet) }
        try muxer.finish()
        let library = PresetLibrary(supportDirectory: folder)
        let preset = try #require(library.bundled.first { $0.id == "discord" })
        let context = context(folder: folder, mode: .replace)
        defer { context.removeStaging() }
        let output = try staged(
            try await VideoCompressor.run(
                VideoPlanner.compression(for: preset, settings: context.settings), url: source, context: context))
        let written = try await MediaInput.open(output)
        #expect(written.codedSize == PixelSize(width: width, height: height))
        let copied = try await PacketCopyStage(
            input: written, track: #require(written.video), number: 1, start: 0, end: written.duration)
        var payloads: [Data] = []
        while copied.nextTime != nil { payloads += try await copied.pull().map(\.payload) }
        #expect(try payloads == videoPackets(source))
        #expect(context.warnings.isEmpty)
    }

    @Test func thumbnailAppliesDisplayGeometryWithReplaceSelected() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = try fixture(folder: folder, fields: Self.croppedDisplay)
        let context = context(folder: folder, mode: .replace)
        defer { context.removeStaging() }
        guard case .derived(_, let outputs) = try await VideoStills.run(.first, url: source, context: context) else {
            Issue.record("expected derived thumbnail")
            return
        }
        let output = try #require(outputs.first)
        let picture = try ImageFixtures.image(output.url)
        #expect(picture.width == 112 && picture.height == 36)
        #expect(context.warnings.isEmpty)
    }

    @Test(arguments: [false, true])
    func unsupportedDisplayUsesExistingLossPolicy(unknownUnit: Bool) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        var fields = Self.croppedDisplay
        if unknownUnit { fields.append((Self.displayUnitID, 4)) }
        let source = try fixture(folder: folder, fields: fields)
        let original = try Data(contentsOf: source)
        let operation: VideoOperation = unknownUnit ? .flip(horizontally: true) : .convert(.avi)
        let replacement = context(folder: folder, mode: .replace)
        defer { replacement.removeStaging() }
        await #expect(throws: EngineError.videoMetadataUnsupported([.trackMetadata])) {
            _ = try await VideoEdits.run(operation, url: source, context: replacement)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "staging.json").path))
        let input = try await MediaInput.open(source)
        let plan = try VideoEdits.plan(
            operation, input: input, source: #require(input.video), settings: VideoSettings())
        let newFile = context(folder: folder, mode: .newFile)
        _ = try await VideoProperties.prepare(plan, input: input, context: newFile)
        #expect(newFile.warnings == [.videoMetadataDropped([.trackMetadata])])
        var derivedPlan = plan
        derivedPlan.derived = true
        _ = try await VideoProperties.prepare(derivedPlan, input: input, context: replacement)
        #expect(replacement.warnings == [.videoMetadataDropped([.trackMetadata])])
        #expect(try Data(contentsOf: source) == original)
    }

    private func context(folder: URL, mode: Settings.OutputMode) -> ItemContext {
        var settings = Settings()
        settings.outputMode = mode
        return ItemContext(settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
    }

    private func staged(_ result: ItemResult) throws -> URL {
        guard case .replace(_, let output) = result else {
            Issue.record("expected staged video")
            throw CancellationError()
        }
        return output.url
    }

    private func videoPackets(_ url: URL) throws -> [Data] {
        var demuxer = try MatroskaDemuxer(url: url)
        var payloads: [Data] = []
        while let packet = try demuxer.nextPacket() {
            if packet.track == 1 { payloads.append(packet.payload) }
        }
        return payloads
    }

    private func fixture(
        folder: URL, width: Int = 64, height: Int = 48, fields: [(UInt32, UInt64)], audio: Bool = false
    ) throws -> URL {
        let image = try ImageFixtures.canvas(width: width, height: height) { canvas in
            canvas.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
            canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
            canvas.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            canvas.fill(CGRect(x: 4, y: 4, width: width / 2 - 4, height: height - 12))
            canvas.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            canvas.fill(CGRect(x: width / 2, y: 4, width: width / 2 - 4, height: height - 12))
        }
        let jpeg = try ImageEncoder.encode(
            [ImageFrame(image: image, duration: 0)], as: .jpeg,
            options: EncodeOptions(quality: ImageEncoder.maximumQuality))
        let header = EBML.element(MatroskaID.ebml, EBML.element(MatroskaID.docType, string: "matroska"))
        let dimensions =
            EBML.element(MatroskaID.pixelWidth, unsigned: UInt64(width))
            + EBML.element(MatroskaID.pixelHeight, unsigned: UInt64(height))
            + fields.flatMap { EBML.element($0.0, unsigned: $0.1) }
        var tracks = EBML.element(
            MatroskaID.trackEntry,
            EBML.element(MatroskaID.trackNumber, unsigned: 1)
                + EBML.element(MatroskaID.trackType, unsigned: 1)
                + EBML.element(MatroskaID.codecID, string: "V_MJPEG")
                + EBML.element(MatroskaID.defaultDuration, unsigned: 125_000_000)
                + EBML.element(MatroskaID.video, dimensions))
        var blocks = EBML.element(MatroskaID.clusterTimestamp, unsigned: 0)
        if audio {
            tracks += EBML.element(
                MatroskaID.trackEntry,
                EBML.element(MatroskaID.trackNumber, unsigned: 2)
                    + EBML.element(MatroskaID.trackType, unsigned: 2)
                    + EBML.element(MatroskaID.codecID, string: "A_PCM/INT/LIT")
                    + EBML.element(
                        MatroskaID.audio,
                        EBML.element(MatroskaID.samplingFrequency, float: 8_000)
                            + EBML.element(MatroskaID.channels, unsigned: 1)
                            + EBML.element(MatroskaID.bitDepth, unsigned: 16)))
            blocks += EBML.element(MatroskaID.simpleBlock, [0x82, 0, 0, 0x80] + [UInt8](repeating: 0, count: 16_000))
        }
        for index in 0..<8 {
            let timestamp = UInt16(index * 125)
            blocks += EBML.element(
                MatroskaID.simpleBlock,
                [0x81, UInt8(timestamp >> 8), UInt8(truncatingIfNeeded: timestamp), 0x80] + jpeg)
        }
        let segment =
            EBML.element(MatroskaID.info, EBML.element(MatroskaID.duration, float: 1_000))
            + EBML.element(MatroskaID.tracks, tracks) + EBML.element(MatroskaID.cluster, blocks)
        let source = folder.appending(path: "display.mkv")
        try Data(header + EBML.element(MatroskaID.segment, segment)).write(to: source)
        return source
    }
}
