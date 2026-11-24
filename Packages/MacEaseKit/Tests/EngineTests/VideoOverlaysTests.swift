import AVFoundation
import CoreGraphics
import CoreVideo
import Formats
import Foundation
import Testing

@testable import Engine

@Suite(.serialized) struct VideoOverlaysTests {
    private static let frameRate = 30
    private static let duration = 2.0

    @Test func legacyVideoEditsDecodeWithoutOverlaysAndRejectLegacyOverlays() async throws {
        let legacy = Data(#"{"start":0,"end":2,"speed":1,"trimMode":"exact"}"#.utf8)
        let decoded = try JSONDecoder().decode(VideoEdit.self, from: legacy)
        #expect(decoded.overlays.isEmpty)
        #expect(!decoded.changesColor)
        #expect(!decoded.changesAppearance)

        let overlay = TimedOverlay(
            overlay: EditOverlay(
                mark: .redaction(rect: EditCrop(x: 0.2, y: 0.2, width: 0.3, height: 0.3), style: .solid)),
            start: 0.5, end: 1.5)
        var segmented = VideoEdit(start: 0, end: 2)
        segmented.segments = [VideoSegment(start: 0, end: 2)]
        segmented.overlays = [overlay]
        #expect(segmented.changesColor)
        #expect(segmented.changesAppearance)
        let restored = try JSONDecoder().decode(VideoEdit.self, from: JSONEncoder().encode(segmented))
        #expect(restored == segmented)

        var legacyWithOverlay = VideoEdit(start: 0, end: 2)
        legacyWithOverlay.overlays = [overlay]
        #expect(throws: EngineError.self) { try VideoTimeline(edit: legacyWithOverlay, sourceDuration: 2) }

        let source = try await videoFixture(width: 128, height: 96, duration: 1)
        let input = try await MediaInput.open(source)
        let track = try #require(input.video)
        #expect(throws: EngineError.self) {
            try VideoEdits.plan(.edit(legacyWithOverlay), input: input, source: track, settings: VideoSettings())
        }
    }

