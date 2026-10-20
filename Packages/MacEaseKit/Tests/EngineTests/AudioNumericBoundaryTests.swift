import Formats
import Foundation
import Testing

@testable import Engine

@Suite struct AudioNumericBoundaryTests {
    @Test(arguments: [0, -1, 9, 4_294_967_296, Int.max])
    func pcmRejectsInvalidChannels(channels: Int) {
        #expect(throws: FormatError.corrupt("Audio channel count out of range")) {
            try PCMFormat.make(sampleRate: 48_000, channels: channels)
        }
    }

    @Test(arguments: [0.0, -1, .nan, .infinity, 768_001, Double.greatestFiniteMagnitude])
    func pcmRejectsInvalidSampleRates(sampleRate: Double) {
        #expect(throws: FormatError.corrupt("Audio sample rate out of range")) {
            try PCMFormat.make(sampleRate: sampleRate, channels: 2)
        }
    }

    @Test func opusDelayAvoidsIntermediateOverflow() throws {
        var track = MediaTrack(number: 1, kind: .audio(sampleRate: 48_000, channels: 1), codec: .opus)
        track.codecDelay = .max
        let encoder = try OpusAudioEncoder(channels: 1, bitrate: 64_000)
        let samples = [Float](repeating: 0, count: OpusAudioEncoder.frameSamples)
        let payload = try #require(try encoder.encode(samples).first)
        let decoder = try AudioPacketDecoder(track: track)
        #expect(try decoder.decode(MediaPacket(track: 1, timestamp: 0, isKeyframe: true, payload: payload)).isEmpty)
    }

    @Test func discardPaddingAvoidsIntermediateOverflow() throws {
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 768_000, channels: 8),
            codec: .pcm(bits: 16, float: false, bigEndian: false))
        let decoder = try AudioPacketDecoder(track: track)
        var packet = MediaPacket(track: 1, timestamp: 0, isKeyframe: true, payload: Data(repeating: 1, count: 32))
        packet.discardPadding = .max
        #expect(try decoder.decode(packet).isEmpty)
    }
}
