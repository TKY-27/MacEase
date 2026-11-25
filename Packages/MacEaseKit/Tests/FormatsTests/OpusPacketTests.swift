import Foundation
import Testing

@testable import Formats

@Suite struct OpusPacketTests {
    @Test(arguments: [1, 2])
    func emptyPayloadIsRejected(channels: Int) throws {
        let failure = FormatError.corrupt(String(localized: "Audio packet size out of range"))
        let decoder = try OpusAudioDecoder(channels: channels)
        #expect(throws: failure) { _ = try decoder.decode(Data()) }

        let url = ContainerFixtures.temporaryURL("empty-packet.opus")
        let encoder = try OpusAudioEncoder(channels: channels, bitrate: 64_000)
        let writer = try OggPacketWriter(url: url)
        try writer.writeHeader(encoder.identificationHeader)
        try writer.writeHeader(OpusHead.tagsMagic + VorbisComment.encode(AudioTags()))
        try writer.write(Data(), granule: Int64(OpusAudioEncoder.frameSamples), last: true)
        try writer.close()
        let reader = try OggAudioReader(url: url)
        #expect(throws: failure) { _ = try reader.read() }
    }

    @Test(arguments: [1, 2])
    func encodedSilenceAndLossConcealmentRemainValid(channels: Int) throws {
        let encoder = try OpusAudioEncoder(channels: channels, bitrate: 64_000)
        let count = OpusAudioEncoder.frameSamples * channels
        let packet = try #require(try encoder.encode([Float](repeating: 0, count: count)).first)
        try #require(!packet.isEmpty)
        // Concealment packets still carry a TOC byte.
        for encoded in [packet, Data([0xF8])] {
            let decoder = try OpusAudioDecoder(channels: channels)
            let samples = try decoder.decode(encoded)
            #expect(samples.count == count)
            #expect(samples.allSatisfy { $0.isFinite })
        }
    }
}
