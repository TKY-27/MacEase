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
        let merged = (videoPackets + audioPackets).sorted {
            ($0.decodeTimestamp ?? $0.timestamp) < ($1.decodeTimestamp ?? $1.timestamp)
        }
        for packet in merged { try await sink.write(packet) }
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
