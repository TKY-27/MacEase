import AVFoundation
import CoreGraphics
import CoreVideo
import Formats
import Foundation
import ImageIO
import Testing

@testable import Engine

@Suite(.serialized) struct VideoFrameToolsTests {
    private static let frameRate = 30
    private static let clipDuration = 2.0
    private static let frameWidth = 320
    private static let frameHeight = 240

    @Test func editedStillMatchesExportedFrameWithGeometryColorOverlaysAndFade() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "clip.mov")
        try await writeGradientVideo(
            to: source, width: Self.frameWidth, height: Self.frameHeight, duration: Self.clipDuration)
        let originalBytes = try Data(contentsOf: source)

        var segment = VideoSegment(start: 0, end: Self.clipDuration)
        segment.fadeIn = 1.0
        segment.adjustments.style = .monochrome
        segment.adjustments[.exposure] = 0.2
        var edit = VideoEdit(start: 0, end: Self.clipDuration)
        edit.geometry.quarterTurns = 1
        edit.geometry.crop = EditCrop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        edit.segments = [segment]
        edit.overlays = [
            TimedOverlay(
                overlay: EditOverlay(
                    mark: .redaction(rect: EditCrop(x: 0.15, y: 0.15, width: 0.3, height: 0.3), style: .solid)),
                start: 0.2, end: 1.5),
            TimedOverlay(
                overlay: EditOverlay(
                    mark: .arrow(
                        from: EditPoint(x: 0.2, y: 0.75), to: EditPoint(x: 0.8, y: 0.75), color: .red, size: .large)),
                start: 0.2, end: 1.5),
        ]

        let input = try await MediaInput.open(source)
        let track = try #require(input.video)
        let plan = try VideoEdits.plan(.edit(edit), input: input, source: track, settings: VideoSettings())
        let exportedVideo = folder.appending(path: "exported.mov")
        try await Transcoder.run(input, plan: plan, to: exportedVideo) { _ in }

        let targetSeconds = 0.5
        let engine = try JobEngine(supportDirectory: AudioSignals.temporaryFolder(), concurrency: 1)
        var settings = Settings()
        settings.video.thumbnailFormat = .png
        let outcome = await engine.run(
            MediaEditing.frame(url: source, edit: edit, outputSeconds: targetSeconds, settings: settings),
            settings: settings
        ) { _ in }
        guard case .succeeded(let outputs, _) = outcome.outcomes.first, let stillURL = outputs.first else {
            Issue.record("expected edited still output")
            return
        }
        #expect(stillURL.lastPathComponent == "clip_frame_0-00.500.png")
        #expect(try Data(contentsOf: source) == originalBytes)

        let stillImage = try ImageFixtures.image(stillURL)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: exportedVideo))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (exportedFrame, _) = try await generator.image(
            at: CMTime(seconds: targetSeconds, preferredTimescale: 60_000))

        #expect(stillImage.width == exportedFrame.width)
        #expect(stillImage.height == exportedFrame.height)
        for sampleX in stride(from: 12, to: stillImage.width - 12, by: 24) {
            for sampleY in stride(from: 12, to: stillImage.height - 12, by: 24) {
                let expected = try ImageFixtures.pixel(exportedFrame, x: sampleX, y: sampleY)
                let actual = try ImageFixtures.pixel(stillImage, x: sampleX, y: sampleY)
                #expect(
                    zip(expected, actual).allSatisfy { abs(Int($0) - Int($1)) <= 20 },
                    "pixel mismatch at (\(sampleX),\(sampleY)): still \(actual) vs export \(expected)")
            }
        }

        settings.video.thumbnailFormat = .jpeg
        let jpegOutcome = await engine.run(
            MediaEditing.frame(url: source, edit: edit, outputSeconds: 1.25, settings: settings),
            settings: settings
        ) { _ in }
        guard case .succeeded(let jpegOutputs, _) = jpegOutcome.outcomes.first, let jpegURL = jpegOutputs.first else {
            Issue.record("expected JPEG edited still output")
            return
        }
        #expect(jpegURL.lastPathComponent == "clip_frame_0-01.250.jpeg")
        let jpegImage = try ImageFixtures.image(jpegURL)
        #expect(jpegImage.width == exportedFrame.width && jpegImage.height == exportedFrame.height)

        let record = try #require(outcome.record)
        #expect(try await engine.history.undo(record.id) == [.restored])
        #expect(!FileManager.default.fileExists(atPath: stillURL.path))
        #expect(try Data(contentsOf: source) == originalBytes)
    }

    @Test func editedStillToneMapsHDRSupportsMultiSourceAndValidatesRange() async throws {
        let fixture = try #require(
            Bundle.module.url(forResource: "x265-pq.mp4", withExtension: nil, subdirectory: "Resources"))
        let folder = try TestVolume.makeFolder()
        let hdrSource = folder.appending(path: "hdr.mp4")
        try FileManager.default.copyItem(at: fixture, to: hdrSource)
        let originalHDR = try Data(contentsOf: hdrSource)
        let hdrInput = try await MediaInput.open(hdrSource)
        let hdrDuration = Double(hdrInput.duration) / Double(Nanoseconds.perSecond)

        var hdrEdit = VideoEdit(start: 0, end: hdrDuration)
        hdrEdit.segments = [VideoSegment(start: 0, end: hdrDuration)]
        hdrEdit.overlays = [
            TimedOverlay(
                overlay: EditOverlay(
                    mark: .redaction(rect: EditCrop(x: 0.25, y: 0.25, width: 0.5, height: 0.5), style: .solid)),
                start: 0, end: hdrDuration)
        ]
        let roundTrip = try JSONDecoder().decode(
            VideoStill.self, from: JSONEncoder().encode(VideoStill.edited(hdrEdit, outputSeconds: 0.2)))
        #expect(roundTrip == .edited(hdrEdit, outputSeconds: 0.2))

        let hdrContext = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: try AudioSignals.temporaryFolder()),
            progress: { _ in })
        defer { hdrContext.removeStaging() }
        guard
            case .derived(_, let hdrOutputs) = try await VideoStills.run(
                .edited(hdrEdit, outputSeconds: hdrDuration / 2), url: hdrSource, context: hdrContext),
            let hdrStill = hdrOutputs.first
        else {
            Issue.record("expected HDR edited still")
            return
        }
        #expect(hdrContext.warnings.contains(.videoToneMappedToSDR))
        #expect(try Data(contentsOf: hdrSource) == originalHDR)
        let hdrImage = try ImageFixtures.image(hdrStill.url)
        let center = try ImageFixtures.pixel(hdrImage, x: hdrImage.width / 2, y: hdrImage.height / 2)
        #expect(center[0] < 20 && center[1] < 20 && center[2] < 20)

        let redClip = folder.appending(path: "red.mov")
        let blueClip = folder.appending(path: "blue.mov")
        try await writeSolidVideo(to: redClip, width: 160, height: 120, duration: 1.0, red: 220, green: 30, blue: 30)
        try await writeSolidVideo(to: blueClip, width: 160, height: 120, duration: 1.0, red: 30, green: 40, blue: 220)
        var joinedEdit = VideoEdit()
        joinedEdit.sources = [
            VideoEditSource(url: redClip, duration: 1.0, stamp: try MediaSourceStamp(url: redClip)),
            VideoEditSource(url: blueClip, duration: 1.0, stamp: try MediaSourceStamp(url: blueClip)),
        ]
        joinedEdit.segments = [
            VideoSegment(start: 0, end: 1.0, sourceIndex: 0),
            VideoSegment(start: 0, end: 1.0, sourceIndex: 1),
        ]
        let engine = try JobEngine(supportDirectory: AudioSignals.temporaryFolder(), concurrency: 1)
        let joinedOutcome = await engine.run(
            MediaEditing.frame(url: redClip, edit: joinedEdit, outputSeconds: 1.5, settings: Settings()),
            settings: Settings()
        ) { _ in }
        guard case .succeeded(let joinedOutputs, _) = joinedOutcome.outcomes.first,
            let joinedStill = joinedOutputs.first
        else {
            Issue.record("expected multi-source edited still")
            return
        }
        let joinedPixel = try ImageFixtures.pixel(try ImageFixtures.image(joinedStill), x: 80, y: 60)
        #expect(joinedPixel[2] > 180 && joinedPixel[0] < 70)

        for invalid in [-0.1, Double.nan, 2.5] {
            let checkContext = ItemContext(
                settings: Settings(), staging: StagingArea(supportDirectory: try AudioSignals.temporaryFolder()),
                progress: { _ in })
            defer { checkContext.removeStaging() }
            await #expect(throws: EngineError.self) {
                _ = try await VideoStills.run(
                    .edited(joinedEdit, outputSeconds: invalid), url: redClip, context: checkContext)
            }
        }
    }

    private func solidBuffer(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        try #require(
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &created) == kCVReturnSuccess)
        let buffer = try #require(created)
        try #require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowBytes + x * 4
                base[offset] = blue
                base[offset + 1] = green
                base[offset + 2] = red
                base[offset + 3] = 255
            }
        }
        return buffer
    }

    private func writeSolidVideo(
        to url: URL, width: Int, height: Int, duration: Double, red: UInt8, green: UInt8, blue: UInt8
    ) async throws {
        let frame = try solidBuffer(width: width, height: height, red: red, green: green, blue: blue)
        try await writeVideo(to: url, width: width, height: height, duration: duration) { _ in frame }
    }

    private func writeGradientVideo(to url: URL, width: Int, height: Int, duration: Double) async throws {
        let totalFrames = Int(duration * Double(Self.frameRate))
        try await writeVideo(to: url, width: width, height: height, duration: duration) { index in
            let progress = Double(index) / Double(max(1, totalFrames - 1))
            let red = UInt8((40 + progress * 180).rounded())
            let green = UInt8((200 - progress * 120).rounded())
            let blue = UInt8((80 + progress * 140).rounded())
            return try solidBuffer(width: width, height: height, red: red, green: green, blue: blue)
        }
    }

    private func writeVideo(
        to url: URL, width: Int, height: Int, duration: Double, makeFrame: (Int) throws -> CVPixelBuffer
    ) async throws {
        let encoding = VideoEncoding(
            codec: .h264, width: width, height: height,
            frameDuration: Nanoseconds.perSecond / Int64(Self.frameRate), bitrate: nil)
        var encoder = try VideoEncoders.make(encoding, track: 1)
        var packets: [MediaPacket] = []
        for index in 0..<Int(duration * Double(Self.frameRate)) {
            let timestamp = try Nanoseconds.from(seconds: Double(index) / Double(Self.frameRate))
            packets += try encoder.encode(try makeFrame(index), timestamp: timestamp)
        }
        packets += try encoder.finish()
        var sink = try Sinks.make(
            .mov, url: url, tracks: [OutputTrack(track: encoder.track, format: encoder.formatDescription)],
            transform: .identity)
        for packet in packets.sorted(by: { ($0.decodeTimestamp ?? $0.timestamp) < ($1.decodeTimestamp ?? $1.timestamp) }
        ) {
            try await sink.write(packet)
        }
        sink.endTrack(1)
        try await sink.finish()
    }
}
