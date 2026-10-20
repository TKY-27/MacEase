import AVFoundation
import Foundation
import Testing

@testable import Formats

@Suite struct OggFLACTests {
    private let ffmpegTags = AudioTags(title: "Fixture", artist: "FFmpeg", album: "Tests")

    private func readAll(_ reader: some PCMSource) throws -> [Float] {
        var samples: [Float] = []
        while let chunk = try reader.read() { samples += chunk }
        return samples
    }

    /// Stereo tone with distinct channels.
    private func tone(frames: Int, rate: Double) -> [Float] {
        (0..<frames).flatMap { frame -> [Float] in
            let time = Double(frame) / rate
            return [Float(sin(2 * .pi * 440 * time) * 0.4), Float(sin(2 * .pi * 660 * time) * 0.3)]
        }
    }

    private func peakFrequencyMatches(_ samples: [Float], channels: Int, rate: Double, frequency: Double) -> Bool {
        let mono = stride(from: 0, to: samples.count, by: channels).map { Double(samples[$0]) }
        let energy = { (candidate: Double) -> Double in
            var real = 0.0
            var imaginary = 0.0
            for (index, value) in mono.enumerated() {
                let angle = 2 * Double.pi * candidate * Double(index) / rate
                real += value * cos(angle)
                imaginary += value * sin(angle)
            }
            return real * real + imaginary * imaginary
        }
        return energy(frequency) > 100 * energy(frequency * 1.5)
    }

    @Test func decodesThirdPartyOggVorbis() throws {
        let reader = try OggAudioReader(url: ContainerFixtures.resource("ffmpeg-vorbis.ogg"))
        let samples = try readAll(reader)

        #expect(reader.codec == .vorbis)
        #expect(reader.sampleRate == 44_100 && reader.channels == 2)
        #expect(reader.tags == ffmpegTags)
        #expect(reader.frameCount.map { Int($0) } == samples.count / 2)
        // FFmpeg's encoder ends on granule 44,160.
        #expect(samples.count / 2 == 44_160)
        #expect(peakFrequencyMatches(samples, channels: 2, rate: 44_100, frequency: 440))
    }

    @Test func decodesThirdPartyOggOpus() throws {
        let reader = try OggAudioReader(url: ContainerFixtures.resource("ffmpeg-opus.opus"))
        let samples = try readAll(reader)

        #expect(reader.codec == .opus)
        #expect(reader.sampleRate == 48_000 && reader.channels == 2)
        #expect(reader.tags == ffmpegTags)
        #expect(samples.count / 2 == 48_000)
        #expect(peakFrequencyMatches(samples, channels: 2, rate: 48_000, frequency: 440))
    }

    @Test func decodesThirdPartyFLACWithItsArtwork() throws {
        let url = try ContainerFixtures.resource("ffmpeg-flac.flac")
        let tags = try FLACMetadata.tags(in: url)
        let file = try AVAudioFile(forReading: url)

        #expect(tags.title == "Fixture" && tags.artist == "FFmpeg" && tags.album == "Tests")
        #expect(tags.artwork?.mimeType == "image/png")
        #expect(tags.artwork?.data.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true)
        #expect(file.length == 44_100)
    }

    @Test(arguments: [MediaCodec.vorbis, .opus])
    func oggRoundTripIsSampleAlignedAndTrimmed(codec: MediaCodec) throws {
        let rate = codec == .opus ? 48_000.0 : 44_100.0
        let frames = 12_345
        let source = tone(frames: frames, rate: rate)
        let url = ContainerFixtures.temporaryURL("round.ogg")
        let tags = AudioTags(
            title: "Round", artwork: Artwork(data: Data([0xFF, 0xD8, 0xFF, 0xE0]), mimeType: "image/jpeg"))
        let writer = try OggAudioWriter(
            url: url, codec: codec, sampleRate: Int(rate), channels: 2, bitrate: 160_000, tags: tags)
        try writer.write(Array(source[..<10_000]))
        try writer.write(Array(source[10_000...]))
        try writer.finish()

        let reader = try OggAudioReader(url: url)
        let decoded = try readAll(reader)

        #expect(reader.tags == tags)
        #expect(decoded.count == source.count)
        #expect(reader.frameCount == Int64(frames))
        let left = stride(from: 0, to: source.count, by: 2).map { source[$0] }
        let decodedLeft = stride(from: 0, to: decoded.count, by: 2).map { decoded[$0] }
        #expect(AudioFixtures.delay(of: decodedLeft, behind: left, maximum: 64) == 0)
    }

    @Test func vorbisCodecPrivateSplitsBackIntoHeaders() throws {
        let encoder = try VorbisAudioEncoder(sampleRate: 48_000, channels: 1, bitrate: 96_000)
        #expect(try VorbisAudioDecoder.headers(codecPrivate: encoder.codecPrivate) == encoder.headers)
    }

    @Test func flacWriterIsLosslessAndTagged() throws {
        let url = ContainerFixtures.temporaryURL("tagged.flac")
        let source = tone(frames: 30_000, rate: 44_100).map { ($0 * 8_388_608).rounded() / 8_388_608 }
        let tags = AudioTags(
            title: "T", artist: "A", album: "B", artwork: Artwork(data: Data([1, 2, 3]), mimeType: "image/png"))
        let writer = try FLACFileWriter(url: url, sampleRate: 44_100, channels: 2, bitsPerSample: 24, tags: tags)
        try writer.write(source)
        try writer.finish()

        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 40_000))
        try file.read(into: buffer)
        let decoded = Array(UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(buffer.frameLength) * 2))
        #expect(decoded == source)
        #expect(try FLACMetadata.tags(in: url) == tags)
    }

    @Test func oggRejectsUnknownCodecsByName() throws {
        let url = ContainerFixtures.temporaryURL("speex.ogg")
        let writer = try OggPacketWriter(url: url)
        try writer.write(Data("Speex   version".utf8), granule: 0, last: true)
        try writer.close()
        #expect(throws: FormatError.unsupported("Speex")) { try OggAudioReader(url: url) }
    }
}
