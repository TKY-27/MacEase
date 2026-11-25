import Foundation
import Testing
@testable import Formats

@Suite struct OggBufferingProbe {
    @Test(arguments: [100, 1_000, 10_000])
    func completedPacketsWithoutGranules(packetCount: Int) throws {
        let url = URL(fileURLWithPath: "/workspace/scratch/92211793ca84/ogg-harness/unknown-\(packetCount).opus")
        try probe(url: url, packetCount: packetCount, hasGranules: false)
    }

    @Test(arguments: [100, 1_000, 10_000])
    func completedPacketsWithGranules(packetCount: Int) throws {
        let url = URL(fileURLWithPath: "/workspace/scratch/92211793ca84/ogg-harness/valid-\(packetCount).opus")
        try probe(url: url, packetCount: packetCount, hasGranules: true)
    }

    private func probe(url: URL, packetCount: Int, hasGranules: Bool) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let encoder = try OpusAudioEncoder(channels: 1, bitrate: 64_000)
        let writer = try OggPacketWriter(url: url)
        try writer.writeHeader(encoder.identificationHeader)
        try writer.writeHeader(OpusHead.tagsMagic + VorbisComment.encode(AudioTags()))
        let packet = Data([0xF8, 0xFF, 0xFE])
        for index in 0..<packetCount {
            try writer.write(packet, granule: hasGranules ? Int64((index + 1) * 960) : -1, last: index == packetCount - 1)
        }
        try writer.close()
        let reader = try OggAudioReader(url: url)
        let first = try #require(try reader.read())
        let bytes = try Data(contentsOf: url).count
        print("granules=\(hasGranules) packets=\(packetCount) input_bytes=\(bytes) first_read_samples=\(first.count) first_read_bytes=\(first.count * 4) reported_frames=\(String(describing: reader.frameCount))")
        if hasGranules {
            #expect(first.count <= 255 * 960)
        } else {
            #expect(first.count == packetCount * 960 - encoder.preSkip)
            #expect(try reader.read() == nil)
        }
    }
}
