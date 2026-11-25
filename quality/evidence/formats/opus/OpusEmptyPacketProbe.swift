import Foundation
import Testing
@testable import Formats
@Suite struct OpusEmptyPacketProbe {
    @Test func emptyPacketSynthesizesPCM() throws {
        let decoder = try OpusAudioDecoder(channels: 1)
        let plc = try decoder.decode(Data([0xF8]))
        print("nonempty Opus PLC packet decoded frames=\(plc.count)")
        #expect(plc.count == 960)
        let samples = try decoder.decode(Data())
        print("empty Opus packet decoded frames=\(samples.count)")
        #expect(samples.count == 5_760)
        let url = ContainerFixtures.temporaryURL("empty-packet.opus")
        let encoder = try OpusAudioEncoder(channels: 1, bitrate: 64_000)
        let writer = try OggPacketWriter(url: url)
        try writer.writeHeader(encoder.identificationHeader)
        try writer.writeHeader(OpusHead.tagsMagic + VorbisComment.encode(AudioTags()))
        try writer.write(Data(), granule: 5_760, last: true)
        try writer.close()
        let reader = try OggAudioReader(url: url)
        let output = try #require(try reader.read())
        print("empty Ogg Opus packet returned frames=\(output.count), frameCount=\(String(describing: reader.frameCount))")
        #expect(output.count == 5_760 - encoder.preSkip)
    }
}
