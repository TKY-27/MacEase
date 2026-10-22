import Foundation
import Testing

@testable import Formats

@Suite struct DemuxerAudioBoundaryTests {
    @Test(arguments: [0, 9, 4_294_967_296, Int.max])
    func matroskaRejectsInvalidChannels(channels: Int) throws {
        try expectInvalidMatroska(channels: channels, message: "Audio channel count out of range")
    }

    @Test(arguments: [0.0, -1, .nan, .infinity, -.infinity, 768_001, Double.greatestFiniteMagnitude])
    func matroskaRejectsInvalidSampleRates(sampleRate: Double) throws {
        try expectInvalidMatroska(sampleRate: sampleRate, message: "Audio sample rate out of range")
    }

    @Test(arguments: [0, 65, 4_294_967_296, Int.max])
    func matroskaRejectsInvalidBitDepths(bitDepth: Int) throws {
        try expectInvalidMatroska(bitDepth: bitDepth, message: "Audio bit depth out of range")
    }

    @Test func matroskaAcceptsAudioLimitsAndKeepsVideo() throws {
        let url = ContainerFixtures.temporaryURL("audio-limits.mkv")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        try matroska(channels: 8, sampleRate: 768_000, bitDepth: 64).write(to: url)
        let demuxer = try MatroskaDemuxer(url: url)
        #expect(demuxer.tracks.map(\.codec) == [.h264, .aac])
        #expect(demuxer.tracks.last?.kind == .audio(sampleRate: 768_000, channels: 8))
    }

    @Test(arguments: [
        (2, 0, 16), (2, 768_001, 16), (0, 48_000, 16), (9, 48_000, 16),
        (2, 48_000, 0), (2, 48_000, 65),
    ])
    func aviRejectsInvalidAudio(channels: UInt16, sampleRate: UInt32, bitDepth: UInt16) throws {
        let url = ContainerFixtures.temporaryURL("audio.avi")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        var bytes = try Data(contentsOf: ContainerFixtures.resource("ffmpeg-mjpeg-pcm.avi"))
        let marker = Data("strf".utf8)
        let first = try #require(bytes.range(of: marker))
        let audio = try #require(bytes.range(of: marker, in: first.upperBound..<bytes.endIndex)).lowerBound + 8
        bytes.replaceSubrange((audio + 2)..<(audio + 4), with: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        bytes.replaceSubrange(
            (audio + 4)..<(audio + 8), with: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        bytes.replaceSubrange(
            (audio + 14)..<(audio + 16), with: withUnsafeBytes(of: bitDepth.littleEndian) { Array($0) })
        try bytes.write(to: url)
        let message =
            channels == 0 || channels > 8
            ? "Audio channel count out of range"
            : sampleRate == 0 || sampleRate > 768_000
                ? "Audio sample rate out of range"
                : "Audio bit depth out of range"
        #expect(throws: FormatError.corrupt(message)) { try AVIDemuxer(url: url) }
    }

    @Test(arguments: [UInt32(0), 768_001, 0xFF_FFFF])
    func flvRejectsInvalidExplicitAACRate(sampleRate: UInt32) throws {
        let url = ContainerFixtures.temporaryURL("audio.flv")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        let configuration = UInt64(2) << 35 | UInt64(15) << 31 | UInt64(sampleRate) << 7 | UInt64(2) << 3
        let config = (0..<5).map { UInt8(truncatingIfNeeded: configuration >> (8 * (4 - $0))) }
        let body: [UInt8] = [0xAF, 0] + config
        var bytes = Data([0x46, 0x4C, 0x56, 1, 4, 0, 0, 0, 9, 0, 0, 0, 0])
        bytes.append(contentsOf: [8, 0, 0, UInt8(body.count), 0, 0, 0, 0, 0, 0, 0])
        bytes.append(contentsOf: body)
        bytes.append(contentsOf: [0, 0, 0, UInt8(body.count + 11)])
        try bytes.write(to: url)
        #expect(throws: FormatError.corrupt("Audio sample rate out of range")) { try FLVDemuxer(url: url) }
    }

    private func expectInvalidMatroska(
        channels: Int = 2, sampleRate: Double = 48_000, bitDepth: Int = 16, message: String
    ) throws {
        let url = ContainerFixtures.temporaryURL("invalid-audio.mkv")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        try matroska(channels: channels, sampleRate: sampleRate, bitDepth: bitDepth).write(to: url)
        #expect(throws: FormatError.corrupt(message)) { try MatroskaDemuxer(url: url) }
    }

    private func matroska(channels: Int, sampleRate: Double, bitDepth: Int) -> Data {
        let video = EBML.element(
            MatroskaID.trackEntry,
            EBML.element(MatroskaID.trackNumber, unsigned: 1)
                + EBML.element(MatroskaID.trackType, unsigned: UInt64(MatroskaValue.videoTrack))
                + EBML.element(MatroskaID.codecID, string: "V_MPEG4/ISO/AVC")
                + EBML.element(
                    MatroskaID.video,
                    EBML.element(MatroskaID.pixelWidth, unsigned: 16)
                        + EBML.element(MatroskaID.pixelHeight, unsigned: 16)))
        let audio = EBML.element(
            MatroskaID.trackEntry,
            EBML.element(MatroskaID.trackNumber, unsigned: 2)
                + EBML.element(MatroskaID.trackType, unsigned: UInt64(MatroskaValue.audioTrack))
                + EBML.element(MatroskaID.codecID, string: "A_AAC")
                + EBML.element(MatroskaID.codecPrivate, [0x11, 0x90])
                + EBML.element(
                    MatroskaID.audio,
                    EBML.element(MatroskaID.channels, unsigned: UInt64(channels))
                        + EBML.element(MatroskaID.samplingFrequency, float: sampleRate)
                        + EBML.element(MatroskaID.bitDepth, unsigned: UInt64(bitDepth))))
        return Data(
            EBML.element(MatroskaID.ebml, EBML.element(MatroskaID.docType, string: "matroska"))
                + EBML.element(MatroskaID.segment, EBML.element(MatroskaID.tracks, video + audio)))
    }
}

@Suite struct AudioTrackBoundaryTests {
    @Test(arguments: [0, -1, 9, 4_294_967_296, Int.max])
    func descriptionRejectsInvalidChannels(channels: Int) {
        let track = MediaTrack(number: 1, kind: .audio(sampleRate: 48_000, channels: channels), codec: .mp3)
        #expect(throws: FormatError.corrupt("Audio channel count out of range")) {
            try AudioTrackFormat.description(for: track)
        }
    }

    @Test(arguments: [0.0, -1, .nan, .infinity, 768_001])
    func descriptionRejectsInvalidSampleRates(sampleRate: Double) {
        let track = MediaTrack(number: 1, kind: .audio(sampleRate: sampleRate, channels: 2), codec: .mp3)
        #expect(throws: FormatError.corrupt("Audio sample rate out of range")) {
            try AudioTrackFormat.description(for: track)
        }
    }
}
