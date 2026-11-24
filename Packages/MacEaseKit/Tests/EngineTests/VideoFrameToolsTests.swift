import AVFoundation
import CoreGraphics
import CoreVideo
import Formats
import Foundation
import ImageIO
import Synchronization
import Testing

@testable import Engine

private final class ProgressRecorder: Sendable {
    private let recorded = Mutex<[Double]>([])
    var values: [Double] { recorded.withLock { $0 } }
    func record(_ value: Double) { recorded.withLock { $0.append(value) } }
}

private final class TaskHolder: Sendable {
    private let current = Mutex<(task: Task<VideoEdit, any Error>?, cancelled: Bool)>((nil, false))
    func store(_ task: Task<VideoEdit, any Error>) {
        current.withLock { state in
            state.task = task
            if state.cancelled { task.cancel() }
        }
    }
    func cancel() {
        current.withLock { state in
            state.cancelled = true
            state.task?.cancel()
        }
    }
}

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

    @Test func freezeTimelineMathValidationAndLegacyDecoding() throws {
        let legacyJSON = Data(
            #"{"id":"F776754A-28B9-45D4-9001-6659A97C6786","start":1,"end":2,"speed":1,"volume":1,"adjustments":{"style":"original","styleIntensity":1,"values":{}}}"#
                .utf8)
        let legacy = try JSONDecoder().decode(VideoSegment.self, from: legacyJSON)
        #expect(legacy.freezeDuration == nil)
        #expect(!legacy.isFreeze)
        #expect(legacy.outputDuration == 1.0)

        let frameStep = 1.0 / Double(Self.frameRate)
        let before = VideoSegment(start: 0, end: 1.0)
        let freeze = VideoSegment(
            start: 1.0, end: 1.0 + frameStep, speed: 1, volume: 0, freezeDuration: 2.0)
        let after = VideoSegment(start: 1.0, end: 2.0, speed: 2)
        #expect(freeze.isFreeze)
        #expect(freeze.outputDuration == 2.0)
        #expect(after.outputDuration == 0.5)

        var edit = VideoEdit()
        edit.segments = [before, freeze, after]
        let overlay = TimedOverlay(
            overlay: EditOverlay(
                mark: .redaction(rect: EditCrop(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .solid)),
            start: 0.5, end: 1.5)
        edit.overlays = [overlay]

        let restored = try JSONDecoder().decode(VideoEdit.self, from: JSONEncoder().encode(edit))
        #expect(restored == edit)

        let timeline = try VideoTimeline(edit: restored, sourceDuration: 2.0)
        #expect(abs(timeline.duration - 3.5) < 1e-9)
        #expect(abs(timeline.sourceTime(at: 0.5) - 0.5) < 1e-9)
        #expect(abs(timeline.sourceTime(at: 1.0) - 1.0) < 1e-9)
        #expect(abs(timeline.sourceTime(at: 2.0) - 1.0) < 1e-9)
        #expect(abs(timeline.sourceTime(at: 2.99) - 1.0) < 1e-9)
        #expect(abs(timeline.sourceTime(at: 3.25) - 1.5) < 1e-9)
        #expect(timeline.outputTime(for: 1.0, segmentID: freeze.id) == 1.0)
        #expect(timeline.overlays(at: 2.0) == [overlay.overlay])
        let ranges = timeline.outputRanges(of: overlay)
        #expect(ranges.count == 1)
        #expect(abs(ranges[0].lowerBound - 0.5) < 1e-9 && abs(ranges[0].upperBound - 3.25) < 1e-9)

        let invalidSegments: [VideoSegment] = [
            VideoSegment(start: 0.5, end: 0.5 + frameStep, speed: 2, volume: 0, freezeDuration: 2.0),
            VideoSegment(start: 0.5, end: 0.5 + frameStep, speed: 1, volume: 0.5, freezeDuration: 2.0),
            VideoSegment(start: 0.5, end: 0.5 + frameStep, speed: 1, volume: 0, freezeDuration: 0.05),
            VideoSegment(start: 0.5, end: 0.5 + frameStep, speed: 1, volume: 0, freezeDuration: 30.1),
            VideoSegment(start: 0.5, end: 0.5 + frameStep, speed: 1, volume: 0, freezeDuration: .nan),
        ]
        for invalid in invalidSegments {
            var bad = VideoEdit()
            bad.segments = [invalid]
            #expect(throws: EngineError.self) { try VideoTimeline(edit: bad, sourceDuration: 2.0) }
        }
    }

    @Test func freezeFramePreviewAndExportHoldSingleFrameAndSilenceAudio() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "distinct_audio.mov")
        try await writeDistinctFramesWithTone(
            to: source, width: 160, height: 120, duration: 1.0)
        let frameStep = 1.0 / Double(Self.frameRate)
        let freezeStart = 15.0 * frameStep
        let freezeDuration = 2.0

        var edit = VideoEdit()
        edit.segments = [
            VideoSegment(start: 0, end: freezeStart),
            VideoSegment(
                start: freezeStart, end: freezeStart + frameStep, speed: 1, volume: 0,
                freezeDuration: freezeDuration),
            VideoSegment(start: freezeStart, end: 1.0),
        ]

        let input = try await MediaInput.open(source)
        let track = try #require(input.video)
        let plan = try VideoEdits.plan(.edit(edit), input: input, source: track, settings: VideoSettings())
        let exported = folder.appending(path: "freeze_export.mov")
        try await Transcoder.run(input, plan: plan, to: exported) { _ in }

        let editor = try await VideoEditorSource.open(
            source, staging: StagingArea(supportDirectory: try AudioSignals.temporaryFolder()))
        defer { Task { await editor.close() } }
        let playback = try await editor.playback(edit: edit)

        let sourceGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        let exportGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: exported))
        let previewGenerator = AVAssetImageGenerator(asset: playback.asset)
        previewGenerator.videoComposition = playback.videoComposition
        for generator in [sourceGenerator, exportGenerator, previewGenerator] {
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }

        let (heldSource, _) = try await sourceGenerator.image(
            at: CMTime(seconds: freezeStart, preferredTimescale: 60_000))
        let heldPixel = try ImageFixtures.pixel(heldSource, x: 80, y: 60)

        for probe in [0.55, 1.0, 1.5, 2.0, 2.45] {
            let time = CMTime(seconds: probe, preferredTimescale: 60_000)
            let (exportedImage, _) = try await exportGenerator.image(at: time)
            let (previewImage, _) = try await previewGenerator.image(at: time)
            let exportPixel = try ImageFixtures.pixel(exportedImage, x: 80, y: 60)
            let previewPixel = try ImageFixtures.pixel(previewImage, x: 80, y: 60)
            #expect(
                zip(heldPixel, exportPixel).allSatisfy { abs(Int($0) - Int($1)) <= 15 },
                "export freeze mismatch at \(probe): got \(exportPixel), expected \(heldPixel)")
            #expect(
                zip(heldPixel, previewPixel).allSatisfy { abs(Int($0) - Int($1)) <= 15 },
                "preview freeze mismatch at \(probe): got \(previewPixel), expected \(heldPixel)")
        }

        let playerPixels = try await sampleWithPlayer(playback: playback, times: [0.25, 0.6, 1.5, 2.4, 2.75])
        for (probe, playerPixel) in zip([0.6, 1.5, 2.4], Array(playerPixels[1...3])) {
            #expect(
                zip(heldPixel, playerPixel).allSatisfy { abs(Int($0) - Int($1)) <= 15 },
                "AVPlayer freeze mismatch at \(probe): got \(playerPixel), expected \(heldPixel)")
        }
        #expect(
            !zip(heldPixel, playerPixels[0]).allSatisfy { abs(Int($0) - Int($1)) <= 15 },
            "before-freeze frame unexpectedly equalled held frame")
        #expect(
            !zip(heldPixel, playerPixels[4]).allSatisfy { abs(Int($0) - Int($1)) <= 15 },
            "after-freeze frame unexpectedly equalled held frame")

        let exportedInput = try await MediaInput.open(exported)
        let audioTrack = try #require(exportedInput.audio)
        let pcmSource = try VideoPCMSource(
            input: exportedInput, track: audioTrack, start: 0, end: exportedInput.duration)
        var allSamples: [Float] = []
        while let chunk = try await pcmSource.next() { allSamples += chunk.samples }
        let sampleRate = pcmSource.sampleRate
        let channels = pcmSource.channels
        func peak(from startSeconds: Double, to endSeconds: Double) -> Float {
            let first = max(0, Int(startSeconds * sampleRate)) * channels
            let last = min(allSamples.count, Int(endSeconds * sampleRate) * channels)
            guard first < last else { return 0 }
            return allSamples[first..<last].map(abs).max() ?? 0
        }
        #expect(peak(from: 0.1, to: 0.4) > 0.1)
        #expect(peak(from: 0.6, to: 2.4) < 0.005)
        #expect(peak(from: 2.6, to: 2.9) > 0.1)
    }

    @Test func freezeFrameUnalignedStartAndLongDurationStaySingleFrame() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "distinct.mov")
        try await writeDistinctFramesWithTone(to: source, width: 160, height: 120, duration: 1.0)
        let frameStep = 1.0 / Double(Self.frameRate)
        let unalignedStart = 15.0 * frameStep + frameStep * 0.4

        var edit = VideoEdit()
        edit.segments = [
            VideoSegment(
                start: unalignedStart, end: unalignedStart + frameStep, speed: 1, volume: 0,
                freezeDuration: 30.0)
        ]

        let editor = try await VideoEditorSource.open(
            source, staging: StagingArea(supportDirectory: try AudioSignals.temporaryFolder()))
        defer { Task { await editor.close() } }
        let playback = try await editor.playback(edit: edit)

        let sourceGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        let previewGenerator = AVAssetImageGenerator(asset: playback.asset)
        previewGenerator.videoComposition = playback.videoComposition
        for generator in [sourceGenerator, previewGenerator] {
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        let (held, _) = try await sourceGenerator.image(
            at: CMTime(seconds: unalignedStart, preferredTimescale: 60_000))
        let heldPixel = try ImageFixtures.pixel(held, x: 80, y: 60)

        for probe in [0.1, 10.0, 20.0, 29.5] {
            let (shown, _) = try await previewGenerator.image(at: CMTime(seconds: probe, preferredTimescale: 60_000))
            let actual = try ImageFixtures.pixel(shown, x: 80, y: 60)
            #expect(
                zip(heldPixel, actual).allSatisfy { abs(Int($0) - Int($1)) <= 15 },
                "long/unaligned preview mismatch at \(probe): got \(actual), expected \(heldPixel)")
        }

        var fadedFreeze = VideoSegment(
            start: unalignedStart, end: unalignedStart + frameStep, speed: 1, volume: 0,
            freezeDuration: 2.0)
        fadedFreeze.fadeOut = 1.0
        var fadedEdit = VideoEdit()
        fadedEdit.segments = [fadedFreeze]
        let fadedPlayback = try await editor.playback(edit: fadedEdit)
        let fadedGen = AVAssetImageGenerator(asset: fadedPlayback.asset)
        fadedGen.videoComposition = fadedPlayback.videoComposition
        fadedGen.appliesPreferredTrackTransform = true
        fadedGen.requestedTimeToleranceBefore = .zero
        fadedGen.requestedTimeToleranceAfter = .zero
        let (brightFrame, _) = try await fadedGen.image(at: CMTime(seconds: 0.5, preferredTimescale: 60_000))
        let (midFadeFrame, _) = try await fadedGen.image(at: CMTime(seconds: 1.5, preferredTimescale: 60_000))
        let (darkFrame, _) = try await fadedGen.image(at: CMTime(seconds: 1.9, preferredTimescale: 60_000))
        let bright = try ImageFixtures.pixel(brightFrame, x: 80, y: 60)
        let mid = try ImageFixtures.pixel(midFadeFrame, x: 80, y: 60)
        let dark = try ImageFixtures.pixel(darkFrame, x: 80, y: 60)
        #expect(bright[0] > 180)
        #expect(mid[0] < bright[0] - 30 && mid[0] > dark[0] + 30)
        #expect(dark[0] < 100)

        let playedFade = try await playThroughAndSample(playback: fadedPlayback, startAt: 1.2, waitMilliseconds: 700)
        #expect(playedFade.last[0] < playedFade.first[0] - 20, "real playback did not animate fade: \(playedFade)")
    }

    @MainActor
    private func playThroughAndSample(
        playback: VideoEditorPlayback, startAt: Double, waitMilliseconds: Int
    ) async throws -> (first: [UInt8], last: [UInt8]) {
        let playerItem = AVPlayerItem(asset: playback.asset)
        playerItem.videoComposition = playback.videoComposition
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        playerItem.add(videoOutput)
        let player = AVPlayer(playerItem: playerItem)
        let startTime = CMTime(seconds: startAt, preferredTimescale: 60_000)
        await player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
        var firstPixel: [UInt8]?
        for _ in 0..<50 {
            if let buffer = videoOutput.copyPixelBuffer(forItemTime: startTime, itemTimeForDisplay: nil) {
                firstPixel = try ImageFixtures.pixel(try CGImage.make(from: buffer), x: 80, y: 60)
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let initial = try #require(firstPixel)
        player.play()
        try await Task.sleep(for: .milliseconds(waitMilliseconds))
        let now = player.currentTime()
        player.pause()
        var lastPixel: [UInt8]?
        for _ in 0..<25 {
            if let buffer = videoOutput.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) {
                lastPixel = try ImageFixtures.pixel(try CGImage.make(from: buffer), x: 80, y: 60)
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return (initial, try #require(lastPixel))
    }

    @MainActor
    private func sampleWithPlayer(playback: VideoEditorPlayback, times: [Double]) async throws -> [[UInt8]] {
        var pixels: [[UInt8]] = []
        for probe in times {
            let playerItem = AVPlayerItem(asset: playback.asset)
            playerItem.videoComposition = playback.videoComposition
            let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            playerItem.add(videoOutput)
            let player = AVPlayer(playerItem: playerItem)
            let target = CMTime(seconds: probe, preferredTimescale: 60_000)
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            var buffer: CVPixelBuffer?
            for _ in 0..<50 {
                if let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: nil) {
                    buffer = pixelBuffer
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let copied = try #require(buffer, "AVPlayerItemVideoOutput returned no frame at \(probe)")
            pixels.append(try ImageFixtures.pixel(try CGImage.make(from: copied), x: 80, y: 60))
        }
        return pixels
    }

    @Test func reverseSegmentReversesVideoAndAudioAcrossGOPsRestoresAndExports() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "multi_gop.mov")
        let totalDuration = 3.0
        try await writeUniqueFramesWithRampAudio(
            to: source, width: 160, height: 120, duration: totalDuration, keyframeSeconds: 0.5)
        let originalBytes = try Data(contentsOf: source)

        let support = try AudioSignals.temporaryFolder()
        let staging = StagingArea(supportDirectory: support)

        let targetSegment = VideoSegment(start: 0.5, end: 2.0)
        var edit = VideoEdit()
        edit.segments = [
            VideoSegment(start: 0, end: 0.5),
            targetSegment,
            VideoSegment(start: 2.0, end: totalDuration),
        ]

        let progressRecorder = ProgressRecorder()
        let reversedEdit = try await VideoSegmentReverser.reverse(
            segmentID: targetSegment.id, in: edit, primaryURL: source, staging: staging
        ) { value in
            progressRecorder.record(value)
        }

        let updatedSegment = try #require(reversedEdit.segments?[1])
        #expect(updatedSegment.isReversed)
        #expect(updatedSegment.reversedOrigin == ReversedSegmentOrigin(sourceIndex: 0, start: 0.5, end: 2.0))
        #expect(updatedSegment.sourceIndex == 1)
        #expect(abs(updatedSegment.outputDuration - 1.5) < 0.05)
        #expect(progressRecorder.values.contains { $0 >= 0.99 })

        let reversedURL = try #require(reversedEdit.sources?[1].url)
        #expect(FileManager.default.fileExists(atPath: reversedURL.path))

        let roundTrip = try JSONDecoder().decode(VideoEdit.self, from: JSONEncoder().encode(reversedEdit))
        #expect(roundTrip == reversedEdit)

        let sourceFrames = try await readAllFrames(from: source, range: 0.5..<2.0)
        let reversedFrames = try await readAllFrames(from: reversedURL, range: nil)
        #expect(reversedFrames.count == sourceFrames.count)
        for index in reversedFrames.indices {
            let expected = try ImageFixtures.pixel(sourceFrames[sourceFrames.count - 1 - index], x: 80, y: 60)
            let actual = try ImageFixtures.pixel(reversedFrames[index], x: 80, y: 60)
            #expect(
                zip(expected, actual).allSatisfy { abs(Int($0) - Int($1)) <= 18 },
                "frame \(index) mismatch: got \(actual), expected \(expected)")
        }

        let sourceAudio = try await readPCM(from: source, start: 0.5, end: 2.0)
        let reversedAudio = try await readPCM(from: reversedURL, start: 0, end: nil)
        let frameCount = min(sourceAudio.samples.count, reversedAudio.samples.count) / sourceAudio.channels
        #expect(abs(sourceAudio.samples.count - reversedAudio.samples.count) <= sourceAudio.channels * 4)
        let channels = sourceAudio.channels
        for frame in stride(from: 100, to: frameCount - 100, by: 257) {
            let mirrored = frameCount - 1 - frame
            for channel in 0..<channels {
                let expected = sourceAudio.samples[mirrored * channels + channel]
                let actual = reversedAudio.samples[frame * channels + channel]
                #expect(
                    abs(actual - expected) < 0.01,
                    "audio mismatch at frame \(frame) ch \(channel): got \(actual), expected \(expected)")
            }
        }

        let urls = try #require(reversedEdit.sources?.map(\.url))
        let playback = try await VideoEditorPlayback.joined(
            urls: urls, edit: reversedEdit, sourceSize: CGSize(width: 160, height: 120))
        #expect(abs(playback.timeline.duration - totalDuration) < 0.05)

        let engine = try JobEngine(supportDirectory: try AudioSignals.temporaryFolder(), concurrency: 1)
        let exportOutcome = await engine.run(
            MediaEditing.video(url: source, edit: reversedEdit, settings: Settings()), settings: Settings()
        ) { _ in }
        guard case .succeeded(let exportedOutputs, _) = exportOutcome.outcomes.first,
            let exportedURL = exportedOutputs.first
        else {
            Issue.record("expected reversed timeline export to succeed")
            return
        }
        let exportedInput = try await MediaInput.open(exportedURL)
        #expect(abs(Double(exportedInput.duration) / Double(Nanoseconds.perSecond) - totalDuration) < 0.1)
        #expect(try Data(contentsOf: source) == originalBytes)

        var trimmedReversed = reversedEdit
        trimmedReversed.segments?[1].start = 0.25
        trimmedReversed.segments?[1].end = 1.0
        let trimmedRestored = try VideoSegmentReverser.unreverse(segmentID: targetSegment.id, in: trimmedReversed)
        let trimmedSegment = try #require(trimmedRestored.segments?[1])
        #expect(abs(trimmedSegment.start - 1.0) < 0.05 && abs(trimmedSegment.end - 1.75) < 0.05)

        let stagedDirectory = reversedURL.deletingLastPathComponent()
        let restored = try VideoSegmentReverser.unreverse(
            segmentID: targetSegment.id, in: reversedEdit, staging: staging)
        let restoredSegment = try #require(restored.segments?[1])
        #expect(!restoredSegment.isReversed)
        #expect(restoredSegment.sourceIndex == 0)
        #expect(abs(restoredSegment.start - 0.5) < 1e-9)
        #expect(abs(restoredSegment.end - 2.0) < 1e-9)
        #expect(restored.sources?.count == 1)
        #expect(!FileManager.default.fileExists(atPath: stagedDirectory.path))
    }

    @Test func reverseSegmentRespectsMaximumLengthCancellationHDRAlphaAndLegacyDecode() async throws {
        let legacyJSON = Data(
            #"{"id":"F776754A-28B9-45D4-9001-6659A97C6786","start":0,"end":1,"speed":1,"volume":1,"adjustments":{"style":"original","styleIntensity":1,"values":{}}}"#
                .utf8)
        let legacy = try JSONDecoder().decode(VideoSegment.self, from: legacyJSON)
        #expect(!legacy.isReversed && legacy.reversedOrigin == nil)

        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "short.mov")
        try await writeUniqueFramesWithRampAudio(
            to: source, width: 128, height: 96, duration: 1.0, keyframeSeconds: 0.5)
        let staging = StagingArea(supportDirectory: try AudioSignals.temporaryFolder())

        let oversizedSegment = VideoSegment(
            start: 0, end: VideoSegmentReverser.maximumSegmentSeconds + 1.0)
        var oversizedEdit = VideoEdit()
        oversizedEdit.segments = [oversizedSegment]
        await #expect(
            throws: EngineError.invalidInput(.tooLong(limitSeconds: VideoSegmentReverser.maximumSegmentSeconds))
        ) {
            _ = try await VideoSegmentReverser.reverse(
                segmentID: oversizedSegment.id, in: oversizedEdit, primaryURL: source, staging: staging)
        }

        let cancelSupport = try AudioSignals.temporaryFolder()
        let cancelStaging = StagingArea(supportDirectory: cancelSupport)
        let cancelSegment = VideoSegment(start: 0, end: 1.0)
        var cancelEdit = VideoEdit()
        cancelEdit.segments = [cancelSegment]
        let preparationHolder = TaskHolder()
        let preparationDirectories = Mutex<[String]>([])
        let preparationTask = Task {
            try await VideoSegmentReverser.reverse(
                segmentID: cancelSegment.id, in: cancelEdit, primaryURL: source, staging: cancelStaging
            ) { fraction in
                guard fraction > 0 else { return }
                let paths = Result {
                    try JSONDecoder().decode(
                        [String].self, from: Data(contentsOf: cancelSupport.appending(path: "staging.json")))
                }
                if case .success(let recorded) = paths { preparationDirectories.withLock { $0 = recorded } }
                preparationHolder.cancel()
            }
        }
        preparationHolder.store(preparationTask)
        await #expect(throws: CancellationError.self) { _ = try await preparationTask.value }
        let preparedPaths = preparationDirectories.withLock { $0 }
        #expect(!preparedPaths.isEmpty)
        for path in preparedPaths { #expect(!FileManager.default.fileExists(atPath: path)) }
        let preparationRegistry = try JSONDecoder().decode(
            [String].self, from: Data(contentsOf: cancelSupport.appending(path: "staging.json")))
        #expect(preparationRegistry.isEmpty)

        let midSupport = try AudioSignals.temporaryFolder()
        let midStaging = StagingArea(supportDirectory: midSupport)
        let registryPath = midSupport.appending(path: "staging.json")
        let longClip = folder.appending(path: "longer.mov")
        try await writeUniqueFramesWithRampAudio(
            to: longClip, width: 160, height: 120, duration: 2.0, keyframeSeconds: 0.5)
        let midSegment = VideoSegment(start: 0, end: 2.0)
        var midEdit = VideoEdit()
        midEdit.segments = [midSegment]
        let taskHolder = TaskHolder()
        let renderingDirectories = Mutex<[String]>([])
        let midTask = Task {
            try await VideoSegmentReverser.reverse(
                segmentID: midSegment.id, in: midEdit, primaryURL: longClip, staging: midStaging
            ) { value in
                guard value > 0.6 && value < 1 else { return }
                let paths = Result { try JSONDecoder().decode([String].self, from: Data(contentsOf: registryPath)) }
                if case .success(let recorded) = paths { renderingDirectories.withLock { $0 = recorded } }
                taskHolder.cancel()
            }
        }
        taskHolder.store(midTask)
        await #expect(throws: CancellationError.self) { _ = try await midTask.value }
        let renderedPaths = renderingDirectories.withLock { $0 }
        #expect(!renderedPaths.isEmpty)
        for path in renderedPaths { #expect(!FileManager.default.fileExists(atPath: path)) }
        let tracked = try JSONDecoder().decode([String].self, from: Data(contentsOf: registryPath))
        #expect(tracked.isEmpty)

        let hdrFixture = try #require(
            Bundle.module.url(forResource: "x265-pq.mp4", withExtension: nil, subdirectory: "Resources"))
        let hdrSource = folder.appending(path: "hdr.mp4")
        try FileManager.default.copyItem(at: hdrFixture, to: hdrSource)
        let hdrInput = try await MediaInput.open(hdrSource)
        let hdrDuration = Double(hdrInput.duration) / Double(Nanoseconds.perSecond)
        let hdrSegment = VideoSegment(start: 0, end: hdrDuration)
        var hdrEdit = VideoEdit()
        hdrEdit.segments = [hdrSegment]
        let hdrReversed = try await VideoSegmentReverser.reverse(
            segmentID: hdrSegment.id, in: hdrEdit, primaryURL: hdrSource, staging: staging)
        let hdrReversedURL = try #require(hdrReversed.sources?[1].url)
        defer { VideoSegmentReverser.cleanupStagedSource(hdrReversedURL, in: staging) }
        let hdrReversedInput = try await MediaInput.open(hdrReversedURL)
        #expect(try await VideoProperties.hdrConfiguration(hdrReversedInput)?.configuration.transfer == .pq)

        let alphaSource = folder.appending(path: "alpha.mov")
        try await writeAlphaVideo(to: alphaSource, width: 64, height: 48, frameCount: 6)
        let alphaInput = try await MediaInput.open(alphaSource)
        let alphaDuration = Double(alphaInput.duration) / Double(Nanoseconds.perSecond)
        let alphaSegment = VideoSegment(start: 0, end: alphaDuration)
        var alphaEdit = VideoEdit()
        alphaEdit.segments = [alphaSegment]
        let alphaReversed = try await VideoSegmentReverser.reverse(
            segmentID: alphaSegment.id, in: alphaEdit, primaryURL: alphaSource, staging: staging)
        let alphaReversedURL = try #require(alphaReversed.sources?[1].url)
        defer { VideoSegmentReverser.cleanupStagedSource(alphaReversedURL, in: staging) }
        let alphaReversedInput = try await MediaInput.open(alphaReversedURL)
        #expect(alphaReversedInput.video?.hasAlpha == true)
        let alphaFrames = try await readAllFrames(from: alphaReversedURL, range: nil)
        let firstAlpha = try #require(alphaFrames.first)
        #expect(try ImageFixtures.pixel(firstAlpha, x: 8, y: 24)[3] < 16)
        #expect(try ImageFixtures.pixel(firstAlpha, x: 56, y: 24)[3] > 240)

        let rotatedFixture = try #require(
            Bundle.module.url(forResource: "ffmpeg-rotated.mov", withExtension: nil, subdirectory: "Resources"))
        let rotatedSource = folder.appending(path: "rotated.mov")
        try FileManager.default.copyItem(at: rotatedFixture, to: rotatedSource)
        let rotatedInput = try await MediaInput.open(rotatedSource)
        let rotatedDuration = Double(rotatedInput.duration) / Double(Nanoseconds.perSecond)
        let rotatedSegment = VideoSegment(start: 0, end: rotatedDuration)
        var rotatedEdit = VideoEdit()
        rotatedEdit.segments = [rotatedSegment]
        let rotatedReversed = try await VideoSegmentReverser.reverse(
            segmentID: rotatedSegment.id, in: rotatedEdit, primaryURL: rotatedSource, staging: staging)
        let rotatedReversedURL = try #require(rotatedReversed.sources?[1].url)
        defer { VideoSegmentReverser.cleanupStagedSource(rotatedReversedURL, in: staging) }
        let rotatedReversedInput = try await MediaInput.open(rotatedReversedURL)
        #expect(rotatedReversedInput.displaySize == rotatedInput.displaySize)
        #expect(try rotatedReversedInput.displayOrientation == rotatedInput.displayOrientation)
    }

    @Test func reversedFreezeDuplicateUnreverseFrameFetchAndExportKeepPatternRedacted() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "pattern.mov")
        try await writeGradientVideo(to: source, width: 160, height: 120, duration: 2)
        let staging = StagingArea(supportDirectory: try AudioSignals.temporaryFolder())
        let editor = try await VideoEditorSource.open(source, staging: staging)
        let target = VideoSegment(start: 0.51, end: 1.91)
        var edit = VideoEdit()
        edit.segments = [target]
        let redaction = EditOverlay(
            mark: .redaction(rect: EditCrop(x: 0.2, y: 0.2, width: 0.4, height: 0.4), style: .solid))
        let annotation = EditOverlay(
            mark: .box(rect: EditCrop(x: 0.1, y: 0.1, width: 0.8, height: 0.8), color: .red, size: .large))
        edit.overlays = [
            TimedOverlay(overlay: redaction, start: 0.4, end: 2), TimedOverlay(overlay: annotation, start: 0.4, end: 2),
        ]
        var reversed = try await editor.reverse(segmentID: target.id, in: edit)
        let staged = try #require(reversed.sources?.last)
        let inferred = try #require(
            try await editor.frames(at: [0.3], width: 160, edit: reversed, exactFrame: true).first)
        #expect(try ImageFixtures.pixel(inferred, x: 60, y: 50).prefix(3).allSatisfy { $0 < 16 })
        var duplicate = try #require(reversed.segments?.first)
        duplicate.id = UUID()
        let freeze = VideoSegment(start: 0.3, end: 0.31, volume: 0, sourceIndex: 1, freezeDuration: 0.5)
        reversed.segments?.append(contentsOf: [duplicate, freeze])
        reversed.overlays.append(
            TimedOverlay(
                overlay: EditOverlay(
                    mark: .redaction(rect: EditCrop(x: 0.65, y: 0.25, width: 0.2, height: 0.3), style: .solid)),
                sourceIndex: 1, start: 0, end: staged.duration))
        let restored = try VideoSegmentReverser.unreverse(segmentID: target.id, in: reversed, staging: staging)
        let timeline = try VideoTimeline(edit: restored, sourceDuration: 2)
        #expect(timeline.segments.last?.reversedOrigin != nil)
        #expect(restored.requiresJoinedExport && restored.joinedExportNotice != nil)
        for segment in timeline.segments {
            let time = segment.isFreeze ? segment.start : segment.end
            let frames = try await editor.frames(
                at: [time], width: 160, edit: restored, exactFrame: true, segmentID: segment.id)
            let image = try #require(frames.first)
            let redacted = try ImageFixtures.pixel(image, x: 60, y: 50)
            let stagedRedacted = try ImageFixtures.pixel(image, x: 120, y: 50)
            #expect(redacted.prefix(3).allSatisfy { $0 < 16 })
            #expect(stagedRedacted.prefix(3).allSatisfy { $0 < 16 })
        }
        let playback = try await editor.playback(edit: restored)
        #expect(abs(playback.timeline.duration - timeline.duration) < 1e-9)
        let engine = try JobEngine(supportDirectory: AudioSignals.temporaryFolder(), concurrency: 1)
        let outcome = await engine.run(
            MediaEditing.video(url: source, edit: restored, settings: Settings()), settings: Settings()
        ) { _ in }
        guard case .succeeded(let outputs, _) = outcome.outcomes.first, let output = outputs.first else {
            Issue.record("redacted reversed timeline did not export")
            await editor.close()
            return
        }
        let exported = try await readAllFrames(from: output, range: nil)
        #expect(!exported.isEmpty)
        for image in exported {
            #expect(try ImageFixtures.pixel(image, x: 60, y: 50).prefix(3).allSatisfy { $0 < 20 })
            #expect(try ImageFixtures.pixel(image, x: 120, y: 50).prefix(3).allSatisfy { $0 < 20 })
        }
        var deleted = restored
        deleted.segments?.removeAll { $0.sourceIndex == 1 }
        _ = VideoSegmentReverser.removeUnusedStagedSources(in: deleted, staging: staging)
        #expect(FileManager.default.fileExists(atPath: staged.url.path))
        _ = try await editor.frames(
            at: [freeze.start], width: 160, edit: restored, exactFrame: true, segmentID: freeze.id)
        await editor.close()
        #expect(!FileManager.default.fileExists(atPath: staged.url.deletingLastPathComponent().path))
    }

    @Test func joinedFrameFetchUsesSelectedSourceAtItsEndAndReportsMissingSegments() async throws {
        let folder = try TestVolume.makeFolder()
        let first = folder.appending(path: "first.mov")
        let second = folder.appending(path: "second.mov")
        try await writeUniqueFramesWithRampAudio(to: first, width: 160, height: 120, duration: 1, keyframeSeconds: 0.5)
        try await writeGradientVideo(to: second, width: 160, height: 120, duration: 1)
        let source0 = VideoEditSource(url: first, duration: 1, stamp: try MediaSourceStamp(url: first))
        let source1 = VideoEditSource(url: second, duration: 1, stamp: try MediaSourceStamp(url: second))
        let seg0 = VideoSegment(start: 0, end: 1)
        let seg1 = VideoSegment(start: 0, end: 1, sourceIndex: 1)
        var edit = VideoEdit()
        edit.sources = [source0, source1]
        edit.segments = [seg0, seg1]
        edit.overlays = [
            TimedOverlay(
                overlay: EditOverlay(
                    mark: .redaction(rect: EditCrop(x: 0, y: 0, width: 0.5, height: 1), style: .solid)), sourceIndex: 1,
                start: 0, end: 1)
        ]
        let editor = try await VideoEditorSource.open(
            first, staging: StagingArea(supportDirectory: try AudioSignals.temporaryFolder()))
        let frames = try await editor.frames(at: [1], width: 160, edit: edit, exactFrame: true, segmentID: seg1.id)
        let image = try #require(frames.first)
        #expect(try ImageFixtures.pixel(image, x: 20, y: 60).prefix(3).allSatisfy { $0 < 10 })
        let reference = try await MediaPreview(videoAt: second)
        let expected = try #require(
            try await reference.frames(
                at: [1], width: 160, exactFrame: true, overlays: edit.overlays.map(\.overlay)
            ).first)
        let actualPixel = try ImageFixtures.pixel(image, x: 140, y: 60)
        let expectedPixel = try ImageFixtures.pixel(expected, x: 140, y: 60)
        #expect(
            zip(actualPixel, expectedPixel).allSatisfy { abs(Int($0) - Int($1)) < 10 },
            "actual \(actualPixel), expected \(expectedPixel)")
        await #expect(throws: EngineError.invalidInput(.videoSegmentNotFound)) {
            _ = try await editor.frames(at: [0.5], width: 160, edit: edit, segmentID: UUID())
        }
        await editor.close()
    }

    @Test func reversePreservesOpenGOPLeadingBFramesVFRAndUnalignedRedactions() async throws {
        let fixture = try #require(
            Bundle.module.url(forResource: "reverse-open-gop-vfr.mp4", withExtension: nil, subdirectory: "Resources"))
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "vfr.mp4")
        try FileManager.default.copyItem(at: fixture, to: source)
        let staging = StagingArea(supportDirectory: try AudioSignals.temporaryFolder())
        let segment = VideoSegment(start: 0.26, end: 0.7)
        var edit = VideoEdit()
        edit.segments = [segment]
        let redaction = EditOverlay(mark: .redaction(rect: EditCrop(), style: .solid))
        edit.overlays = [TimedOverlay(overlay: redaction, start: 0.24, end: 0.255)]
        let measured = Mutex<VideoReverseStatistics?>(nil)
        let reversed = try await VideoSegmentReverser.reverse(
            segmentID: segment.id, in: edit, primaryURL: source, staging: staging,
            statistics: { result in measured.withLock { $0 = result } })
        let staged = try #require(reversed.sources?.last)
        defer { VideoSegmentReverser.cleanupStagedSource(staged.url, in: staging) }
        let original = try await readAllFrames(from: source, range: 0.25..<0.7)
        let backwards = try await readAllFrames(from: staged.url, range: nil)
        #expect(original.count == 6 && backwards.count == 6)
        let expectedOrder = Array(original.reversed())
        for (index, actual) in backwards.enumerated() {
            let scores = try expectedOrder.map { expected in
                var error = 0.0
                var samples = 0
                for y in stride(from: 4, to: 60, by: 4) {
                    for x in stride(from: 4, to: 92, by: 4) {
                        let left = try ImageFixtures.pixel(expected, x: x, y: y)
                        let right = try ImageFixtures.pixel(actual, x: x, y: y)
                        error += zip(left.prefix(3), right.prefix(3)).reduce(0.0) {
                            $0 + abs(Double($1.0) - Double($1.1))
                        }
                        samples += 3
                    }
                }
                return error / Double(samples)
            }
            #expect(scores[index] < 10, "frame \(index) mean error \(scores[index])")
            #expect(
                scores.indices.min { scores[$0] < scores[$1] } == index,
                "frame \(index) matched another source frame: \(scores)")
        }
        let intervals = try #require(staged.reversedFrames)
        #expect(abs(intervals[0].stagedEnd - intervals[0].stagedStart - 0.075) < 1e-8)
        #expect(abs(intervals[1].stagedEnd - intervals[1].stagedStart - 1.0 / 24) < 1e-8)
        let timeline = try VideoTimeline(edit: reversed, sourceDuration: 2)
        #expect(timeline.overlays(at: timeline.duration - 0.001, sourceRange: 0.43...0.44).contains(redaction))
        let statistics = try #require(measured.withLock { $0 })
        #expect(statistics.decodedFrames <= 7)
        #expect(statistics.peakBufferedBytes <= ReversedFrameSpill.maximumBufferedBytes)
    }

    @Test func reversedExportsDiscloseH264AlphaFlatteningAndHDRToneMapping() async throws {
        let folder = try TestVolume.makeFolder()
        let hdr = try #require(
            Bundle.module.url(forResource: "x265-pq.mp4", withExtension: nil, subdirectory: "Resources"))
        let alpha = folder.appending(path: "transparent.mov")
        try await writeAlphaVideo(to: alpha, width: 64, height: 48, frameCount: 6)
        for (index, fixture) in [hdr, alpha].enumerated() {
            let source = folder.appending(path: "source-\(index).\(fixture.pathExtension)")
            try FileManager.default.copyItem(at: fixture, to: source)
            let input = try await MediaInput.open(source)
            let segment = VideoSegment(start: 0, end: Double(input.duration) / Double(Nanoseconds.perSecond))
            var edit = VideoEdit()
            edit.segments = [segment]
            let staging = StagingArea(supportDirectory: try AudioSignals.temporaryFolder())
            let reversed = try await VideoSegmentReverser.reverse(
                segmentID: segment.id, in: edit, primaryURL: source, staging: staging)
            #expect(reversed.requiresJoinedExport && reversed.joinedExportNotice != nil)
            let engine = try JobEngine(supportDirectory: AudioSignals.temporaryFolder(), concurrency: 1)
            let result = await engine.run(
                MediaEditing.video(url: source, edit: reversed, settings: Settings()), settings: Settings()
            ) { _ in }
            guard case .succeeded(let outputs, let warnings) = result.outcomes.first, let output = outputs.first else {
                Issue.record("reversed HDR/alpha export failed: \(result.outcomes)")
                continue
            }
            let encoded = try await MediaInput.open(output)
            #expect(encoded.video?.codec == .h264 && encoded.video?.hasAlpha == false)
            #expect(output.pathExtension == "mp4")
            #expect(try await VideoProperties.hdrConfiguration(encoded) == nil)
            #expect(warnings.contains(index == 0 ? .videoToneMappedToSDR : .videoTransparencyFlattened))
            #expect(
                warnings.filter { $0 == (index == 0 ? .videoToneMappedToSDR : .videoTransparencyFlattened) }.count == 1)
            for source in reversed.sources?.dropFirst() ?? [] {
                VideoSegmentReverser.cleanupStagedSource(source.url, in: staging)
            }
        }
    }

    @Test func closingEditorCancelsInFlightReverseAndRemovesItsDirectory() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "close.mov")
        try await writeGradientVideo(to: source, width: 160, height: 120, duration: 2)
        let support = try AudioSignals.temporaryFolder()
        let editor = try await VideoEditorSource.open(source, staging: StagingArea(supportDirectory: support))
        let segment = VideoSegment(start: 0, end: 2)
        var edit = VideoEdit()
        edit.segments = [segment]
        let closing = Mutex<Task<Void, Never>?>(nil)
        let directories = Mutex<[String]>([])
        let task = Task {
            try await editor.reverse(segmentID: segment.id, in: edit) { progress in
                guard progress > 0 else { return }
                closing.withLock { closing in
                    guard closing == nil else { return }
                    let recorded = Result {
                        try JSONDecoder().decode(
                            [String].self, from: Data(contentsOf: support.appending(path: "staging.json")))
                    }
                    if case .success(let paths) = recorded { directories.withLock { $0 = paths } }
                    closing = Task { await editor.close() }
                }
            }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let close = try #require(closing.withLock { $0 })
        await close.value
        let paths = directories.withLock { $0 }
        #expect(!paths.isEmpty)
        for path in paths { #expect(!FileManager.default.fileExists(atPath: path)) }
        #expect(
            try JSONDecoder().decode([String].self, from: Data(contentsOf: support.appending(path: "staging.json")))
                .isEmpty)
    }

    private func writeAlphaVideo(to url: URL, width: Int, height: Int, frameCount: Int) async throws {
        let frameDuration = Nanoseconds.perSecond / 12
        var encoding = VideoEncoding(
            codec: .prores4444, width: width, height: height, frameDuration: frameDuration, bitrate: nil)
        encoding.alpha = true
        var encoder = try VideoEncoders.make(encoding, track: 1)
        var packets: [MediaPacket] = []
        for index in 0..<frameCount {
            var created: CVPixelBuffer?
            try #require(
                CVPixelBufferCreate(
                    nil, width, height, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created) == kCVReturnSuccess)
            let buffer = try #require(created)
            try #require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
            let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * rowBytes + x * 4
                    if x < width / 2 {
                        base[offset] = 0
                        base[offset + 1] = 0
                        base[offset + 2] = 0
                        base[offset + 3] = 0
                    } else {
                        base[offset] = 30
                        base[offset + 1] = UInt8(40 + index * 30)
                        base[offset + 2] = 220
                        base[offset + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            packets += try encoder.encode(buffer, timestamp: Int64(index) * frameDuration)
        }
        packets += try encoder.finish()
        var sink = try Sinks.make(
            .mov, url: url, tracks: [OutputTrack(track: encoder.track, format: encoder.formatDescription)],
            transform: .identity)
        for packet in packets { try await sink.write(packet) }
        try await sink.finish()
    }

    private func readAllFrames(from url: URL, range: Range<Double>?) async throws -> [CGImage] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let timeRange: CMTimeRange? = range.map {
            CMTimeRange(
                start: CMTime(seconds: $0.lowerBound, preferredTimescale: SampleBuffers.nanosecondScale),
                end: CMTime(seconds: $0.upperBound, preferredTimescale: SampleBuffers.nanosecondScale))
        }
        let reader = try AssetTrackReader(asset: asset, track: track, number: 1, mode: .frames, range: timeRange)
        var images: [CGImage] = []
        while let frame = try await reader.nextFrame() {
            images.append(try CGImage.make(from: frame.image))
        }
        return images
    }

    private func readPCM(from url: URL, start: Double, end: Double?) async throws -> (samples: [Float], channels: Int) {
        let input = try await MediaInput.open(url)
        let track = try #require(input.audio)
        let startNs = try Nanoseconds.from(seconds: start)
        let endNs = try end.map { try Nanoseconds.from(seconds: $0) } ?? input.duration
        let source = try VideoPCMSource(input: input, track: track, start: startNs, end: endNs)
        var samples: [Float] = []
        while let chunk = try await source.next() { samples += chunk.samples }
        return (samples, source.channels)
    }

    private func writeUniqueFramesWithRampAudio(
        to url: URL, width: Int, height: Int, duration: Double, keyframeSeconds: Double
    ) async throws {
        var encoding = VideoEncoding(
            codec: .h264, width: width, height: height,
            frameDuration: Nanoseconds.perSecond / Int64(Self.frameRate), bitrate: nil)
        encoding.keyframeInterval = try Nanoseconds.from(seconds: keyframeSeconds)
        var encoder = try VideoEncoders.make(encoding, track: 1)
        var videoPackets: [MediaPacket] = []
        let totalFrames = Int((duration * Double(Self.frameRate)).rounded())
        for index in 0..<totalFrames {
            let progress = Double(index) / Double(max(1, totalFrames - 1))
            let red = UInt8((20 + progress * 220).rounded())
            let green = UInt8((230 - progress * 200).rounded())
            let blue = UInt8(((index * 37) % 200) + 30)
            let frame = try solidBuffer(width: width, height: height, red: red, green: green, blue: blue)
            let timestamp = try Nanoseconds.from(seconds: Double(index) / Double(Self.frameRate))
            videoPackets += try encoder.encode(frame, timestamp: timestamp)
        }
        videoPackets += try encoder.finish()

        let sampleRate = 48_000.0
        let channels = 2
        let totalSamples = Int((duration * sampleRate).rounded())
        let pcmFormat = try PCMFormat.make(sampleRate: sampleRate, channels: channels)
        let audioTrack = MediaTrack(
            number: 2, kind: .audio(sampleRate: sampleRate, channels: channels),
            codec: .pcm(bits: 32, float: true, bigEndian: false))
        var audioPackets: [MediaPacket] = []
        let chunkFrames = 4_096
        var cursor = 0
        while cursor < totalSamples {
            let count = min(chunkFrames, totalSamples - cursor)
            var samples = [Float](repeating: 0, count: count * channels)
            for offset in 0..<count {
                let sampleIndex = cursor + offset
                let left = Float(-0.8 + 1.6 * Double(sampleIndex) / Double(totalSamples))
                let right = Float(sin(2 * .pi * 220 * Double(sampleIndex) / sampleRate) * 0.5)
                samples[offset * channels] = left
                samples[offset * channels + 1] = right
            }
            let timestamp = try Nanoseconds.scale(Int64(cursor), by: Nanoseconds.perSecond, over: Int64(sampleRate))
            let packetDuration = try Nanoseconds.scale(
                Int64(count), by: Nanoseconds.perSecond, over: Int64(sampleRate))
            audioPackets.append(
                MediaPacket(
                    track: 2, timestamp: timestamp, duration: packetDuration, isKeyframe: true,
                    payload: samples.withUnsafeBytes { Data($0) }))
            cursor += count
        }
        var sink = try Sinks.make(
            .mov, url: url,
            tracks: [
                OutputTrack(track: encoder.track, format: encoder.formatDescription),
                OutputTrack(track: audioTrack, format: pcmFormat.formatDescription),
            ],
            transform: .identity)
        var pendingVideo = videoPackets.sorted {
            ($0.decodeTimestamp ?? $0.timestamp) < ($1.decodeTimestamp ?? $1.timestamp)
        }
        var pendingAudio = audioPackets
        while !pendingVideo.isEmpty || !pendingAudio.isEmpty {
            let videoTime = pendingVideo.first?.timestamp ?? .max
            let audioTime = pendingAudio.first?.timestamp ?? .max
            if !pendingVideo.isEmpty, videoTime <= audioTime || !sink.accepts(track: 2), sink.accepts(track: 1) {
                try await sink.write(pendingVideo.removeFirst())
            } else if !pendingAudio.isEmpty, sink.accepts(track: 2) {
                try await sink.write(pendingAudio.removeFirst())
            } else {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        sink.endTrack(1)
        sink.endTrack(2)
        try await sink.finish()
    }

    private func writeDistinctFramesWithTone(
        to url: URL, width: Int, height: Int, duration: Double
    ) async throws {
        let palette: [(UInt8, UInt8, UInt8)] = [
            (220, 30, 30), (30, 220, 30), (30, 30, 220),
            (220, 220, 30), (30, 220, 220), (220, 30, 220),
        ]
        let encoding = VideoEncoding(
            codec: .h264, width: width, height: height,
            frameDuration: Nanoseconds.perSecond / Int64(Self.frameRate), bitrate: nil)
        var encoder = try VideoEncoders.make(encoding, track: 1)
        var videoPackets: [MediaPacket] = []
        let totalFrames = Int((duration * Double(Self.frameRate)).rounded())
        for index in 0..<totalFrames {
            let color = palette[index % palette.count]
            let frame = try solidBuffer(width: width, height: height, red: color.0, green: color.1, blue: color.2)
            let timestamp = try Nanoseconds.from(seconds: Double(index) / Double(Self.frameRate))
            videoPackets += try encoder.encode(frame, timestamp: timestamp)
        }
        videoPackets += try encoder.finish()

        let sampleRate = 48_000
        let channels = 2
        let audioEncoder = try AudioPacketEncoder(
            codec: .aac, sampleRate: sampleRate, channels: channels, kilobits: 128)
        let totalSamples = Int((duration * Double(sampleRate)).rounded())
        var pcm = [Float](repeating: 0, count: totalSamples * channels)
        for frame in 0..<totalSamples {
            let sample = Float(sin(2 * .pi * 440 * Double(frame) / Double(sampleRate)) * 0.5)
            pcm[frame * channels] = sample
            pcm[frame * channels + 1] = sample
        }
        let encodedAudio = try audioEncoder.encode(pcm) + audioEncoder.finish()
        var audioPackets: [MediaPacket] = []
        var sampleCursor: Int64 = 0
        for packet in encodedAudio {
            let timestamp = try Nanoseconds.scale(sampleCursor, by: Nanoseconds.perSecond, over: Int64(sampleRate))
            let packetDuration = try Nanoseconds.scale(
                Int64(packet.frames), by: Nanoseconds.perSecond, over: Int64(sampleRate))
            audioPackets.append(
                MediaPacket(
                    track: 2, timestamp: timestamp, duration: packetDuration, isKeyframe: true, payload: packet.data))
            sampleCursor += Int64(packet.frames)
        }
        let audioTrack = MediaTrack(
            number: 2, kind: .audio(sampleRate: Double(sampleRate), channels: channels), codec: .aac,
            codecPrivate: audioEncoder.codecPrivate)
        var sink = try Sinks.make(
            .mov, url: url,
            tracks: [
                OutputTrack(track: encoder.track, format: encoder.formatDescription),
                OutputTrack(track: audioTrack, format: nil),
            ],
            transform: .identity)
        var pendingVideo = videoPackets.sorted {
            ($0.decodeTimestamp ?? $0.timestamp) < ($1.decodeTimestamp ?? $1.timestamp)
        }
        var pendingAudio = audioPackets
        while !pendingVideo.isEmpty || !pendingAudio.isEmpty {
            let videoTime = pendingVideo.first?.timestamp ?? .max
            let audioTime = pendingAudio.first?.timestamp ?? .max
            if !pendingVideo.isEmpty, videoTime <= audioTime || !sink.accepts(track: 2), sink.accepts(track: 1) {
                try await sink.write(pendingVideo.removeFirst())
            } else if !pendingAudio.isEmpty, sink.accepts(track: 2) {
                try await sink.write(pendingAudio.removeFirst())
            } else {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        sink.endTrack(1)
        sink.endTrack(2)
        try await sink.finish()
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
