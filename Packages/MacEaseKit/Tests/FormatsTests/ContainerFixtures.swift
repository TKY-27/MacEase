import Foundation
import Testing

@testable import Formats

enum ContainerFixtures {
    static func resource(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"))
    }

    static func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(name)")
    }

    static func packets(_ demuxer: inout some MediaDemuxer) throws -> [MediaPacket] {
        var packets: [MediaPacket] = []
        while let packet = try demuxer.nextPacket() { packets.append(packet) }
        return packets
    }
}
