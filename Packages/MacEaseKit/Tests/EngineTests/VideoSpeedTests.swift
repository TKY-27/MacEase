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
        variableFrameRate: Bool = false, sampleRate: Double = sampleRate
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
                    for channel in 0..<3 { bytes[offset + channel] = bright ? 240 : 16 }
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

    @Test(arguments: [Settings.OutputMode.newFile, .replace])
    func speedCommitAndUndoProtectOriginal(mode: Settings.OutputMode) async throws {
        let fixture = try await fixture(channels: 0)
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "original.mov")
        try FileManager.default.copyItem(at: fixture, to: source)
        let original = try Data(contentsOf: source)
        let support = try AudioSignals.temporaryFolder()
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        var settings = Settings()
        settings.outputMode = mode
        let batch = OperationPlanner.batch(
            for: OperationRequest(
                op: .videoSpeed,
                options: .video(.speed(1.37)), inputs: [source]), settings: settings)
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
}
