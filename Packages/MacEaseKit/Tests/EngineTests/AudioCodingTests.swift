import AudioToolbox
import Formats
import Foundation
import Testing

@testable import Engine

enum AudioSignals {
    /// Two tones with a little noise.
    static func music(seconds: Double = 2, sampleRate: Double = 44_100, channels: Int = 2) -> [Float] {
        var state: UInt64 = 0x1234_5678
        let frames = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let time = Double(frame) / sampleRate
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let noise = Double(state >> 40) / Double(1 << 24) - 0.5
            for channel in 0..<channels {
                let base = channel == 0 ? 220.0 : 277.18
                let tone = sin(2 * .pi * base * time) * 0.3 + sin(2 * .pi * base * 1.5 * time) * 0.2
                samples[frame * channels + channel] = Float(tone + noise * 0.02)
            }
        }
        return samples
    }

    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MacEaseAudio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func write(
        _ samples: [Float], to url: URL, format: AudioFormat, sampleRate: Double = 44_100, channels: Int = 2,
        kilobits: Int = 128, bitDepth: Int? = 16, tags: AudioTags = AudioTags()
    ) async throws {
        let encoder = try AudioFileEncoder(
            url: url, target: AudioTarget(format: format, kilobits: kilobits), sampleRate: sampleRate,
            channels: channels, bitDepth: bitDepth, tags: tags)
        let chunk = 8_192 * channels
        for start in stride(from: 0, to: samples.count, by: chunk) {
            try await encoder.write(Array(samples[start..<min(start + chunk, samples.count)]))
        }
        try await encoder.finish()
    }

    static func decode(_ url: URL) throws -> (input: AudioInput, samples: [Float]) {
        let input = try AudioInput(url: url)
        let source = try input.open()
        var samples: [Float] = []
        while let chunk = try source.read() { samples += chunk }
        return (input, samples)
    }

    static func pngArtwork() -> Artwork {
        let png = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYPj/HwADAgH/eL8z2wAAAABJRU5ErkJggg==")
        return Artwork(data: png ?? Data(), mimeType: "image/png")
    }
}

@Suite struct AudioCodingTests {
    /// Slack covers encoder delay and padding.
    @Test(arguments: [
        (AudioFormat.wav, 0), (.aiff, 0), (.flac, 0), (.cafPCM, 0), (.cafALAC, 0), (.m4aALAC, 0), (.m4aAAC, 0),
        (.ogg, 0), (.opus, 0), (.mp3, 3_000), (.aac, 4_200),
    ])
    func roundTripKeepsDurationAndChannels(format: AudioFormat, slack: Int) async throws {
        let folder = try AudioSignals.temporaryFolder()
        for channels in [1, 2] {
            let url = folder.appending(path: "tone-\(channels).\(format.fileExtension)")
            try await AudioSignals.write(
                AudioSignals.music(channels: channels), to: url, format: format, channels: channels)

            let (input, samples) = try AudioSignals.decode(url)

            let expected = Int(2 * format.outputSampleRate(44_100))
            #expect(input.channels == channels)
            #expect(samples.count % channels == 0)
            let frames = samples.count / channels
            #expect(frames >= expected && frames <= expected + slack, "\(format) \(channels) ch: \(frames) frames")
        }
    }

    @Test func losslessFormatsReproduceSamplesExactly() async throws {
        let folder = try AudioSignals.temporaryFolder()
        let quantized = AudioSignals.music().map { ($0 * 32_768).rounded() / 32_768 }
        for format in [AudioFormat.wav, .aiff, .flac, .cafALAC, .m4aALAC] {
            let url = folder.appending(path: "exact.\(format.fileExtension)")
            try await AudioSignals.write(quantized, to: url, format: format)
            #expect(try AudioSignals.decode(url).samples == quantized, "\(format)")
        }
    }

    @Test func audioToolboxDecodesEveryMP3AndAACOutput() async throws {
        let folder = try AudioSignals.temporaryFolder()
        for (format, kilobits) in [(AudioFormat.mp3, 128), (.mp3, 320), (.aac, 96), (.m4aAAC, 256)] {
            let url = folder.appending(path: "\(kilobits).\(format.fileExtension)")
            try await AudioSignals.write(AudioSignals.music(), to: url, format: format, kilobits: kilobits)
            var file: AudioFileID?
            #expect(AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr)
            if let file { AudioFileClose(file) }
            let samples = try AudioSignals.decode(url).samples
            #expect(samples.contains { abs($0) > 0.1 }, "\(format) \(kilobits) decodes to silence")
        }
    }

    @Test(arguments: [AudioFormat.mp3, .m4aAAC, .m4aALAC, .flac, .ogg, .opus])
    func tagsSurvive(format: AudioFormat) async throws {
        let tags = AudioTags(title: "Café ☕", artist: "Artist", album: "Album", artwork: AudioSignals.pngArtwork())
        let url = try AudioSignals.temporaryFolder().appending(path: "tagged.\(format.fileExtension)")
        try await AudioSignals.write(AudioSignals.music(seconds: 0.5), to: url, format: format, tags: tags)

        #expect(try await AudioInput(url: url).tags() == tags)
    }

    @Test func wmaFailsNamingTheCodec() throws {
        let url = try AudioSignals.temporaryFolder().appending(path: "song.wma")
        try Data([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0, 0xAA, 0, 0x62, 0xCE, 0x6C]).write(
            to: url)
        #expect(throws: EngineError.unsupportedCodec("Windows Media Audio")) { try AudioInput(url: url) }
    }
}
