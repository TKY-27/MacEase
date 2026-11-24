import AVFoundation
import CoreVideo
import Formats
import Foundation
import Synchronization
import Testing

@testable import Engine

@Suite(.serialized) struct VideoReverseSafetyTests {
    @Test func editorReverseUsesOnlyGrantedStreamConsent() async throws {
        let source = try #require(
            Bundle.module.url(forResource: "reverse-timecode.mov", withExtension: nil, subdirectory: "Resources"))
        let input = try await MediaInput.open(source)
        #expect(MediaInput.unpreservedStreams(from: input.skippedStreams).contains(.timecode))
        let segment = VideoSegment(start: 0, end: 0.5)
        var edit = VideoEdit()
        edit.segments = [segment]
        let staging = StagingArea(supportDirectory: try AudioSignals.temporaryFolder())
        await #expect(throws: EngineError.invalidInput(.unpreservedStreams([.timecode]))) {
            _ = try await VideoEditorSource.open(source, staging: staging)
        }
        await #expect(throws: EngineError.invalidInput(.unpreservedStreams([.timecode]))) {
            _ = try await VideoSegmentReverser.reverse(
                segmentID: segment.id, in: edit, primaryURL: source, staging: staging, omittedStreams: [.subtitle])
        }
        let editor = try await VideoEditorSource.open(
            source, staging: staging,
            omission: StreamOmission(stamp: try MediaSourceStamp(url: source), streams: [.timecode]))
        let reversed = try await editor.reverse(segmentID: segment.id, in: edit)
        let staged = try #require(reversed.sources?.last?.url)
        #expect(FileManager.default.fileExists(atPath: staged.path))
        await editor.close()
        #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    @Test func unreverseClampsOverlayEndpointsAndDistinguishesInvalidActions() async throws {
        let source = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac.mp4", withExtension: nil, subdirectory: "Resources"))
        let stamp = try MediaSourceStamp(url: source)
        let duration = 1.91.nextDown
        let origin = ReversedSegmentOrigin(sourceIndex: 0, start: 0, end: 1.91)
        let segment = VideoSegment(start: 0, end: duration, sourceIndex: 1, reversedOrigin: origin)
        var edit = VideoEdit()
        edit.sources = [
            VideoEditSource(url: source, duration: 2, stamp: stamp),
            VideoEditSource(url: source, duration: duration, stamp: stamp, reversedOrigin: origin),
        ]
        edit.segments = [segment]
        edit.overlays = [
            TimedOverlay(
                overlay: EditOverlay(mark: .redaction(rect: EditCrop(), style: .solid)), sourceIndex: 1, start: 0,
                end: duration)
        ]
        let restored = try VideoSegmentReverser.unreverse(segmentID: segment.id, in: edit)
        #expect(restored.overlays.first?.start == 0)
        #expect(restored.overlays.first?.end == 1.91)
        _ = try VideoTimeline(edit: restored, sourceDuration: 2)
        #expect(origin.mappedTime(-1, stagedDuration: duration, toOriginal: true) == 1.91)
        #expect(origin.mappedTime(2, stagedDuration: duration, toOriginal: true) == 0)
        #expect(origin.mappedTime(-1, stagedDuration: duration, toOriginal: false) == duration)
        #expect(origin.mappedTime(2, stagedDuration: duration, toOriginal: false) == 0)
        let staging = StagingArea(supportDirectory: try AudioSignals.temporaryFolder())
        await #expect(throws: EngineError.invalidInput(.videoSegmentNotFound)) {
            _ = try await VideoSegmentReverser.reverse(
                segmentID: UUID(), in: edit, primaryURL: source, staging: staging)
        }
        let freeze = VideoSegment(start: 0, end: 0.1, volume: 0, freezeDuration: 1)
        edit.segments = [freeze]
        await #expect(throws: EngineError.invalidInput(.cannotReverseFreeze)) {
            _ = try await VideoSegmentReverser.reverse(
                segmentID: freeze.id, in: edit, primaryURL: source, staging: staging)
        }
    }

    @Test func unreverseKeepsStagedAnnotationsOnDuplicateAndLinkedFreeze() throws {
        let source = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac.mp4", withExtension: nil, subdirectory: "Resources"))
        let stamp = try MediaSourceStamp(url: source)
        let origin = ReversedSegmentOrigin(sourceIndex: 0, start: 0, end: 1)
        let frames: [ReversedSourceFrame] = (0..<5).map { index in
            let stagedStart = Double(index) / 5
            let stagedEnd = Double(index + 1) / 5
            let sourceStart = Double(4 - index) / 5
            let sourceEnd = Double(5 - index) / 5
            return ReversedSourceFrame(
                stagedStart: stagedStart, stagedEnd: stagedEnd,
                sourceStart: sourceStart, sourceEnd: sourceEnd)
        }
        let first = VideoSegment(start: 0, end: 1, sourceIndex: 1)
        let copy = VideoSegment(start: 0, end: 1, sourceIndex: 1)
        let freeze = VideoSegment(start: 0.2, end: 0.21, volume: 0, sourceIndex: 1, freezeDuration: 1)
        let annotation = EditOverlay(mark: .box(rect: EditCrop(), color: .blue, size: .large))
        var edit = VideoEdit()
        edit.sources = [
            VideoEditSource(url: source, duration: 1, stamp: stamp),
            VideoEditSource(url: source, duration: 1, stamp: stamp, reversedOrigin: origin, reversedFrames: frames),
        ]
        edit.segments = [first, copy, freeze]
        edit.overlays = [TimedOverlay(overlay: annotation, sourceIndex: 1, start: 0.01, end: 0.21)]
        let restored = try VideoSegmentReverser.unreverse(segmentID: first.id, in: edit)
        let timeline = try VideoTimeline(edit: restored, sourceDuration: 1)
        #expect(timeline.overlays(at: 0.65, sourceRange: 0.6...0.8).contains(annotation))
        #expect(timeline.overlays(at: 1.25, sourceRange: 0.2...0.4).contains(annotation))
        #expect(timeline.overlays(at: 2.5, sourceRange: 0.2...0.4).contains(annotation))
    }

    @Test func reverse8KHDRSpillsWithinBudgetAndRetainsPixels() async throws {
        let fixture = try #require(
            Bundle.module.url(forResource: "reverse-8k-pq.mp4", withExtension: nil, subdirectory: "Resources"))
        let folder = try AudioSignals.temporaryFolder()
        let source = folder.appending(path: "8k.mp4")
        try FileManager.default.copyItem(at: fixture, to: source)
        let input = try await MediaInput.open(source)
        let segment = VideoSegment(start: 0, end: Double(input.duration) / Double(Nanoseconds.perSecond))
        var edit = VideoEdit()
        edit.segments = [segment]
        let staging = StagingArea(supportDirectory: try AudioSignals.temporaryFolder())
        let measurements = Mutex<VideoReverseStatistics?>(nil)
        let reversed = try await VideoSegmentReverser.reverse(
            segmentID: segment.id, in: edit, primaryURL: source, staging: staging,
            statistics: { measured in measurements.withLock { $0 = measured } })
        let staged = try #require(reversed.sources?.last)
        defer { VideoSegmentReverser.cleanupStagedSource(staged.url, in: staging) }
        let measured = try #require(measurements.withLock { $0 })
        #expect(measured.decodedFrames == 4)
        #expect(measured.peakSpillBytes > 0)
        #expect(measured.peakBufferedBytes > 90_000_000)
        #expect(measured.peakBufferedBytes <= ReversedFrameSpill.maximumBufferedBytes)
        let rendered = try await MediaInput.open(staged.url)
        #expect(rendered.codedSize == PixelSize(width: 7680, height: 4320))
        #expect(try await VideoProperties.hdrConfiguration(rendered)?.configuration.transfer == .pq)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: staged.url.deletingLastPathComponent().path) == [
                staged.url.lastPathComponent
            ])
    }

    @Test func reverse8KContainerBoundsNativeFrameRetention() async throws {
        let fixture = try #require(
            Bundle.module.url(forResource: "reverse-8k-sdr.mkv", withExtension: nil, subdirectory: "Resources"))
        let folder = try AudioSignals.temporaryFolder()
        let source = folder.appending(path: "8k.mkv")
        try FileManager.default.copyItem(at: fixture, to: source)
        let segment = VideoSegment(start: 0, end: 1)
        var edit = VideoEdit()
        edit.segments = [segment]
        let staging = StagingArea(supportDirectory: try AudioSignals.temporaryFolder())
        let measured = Mutex<VideoReverseStatistics?>(nil)
        let reversed = try await VideoSegmentReverser.reverse(
            segmentID: segment.id, in: edit, primaryURL: source, staging: staging,
            statistics: { result in measured.withLock { $0 = result } })
        let sourceURL = try #require(reversed.sources?.last?.url)
        defer { VideoSegmentReverser.cleanupStagedSource(sourceURL, in: staging) }
        let result = try #require(measured.withLock { $0 })
        #expect(result.decodedFrames == 4)
        #expect(result.peakBufferedBytes == 4 * 7680 * 4320 * 3 / 2)
        #expect(result.peakSpillBytes == 0)
        #expect(result.peakBufferedBytes <= ReversedFrameSpill.maximumBufferedBytes)
    }

    @Test func pruningEarlierStagedSourceRemapsLaterOriginAndItsRedactions() throws {
        let fixture = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac.mp4", withExtension: nil, subdirectory: "Resources"))
        let staging = StagingArea(supportDirectory: try AudioSignals.temporaryFolder())
        let earlierDirectory = try staging.makeDirectory(for: fixture)
        let laterDirectory = try staging.makeDirectory(for: fixture)
        defer { staging.remove(earlierDirectory); staging.remove(laterDirectory) }
        let earlier = earlierDirectory.appending(path: "earlier.mov")
        let later = laterDirectory.appending(path: "later.mov")
        try FileManager.default.copyItem(at: fixture, to: earlier)
        try FileManager.default.copyItem(at: fixture, to: later)
        let original = VideoEditSource(url: fixture, duration: 1, stamp: try MediaSourceStamp(url: fixture))
        var edit = VideoEdit()
        edit.sources = [
            original,
            VideoEditSource(url: earlier, duration: 1, stamp: try MediaSourceStamp(url: earlier)),
            original,
            VideoEditSource(
                url: later, duration: 1, stamp: try MediaSourceStamp(url: later),
                reversedOrigin: ReversedSegmentOrigin(sourceIndex: 2, start: 0, end: 1)),
        ]
        edit.segments = [VideoSegment(start: 0, end: 1, sourceIndex: 3)]
        let redaction = EditOverlay(mark: .redaction(rect: EditCrop(), style: .solid))
        edit.overlays = [TimedOverlay(overlay: redaction, sourceIndex: 2, start: 0.2, end: 0.8)]
        let pruned = VideoSegmentReverser.removeUnusedStagedSources(in: edit, staging: staging)
        #expect(pruned.sources?.count == 3)
        #expect(pruned.sources?.last?.reversedOrigin?.sourceIndex == 1)
        let timeline = try VideoTimeline(edit: pruned, sourceDuration: 1)
        #expect(timeline.overlays(at: 0.5).contains(redaction))
        #expect(!FileManager.default.fileExists(atPath: earlierDirectory.path))
        #expect(FileManager.default.fileExists(atPath: later.path))
    }

    @Test func variableRateContainerProxyUsesOriginalFrameBoundsForRedaction() async throws {
        let source = try #require(
            Bundle.module.url(forResource: "preview-vfr-hold.mkv", withExtension: nil, subdirectory: "Resources"))
        let support = try AudioSignals.temporaryFolder()
        let editor = try await VideoEditorSource.open(source, staging: StagingArea(supportDirectory: support))
        var edit = VideoEdit()
        edit.segments = [VideoSegment(start: 0, end: 2)]
        edit.overlays = [
            TimedOverlay(overlay: EditOverlay(mark: .redaction(rect: EditCrop(), style: .solid)), start: 0.4, end: 0.45)
        ]
        let playback = try await editor.playback(edit: edit)
        let generator = AVAssetImageGenerator(asset: playback.asset)
        generator.videoComposition = playback.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let preview = try await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 60_000)).image
        let fetched = try #require(
            try await editor.frames(at: [0.1], width: 160, edit: edit, exactFrame: true).first)
        for image in [preview, fetched] {
            #expect(
                try ImageFixtures.pixel(image, x: image.width / 2, y: image.height / 2).prefix(3).allSatisfy { $0 < 16 }
            )
        }
        await editor.close()
    }

    @Test func fractionalRatePreviewRedactsAfterBoundaryWithoutRoundingIntoPreviousFrame() async throws {
        let source = try #require(
            Bundle.module.url(forResource: "preview-23976.mp4", withExtension: nil, subdirectory: "Resources"))
        let editor = try await VideoEditorSource.open(
            source, staging: StagingArea(supportDirectory: try AudioSignals.temporaryFolder()))
        let boundary = 1001.0 / 24000
        let requested = boundary + 0.000004
        #expect(CMTime(seconds: requested, preferredTimescale: 60_000).seconds < boundary)
        let original = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        let unredacted = try await original.image(at: CMTime(seconds: boundary, preferredTimescale: 60_000)).image
        #expect(try ImageFixtures.pixel(unredacted, x: 80, y: 60).prefix(3).contains { $0 > 100 })
        let freeze = VideoSegment(start: requested, end: boundary + 0.001, volume: 0, freezeDuration: 0.2)
        var edit = VideoEdit()
        edit.segments = [freeze]
        edit.overlays = [
            TimedOverlay(
                overlay: EditOverlay(mark: .redaction(rect: EditCrop(), style: .solid)),
                start: 0.05, end: 0.06)
        ]
        let playback = try await editor.playback(edit: edit)
        let generator = AVAssetImageGenerator(asset: playback.asset)
        generator.videoComposition = playback.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let preview = try await generator.image(at: .zero).image
        let fetched = try #require(
            try await editor.frames(at: [requested], width: 160, edit: edit, exactFrame: true).first)
        for image in [preview, fetched] {
            #expect(
                try ImageFixtures.pixel(image, x: image.width / 2, y: image.height / 2)
                    .prefix(3).allSatisfy { $0 < 16 })
        }
        await editor.close()
    }

    @Test func frameIndexCoversBothSidesOfFractionalBoundary() async throws {
        let source = try #require(
            Bundle.module.url(forResource: "reverse-open-gop-vfr.mp4", withExtension: nil, subdirectory: "Resources"))
        let asset = AVURLAsset(url: source)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let index = try await EditorFrameIndex(asset: asset, track: track, end: 2 * Nanoseconds.perSecond)
        let boundary = 7.0 / 24
        for offset in [-0.000004, -0.000000002, 0.0, 0.000000002] {
            let range = try index.range(
                at: CMTime(seconds: boundary + offset, preferredTimescale: SampleBuffers.nanosecondScale),
                coversBoundary: true)
            #expect(range.lowerBound <= boundary + offset + 1e-9)
            if offset < 0 { #expect(range.lowerBound <= 0.25) }
            #expect(range.upperBound >= boundary)
        }
    }
}
