import Foundation
import Testing

@testable import Engine
@testable import Formats

@Suite struct OpusOutputGainTests {
    private static let outputGainRange = 16..<18

    @Test(arguments: [false, true], [Int16(-1_536), 0, 896])
    func matroskaOpusWAVExtractionMatchesOggOutputGain(webm: Bool, gainQ8: Int16) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let channels = 2
        let sampleRate = OpusAudioEncoder.sampleRate
        let encoder = try OpusAudioEncoder(channels: channels, bitrate: 128_000)
        let packets = try encoder.encode(
            AudioSignals.music(seconds: 0.24, sampleRate: Double(sampleRate), channels: channels))
        try #require(!packets.isEmpty)
        var header = encoder.identificationHeader
        var gainBytes = Data()
        gainBytes.appendLittleEndian(UInt16(bitPattern: gainQ8))
        header.replaceSubrange(Self.outputGainRange, with: gainBytes)

        let oggURL = folder.appending(path: "reference.opus")
        let ogg = try OggPacketWriter(url: oggURL)
        try ogg.writeHeader(header)
        try ogg.writeHeader(OpusHead.tagsMagic + VorbisComment.encode(AudioTags()))
        let source = folder.appending(path: webm ? "gained.webm" : "gained.mkv")
        var track = MediaTrack(
            number: 1, kind: .audio(sampleRate: Double(sampleRate), channels: channels), codec: .opus,
            codecPrivate: header)
        track.codecDelay = Int64(encoder.preSkip) * Nanoseconds.perSecond / Int64(sampleRate)
        var muxer = try MatroskaMuxer(url: source, tracks: [track], webm: webm)
        let decoder = try OpusAudioDecoder(channels: channels)
        var ungained: [Float] = []
        for (index, packet) in packets.enumerated() {
            let frame = Int64(index * OpusAudioEncoder.frameSamples)
            try ogg.write(
                packet, granule: frame + Int64(OpusAudioEncoder.frameSamples), last: index == packets.count - 1)
            try muxer.write(
                MediaPacket(
                    track: 1, timestamp: frame * Nanoseconds.perSecond / Int64(sampleRate),
                    isKeyframe: true, payload: packet))
            ungained += try decoder.decode(packet)
        }
        try ogg.close()
        try muxer.finish()
        let original = try Data(contentsOf: source)
        let expectedGain = Float(pow(10, Double(gainQ8) / 256 / 20))
        let expected = ungained.dropFirst(encoder.preSkip * channels).map { $0 * expectedGain }
        let oggSamples = try AudioSignals.decode(oggURL).samples
        try #require(oggSamples.count == expected.count)
        #expect(zip(oggSamples, expected).allSatisfy { abs($0 - $1) < 0.000_001 })
        #expect(expected.contains { abs($0) > 0.05 })

        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard case .derived(_, let outputs) = try await VideoAudio.extract(.wav, url: source, context: context) else {
            Issue.record("expected extracted WAV")
            return
        }
        let output = try #require(outputs.first)
        let extracted = try AudioSignals.decode(output.url).samples
        try #require(extracted.count == expected.count)
        let pcmTolerance: Float = 1.0 / 32_768
        #expect(zip(extracted, expected).allSatisfy { abs($0 - $1) <= pcmTolerance })
        #expect(zip(extracted, oggSamples).allSatisfy { abs($0 - $1) <= pcmTolerance })
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func opusOutputGainUsesCodecDelayWithoutAddingHeaderPreskip() throws {
        let encoder = try OpusAudioEncoder(channels: 1, bitrate: 64_000)
        let payload = try #require(
            try encoder.encode(AudioSignals.music(seconds: 0.02, sampleRate: 48_000, channels: 1)).first)
        let raw = try OpusAudioDecoder(channels: 1).decode(payload)
        var header = encoder.identificationHeader
        var gainBytes = Data()
        gainBytes.appendLittleEndian(UInt16(bitPattern: Int16(-1_536)))
        header.replaceSubrange(Self.outputGainRange, with: gainBytes)
        var track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 48_000, channels: 1), codec: .opus, codecPrivate: header)
        let delayFrames = 120
        try #require(encoder.preSkip != delayFrames)
        track.codecDelay = Int64(delayFrames) * Nanoseconds.perSecond / 48_000
        let decoder = try AudioPacketDecoder(track: track)
        let decoded = try decoder.decode(MediaPacket(track: 1, timestamp: 0, isKeyframe: true, payload: payload))
        let expected = raw.dropFirst(delayFrames).map { $0 * Float(pow(10, -6.0 / 20)) }
        #expect(decoded.count == expected.count)
        #expect(zip(decoded, expected).allSatisfy { abs($0 - $1) < 0.000_001 })
    }

    @Test func matroskaOpusRejectsMissingTruncatedOrInconsistentHeaders() throws {
        let encoder = try OpusAudioEncoder(channels: 1, bitrate: 64_000)
        var invalidSignature = encoder.identificationHeader
        invalidSignature[0] = 0
        let headers: [Data?] = [nil, invalidSignature, Data(encoder.identificationHeader.prefix(12))]
        for header in headers {
            let track = MediaTrack(
                number: 1, kind: .audio(sampleRate: 48_000, channels: 1), codec: .opus, codecPrivate: header)
            #expect(throws: EngineError.self) { try AudioPacketDecoder(track: track) }
        }
        let inconsistent = MediaTrack(
            number: 1, kind: .audio(sampleRate: 48_000, channels: 2), codec: .opus,
            codecPrivate: encoder.identificationHeader)
        #expect(throws: EngineError.decodeFailed("Audio channel count out of range")) {
            try AudioPacketDecoder(track: inconsistent)
        }
    }
}
