import AVFoundation
import CoreVideo
import Formats
import Foundation
import MenuCatalog
import Testing

@testable import Engine

@Suite(.serialized) struct VideoSpeedTests {
    private static let sampleRate = 48_000.0
    private static let duration = 4.0
    private static let markers = [0.5, 1.75, 3.0]
    private static let markerDuration = 0.2
    private static let frameRate = 60

    private func fixture(
        channels: Int = 1, audioStart: Double = 0, audioEnd: Double = duration,
        variableFrameRate: Bool = false, sampleRate: Double = sampleRate, colored: Bool = false
    ) async throws -> URL {
        let folder = try AudioSignals.temporaryFolder()
        let videoURL = folder.appending(path: "video.mov")
        let encoding = VideoEncoding(
            codec: .h264, width: 128, height: 96, frameDuration: Nanoseconds.perSecond / Int64(Self.frameRate),
            bitrate: nil)
        var encoder = try VideoEncoders.make(encoding, track: 1)
        var packets: [MediaPacket] = []
        for index in 0..<Int(Self.duration * Double(Self.frameRate)) {
            if variableFrameRate, index % 3 == 1 { continue }
            var buffer: CVPixelBuffer?
            try #require(CVPixelBufferCreate(nil, 128, 96, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
            let picture = try #require(buffer)
            try #require(CVPixelBufferLockBaseAddress(picture, []) == kCVReturnSuccess)
            let bytes = try #require(CVPixelBufferGetBaseAddress(picture)).assumingMemoryBound(to: UInt8.self)
            let timestamp = Double(index) / Double(Self.frameRate)
            let bright = Self.markers.contains { timestamp >= $0 && timestamp < $0 + Self.markerDuration }
            for row in 0..<96 {
                for column in 0..<128 {
                    let offset = row * CVPixelBufferGetBytesPerRow(picture) + column * 4
                    for channel in 0..<3 {
                        bytes[offset + channel] =
                            colored
                            ? (channel == (timestamp < 2 ? 2 : 0) ? 240 : 16)
                            : (bright ? 240 : 16)
                    }
                    bytes[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(picture, [])
            packets += try encoder.encode(picture, timestamp: try Nanoseconds.from(seconds: timestamp))
        }
        packets += try encoder.finish()
        var sink = try Sinks.make(
            .mov, url: videoURL, tracks: [OutputTrack(track: encoder.track, format: encoder.formatDescription)],
            transform: .identity)
        for packet in packets.sorted(by: { ($0.decodeTimestamp ?? $0.timestamp) < ($1.decodeTimestamp ?? $1.timestamp) }
        ) {
            try await sink.write(packet)
        }
        sink.endTrack(1)
        try await sink.finish()
        guard channels > 0 else { return videoURL }
        let audioURL = folder.appending(path: channels > 2 ? "audio.wav" : "audio.m4a")
        var samples = [Float](repeating: 0, count: Int((audioEnd - audioStart) * sampleRate) * channels)
        for frame in 0..<(samples.count / channels) {
            let time = Double(frame) / sampleRate + audioStart
            let amplitude = Self.markers.contains { time >= $0 && time < $0 + Self.markerDuration } ? 0.8 : 0.1
            for channel in 0..<channels {
                samples[frame * channels + channel] = Float(
                    amplitude * sin(2 * .pi * (440 + Double(channel) * 220) * time))
            }
        }
        try await AudioSignals.write(
            samples, to: audioURL, format: channels > 2 ? .wav : .m4aALAC, sampleRate: sampleRate,
            channels: channels)
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        defer { withExtendedLifetime((videoAsset, audioAsset)) {} }
        let video = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
        let audio = try #require(try await audioAsset.loadTracks(withMediaType: .audio).first)
        let videoTrack = try #require(
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: CMTime(seconds: Self.duration, preferredTimescale: 600)), of: video,
            at: .zero)
        let audioTrack = try #require(
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try audioTrack.insertTimeRange(
            CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: audioEnd - audioStart, preferredTimescale: CMTimeScale(sampleRate))),
            of: audio, at: CMTime(seconds: audioStart, preferredTimescale: CMTimeScale(sampleRate)))
        let export = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        let result = folder.appending(path: "source.mov")
        do { try await export.export(to: result, as: .mov) } catch {
            throw EngineError.decodeFailed("fixture export: \(error)")
        }
        return result
    }

    private func edited(_ source: URL, edit: VideoEdit) async throws -> URL {
        let input = try await MediaInput.open(source)
        let track = try #require(input.video)
        let plan = try VideoEdits.plan(.edit(edit), input: input, source: track, settings: VideoSettings())
        let output = source.deletingLastPathComponent().appending(
            path: "edited-\(UUID().uuidString).\(input.container.fileExtension)")
        do { try await Transcoder.run(input, plan: plan, to: output) { _ in } } catch {
            throw EngineError.encodeFailed("speed transcode: \(error)")
        }
        return output
    }

    private func audioSamples(_ url: URL) async throws -> [Float] {
        if url.pathExtension == "mkv" {
            let input = try await MediaInput.open(url)
            let track = try #require(input.audio)
            let source = try VideoPCMSource(input: input, track: track, start: 0, end: input.duration)
            var samples: [Float] = []
            while let chunk = try await source.next() { samples += chunk.samples }
            return samples
        }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AssetTrackReader(asset: asset, track: track, number: 2, mode: .pcm)
        var samples: [Float] = []
        while let sample = try await reader.nextSample() {
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            let byteCount = CMBlockBufferGetDataLength(block)
            var decoded = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
            let status = try decoded.withUnsafeMutableBytes { pointer in
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: byteCount, destination: try #require(pointer.baseAddress))
            }
            try #require(status == noErr)
            let formats = try #require(CMSampleBufferGetFormatDescription(sample))
            let description = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(formats)).pointee
            let channels = Int(description.mChannelsPerFrame)
            let offset = Int((sample.presentationTimeStamp.seconds * description.mSampleRate).rounded())
            let mono = stride(from: 0, to: decoded.count, by: channels).map { decoded[$0] }
            if offset > samples.count { samples += Array(repeating: 0, count: offset - samples.count) }
            if offset >= 0 {
                let overlap = max(0, samples.count - offset)
                samples += mono.dropFirst(min(overlap, mono.count))
            }
        }
        return samples
    }

    private func videoMarkerTimes(_ url: URL) async throws -> [Double] {
        if url.pathExtension == "mkv" {
            let input = try await MediaInput.open(url)
            let video = try #require(input.video)
            var demuxer = try #require(try input.demuxer)
            var decoder = try VideoDecoders.make(for: video)
            var frames: [DecodedFrame] = []
            while let packet = try demuxer.nextPacket() {
                if packet.track == video.number { frames += try decoder.decode(packet) }
            }
            frames += try decoder.finish()
            var markers: [Double] = []
            var wasBright = false
            for frame in frames.sorted(by: { $0.timestamp < $1.timestamp }) {
                let pixels = try PixelBuffer(cgImage: CGImage.make(from: frame.image))
                let bright = pixels.rgba[0] > 180
                if bright && !wasBright { markers.append(Double(frame.timestamp) / Double(Nanoseconds.perSecond)) }
                wasBright = bright
            }
            return markers
        }
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AssetTrackReader(asset: asset, track: track, number: 1, mode: .frames)
        var markers: [Double] = []
        var wasBright = false
        while let frame = try await reader.nextFrame() {
            let pixels = try PixelBuffer(cgImage: CGImage.make(from: frame.image))
            let bright = pixels.rgba[0] > 180
            if bright && !wasBright { markers.append(Double(frame.timestamp) / Double(Nanoseconds.perSecond)) }
            wasBright = bright
        }
        return markers
    }

    @Test(arguments: [0.5, 0.75, 1.25, 1.5, 2, 4, 1.37])
    func preservesPitchAndMarkerTiming(speed: Double) async throws {
        let source = try await fixture()
        let output = try await edited(source, edit: VideoEdit(speed: speed))
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        let tolerance = max(1 / Double(Self.frameRate), 0.02)
        #expect(abs(duration - Self.duration / speed) <= tolerance, "duration \(duration), speed \(speed)")
        let samples = try await audioSamples(output)
        let videoMarkers = try await videoMarkerTimes(output)
        try #require(videoMarkers.count == Self.markers.count)
        for (markerIndex, marker) in Self.markers.enumerated() {
            let expected = marker / speed
            let searchStart = max(0, Int((expected - 0.15) * Self.sampleRate))
            let searchEnd = min(samples.count, Int((expected + 0.2) * Self.sampleRate))
            let window = 48
            let onset = stride(from: searchStart, to: searchEnd - window, by: window).first { offset in
                let energy = samples[offset..<(offset + window)].reduce(0.0) { $0 + Double($1 * $1) } / Double(window)
                return energy.squareRoot() > 0.25
            }
            let measured = Double(try #require(onset)) / Self.sampleRate
            #expect(
                abs(measured - videoMarkers[markerIndex]) <= tolerance,
                "A/V marker \(marker): audio \(measured), video \(videoMarkers[markerIndex]), speed \(speed)")
            #expect(
                abs(measured - expected) <= tolerance, "marker \(marker): \(measured) vs \(expected), speed \(speed)")
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let (image, _) = try await generator.image(
                at: CMTime(seconds: expected + Self.markerDuration / speed / 2, preferredTimescale: 60_000))
            let pixels = try PixelBuffer(cgImage: image)
            #expect(pixels.rgba[0] > 180)
        }
        let start = Int(0.85 / speed * Self.sampleRate)
        let end = min(samples.count, Int(1.5 / speed * Self.sampleRate))
        let crossings = (start + 1..<end).filter { samples[$0 - 1] <= 0 && samples[$0] > 0 }
        let first = try #require(crossings.first)
        let last = try #require(crossings.last)
        let frequency = Double(crossings.count - 1) * Self.sampleRate / Double(last - first)
        #expect(abs(frequency / 440 - 1) <= 0.01, "frequency \(frequency), speed \(speed)")
    }

    @Test(arguments: [false, true])
    func editorStepsSourceFramesAcrossVariableTiming(container: Bool) async throws {
        var source = try await fixture(channels: 0, variableFrameRate: true)
        if container {
            let input = try await MediaInput.open(source)
            let video = try #require(input.video)
            let plan = try VideoEdits.plan(.convert(.mkv), input: input, source: video, settings: VideoSettings())
            let output = source.deletingLastPathComponent().appending(path: "variable.mkv")
            try await Transcoder.run(input, plan: plan, to: output) { _ in }
            source = output
        }
        let editor = try await VideoEditorSource.open(
            source, staging: StagingArea(supportDirectory: source.deletingLastPathComponent()))
        let first = try await editor.adjacentFrameTime(to: 0, forward: true)
        let second = try await editor.adjacentFrameTime(to: first, forward: true)
        let third = try await editor.adjacentFrameTime(to: second, forward: true)
        let previous = try await editor.adjacentFrameTime(to: third, forward: false)
        #expect(abs(first - 2.0 / 60) < 0.001)
        #expect(abs(second - 3.0 / 60) < 0.001)
        #expect(abs(third - 5.0 / 60) < 0.001)
        #expect(previous == second)
        let last = try await editor.adjacentFrameTime(to: 4, forward: false)
        let frames = try await editor.frames(at: [0.5, last], width: 128, exactFrame: true)
        #expect(frames.count == 2)
        #expect(try PixelBuffer(cgImage: frames[0]).rgba[0] > 180)
        await editor.close()
    }

    @Test func editorSplitUsesNearestRetainedVariableFrameTimestamp() async throws {
        let source = try await fixture(channels: 0, variableFrameRate: true)
        let editor = try await VideoEditorSource.open(
            source, staging: StagingArea(supportDirectory: source.deletingLastPathComponent()))
        let first = try #require(try await editor.nearestFrameTime(to: 0.019, within: 0..<Self.duration))
        let second = try #require(try await editor.nearestFrameTime(to: 0.059, within: 0..<Self.duration))
        let third = try #require(try await editor.nearestFrameTime(to: 0.075, within: 0..<Self.duration))
        let retained = try #require(try await editor.nearestFrameTime(to: 0.075, within: 0.04..<0.08))
        #expect(abs(first - 2.0 / 60) < 1e-8)
        #expect(abs(second - 3.0 / 60) < 1e-8)
        #expect(abs(third - 5.0 / 60) < 1e-8)
        #expect(abs(retained - 3.0 / 60) < 1e-8)
        #expect(try await editor.nearestFrameTime(to: 0.04, within: 0.034..<0.049) == nil)
        await editor.close()
    }

    @Test func combinedEditorKeepsAudioVideoMarkersAndVolume() async throws {
        let source = try await fixture(variableFrameRate: true)
        var edit = VideoEdit(start: 0.25, end: 3.5, speed: 1.5)
        edit.geometry.quarterTurns = 1
        edit.geometry.crop = EditCrop(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        edit.adjustments.style = .monochrome
        edit.adjustments[.exposure] = 0.1
        edit.volume = 0.25
        let output = try await edited(source, edit: edit)
        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size.width == 48 && size.height == 64)
        #expect(abs(try await asset.load(.duration).seconds - 3.25 / 1.5) < 0.04)
        let samples = try await audioSamples(output)
        let markers = try await videoMarkerTimes(output)
        try #require(markers.count == Self.markers.count)
        for (index, marker) in Self.markers.enumerated() {
            let expected = (marker - 0.25) / 1.5
            let window = 48
            let lower = max(0, Int((expected - 0.1) * Self.sampleRate))
            let upper = min(samples.count - window, Int((expected + 0.15) * Self.sampleRate))
            let onset = stride(from: lower, to: upper, by: window).first { offset in
                let energy = samples[offset..<(offset + window)].reduce(0.0) { $0 + Double($1 * $1) } / Double(window)
                return energy.squareRoot() > 0.08
            }
            let measured = Double(try #require(onset)) / Self.sampleRate
            #expect(abs(markers[index] - expected) < 0.04)
            #expect(abs(measured - markers[index]) < 0.04)
            let center = Int((expected + 0.06) * Self.sampleRate)
            let energy = samples[center..<(center + 480)].reduce(0.0) { $0 + Double($1 * $1) } / 480
            #expect((0.11...0.17).contains(energy.squareRoot()))
        }
    }

    @Test(arguments: [8_000.0, 16_000.0, 22_050.0])
    func nativeAACUsesSupportedBitrateAtLowSampleRates(sampleRate: Double) async throws {
        let source = try await fixture(sampleRate: sampleRate)
        let output = try await edited(source, edit: VideoEdit(speed: 2))
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - Self.duration / 2) <= 0.02)
        let samples = try await audioSamples(output)
        let start = Int(0.5 * sampleRate)
        let end = min(samples.count, Int(0.7 * sampleRate))
        let crossings = (start + 1..<end).filter { samples[$0 - 1] <= 0 && samples[$0] > 0 }
        let first = try #require(crossings.first)
        let last = try #require(crossings.last)
        let frequency = Double(crossings.count - 1) * sampleRate / Double(last - first)
        #expect(abs(frequency / 440 - 1) <= 0.01)
    }

    @Test func silentSelectionAndDelayedAudioRetainTimeline() async throws {
        let source = try await fixture(channels: 2, audioStart: 1, audioEnd: 2.5)
        for edit in [
            VideoEdit(start: 0, end: 0.5, speed: 2), VideoEdit(start: 3, end: 4, speed: 0.5), VideoEdit(speed: 2),
        ] {
            let output = try await edited(source, edit: edit)
            let duration = try await AVURLAsset(url: output).load(.duration).seconds
            let samples = try await audioSamples(output)
            if edit.end != nil {
                #expect(samples.allSatisfy { abs($0) < 0.001 })
            } else {
                let leading = samples.prefix(Int(0.45 * Self.sampleRate))
                let trailing = samples.suffix(Int(0.5 * Self.sampleRate))
                #expect(leading.allSatisfy { abs($0) < 0.001 })
                #expect(trailing.allSatisfy { abs($0) < 0.001 })
                #expect(samples[Int(0.6 * Self.sampleRate)..<Int(0.7 * Self.sampleRate)].contains { abs($0) > 0.05 })
            }
            #expect(
                abs(duration - ((edit.end ?? Self.duration) - edit.start) / edit.speed) <= 1 / Double(Self.frameRate))
        }
    }

    @Test func speedWithoutAudioChangesVideoDuration() async throws {
        let source = try await fixture(channels: 0)
        let output = try await edited(source, edit: VideoEdit(start: 0.5, end: 3.5, speed: 2, resize: .percent(50)))
        let input = try await MediaInput.open(output)
        #expect(abs(Double(input.duration) / Double(Nanoseconds.perSecond) - 1.5) < 0.04)
        #expect(input.audio == nil)
        #expect(input.displaySize == PixelSize(width: 64, height: 48))
    }

    @Test(arguments: [3, 6])
    func speedRefusesMultichannelWithoutRelabelingSpeakers(channels: Int) async throws {
        let source = try await fixture(channels: channels)
        let input = try await MediaInput.open(source)
        let track = try #require(input.audio)
        let directory = try AudioSignals.temporaryFolder()
        await #expect(throws: EngineError.audioChannelLayoutUnsupported) {
            _ = try await TimeStretchedAudio(
                input: input, track: track, start: 0, end: input.duration,
                speed: 2, stagingDirectory: directory)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func combinedEditKeepsVariableFrameRateMarkersAligned() async throws {
        let source = try await fixture(variableFrameRate: true)
        let output = try await edited(source, edit: VideoEdit(start: 1, end: 3.5, speed: 2, resize: .percent(50)))
        let input = try await MediaInput.open(output)
        #expect(input.displaySize == PixelSize(width: 64, height: 48))
        #expect(abs(Double(input.duration) / Double(Nanoseconds.perSecond) - 1.25) <= 0.02)
        let audio = try await audioSamples(output)
        let video = try await videoMarkerTimes(output)
        try #require(video.count == 2)
        for (index, expected) in [0.375, 1.0].enumerated() {
            let window = 48
            let first = Int((expected - 0.05) * Self.sampleRate)
            let last = min(audio.count - window, Int((expected + 0.05) * Self.sampleRate))
            let onset = try #require(
                stride(from: first, to: last, by: window).first { offset in
                    audio[offset..<(offset + window)].reduce(0.0) { $0 + Double($1 * $1) } / Double(window) > 0.0625
                })
            #expect(abs(Double(onset) / Self.sampleRate - video[index]) <= 0.02)
        }
    }

    @Test func subframeSelectionStillProducesPlayableVideo() async throws {
        let source = try await fixture(channels: 0)
        let output = try await edited(source, edit: VideoEdit(start: 0, end: 0.01, speed: 4))
        let asset = AVURLAsset(url: output)
        let generator = AVAssetImageGenerator(asset: asset)
        let (image, _) = try await generator.image(at: .zero)
        #expect(image.width == 128 && image.height == 96)
        #expect(try await asset.load(.duration).seconds > 0)
    }

    @Test func flvMillisecondTimestampsDoNotWarpPitchOrMarkers() async throws {
        let source = try await fixture()
        let original = try await MediaInput.open(source)
        let flv = source.deletingLastPathComponent().appending(path: "source.flv")
        let plan = TranscodePlan(
            container: .flv, video: .copy,
            audio: .encode(.pcm(bits: 16, float: false, bigEndian: false), kilobits: 0))
        try await Transcoder.run(original, plan: plan, to: flv) { _ in }
        let output = try await edited(flv, edit: VideoEdit(speed: 2))
        let input = try await MediaInput.open(output)
        let track = try #require(input.audio)
        let decoder = try VideoPCMSource(input: input, track: track, start: 0, end: input.duration)
        var samples: [Float] = []
        while let chunk = try await decoder.next() { samples += chunk.samples }
        let rate = decoder.sampleRate
        for marker in Self.markers {
            let expected = marker / 2
            let window = Int(rate / 1_000)
            let first = Int((expected - 0.05) * rate)
            let last = min(samples.count - window, Int((expected + 0.1) * rate))
            let onset = try #require(
                stride(from: first, to: last, by: window).first { offset in
                    samples[offset..<(offset + window)].reduce(0.0) { $0 + Double($1 * $1) } / Double(window) > 0.0625
                })
            #expect(abs(Double(onset) / rate - expected) <= 0.02)
        }
        let start = Int(0.425 * rate)
        let end = Int(0.75 * rate)
        let crossings = (start + 1..<end).filter { samples[$0 - 1] <= 0 && samples[$0] > 0 }
        let first = try #require(crossings.first)
        let last = try #require(crossings.last)
        let frequency = Double(crossings.count - 1) * rate / Double(last - first)
        #expect(abs(frequency / 440 - 1) <= 0.01, "FLV pitch: \(frequency)")
    }

    @Test(arguments: [Settings.OutputMode.newFile, .replace], [false, true])
    func speedCommitAndUndoProtectOriginal(mode: Settings.OutputMode, segmented: Bool) async throws {
        let fixture = try await fixture(channels: 0)
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "original.mov")
        try FileManager.default.copyItem(at: fixture, to: source)
        let original = try Data(contentsOf: source)
        let support = try AudioSignals.temporaryFolder()
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        var settings = Settings()
        settings.outputMode = mode
        var edit = VideoEdit()
        edit.segments = [VideoSegment(start: 2, end: 3, speed: 1.37), VideoSegment(start: 0, end: 1)]
        let batch = OperationPlanner.batch(
            for: OperationRequest(
                op: segmented ? .videoEdit : .videoSpeed,
                options: .video(segmented ? .edit(edit) : .speed(1.37)), inputs: [source]), settings: settings)
        let result = await engine.run(batch, settings: settings) { _ in }
        guard case .succeeded(let outputs, _) = try #require(result.outcomes.first) else {
            Issue.record("Speed batch failed: \(result.outcomes)")
            return
        }
        let output = try #require(outputs.first)
        #expect(output == source ? mode == .replace : mode == .newFile)
        #expect(try Data(contentsOf: output) != original)
        if mode == .newFile { #expect(try Data(contentsOf: source) == original) }
        let record = try #require(result.record)
        #expect(try await engine.history.undo(record.id) == [.restored])
        #expect(try Data(contentsOf: source) == original)
        if mode == .newFile { #expect(!FileManager.default.fileExists(atPath: output.path)) }
    }
    @Test(arguments: [false, true])
    func reorderedDuplicateSegmentsKeepVFRMarkersVolumeAndPitch(container: Bool) async throws {
        var source = try await fixture(variableFrameRate: true)
        if container {
            let original = try await MediaInput.open(source)
            let output = source.deletingLastPathComponent().appending(path: "source.mkv")
            let plan = TranscodePlan(container: .mkv, video: .copy, audio: .encode(.opus, kilobits: 128))
            try await Transcoder.run(original, plan: plan, to: output) { _ in }
            source = output
        }
        var edit = VideoEdit()
        edit.segments = [
            VideoSegment(start: 2.5, end: 3.5, speed: 0.5, volume: 0.25),
            VideoSegment(start: 0, end: 1, speed: 2, volume: 0),
            VideoSegment(start: 2.5, end: 3.5, volume: 0.5),
        ]
        let output = try await edited(source, edit: edit)
        let result = try await MediaInput.open(output)
        #expect(abs(result.duration - 3_500_000_000) <= 20_000_000)
        let video = try await videoMarkerTimes(output)
        try #require(video.count == 3)
        for (actual, expected) in zip(video, [1.0, 2.25, 3.0]) { #expect(abs(actual - expected) <= 0.02) }
        let audio = try await audioSamples(output)
        #expect(abs(Double(audio.count) / Self.sampleRate - 3.5) <= 0.001)
        for (onset, amplitude) in [(1.0, 0.14), (3.0, 0.28)] {
            let first = Int((onset + 0.06) * Self.sampleRate)
            let count = 480
            let rms = (audio[first..<first + count].reduce(0.0) { $0 + Double($1 * $1) } / Double(count)).squareRoot()
            #expect(abs(rms - amplitude) < 0.025)
            let lower = Int((onset - 0.05) * Self.sampleRate)
            let upper = Int((onset + 0.05) * Self.sampleRate)
            let marker = try #require(
                stride(from: lower, to: upper, by: 48).first { position in
                    audio[position..<position + 48].reduce(0.0) { $0 + Double($1 * $1) } / 48 > 0.01
                })
            #expect(abs(Double(marker) / Self.sampleRate - onset) <= 0.02)
        }
        #expect(audio[Int(2.02 * Self.sampleRate)..<Int(2.48 * Self.sampleRate)].allSatisfy { abs($0) < 0.001 })
        let lower = Int(0.2 * Self.sampleRate)
        let upper = Int(0.8 * Self.sampleRate)
        let crossings = (lower + 1..<upper).filter { audio[$0 - 1] <= 0 && audio[$0] > 0 }
        let first = try #require(crossings.first)
        let last = try #require(crossings.last)
        let pitch = Double(crossings.count - 1) * Self.sampleRate / Double(last - first)
        #expect(abs(pitch / 440 - 1) <= 0.01)
    }

    @Test func reorderedColorSegmentsAndNativePreviewShareAppearance() async throws {
        let source = try await fixture(channels: 0, colored: true)
        var edit = VideoEdit(resize: .percent(50))
        var monochrome = MediaAdjustments()
        monochrome.style = .monochrome
        edit.geometry.quarterTurns = 1
        edit.segments = [
            VideoSegment(start: 2, end: 3, speed: 2),
            VideoSegment(start: 0, end: 1, adjustments: monochrome),
            VideoSegment(start: 2, end: 3),
        ]
        let output = try await edited(source, edit: edit)
        let editor = try await VideoEditorSource.open(
            source, staging: StagingArea(supportDirectory: AudioSignals.temporaryFolder()))
        let payload = try await editor.playback(edit: edit)
        #expect(payload.videoComposition != nil)
        #expect(abs(try await payload.asset.load(.duration).seconds - 2.5) < 0.001)
        let saved = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        saved.appliesPreferredTrackTransform = true
        saved.requestedTimeToleranceBefore = .zero
        saved.requestedTimeToleranceAfter = .zero
        let preview = AVAssetImageGenerator(asset: payload.asset)
        preview.appliesPreferredTrackTransform = true
        preview.videoComposition = payload.videoComposition
        preview.requestedTimeToleranceBefore = .zero
        preview.requestedTimeToleranceAfter = .zero
        for (index, second) in [0.25, 1.0, 2.0].enumerated() {
            let time = CMTime(seconds: second, preferredTimescale: 60_000)
            let (image, _) = try await saved.image(at: time)
            let (rendered, _) = try await preview.image(at: time)
            #expect(image.width == 48 && image.height == 64)
            #expect(rendered.width == 48 && rendered.height == 64)
            let pixel = try ImageFixtures.pixel(image, x: 20, y: 20)
            let shown = try ImageFixtures.pixel(rendered, x: 20, y: 20)
            if index == 1 {
                #expect(abs(Int(pixel[0]) - Int(pixel[2])) <= 3)
            } else {
                #expect(pixel[2] > 220 && pixel[0] < 30)
            }
            #expect(
                zip(pixel, shown).allSatisfy { abs(Int($0) - Int($1)) <= 12 },
                "time \(second): export \(pixel), preview \(shown)")
        }
        await editor.close()
    }

    @Test func segmentSaveRejectsChangedSourceBeforeStaging() async throws {
        let source = try await fixture(channels: 0)
        let original = try Data(contentsOf: source)
        var edit = VideoEdit()
        edit.segments = [VideoSegment(start: 1, end: 2)]
        edit.sourceStamp = try MediaSourceStamp(url: source)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: source.path)
        let directory = source.deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: directory), progress: { _ in })
        defer { context.removeStaging() }
        await #expect(throws: EngineError.self) { try await VideoEdits.run(.edit(edit), url: source, context: context) }
        #expect(try Data(contentsOf: source) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == names)
    }

    @Test func joinedSourcesKeepLaterAudioAndStableCanvasThroughUndo() async throws {
        let first = try await fixture(channels: 0, colored: true)
        let second = try await fixture(sampleRate: 44_100, colored: true)
        let firstBytes = try Data(contentsOf: first)
        let secondBytes = try Data(contentsOf: second)
        var edit = VideoEdit()
        edit.sources = [
            VideoEditSource(url: first, duration: 4, stamp: try MediaSourceStamp(url: first)),
            VideoEditSource(url: second, duration: 4, stamp: try MediaSourceStamp(url: second)),
        ]
        edit.segments = [
            VideoSegment(start: 0, end: 1),
            VideoSegment(start: 2.5, end: 3.5, speed: 0.5, volume: 0.5, sourceIndex: 1),
            VideoSegment(start: 2, end: 3),
        ]
        let engine = try JobEngine(supportDirectory: AudioSignals.temporaryFolder(), concurrency: 1)
        var settings = Settings()
        settings.outputMode = .replace
        let result = await engine.run(
            MediaEditing.video(url: first, edit: edit, settings: settings), settings: settings
        ) { _ in }
        let record = try #require(result.record)
        let output = try ImageFixtures.output(of: result)
        #expect(output != first && output != second)
        let input = try await MediaInput.open(output)
        #expect(abs(Double(input.duration) / Double(Nanoseconds.perSecond) - 4) < 0.03)
        #expect(input.displaySize == PixelSize(width: 128, height: 96))
        #expect(input.frameDuration == (try await MediaInput.open(first)).frameDuration)
        let track = try #require(input.audio)
        let source = try VideoPCMSource(input: input, track: track, start: 0, end: input.duration)
        var samples: [Float] = []
        while let chunk = try await source.next() { samples += chunk.samples }
        let rate = source.sampleRate
        let channels = source.channels
        let quiet = samples[Int(0.1 * rate) * channels..<Int(0.9 * rate) * channels]
        #expect(quiet.allSatisfy { abs($0) < 0.001 })
        let audible = samples[Int(1.9 * rate) * channels..<Int(2.3 * rate) * channels]
        #expect(audible.contains { abs($0) > 0.1 })
        let silentEnd = samples[Int(3.1 * rate) * channels..<Int(3.9 * rate) * channels]
        #expect(silentEnd.allSatisfy { abs($0) < 0.001 })
        #expect(try Data(contentsOf: first) == firstBytes)
        #expect(try Data(contentsOf: second) == secondBytes)
        #expect(try await engine.history.undo(record.id) == [.restored])
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: first) == firstBytes)
        #expect(try Data(contentsOf: second) == secondBytes)
    }

    @Test func joinedPreviewAndExportFitDifferentSourceSizes() async throws {
        let first = try await fixture(channels: 0, colored: true)
        let originalSecond = try await fixture(channels: 0, colored: true)
        let second = originalSecond.deletingLastPathComponent().appending(path: "portrait.mp4")
        let input = try await MediaInput.open(originalSecond)
        let encoding = VideoEncoding(
            codec: .h264, width: 64, height: 128,
            frameDuration: input.frameDuration, bitrate: nil)
        let plan = TranscodePlan(
            container: .mp4,
            video: .encode(
                encoding,
                FrameEdit(size: PixelSize(width: 64, height: 128))), audio: nil)
        try await Transcoder.run(input, plan: plan, to: second) { _ in }
        var edit = VideoEdit()
        edit.sources = [
            VideoEditSource(url: first, duration: 4, stamp: try MediaSourceStamp(url: first)),
            VideoEditSource(url: second, duration: 4, stamp: try MediaSourceStamp(url: second)),
        ]
        edit.segments = [VideoSegment(start: 0, end: 1), VideoSegment(start: 2, end: 3, sourceIndex: 1)]
        let engine = try JobEngine(supportDirectory: AudioSignals.temporaryFolder(), concurrency: 1)
        let result = await engine.run(
            MediaEditing.video(url: first, edit: edit, settings: Settings()), settings: Settings()
        ) { _ in }
        let output = try ImageFixtures.output(of: result)
        let playback = try await VideoEditorPlayback.joined(
            urls: [first, second], edit: edit,
            sourceSize: CGSize(width: 128, height: 96))
        let saved = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        let preview = AVAssetImageGenerator(asset: playback.asset)
        preview.videoComposition = playback.videoComposition
        for generator in [saved, preview] {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        let time = CMTime(seconds: 1.5, preferredTimescale: 60_000)
        let (exported, _) = try await saved.image(at: time)
        let (shown, _) = try await preview.image(at: time)
        #expect(exported.width == 128 && exported.height == 96)
        #expect(shown.width == 128 && shown.height == 96)
        for image in [exported, shown] {
            let border = try ImageFixtures.pixel(image, x: 4, y: 48)
            #expect(border.prefix(3).allSatisfy { $0 < 10 })
            let center = try ImageFixtures.pixel(image, x: 64, y: 48)
            #expect(center[2] > 220 && center[0] < 30)
        }
    }

    @Test func changedJoinedSourceIsRejectedBeforeStaging() async throws {
        let first = try await fixture(channels: 0)
        let second = try await fixture(channels: 0)
        var edit = VideoEdit()
        edit.sources = [
            VideoEditSource(url: first, duration: 4, stamp: try MediaSourceStamp(url: first)),
            VideoEditSource(url: second, duration: 4, stamp: try MediaSourceStamp(url: second)),
        ]
        edit.segments = [VideoSegment(start: 0, end: 1), VideoSegment(start: 0, end: 1, sourceIndex: 1)]
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 10)],
            ofItemAtPath: second.path)
        let context = ItemContext(
            settings: Settings(),
            staging: StagingArea(supportDirectory: try AudioSignals.temporaryFolder()), progress: { _ in })
        defer { context.removeStaging() }
        await #expect(throws: EngineError.self) { try await VideoEdits.run(.edit(edit), url: first, context: context) }
    }

}
