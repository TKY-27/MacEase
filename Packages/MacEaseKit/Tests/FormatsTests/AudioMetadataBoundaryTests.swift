import Foundation
import Testing

@testable import Formats

@Suite struct AudioMetadataBoundaryTests {
    private func opusHeader(channels: UInt8, mapping: UInt8 = 0) -> Data {
        var header = Data("OpusHead".utf8)
        header.append(contentsOf: [1, channels])
        header.appendLittleEndian(UInt16(0))
        header.appendLittleEndian(UInt32(OpusAudioEncoder.sampleRate))
        header.appendLittleEndian(UInt16(0))
        header.append(mapping)
        return header
    }

    @Test(arguments: [0, 3, 9, 255])
    func oggRejectsInvalidOpusChannels(channels: UInt8) throws {
        let url = ContainerFixtures.temporaryURL("invalid-channels.opus")
        let writer = try OggPacketWriter(url: url)
        try writer.write(opusHeader(channels: channels), granule: 0, last: true)
        try writer.close()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }

        #expect(throws: FormatError.corrupt(String(localized: "Audio channel count out of range"))) {
            try OggAudioReader(url: url)
        }
    }

    @Test func mappedOpusRemainsUnsupported() {
        #expect(throws: FormatError.unsupported("Opus with 3 channels")) {
            try OpusHead(opusHeader(channels: 3, mapping: 1))
        }
    }

    @Test(arguments: [0, 3, 9, Int.max])
    func opusDecoderRejectsInvalidChannels(channels: Int) {
        #expect(throws: FormatError.corrupt(String(localized: "Audio channel count out of range"))) {
            try OpusAudioDecoder(channels: channels)
        }
    }

    @Test(arguments: [Int.min, Int.max])
    func opusEncoderRejectsUnrepresentableBitrate(bitrate: Int) {
        #expect(throws: FormatError.encoderFailure("Opus settings rejected")) {
            try OpusAudioEncoder(channels: 2, bitrate: bitrate)
        }
    }

    @Test func vorbisEncoderRejectsUnrepresentableSampleRate() {
        #expect(throws: FormatError.corrupt(String(localized: "Audio sample rate out of range"))) {
            try VorbisAudioEncoder(sampleRate: Int.max, channels: 2, bitrate: 128_000)
        }
    }

    @Test(arguments: [0, 9, 255])
    func vorbisDecoderRejectsInvalidChannels(channels: UInt8) throws {
        let encoder = try VorbisAudioEncoder(sampleRate: 48_000, channels: 2, bitrate: 128_000)
        var headers = encoder.headers
        headers[0][11] = channels
        #expect(throws: FormatError.corrupt(String(localized: "Audio channel count out of range"))) {
            try VorbisAudioDecoder(headers: headers)
        }
    }

    @Test(arguments: [UInt32(0), UInt32(768_001)])
    func vorbisDecoderRejectsInvalidSampleRate(sampleRate: UInt32) throws {
        let encoder = try VorbisAudioEncoder(sampleRate: 48_000, channels: 2, bitrate: 128_000)
        var headers = encoder.headers
        for byte in 0..<MemoryLayout<UInt32>.size {
            headers[0][12 + byte] = UInt8(truncatingIfNeeded: sampleRate >> (byte * 8))
        }
        #expect(throws: FormatError.corrupt(String(localized: "Audio sample rate out of range"))) {
            try VorbisAudioDecoder(headers: headers)
        }
    }

    @Test(arguments: [0, Int.max])
    func flacWriterRejectsInvalidBitDepth(bitsPerSample: Int) {
        let url = ContainerFixtures.temporaryURL("invalid-depth.flac")
        #expect(throws: FormatError.corrupt(String(localized: "Audio bit depth out of range"))) {
            try FLACFileWriter(
                url: url, sampleRate: 48_000, channels: 2, bitsPerSample: bitsPerSample, tags: AudioTags())
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test(arguments: [0, 768_001])
    func flacMetadataRejectsInvalidSampleRate(sampleRate: Int) throws {
        let url = ContainerFixtures.temporaryURL("invalid-rate.flac")
        var file = try Data(contentsOf: ContainerFixtures.resource("ffmpeg-flac.flac"))
        let marker = try #require(file.range(of: FLACBlock.marker))
        try #require(file[marker.upperBound] & ~FLACBlock.lastFlag == FLACBlock.streamInfo)
        let audioOffset = marker.upperBound + 4 + 10
        file[audioOffset] = UInt8(sampleRate >> 12 & 0xFF)
        file[audioOffset + 1] = UInt8(sampleRate >> 4 & 0xFF)
        file[audioOffset + 2] = file[audioOffset + 2] & 0x0F | UInt8((sampleRate & 0x0F) << 4)
        try file.write(to: url)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }

        #expect(throws: FormatError.corrupt(String(localized: "Audio sample rate out of range"))) {
            try FLACMetadata.tags(in: url)
        }
    }

    @Test func flacMetadataRejectsInvalidBitDepth() throws {
        let url = ContainerFixtures.temporaryURL("invalid-depth.flac")
        var file = try Data(contentsOf: ContainerFixtures.resource("ffmpeg-flac.flac"))
        let marker = try #require(file.range(of: FLACBlock.marker))
        try #require(file[marker.upperBound] & ~FLACBlock.lastFlag == FLACBlock.streamInfo)
        let audioOffset = marker.upperBound + 4 + 10
        file[audioOffset + 2] &= 0xFE
        file[audioOffset + 3] &= 0x0F
        try file.write(to: url)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }

        #expect(throws: FormatError.corrupt(String(localized: "Audio bit depth out of range"))) {
            try FLACMetadata.tags(in: url)
        }
    }
}
