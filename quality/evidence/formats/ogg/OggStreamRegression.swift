import Foundation
import Testing
@testable import Formats
@Suite struct OggStreamRegression {
    @Test(arguments: [MediaCodec.vorbis, .opus])
    func rejectsChain(codec: MediaCodec) throws {
        let single = ContainerFixtures.temporaryURL("single.ogg")
        let writer = try OggAudioWriter(url: single, codec: codec, sampleRate: 48_000, channels: 1, bitrate: 96_000, tags: AudioTags())
        try writer.write([Float](repeating: 0, count: 4_800))
        try writer.finish()
        let bytes = try Data(contentsOf: single)
        let chained = ContainerFixtures.temporaryURL("chain.ogg")
        try (bytes + bytes).write(to: chained)
        #expect(throws: OggReadError.chainedStream) { try OggAudioReader(url: chained) }
    }
}
