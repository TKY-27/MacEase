import AVFoundation
import Foundation
import ImageIO
import MenuCatalog
import Testing
import UniformTypeIdentifiers

@testable import Engine
@testable import Formats

@Suite(.serialized) struct VideoAudioTests {
    private func fixture(_ name: String = "ffmpeg-h264-aac.mp4") throws -> URL {
        let source = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"))
        let copy = try TestVolume.makeFolder().appending(path: name)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    private func run(_ operation: OperationID, preset: String, on url: URL) async throws -> URL {
        let options = try #require(OperationPlanner.options(for: operation, preset: preset, settings: Settings()))
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseSupport-\(UUID().uuidString)")
        TestTemporaryFolders.register(support)
        let engine = try JobEngine(supportDirectory: support, concurrency: 1)
        var settings = Settings()
        settings.outputMode = .replace
        let batch = OperationPlanner.batch(
            for: OperationRequest(op: operation, options: options, inputs: [url]), settings: settings)
        let result = await engine.run(batch, settings: settings) { _ in }
        let outcome = try #require(result.outcomes.first)
        guard case .succeeded(let outputs, _) = outcome, let output = outputs.first else {
            Issue.record("expected success, got \(outcome)")
            throw CancellationError()
        }
        return output
    }

    private func decodedAudio(_ demuxer: any MediaDemuxer) throws -> Int {
        var demuxer = demuxer
        let track = try #require(demuxer.tracks.first { !$0.isVideo })
        let decoder = try AudioPacketDecoder(track: track)
        var frames = 0
        while let packet = try demuxer.nextPacket() {
            if packet.track == track.number { frames += try decoder.decode(packet).count / decoder.channels }
        }
        return frames
    }

    private func decodedVideo(_ demuxer: any MediaDemuxer) throws -> Int {
        var demuxer = demuxer
        let track = try #require(demuxer.tracks.first { $0.isVideo })
        var decoder = try VideoDecoders.make(for: track)
        var frames = 0
        while let packet = try demuxer.nextPacket() {
            if packet.track == track.number { frames += try decoder.decode(packet).count }
        }
        return frames + (try decoder.finish().count)
    }

    private func assetPackets(_ url: URL, type: AVMediaType = .audio) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: type).first)
        let reader = try AssetTrackReader(asset: asset, track: track, number: 1, mode: .packets)
        var payloads: [Data] = []
        while let packets = try await reader.nextPackets() { payloads += packets.map(\.payload) }
        return payloads
    }

    private func containerPackets(_ url: URL, video: Bool = false) throws -> [Data] {
        var demuxer = try MatroskaDemuxer(url: url)
        let selected = try #require(demuxer.tracks.first { $0.isVideo == video })
        var payloads: [Data] = []
        while let packet = try demuxer.nextPacket() {
            if packet.track == selected.number { payloads.append(packet.payload) }
        }
        return payloads
    }

    private func resource(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"))
    }

    /// Independent reference decoder.
    private func ffmpegAudio(_ url: URL) async throws -> [Float] {
        let directory = try #require(ProcessInfo.processInfo.environment["MACEASE_MEDIA_TOOLS"])
        let tools = try MediaDownloadTools(directory: URL(filePath: directory))
        let decoded = try await MediaToolProcess().run(
            executable: tools.ffmpeg,
            arguments: ["-nostdin", "-v", "error", "-i", url.path, "-map", "0:a:0", "-f", "f32le", "pipe:1"],
            directory: FileManager.default.temporaryDirectory, tools: tools
        ).stdout
        var samples = [Float](repeating: 0, count: decoded.count / MemoryLayout<Float>.size)
        _ = samples.withUnsafeMutableBytes { decoded.copyBytes(to: $0) }
        return samples
    }

    private func decodedPCM(_ url: URL) async throws -> (sampleRate: Double, samples: [Float]) {
        let input = try await MediaInput.open(url)
        let source = try VideoPCMSource(input: input, track: try #require(input.audio), start: 0, end: .max)
        var samples: [Float] = []
        while let chunk = try await source.next() { samples += chunk.samples }
        return (source.sampleRate, samples)
    }

    private func oggPackets(_ url: URL, headers: Int) throws -> [Data] {
        let reader = try OggPacketReader(url: url)
        var payloads: [Data] = []
        while let packet = try reader.next() { payloads.append(packet.data) }
        return Array(payloads.dropFirst(headers))
    }

    @Test func conversionCopiesCompatibleVideoWhileReencodingAudio() async throws {
        let fixture = try fixture()
        let input = try await MediaInput.open(fixture)
        let source = fixture.deletingLastPathComponent().appending(path: "h264-opus.mkv")
        let plan = TranscodePlan(container: .mkv, video: .copy, audio: .encode(.opus, kilobits: 96))
        try await Transcoder.run(input, plan: plan, to: source) { _ in }
        let expectedVideo = try containerPackets(source, video: true)
        #expect(!expectedVideo.isEmpty)
        let output = try await run(.videoConvert, preset: "mp4", on: source)
        #expect(try await assetPackets(output, type: .video) == expectedVideo)
        let converted = try await MediaInput.open(output)
        #expect(converted.video?.codec == .h264)
        #expect(converted.audio?.codec == .aac)
        #expect(try await assetPackets(output).count > 0)
    }

    @Test func conversionCopiesCompatibleAudioWhileReencodingVideo() async throws {
        let fixture = try fixture()
        let input = try await MediaInput.open(fixture)
        let source = fixture.deletingLastPathComponent().appending(path: "vp9-aac.mkv")
        let encoding = VideoEncoding(
            codec: .vp9, width: input.codedSize.width, height: input.codedSize.height,
            frameDuration: input.frameDuration, bitrate: nil)
        let plan = TranscodePlan(container: .mkv, video: .encode(encoding, FrameEdit()), audio: .copy)
        try await Transcoder.run(input, plan: plan, to: source) { _ in }
        let expectedAudio = try containerPackets(source)
        #expect(!expectedAudio.isEmpty)
        let output = try await run(.videoConvert, preset: "mp4", on: source)
        #expect(try await assetPackets(output) == expectedAudio)
        let converted = try await MediaInput.open(output)
        #expect(converted.video?.codec == .h264)
        #expect(converted.audio?.codec == .aac)
        let asset = AVURLAsset(url: output)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AssetTrackReader(asset: asset, track: video, number: 1, mode: .frames)
        var frames = 0
        while try await reader.nextFrame() != nil { frames += 1 }
        #expect(frames == 48)
    }

    @Test func convertWebMEncodesVP9AndOpus() async throws {
        let source = try fixture()
        let output = try await run(.videoConvert, preset: "webm", on: source)
        let demuxer = try MatroskaDemuxer(url: output)
        #expect(demuxer.tracks.map(\.codec) == [.vp9, .opus])
        #expect(try decodedVideo(demuxer) == 48)
        #expect(try decodedAudio(demuxer) > 80_000)
    }

    @Test func convertAVIEncodesMJPEGAndPCM() async throws {
        let source = try fixture()
        let output = try await run(.videoConvert, preset: "avi", on: source)
        let demuxer = try AVIDemuxer(url: output)
        #expect(demuxer.tracks.first?.codec == .mjpeg)
        #expect(demuxer.tracks.last?.codec == .pcm(bits: 16, float: false, bigEndian: false))
        #expect(try decodedVideo(demuxer) == 48)
        #expect(try decodedAudio(demuxer) > 80_000)
    }

    @Test(arguments: [0, 4_128, 4_800])
    func quantizedPCMReencodingPreservesFrameCountAndRealGap(gapFrames: Int) async throws {
        let sampleRate = 48_000
        let packetFrames = 1_024
        let packetCount = 12
        let gapStartPacket = 6
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "quantized.mkv")
        let videoResource = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac.mp4", withExtension: nil, subdirectory: "Resources"))
        let asset = AVURLAsset(url: videoResource)
        let sourceVideo = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let video = try await AssetTracks.describe(sourceVideo, number: 1)
        let reader = try AssetTrackReader(asset: asset, track: sourceVideo, number: 1, mode: .packets)
        var firstKeyframe: MediaPacket?
        while let packets = try await reader.nextPackets() {
            if let keyframe = packets.first(where: { $0.isKeyframe }) {
                firstKeyframe = keyframe
                break
            }
        }
        let videoPacket = try #require(firstKeyframe)
        let audio = MediaTrack(
            number: 2, kind: .audio(sampleRate: Double(sampleRate), channels: 1),
            codec: .pcm(bits: 16, float: false, bigEndian: false))
        var muxer = try MatroskaMuxer(url: source, tracks: [video, audio], webm: false)
        try muxer.write(videoPacket)
        for packet in 0..<packetCount {
            let offset = packet * packetFrames + (packet >= gapStartPacket ? gapFrames : 0)
            let timestamp = try Nanoseconds.scale(
                Int64(offset), by: Nanoseconds.perSecond, over: Int64(sampleRate))
            try muxer.write(
                MediaPacket(
                    track: audio.number, timestamp: timestamp, isKeyframe: true,
                    payload: Data(repeating: 1, count: packetFrames * MemoryLayout<Int16>.size)))
        }
        try muxer.finish()
        #expect(
            try MatroskaDemuxer(url: source).tracks.first { !$0.isVideo }?.timestampQuantum
                == Nanoseconds.perMillisecond)

        let expectedFrames = packetCount * packetFrames + gapFrames
        let gapStartFrame = gapStartPacket * packetFrames
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard case .replace(_, let converted) = try await VideoEdits.run(.convert(.avi), url: source, context: context)
        else {
            Issue.record("expected staged AVI")
            return
        }
        var aviDemuxer = try AVIDemuxer(url: converted.url)
        let aviAudio = try #require(aviDemuxer.tracks.first { !$0.isVideo })
        let decoder = try AudioPacketDecoder(track: aviAudio)
        var aviSamples: [Float] = []
        while let packet = try aviDemuxer.nextPacket() {
            if packet.track == aviAudio.number { aviSamples += try decoder.decode(packet) }
        }
        try #require(aviSamples.count == expectedFrames)
        #expect(aviSamples[0] != 0)
        #expect(aviSamples[gapStartFrame + gapFrames] != 0)
        if gapFrames > 0 {
            #expect(aviSamples[gapStartFrame..<gapStartFrame + gapFrames].allSatisfy { $0 == 0 })
        }

        guard
            case .derived(_, let outputs) = try await VideoAudio.extract(
                .wav, kilobits: 0, url: source, context: context)
        else {
            Issue.record("expected derived WAV")
            return
        }
        let output = try #require(outputs.first)
        let (_, samples) = try AudioSignals.decode(output.url)
        try #require(samples.count == expectedFrames)
        #expect(samples[0] != 0)
        #expect(samples[gapStartFrame + gapFrames] != 0)
        if gapFrames > 0 {
            #expect(samples[gapStartFrame..<gapStartFrame + gapFrames].allSatisfy { $0 == 0 })
            await #expect(throws: EngineError.audioCopyTimingUnsupported) {
                _ = try await VideoAudio.extractOriginal(url: source, context: context)
            }
        } else {
            guard case .derived(_, let copies) = try await VideoAudio.extractOriginal(url: source, context: context),
                let copy = copies.first
            else {
                Issue.record("expected unchanged PCM extraction")
                return
            }
            #expect(try AudioSignals.decode(copy.url).1 == samples)
        }
    }

    @Test func convertingFloatPCMMatroskaToAVIRejectsNaNWithoutTouchingSource() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "InvalidPCM-\(UUID().uuidString)")
        TestTemporaryFolders.register(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "invalid.mkv")
        let image = try ImageFixtures.canvas(width: 16, height: 16) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let frame = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(frame, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let video = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .mjpeg)
        let audio = MediaTrack(
            number: 2, kind: .audio(sampleRate: 48_000, channels: 1),
            codec: .pcm(bits: 32, float: true, bigEndian: false))
        var muxer = try MatroskaMuxer(url: source, tracks: [video, audio], webm: false)
        try muxer.write(
            MediaPacket(
                track: video.number, timestamp: 0, duration: 40 * Nanoseconds.perMillisecond,
                isKeyframe: true, payload: frame as Data))
        try muxer.write(
            MediaPacket(track: audio.number, timestamp: 0, isKeyframe: true, payload: Data([0, 0, 192, 127])))
        try muxer.finish()
        let original = try Data(contentsOf: source)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        await #expect(throws: EngineError.nonFiniteAudioSample) {
            try await VideoEdits.run(.convert(.avi), url: source, context: context)
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "invalid.avi").path))
    }

    @Test func matroskaAcceptsReencodedAAC() async throws {
        let source = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac.mp4", withExtension: nil, subdirectory: "Resources"))
        let input = try await MediaInput.open(source)
        let output = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-encoded.mkv")
        defer { try? FileManager.default.removeItem(at: output) }
        let plan = TranscodePlan(container: .mkv, video: .copy, audio: .encode(.aac, kilobits: 128))
        try await Transcoder.run(input, plan: plan, to: output) { _ in }
        let demuxer = try MatroskaDemuxer(url: output)
        #expect(demuxer.tracks.map(\.codec) == [.h264, .aac])
        #expect(try decodedAudio(demuxer) > 0)
    }

    @Test func extractAudioCopiesAACAndEncodesWave() async throws {
        let source = try fixture()
        let originalBytes = try Data(contentsOf: source)
        let sourceAudio = try AudioSignals.decode(source)
        let m4a = try await run(.videoExtractAudio, preset: "m4a", on: source)
        #expect(FileManager.default.fileExists(atPath: source.path))
        let copied = try AudioInput(url: m4a)
        #expect(copied.codec == .aac)
        #expect((copied.frameCount ?? 0) > 0)
        let originalPackets = try await assetPackets(source)
        let extractedPackets = try await assetPackets(m4a)
        #expect(extractedPackets == originalPackets)

        let wave = try await run(.videoExtractAudio, preset: "wav", on: source)
        let encoded = try AudioInput(url: wave)
        #expect(encoded.codec == .pcm)
        let waveAudio = try AudioSignals.decode(wave)
        #expect(waveAudio.input.sampleRate == sourceAudio.input.sampleRate)
        #expect(waveAudio.input.channels == sourceAudio.input.channels)
        #expect(waveAudio.samples.count == sourceAudio.samples.count)
        let audibleAmplitude: Float = 0.05
        #expect(sourceAudio.samples.contains { abs($0) > audibleAmplitude })
        let maximumDifference = zip(waveAudio.samples, sourceAudio.samples).map { abs($0 - $1) }.max() ?? .infinity
        let pcmTolerance: Float = 1.0 / 32_768
        #expect(maximumDifference <= pcmTolerance)
        #expect(try Data(contentsOf: source) == originalBytes)
    }

    @Test(arguments: ["wav", "flac", "mp3", "m4a-aac"], ["ffmpeg-h264-heaac.mp4", "ffmpeg-h264-heaac-v2.mp4"])
    func extractionDecodesHEAACAtItsOutputRate(preset: String, name: String) async throws {
        let source = try fixture(name)
        let originalBytes = try Data(contentsOf: source)
        let sourceAudio = try AudioSignals.decode(source)
        let outputRate = 44_100.0
        let channels = 2
        #expect(sourceAudio.input.sampleRate == outputRate)
        let extracted = try AudioSignals.decode(try await run(.videoExtractAudio, preset: preset, on: source))
        #expect(extracted.input.sampleRate == outputRate)
        #expect(extracted.input.channels == channels)
        if preset == "wav" || preset == "flac" {
            #expect(extracted.samples.count == sourceAudio.samples.count)
            let difference = zip(extracted.samples, sourceAudio.samples).map { abs($0 - $1) }.max() ?? .infinity
            let pcmTolerance: Float = 1.0 / 32_768
            #expect(difference <= pcmTolerance)
        } else {
            let mp3FrameSamples = 1_152 * channels
            #expect(abs(extracted.samples.count - sourceAudio.samples.count) <= mp3FrameSamples)
        }
        let minimumCorrelation = 0.95
        let levelToleranceDecibels = 1.0
        for channel in 0..<channels {
            let reference = stride(from: channel, to: sourceAudio.samples.count, by: channels).map {
                Double(sourceAudio.samples[$0])
            }
            let decoded = stride(from: channel, to: extracted.samples.count, by: channels).map {
                Double(extracted.samples[$0])
            }
            let referenceEnergy = reference.reduce(0) { $0 + $1 * $1 }
            let decodedEnergy = decoded.reduce(0) { $0 + $1 * $1 }
            let dot = zip(reference, decoded).reduce(0) { $0 + $1.0 * $1.1 }
            #expect(dot / (referenceEnergy * decodedEnergy).squareRoot() >= minimumCorrelation, "channel \(channel)")
            let levelChange =
                10 * log10(decodedEnergy / Double(decoded.count) / (referenceEnergy / Double(reference.count)))
            #expect(abs(levelChange) <= levelToleranceDecibels, "channel \(channel) level \(levelChange) dB")
        }
        #expect(try Data(contentsOf: source) == originalBytes)
    }

    @Test func matroskaWaveformUsesTheInHouseDecoders() async throws {
        let webm = try await run(.videoConvert, preset: "webm", on: try fixture())
        let summary = try #require(try await AudioWaveform.load(videoURL: webm, bins: 8))
        #expect(abs(summary.duration - 2) < 0.1)
        #expect(summary.peaks.allSatisfy { $0 > 0.05 })
    }

    @Test(arguments: ["ffmpeg-h264-aac.mp4", "ffmpeg-h264-heaac.mp4", "ffmpeg-h264-heaac-v2.mp4"])
    func matroskaConversionKeepsAACPrimingAndPadding(name: String) async throws {
        let source = try resource(name)
        let output = try await run(.videoConvert, preset: "mkv", on: try fixture(name))
        #expect(try containerPackets(output) == (try await assetPackets(source)))
        let recopied = output.deletingLastPathComponent().appending(path: "recopied.mkv")
        try await Transcoder.run(
            try await MediaInput.open(output), plan: TranscodePlan(container: .mkv, video: .copy, audio: .copy),
            to: recopied
        ) { _ in }
        let expected = try await ffmpegAudio(source)
        #expect(!expected.isEmpty)
        for matroska in [output, recopied] {
            let converted = try await ffmpegAudio(matroska)
            #expect(converted.count == expected.count, "\(matroska.lastPathComponent)")
            let difference = zip(converted, expected).map { abs($0 - $1) }.max() ?? .infinity
            #expect(difference == 0, "\(matroska.lastPathComponent)")
        }
    }

    @Test func matroskaAACDecodesLikeItsSource() async throws {
        let output = try await run(.videoConvert, preset: "mkv", on: try fixture())
        let expected = try await decodedPCM(try resource("ffmpeg-h264-aac.mp4"))
        let decoded = try await decodedPCM(output)
        #expect(decoded.sampleRate == expected.sampleRate)
        #expect(decoded.samples.count == expected.samples.count)
        let difference = zip(decoded.samples, expected.samples).map { abs($0 - $1) }.max() ?? .infinity
        let roundingTolerance: Float = 1e-6
        #expect(difference <= roundingTolerance)
    }

    @Test func heAACMatroskaDecodesForItsSourceDuration() async throws {
        let name = "ffmpeg-h264-heaac.mp4"
        let output = try await run(.videoConvert, preset: "mkv", on: try fixture(name))
        let expected = try await decodedPCM(try resource(name))
        let decoded = try await decodedPCM(output)
        let expectedSeconds = Double(expected.samples.count) / expected.sampleRate
        #expect(Double(decoded.samples.count) / decoded.sampleRate == expectedSeconds)
    }

    @Test func matroskaAACCopiesToFLVOnTheSourceTimeline() async throws {
        let matroska = try await run(.videoConvert, preset: "mkv", on: try fixture())
        let output = try await run(.videoConvert, preset: "flv", on: matroska)
        let expected = try await ffmpegAudio(try resource("ffmpeg-h264-aac.mp4"))
        let converted = try await ffmpegAudio(output)
        let frameSamples = 2 * 1_024
        try #require(converted.count >= expected.count && converted.count - expected.count < frameSamples)
        // Edge frames decode without priming context.
        let middle = frameSamples..<(expected.count - frameSamples)
        let difference = zip(converted[middle], expected[middle]).map { abs($0 - $1) }.max() ?? .infinity
        let decoderTolerance: Float = 1e-4
        #expect(difference <= decoderTolerance)
    }

    @Test func originalExtractionIgnoresEncodingPreferences() async throws {
        let source = try fixture()
        let originalBytes = try Data(contentsOf: source)
        var settings = Settings()
        settings.audio.extractedAudioBitrate = 64
        #expect(
            VideoPlanner.options(for: .videoExtractAudio, preset: "original", settings: settings)
                == .extractOriginalAudio)
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: source.deletingLastPathComponent()),
            progress: { _ in })
        defer { context.removeStaging() }
        let result = try await VideoAudio.extractOriginal(url: source, context: context)
        guard case .derived(_, let outputs) = result, let output = outputs.first else {
            Issue.record("expected extracted original audio")
            return
        }
        #expect(output.url.pathExtension == "m4a")
        #expect(try await assetPackets(output.url) == assetPackets(source))
        #expect(try AudioSignals.decode(output.url).samples == AudioSignals.decode(source).samples)
        #expect(try Data(contentsOf: source) == originalBytes)
    }

    @Test func originalExtractionRefusesUnsupportedCopyWithoutEncoding() async throws {
        let source = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../FormatsTests/Resources/ffmpeg-mpeg4-ac3.avi")
        let originalBytes = try Data(contentsOf: source)
        let folder = try AudioSignals.temporaryFolder()
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        await #expect(throws: EngineError.self) { try await VideoAudio.extractOriginal(url: source, context: context) }
        #expect(try Data(contentsOf: source) == originalBytes)
    }

    @Test func extractAudioWithChosenBitrateReencodesAAC() async throws {
        let source = try fixture()
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: source.deletingLastPathComponent()),
            progress: { _ in })
        defer { context.removeStaging() }
        let kilobits = 64
        let bitrateTolerance = 0.2
        let result = try await VideoAudio.extract(.m4aAAC, kilobits: kilobits, url: source, context: context)
        guard case .derived(_, let outputs) = result, let output = outputs.first else {
            Issue.record("expected a staged M4A")
            return
        }
        #expect(try AudioInput(url: output.url).codec == .aac)
        #expect(try await assetPackets(output.url) != (try await assetPackets(source)))
        let track = try #require(try await AVURLAsset(url: output.url).loadTracks(withMediaType: .audio).first)
        let rate = try await track.load(.estimatedDataRate)
        #expect(
            abs(Double(rate) - Double(kilobits * 1_000)) < Double(kilobits * 1_000) * bitrateTolerance, "\(rate) bps")
    }

    @Test func stagedPCMCopyPreservesSignedEndpoints() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "VideoPCM-\(UUID().uuidString)")
        TestTemporaryFolders.register(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "pcm.mkv")
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 48_000, channels: 1),
            codec: .pcm(bits: 16, float: false, bigEndian: false))
        var muxer = try MatroskaMuxer(url: url, tracks: [track], webm: false)
        let payload = Data([0, 128, 255, 127, 0, 0, 232, 3])
        try muxer.write(
            MediaPacket(
                track: 1, timestamp: 0, duration: 4 * Nanoseconds.perSecond / 48_000, isKeyframe: true, payload: payload
            ))
        try muxer.finish()
        let original = try Data(contentsOf: url)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        let result = try await VideoAudio.extract(.wav, url: url, context: context)
        guard case .derived(_, let outputs) = result, let output = outputs.first else {
            Issue.record("expected a staged WAV")
            return
        }
        let audio = try AudioInput(url: output.url)
        let reader = try audio.open()
        let samples = try #require(try reader.read())
        let expectedSamples: [Float] = [-1, 32_767.0 / 32_768, 0, 1_000.0 / 32_768]
        #expect(samples == expectedSamples)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func sparseMatroskaAudioRejectsExcessiveSilenceInBothEncoders() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SparseAudio-\(UUID().uuidString)")
        TestTemporaryFolders.register(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "sparse.mkv")
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 48_000, channels: 1),
            codec: .pcm(bits: 16, float: false, bigEndian: false))
        var muxer = try MatroskaMuxer(url: source, tracks: [track], webm: false)
        let samples = Data([0, 0, 0, 0, 0, 0, 0, 0])
        try muxer.write(MediaPacket(track: 1, timestamp: 0, isKeyframe: true, payload: samples))
        try muxer.write(
            MediaPacket(track: 1, timestamp: 601 * Nanoseconds.perSecond, isKeyframe: true, payload: samples))
        try muxer.finish()
        let original = try Data(contentsOf: source)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        await #expect(throws: EngineError.decodeFailed("audio synthesized silence exceeds 10 minutes")) {
            try await VideoAudio.extract(.m4aAAC, url: source, context: context)
        }
        #expect(try Data(contentsOf: source) == original)

        let input = try await MediaInput.open(source)
        let output = folder.appending(path: "transcoded.mkv")
        await #expect(throws: EngineError.decodeFailed("audio synthesized silence exceeds 10 minutes")) {
            try await Transcoder.run(
                input, plan: TranscodePlan(container: .mkv, video: nil, audio: .encode(.aac, kilobits: 128)),
                to: output
            ) { _ in }
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func repeatedSparsePacketsShareOneSilenceBudget() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "RepeatedSparseAudio-\(UUID().uuidString)")
        TestTemporaryFolders.register(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let source = folder.appending(path: "repeated.mkv")
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 1, channels: 1),
            codec: .pcm(bits: 16, float: false, bigEndian: false))
        var muxer = try MatroskaMuxer(url: source, tracks: [track], webm: false)
        for second in [0, 304, 609] {
            try muxer.write(
                MediaPacket(
                    track: 1, timestamp: Int64(second) * Nanoseconds.perSecond,
                    isKeyframe: true, payload: Data(repeating: 0, count: 8)))
        }
        try muxer.finish()
        let original = try Data(contentsOf: source)
        let input = try await MediaInput.open(source)
        let output = folder.appending(path: "repeated-output.mkv")
        await #expect(throws: EngineError.decodeFailed("audio synthesized silence exceeds 10 minutes")) {
            try await Transcoder.run(
                input,
                plan: TranscodePlan(
                    container: .mkv, video: nil,
                    audio: .encode(.pcm(bits: 16, float: false, bigEndian: false), kilobits: 0)),
                to: output
            ) { _ in }
        }
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func extractOpusAndVorbisCopiesCompressedPackets() async throws {
        let source = try fixture()
        let webm = try await run(.videoConvert, preset: "webm", on: source)
        let opus = try await run(.videoExtractAudio, preset: "opus", on: webm)
        #expect(try oggPackets(opus, headers: 2) == containerPackets(webm))
        let opusAudio = try AudioInput(url: opus)
        #expect(opusAudio.codec == .opus)
        #expect((opusAudio.frameCount ?? 0) > 80_000)
        let originalOpus = try await run(.videoExtractAudio, preset: "original", on: webm)
        #expect(try oggPackets(originalOpus, headers: 2) == containerPackets(webm))
        #expect(try AudioInput(url: originalOpus).frameCount == opusAudio.frameCount)

        let input = try await MediaInput.open(webm)
        let vorbis = try TestVolume.makeFolder().appending(path: "vorbis.webm")
        let plan = TranscodePlan(container: .webm, video: .copy, audio: .encode(.vorbis, kilobits: 128))
        try await Transcoder.run(input, plan: plan, to: vorbis) { _ in }
        let ogg = try await run(.videoExtractAudio, preset: "ogg", on: vorbis)
        #expect(try oggPackets(ogg, headers: 3) == containerPackets(vorbis))
        let vorbisAudio = try AudioInput(url: ogg)
        #expect(vorbisAudio.codec == .vorbis)
        #expect((vorbisAudio.frameCount ?? 0) > 80_000)
        let originalVorbis = try await run(.videoExtractAudio, preset: "original", on: vorbis)
        #expect(try oggPackets(originalVorbis, headers: 3) == containerPackets(vorbis))
        #expect(try AudioInput(url: originalVorbis).frameCount == vorbisAudio.frameCount)
        #expect(try AudioInput(url: originalVorbis).frameCount == Int64(decodedAudio(MatroskaDemuxer(url: vorbis))))
    }

    @Test(arguments: [0, 20])
    func originalOggExtractionRefusesTimelineGaps(firstShiftedPacket: Int) async throws {
        let source = try fixture()
        let webm = try await run(.videoConvert, preset: "webm", on: source)
        var reader = try MatroskaDemuxer(url: webm)
        let folder = try TestVolume.makeFolder()
        let shifted = folder.appending(path: "shifted.webm")
        let audio = try #require(reader.tracks.first { !$0.isVideo })
        var writer = try MatroskaMuxer(url: shifted, tracks: reader.tracks, webm: true)
        var count = 0
        while var packet = try reader.nextPacket() {
            if packet.track == audio.number {
                if count >= firstShiftedPacket { packet.timestamp += 100 * Nanoseconds.perMillisecond }
                count += 1
            }
            try writer.write(packet)
        }
        try writer.finish()
        let original = try Data(contentsOf: shifted)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        await #expect(throws: EngineError.audioCopyTimingUnsupported) {
            _ = try await VideoAudio.extractOriginal(url: shifted, context: context)
        }
        #expect(try Data(contentsOf: shifted) == original)
    }

    @Test(arguments: ["original", "opus"])
    func copiedOggDurationComesFromAudioRatherThanVideo(preset: String) async throws {
        let source = try fixture()
        let webm = try await run(.videoConvert, preset: "webm", on: source)
        var reader = try MatroskaDemuxer(url: webm)
        let folder = try TestVolume.makeFolder()
        let extended = folder.appending(path: "extended.webm")
        let audio = try #require(reader.tracks.first { !$0.isVideo })
        let decoder = try AudioPacketDecoder(track: audio)
        var expected: [Float] = []
        var writer = try MatroskaMuxer(url: extended, tracks: reader.tracks, webm: true)
        while var packet = try reader.nextPacket() {
            if packet.track == audio.number {
                expected += try decoder.decode(packet)
                packet.duration = nil
            } else {
                packet.timestamp += 3 * Nanoseconds.perSecond
            }
            try writer.write(packet)
        }
        try writer.finish()
        let original = try Data(contentsOf: extended)
        let output = try await run(.videoExtractAudio, preset: preset, on: extended)
        let (_, actual) = try AudioSignals.decode(output)
        #expect(actual.count == expected.count)
        #expect(actual == expected)
        #expect(try Data(contentsOf: extended) == original)
    }
}
