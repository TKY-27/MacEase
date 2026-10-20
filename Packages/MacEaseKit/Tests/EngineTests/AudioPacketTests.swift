import Formats
import Foundation
import Testing

@testable import Engine

/// Audio inside video containers.
@Suite struct AudioPacketTests {
    private static let formatsResources = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../FormatsTests/Resources")

    private func decodeAll(_ demuxer: inout some MediaDemuxer) throws -> (decoder: AudioPacketDecoder, samples: [Float])
    {
        let track = try #require(demuxer.tracks.first { !$0.isVideo })
        let decoder = try AudioPacketDecoder(track: track)
        var samples: [Float] = []
        while let packet = try demuxer.nextPacket() {
            if packet.track == track.number { samples += try decoder.decode(packet) }
        }
        return (decoder, samples)
    }

    private func hasTone(_ samples: [Float]) -> Bool {
        samples.contains { abs($0) > 0.05 }
    }

    @Test func decodesThirdPartyAACAC3AndPCM() throws {
        var flv = try FLVDemuxer(url: Self.formatsResources.appending(path: "ffmpeg-h264-aac.flv"))
        let aac = try decodeAll(&flv)
        #expect(aac.decoder.sampleRate == 44_100 && aac.decoder.channels == 2)
        #expect(abs(aac.samples.count / 2 - 88_200) <= 2_048)
        #expect(hasTone(aac.samples))

        var avi = try AVIDemuxer(url: Self.formatsResources.appending(path: "ffmpeg-mpeg4-ac3.avi"))
        let ac3 = try decodeAll(&avi)
        #expect(abs(ac3.samples.count / ac3.decoder.channels - 96_000) <= 1_536)
        #expect(hasTone(ac3.samples))

        var pcmAVI = try AVIDemuxer(url: Self.formatsResources.appending(path: "ffmpeg-mjpeg-pcm.avi"))
        let pcm = try decodeAll(&pcmAVI)
        #expect(pcm.samples.count == 8_000)
        #expect(hasTone(pcm.samples))
    }

    @Test func decodesFLACAndMP3FromMatroska() throws {
        var demuxer = try MatroskaDemuxer(url: Self.formatsResources.appending(path: "ffmpeg-flac-mp3.mka"))
        #expect(demuxer.tracks.map(\.codec) == [.flac, .mp3])
        let decoders = try demuxer.tracks.map { try AudioPacketDecoder(track: $0) }
        var samples: [[Float]] = [[], []]
        while let packet = try demuxer.nextPacket() {
            samples[packet.track - 1] += try decoders[packet.track - 1].decode(packet)
        }
        #expect(samples[0].count == 8_000)
        #expect(abs(samples[1].count / decoders[1].channels - 22_050) <= 1_152)
        #expect(hasTone(samples[0]) && hasTone(samples[1]))
    }

    @Test(arguments: [MediaCodec.opus, .vorbis, .aac])
    func encodedPacketsSurviveMatroska(codec: MediaCodec) throws {
        let rate = 48_000
        let source = AudioSignals.music(seconds: 1, sampleRate: Double(rate))
        let encoder = try AudioPacketEncoder(codec: codec, sampleRate: rate, channels: 2, kilobits: 128)
        let packets = try encoder.encode(source) + encoder.finish()
        var track = MediaTrack(
            number: 1, kind: .audio(sampleRate: Double(rate), channels: 2), codec: codec,
            codecPrivate: encoder.codecPrivate)
        track.codecDelay = Int64(encoder.delay) * Nanoseconds.perSecond / Int64(rate)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mkv")
        var muxer = try MatroskaMuxer(url: url, tracks: [track], webm: codec != .aac)
        var position: Int64 = 0
        for packet in packets {
            let timestamp = position * Nanoseconds.perSecond / Int64(rate)
            try muxer.write(MediaPacket(track: 1, timestamp: timestamp, isKeyframe: true, payload: packet.data))
            position += Int64(packet.frames)
        }
        try muxer.finish()

        var demuxer = try MatroskaDemuxer(url: url)
        let decoded = try decodeAll(&demuxer).samples

        #expect(decoded.count / 2 >= rate)
        #expect(decoded.count / 2 <= rate + 3_200)
        #expect(hasTone(decoded))
    }
}