    @Test func timelineRejectsInvalidTimedOverlays() throws {
        let validMark = EditOverlay(
            mark: .redaction(rect: EditCrop(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .mosaic))
        let duplicateID = UUID()
        let invalidLists: [[TimedOverlay]] = [
            [TimedOverlay(overlay: validMark, sourceIndex: -1, start: 0, end: 1)],
            [TimedOverlay(overlay: validMark, sourceIndex: 1, start: 0, end: 1)],
            [TimedOverlay(overlay: validMark, start: -0.1, end: 1)],
            [TimedOverlay(overlay: validMark, start: 1, end: 1)],
            [TimedOverlay(overlay: validMark, start: 1.5, end: 1)],
            [TimedOverlay(overlay: validMark, start: 0, end: 2.1)],
            [TimedOverlay(overlay: validMark, start: .nan, end: 1)],
            [
                TimedOverlay(overlay: EditOverlay(id: duplicateID, mark: validMark.mark), start: 0, end: 1),
                TimedOverlay(overlay: EditOverlay(id: duplicateID, mark: validMark.mark), start: 1, end: 2),
            ],
            [
                TimedOverlay(
                    overlay: EditOverlay(mark: .text(" ", at: EditPoint(x: 0.5, y: 0.5), color: .red, size: .small)),
                    start: 0, end: 1)
            ],
            (0...EditOverlay.maximumCount).map { _ in
                TimedOverlay(overlay: EditOverlay(mark: validMark.mark), start: 0, end: 1)
            },
        ]
        for list in invalidLists {
            var edit = VideoEdit()
            edit.segments = [VideoSegment(start: 0, end: 2)]
            edit.overlays = list
            #expect(throws: EngineError.self) { try VideoTimeline(edit: edit, sourceDuration: 2) }
        }
    }

    @Test func overlaysAtSurviveSplitReorderDuplicateSpeedAndMultiSource() throws {
        let mark = EditOverlay(
            mark: .redaction(rect: EditCrop(x: 0.1, y: 0.1, width: 0.3, height: 0.3), style: .solid))
        let timed = TimedOverlay(overlay: mark, start: 1, end: 3)

        var split = VideoEdit()
        split.segments = [VideoSegment(start: 0, end: 2), VideoSegment(start: 2, end: 4)]
        split.overlays = [timed]
        let splitTimeline = try VideoTimeline(edit: split, sourceDuration: 4)
        #expect(splitTimeline.overlays(at: 0.5).isEmpty)
        #expect(splitTimeline.overlays(at: 1.5) == [mark])
        #expect(splitTimeline.overlays(at: 2.5) == [mark])
        #expect(splitTimeline.overlays(at: 3.0).isEmpty)

        var reordered = VideoEdit()
        reordered.segments = [VideoSegment(start: 2, end: 4), VideoSegment(start: 0, end: 2)]
        reordered.overlays = [timed]
        let reorderedTimeline = try VideoTimeline(edit: reordered, sourceDuration: 4)
        #expect(reorderedTimeline.overlays(at: 0.5) == [mark])
        #expect(reorderedTimeline.overlays(at: 1.5).isEmpty)
        #expect(reorderedTimeline.overlays(at: 2.5).isEmpty)
        #expect(reorderedTimeline.overlays(at: 3.5) == [mark])

        var duplicated = VideoEdit()
        duplicated.segments = [
            VideoSegment(start: 0, end: 2, speed: 2),
            VideoSegment(start: 0, end: 2, speed: 0.5),
        ]
        let inner = EditOverlay(
            mark: .box(rect: EditCrop(x: 0.2, y: 0.2, width: 0.4, height: 0.4), color: .red, size: .medium))
        duplicated.overlays = [TimedOverlay(overlay: inner, start: 0.5, end: 1.5)]
        let duplicatedTimeline = try VideoTimeline(edit: duplicated, sourceDuration: 2)
        #expect(duplicatedTimeline.overlays(at: 0.1).isEmpty)
        #expect(duplicatedTimeline.overlays(at: 0.5) == [inner])
        #expect(duplicatedTimeline.overlays(at: 0.9).isEmpty)
        #expect(duplicatedTimeline.overlays(at: 1.5).isEmpty)
        #expect(duplicatedTimeline.overlays(at: 3.0) == [inner])
        #expect(duplicatedTimeline.overlays(at: 4.5).isEmpty)

        let folder = try AudioSignals.temporaryFolder()
        let firstURL = folder.appending(path: "a.mp4")
        let secondURL = folder.appending(path: "b.mp4")
        try Data([1]).write(to: firstURL)
        try Data([2]).write(to: secondURL)
        var joined = VideoEdit()
        joined.sources = [
            VideoEditSource(url: firstURL, duration: 2, stamp: try MediaSourceStamp(url: firstURL)),
            VideoEditSource(url: secondURL, duration: 3, stamp: try MediaSourceStamp(url: secondURL)),
        ]
        joined.segments = [
            VideoSegment(start: 0, end: 2, sourceIndex: 0), VideoSegment(start: 0, end: 3, sourceIndex: 1),
        ]
        let secondMark = EditOverlay(mark: .text("B", at: EditPoint(x: 0.5, y: 0.5), color: .white, size: .small))
        joined.overlays = [TimedOverlay(overlay: secondMark, sourceIndex: 1, start: 1, end: 2)]
        let joinedTimeline = try VideoTimeline(edit: joined, sourceDuration: 2)
        #expect(joinedTimeline.overlays(at: 1.5).isEmpty)
        #expect(joinedTimeline.overlays(at: 3.5) == [secondMark])
        #expect(joinedTimeline.overlays(at: 4.5).isEmpty)
    }

    @Test func outputRangesMapAcrossSplitReorderDuplicateSpeedAndSources() throws {
        let mark = EditOverlay(mark: .redaction(rect: EditCrop(x: 0, y: 0, width: 0.5, height: 0.5), style: .blur))
        let timed = TimedOverlay(overlay: mark, start: 1, end: 3)

        var split = VideoEdit()
        split.segments = [VideoSegment(start: 0, end: 2), VideoSegment(start: 2, end: 4)]
        split.overlays = [timed]
        let splitRanges = try VideoTimeline(edit: split, sourceDuration: 4).outputRanges(of: timed)
        #expect(splitRanges.count == 1)
        #expect(abs(splitRanges[0].lowerBound - 1) < 1e-9 && abs(splitRanges[0].upperBound - 3) < 1e-9)

        var reordered = VideoEdit()
        reordered.segments = [VideoSegment(start: 2, end: 4), VideoSegment(start: 0, end: 2)]
        reordered.overlays = [timed]
        let reorderedRanges = try VideoTimeline(edit: reordered, sourceDuration: 4).outputRanges(of: timed)
        #expect(reorderedRanges.count == 2)
        #expect(abs(reorderedRanges[0].lowerBound - 0) < 1e-9 && abs(reorderedRanges[0].upperBound - 1) < 1e-9)
        #expect(abs(reorderedRanges[1].lowerBound - 3) < 1e-9 && abs(reorderedRanges[1].upperBound - 4) < 1e-9)

        let short = TimedOverlay(overlay: mark, start: 1, end: 2)
        var duplicated = VideoEdit()
        duplicated.segments = [VideoSegment(start: 0, end: 3), VideoSegment(start: 0, end: 3)]
        duplicated.overlays = [short]
        let duplicatedRanges = try VideoTimeline(edit: duplicated, sourceDuration: 3).outputRanges(of: short)
        #expect(duplicatedRanges.count == 2)
        #expect(abs(duplicatedRanges[0].lowerBound - 1) < 1e-9 && abs(duplicatedRanges[0].upperBound - 2) < 1e-9)
        #expect(abs(duplicatedRanges[1].lowerBound - 4) < 1e-9 && abs(duplicatedRanges[1].upperBound - 5) < 1e-9)

        var sped = VideoEdit()
        sped.segments = [VideoSegment(start: 0, end: 4, speed: 2)]
        sped.overlays = [timed]
        let spedRanges = try VideoTimeline(edit: sped, sourceDuration: 4).outputRanges(of: timed)
        #expect(spedRanges.count == 1)
        #expect(abs(spedRanges[0].lowerBound - 0.5) < 1e-9 && abs(spedRanges[0].upperBound - 1.5) < 1e-9)
    }

    @Test func frameProcessorAppliesRedactionsAnnotationsFadesAndCachesLayer() throws {
        let size = PixelSize(width: 320, height: 240)
        let buffer = try solidFrame(width: size.width, height: size.height, red: 60, green: 180, blue: 220)
        let redaction = EditOverlay(
            mark: .redaction(rect: EditCrop(x: 0.05, y: 0.05, width: 0.3, height: 0.3), style: .solid))
        let plainProcessor = try FrameProcessor(source: size, edit: FrameEdit())
        let plainOutput = try CGImage.make(from: try plainProcessor.process(buffer, fade: 1, overlays: [redaction]))
        let plainRedacted = try ImageFixtures.pixel(plainOutput, x: 60, y: 40)
        #expect(plainRedacted[0] == 0 && plainRedacted[1] == 0 && plainRedacted[2] == 0)
        let plainOutside = try ImageFixtures.pixel(plainOutput, x: 280, y: 40)
        #expect(abs(Int(plainOutside[0]) - 60) <= 2 && abs(Int(plainOutside[2]) - 220) <= 2)

        var monochrome = MediaAdjustments()
        monochrome.style = .monochrome
        var edit = FrameEdit()
        edit.adjustments = monochrome
        edit.hasAnnotations = true
        let processor = try FrameProcessor(source: size, edit: edit)

        let arrow = EditOverlay(
            mark: .arrow(from: EditPoint(x: 0.2, y: 0.75), to: EditPoint(x: 0.8, y: 0.75), color: .red, size: .large))

        let first = try processor.process(buffer, fade: 1, overlays: [redaction, arrow])
        let firstImage = try CGImage.make(from: first)
        let redactedPixel = try ImageFixtures.pixel(firstImage, x: 60, y: 40)
        #expect(redactedPixel[0] < 30 && redactedPixel[1] < 30 && redactedPixel[2] < 30)
        let arrowPixel = try ImageFixtures.pixel(firstImage, x: 160, y: 179)
        #expect(arrowPixel[0] > 200 && arrowPixel[1] < 80 && arrowPixel[2] < 80)
        let backgroundPixel = try ImageFixtures.pixel(firstImage, x: 280, y: 40)
        #expect(abs(Int(backgroundPixel[0]) - Int(backgroundPixel[2])) <= 4)

        let faded = try processor.process(buffer, fade: 0.5, overlays: [redaction, arrow])
        let fadedImage = try CGImage.make(from: faded)
        let fadedArrow = try ImageFixtures.pixel(fadedImage, x: 160, y: 179)
        #expect(fadedArrow[0] < arrowPixel[0] - 40 && fadedArrow[0] > 40)

        let blueArrow = EditOverlay(
            mark: .arrow(from: EditPoint(x: 0.2, y: 0.75), to: EditPoint(x: 0.8, y: 0.75), color: .blue, size: .large))
        let switched = try processor.process(buffer, fade: 1, overlays: [blueArrow])
        let switchedImage = try CGImage.make(from: switched)
        let bluePixel = try ImageFixtures.pixel(switchedImage, x: 160, y: 179)
        #expect(bluePixel[2] > 200 && bluePixel[0] < 80)
    }

    @Test func videoPreviewAndExportMatchWithTimedOverlays() async throws {
        let source = try await videoFixture(width: 640, height: 480, duration: Self.duration)
        var monochrome = MediaAdjustments()
        monochrome.style = .monochrome
        var edit = VideoEdit(start: 0, end: Self.duration)
        edit.segments = [VideoSegment(start: 0, end: Self.duration, adjustments: monochrome)]
        edit.overlays = [
            TimedOverlay(
                overlay: EditOverlay(
                    mark: .redaction(rect: EditCrop(x: 0.1, y: 0.1, width: 0.35, height: 0.35), style: .solid)),
                start: 0.5, end: 1.5),
            TimedOverlay(
                overlay: EditOverlay(
                    mark: .arrow(
                        from: EditPoint(x: 0.2, y: 0.75), to: EditPoint(x: 0.8, y: 0.75), color: .red, size: .large)),
                start: 0.5, end: 1.5),
        ]

        let input = try await MediaInput.open(source)
        let track = try #require(input.video)
        let plan = try VideoEdits.plan(.edit(edit), input: input, source: track, settings: VideoSettings())
        let output = source.deletingLastPathComponent().appending(path: "exported.mov")
        try await Transcoder.run(input, plan: plan, to: output) { _ in }

        let editor = try await VideoEditorSource.open(
            source, staging: StagingArea(supportDirectory: AudioSignals.temporaryFolder()))
        defer { Task { await editor.close() } }
        let playback = try await editor.playback(edit: edit)
        #expect(playback.videoComposition != nil)

        let saved = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        let preview = AVAssetImageGenerator(asset: playback.asset)
        preview.videoComposition = playback.videoComposition
        for generator in [saved, preview] {
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }

        for second in [0.25, 1.0, 1.75] {
            let time = CMTime(seconds: second, preferredTimescale: 60_000)
            let (exported, _) = try await saved.image(at: time)
            let (shown, _) = try await preview.image(at: time)
            #expect(exported.width == shown.width && exported.height == shown.height)

            let redactExport = try ImageFixtures.pixel(exported, x: 160, y: 120)
            let redactPreview = try ImageFixtures.pixel(shown, x: 160, y: 120)
            let arrowExport = try ImageFixtures.pixel(exported, x: 320, y: 359)
            let arrowPreview = try ImageFixtures.pixel(shown, x: 320, y: 359)

            if second == 1.0 {
                #expect(redactExport[0] < 30 && redactExport[1] < 30 && redactExport[2] < 30)
                #expect(arrowExport[0] > 180 && arrowExport[1] < 90 && arrowExport[2] < 90)
            } else {
                #expect(redactExport[0] > 80)
                #expect(abs(Int(arrowExport[0]) - Int(arrowExport[2])) <= 15)
            }
            #expect(
                zip(redactExport, redactPreview).allSatisfy { abs(Int($0) - Int($1)) <= 20 },
                "redaction mismatch at \(second): export \(redactExport) vs preview \(redactPreview)")
            #expect(
                zip(arrowExport, arrowPreview).allSatisfy { abs(Int($0) - Int($1)) <= 25 },
                "arrow mismatch at \(second): export \(arrowExport) vs preview \(arrowPreview)")
        }
    }

    @Test func hdrVideoWithOverlayBecomesDerivedSDR() async throws {
        let fixture = try #require(
            Bundle.module.url(forResource: "x265-pq.mp4", withExtension: nil, subdirectory: "Resources"))
        let folder = try AudioSignals.temporaryFolder()
        let source = folder.appending(path: "x265-pq.mp4")
        try FileManager.default.copyItem(at: fixture, to: source)
        let original = try Data(contentsOf: source)
        let input = try await MediaInput.open(source)
        let sourceDuration = Double(input.duration) / Double(Nanoseconds.perSecond)

        var edit = VideoEdit(start: 0, end: sourceDuration)
        edit.segments = [VideoSegment(start: 0, end: sourceDuration)]
        edit.overlays = [
            TimedOverlay(
                overlay: EditOverlay(
                    mark: .redaction(rect: EditCrop(x: 0.2, y: 0.2, width: 0.6, height: 0.6), style: .solid)),
                start: 0, end: sourceDuration)
        ]

        var settings = Settings()
        settings.outputMode = .replace
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }

        let result = try await VideoEdits.run(.edit(edit), url: source, context: context)
        guard case .derived(_, let outputs) = result, let output = outputs.first else {
            Issue.record("expected derived SDR output for HDR video with overlays")
            return
        }
        #expect(output.url != source)
        #expect(try Data(contentsOf: source) == original)
        #expect(context.warnings.contains(.videoToneMappedToSDR))
        let written = try await MediaInput.open(output.url)
        #expect(try await VideoProperties.hdrConfiguration(written) == nil)
        try await VideoSDR.verify(output.url)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output.url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (frame, _) = try await generator.image(at: CMTime(seconds: sourceDuration / 2, preferredTimescale: 600))
        let center = try ImageFixtures.pixel(frame, x: frame.width / 2, y: frame.height / 2)
        #expect(center[0] < 20 && center[1] < 20 && center[2] < 20)
    }

    private func solidFrame(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) throws -> CVPixelBuffer {
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

    private func videoFixture(width: Int, height: Int, duration: Double) async throws -> URL {
        let folder = try AudioSignals.temporaryFolder()
        let url = folder.appending(path: "source.mov")
        let encoding = VideoEncoding(
            codec: .h264, width: width, height: height,
            frameDuration: Nanoseconds.perSecond / Int64(Self.frameRate), bitrate: nil)
        var encoder = try VideoEncoders.make(encoding, track: 1)
        let frame = try solidFrame(width: width, height: height, red: 60, green: 180, blue: 220)
        var packets: [MediaPacket] = []
        for index in 0..<Int(duration * Double(Self.frameRate)) {
            let timestamp = try Nanoseconds.from(seconds: Double(index) / Double(Self.frameRate))
            packets += try encoder.encode(frame, timestamp: timestamp)
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
        return url
    }
}
