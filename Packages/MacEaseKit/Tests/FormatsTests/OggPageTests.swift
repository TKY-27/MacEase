import Foundation
import Testing

@testable import Formats

@Suite struct OggPageTests {
    @Test(arguments: [Int64(-1), -2, .min])
    func completedPageRequiresGranule(granule: Int64) throws {
        let url = ContainerFixtures.temporaryURL("missing-granule.opus")
        let encoder = try OpusAudioEncoder(channels: 1, bitrate: 64_000)
        let packet = try #require(try encoder.encode([Float](repeating: 0, count: OpusAudioEncoder.frameSamples)).first)
        let writer = try OggPacketWriter(url: url)
        try writer.writeHeader(encoder.identificationHeader)
        try writer.writeHeader(OpusHead.tagsMagic + VorbisComment.encode(AudioTags()))
        try writer.write(packet, granule: granule, last: false)
        try writer.write(packet, granule: granule, last: true)
        try writer.close()

        let packets = try OggPacketReader(url: url)
        _ = try packets.next()
        _ = try packets.next()
        let failure = FormatError.corrupt(String(localized: "Ogg granule out of range"))
        #expect(throws: failure) { _ = try packets.next() }
        let reader = try OggAudioReader(url: url)
        #expect(throws: failure) { _ = try reader.read() }
    }

    @Test func packetsWithinPageDoNotNeedGranules() throws {
        let url = ContainerFixtures.temporaryURL("packet-granules.opus")
        let encoder = try OpusAudioEncoder(channels: 1, bitrate: 64_000)
        let frames = OpusAudioEncoder.frameSamples * 3
        let encoded = try encoder.encode([Float](repeating: 0, count: frames))
        try #require(encoded.count == 3)
        let writer = try OggPacketWriter(url: url)
        try writer.writeHeader(encoder.identificationHeader)
        try writer.writeHeader(OpusHead.tagsMagic + VorbisComment.encode(AudioTags()))
        for (index, packet) in encoded.enumerated() {
            try writer.write(
                packet, granule: Int64((index + 1) * OpusAudioEncoder.frameSamples), last: index == encoded.count - 1)
        }
        try writer.close()

        let packets = try OggPacketReader(url: url)
        _ = try packets.next()
        _ = try packets.next()
        #expect(try packets.next()?.granule == -1)
        #expect(try packets.next()?.granule == -1)
        #expect(try packets.next()?.granule == Int64(frames))
        let reader = try OggAudioReader(url: url)
        #expect(try reader.read()?.count == frames - encoder.preSkip)
        #expect(try reader.read() == nil)
    }

    @Test(arguments: [MediaCodec.vorbis, .opus])
    func continuedCommentDoesNotNeedGranule(codec: MediaCodec) throws {
        let url = ContainerFixtures.temporaryURL("continued-comment.ogg")
        let tags = AudioTags(title: String(repeating: "a", count: 70_000))
        let frames = 4_800
        let writer = try OggAudioWriter(
            url: url, codec: codec, sampleRate: 48_000, channels: 1, bitrate: 96_000, tags: tags)
        try writer.write([Float](repeating: 0, count: frames))
        try writer.finish()

        let reader = try OggAudioReader(url: url)
        #expect(reader.tags == tags)
        var decodedFrames = 0
        while let samples = try reader.read() { decodedFrames += samples.count }
        #expect(decodedFrames == frames)
    }
}
