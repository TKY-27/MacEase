import AVFoundation
import Foundation
import MenuCatalog
import Testing

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
        let batch = OperationPlanner.batch(
            for: OperationRequest(op: operation, options: options, inputs: [url]), settings: Settings())
        let result = await engine.run(batch, settings: Settings()) { _ in }
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
