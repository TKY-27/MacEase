import Foundation
import Testing

@testable import Formats

enum ContainerFixtures {
    static func resource(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"))
    }

    nonisolated(unsafe) private static var scratchPath = ""

    /// Removed at exit; tests keep outputs.
    private static let scratch: URL = {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MacEaseFormatsTests-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            fatalError("Scratch folder setup failed: \(error)")
        }
        scratchPath = folder.path
        atexit { try? FileManager.default.removeItem(atPath: ContainerFixtures.scratchPath) }
        return folder
    }()

    static func temporaryURL(_ name: String) -> URL {
        scratch.appending(path: "\(UUID().uuidString)-\(name)")
    }

    static func packets(_ demuxer: inout some MediaDemuxer) throws -> [MediaPacket] {
        var packets: [MediaPacket] = []
        while let packet = try demuxer.nextPacket() { packets.append(packet) }
        return packets
    }
}
