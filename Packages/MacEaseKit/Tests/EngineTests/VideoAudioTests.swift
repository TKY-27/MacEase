import AVFoundation
import Foundation
import ImageIO
import MenuCatalog
import Testing
import UniformTypeIdentifiers

@testable import Engine
@testable import Formats

@Suite(.serialized) struct VideoAudioTests {
    private func fixture() throws -> URL {
        let source = try #require(
            Bundle.module.url(forResource: "ffmpeg-h264-aac.mp4", withExtension: nil, subdirectory: "Resources"))
        let copy = try TestVolume.makeFolder().appending(path: "ffmpeg-h264-aac.mp4")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    private func run(_ operation: OperationID, preset: String, on url: URL) async throws -> URL {
        let options = try #require(OperationPlanner.options(for: operation, preset: preset, settings: Settings()))
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseSupport-\(UUID().uuidString)")
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

    private func assetPackets(_ url: URL) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AssetTrackReader(asset: asset, track: track, number: 1, mode: .packets)
        var payloads: [Data] = []
        while let packets = try await reader.nextPackets() { payloads += packets.map(\.payload) }
        return payloads
    }

    private func containerPackets(_ url: URL) throws -> [Data] {
        var demuxer = try MatroskaDemuxer(url: url)
        let audio = try #require(demuxer.tracks.first { !$0.isVideo })
        var payloads: [Data] = []
        while let packet = try demuxer.nextPacket() {
            if packet.track == audio.number { payloads.append(packet.payload) }
        }
        return payloads
    }

    private func oggPackets(_ url: URL, headers: Int) throws -> [Data] {
        let reader = try OggPacketReader(url: url)
        var payloads: [Data] = []
        while let packet = try reader.next() { payloads.append(packet.data) }
        return Array(payloads.dropFirst(headers))
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

    @Test func convertingFloatPCMMatroskaToAVIRejectsNaNWithoutTouchingSource() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "InvalidPCM-\(UUID().uuidString)")
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
        #expect((encoded.frameCount ?? 0) > 0)
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
        #expect(samples == [-1, 32_767.0 / 32_768, 0, 1_000.0 / 32_768])
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func sparseMatroskaAudioRejectsExcessiveSilenceInBothEncoders() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SparseAudio-\(UUID().uuidString)")
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

        let input = try await MediaInput.open(webm)
        let vorbis = try TestVolume.makeFolder().appending(path: "vorbis.webm")
        let plan = TranscodePlan(container: .webm, video: .copy, audio: .encode(.vorbis, kilobits: 128))
        try await Transcoder.run(input, plan: plan, to: vorbis) { _ in }
        let ogg = try await run(.videoExtractAudio, preset: "ogg", on: vorbis)
        #expect(try oggPackets(ogg, headers: 3) == containerPackets(vorbis))
        let vorbisAudio = try AudioInput(url: ogg)
        #expect(vorbisAudio.codec == .vorbis)
        #expect((vorbisAudio.frameCount ?? 0) > 80_000)
    }
}
