import Formats
import Foundation
import MenuCatalog
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

    @Test(arguments: [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude])
    func fileEncoderRejectsUnrepresentableRateBeforeWriting(sampleRate: Double) throws {
        let folder = try TestVolume.makeFolder()
        let output = folder.appending(path: "invalid.flac")
        #expect(throws: EngineError.decodeFailed("Audio sample rate out of range")) {
            try AudioFileEncoder(
                url: output, target: AudioTarget(format: .flac, kilobits: 0), sampleRate: sampleRate, channels: 1)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func normalizationRejectsNonFiniteTarget(target: Double) async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "tone.wav")
        try await AudioSignals.write(
            AudioSignals.music(seconds: 0.2, sampleRate: 48_000), to: source, format: .wav, sampleRate: 48_000)
        let original = try Data(contentsOf: source)
        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let request = OperationRequest(
            op: .audioNormalize, options: .audio(.normalize(targetLoudness: target)), inputs: [source])
        let outcome = await engine.run(
            OperationPlanner.batch(for: request, settings: Settings()), settings: Settings()
        ) { _ in }

        #expect(outcome.outcomes == [.failed(.invalidInput(.invalidNumericParameter))])
        #expect(outcome.record == nil)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func opusDelayAvoidsIntermediateOverflow() throws {
        var track = MediaTrack(number: 1, kind: .audio(sampleRate: 48_000, channels: 1), codec: .opus)
        track.codecDelay = .max
        let encoder = try OpusAudioEncoder(channels: 1, bitrate: 64_000)
        track.codecPrivate = encoder.identificationHeader
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

    @Test(arguments: [Data([0, 0, 192, 127]), Data([0, 0, 128, 127]), Data([0, 0, 128, 255])])
    func floatPCMRejectsNonFiniteSamples(payload: Data) throws {
        let track = MediaTrack(
            number: 1, kind: .audio(sampleRate: 48_000, channels: 1),
            codec: .pcm(bits: 32, float: true, bigEndian: false))
        let decoder = try AudioPacketDecoder(track: track)
        #expect(throws: EngineError.nonFiniteAudioSample) {
            try decoder.decode(MediaPacket(track: 1, timestamp: 0, isKeyframe: true, payload: payload))
        }
    }

    @Test func waveWithNaNFailsConversionAndPreservesOriginal() async throws {
        let folder = try TestVolume.makeFolder()
        let source = folder.appending(path: "nan.wav")
        let header: [UInt8] = [
            0x52, 0x49, 0x46, 0x46, 0x24, 0x10, 0, 0, 0x57, 0x41, 0x56, 0x45,
            0x66, 0x6D, 0x74, 0x20, 16, 0, 0, 0, 3, 0, 1, 0,
            0x80, 0xBB, 0, 0, 0, 0xEE, 2, 0, 4, 0, 32, 0,
            0x64, 0x61, 0x74, 0x61, 0, 0x10, 0, 0,
        ]
        var original = Data(header) + Data(repeating: 0, count: 4096)
        original.replaceSubrange(44..<48, with: [0, 0, 0xC0, 0x7F])
        try original.write(to: source)

        let reader = try AudioInput(url: source).open()
        #expect(throws: EngineError.nonFiniteAudioSample) { try reader.read() }

        let engine = try JobEngine(supportDirectory: folder.appending(path: "support"), concurrency: 1)
        let request = OperationRequest(
            op: .audioConvert, options: .audio(.convert(.mp3)), inputs: [source])
        let outcome = await engine.run(
            OperationPlanner.batch(for: request, settings: Settings()), settings: Settings()
        ) { _ in }

        #expect(outcome.outcomes == [.failed(.nonFiniteAudioSample)])
        #expect(outcome.record == nil)
        #expect(try Data(contentsOf: source) == original)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "nan.mp3").path))
    }
}
