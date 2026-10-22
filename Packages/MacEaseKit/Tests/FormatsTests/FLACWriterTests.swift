import CryptoKit
import Foundation
import Testing

@testable import Formats

@Suite struct FLACWriterTests {
    @Test(arguments: [16, 24], [0, 1, 5000])
    func retainsEncodedBytes(bits: Int, frames: Int) throws {
        // Preserve the previous encoder's exact bytes.
        let expected: [Int: [Int: String]] = [
            16: [
                0: "49266376ce2c6ff1957f6dd82bf3dc5141616326f26d5ca40b3a031c44d6d4c5",
                1: "49d94d55c2360bc4b606bca738008349e96aaddd61056ddc8703d2d9e292db56",
                5000: "dbac31fcd7a891e77e374c0c9ee2d8f3bb6d02bdebd0ddbc8cb9d06d8878a1c7",
            ],
            24: [
                0: "3a546e7c4775ca48e593c2493a401256e982246595be38bb06fdee6cbbff03a3",
                1: "b095c8ba87b96062037a3b41742da9160c86c128091acbaa153e81ed96358980",
                5000: "9165ea4908628355a877f68a89aac90c18cc9eecfa338aa3fbb195f41554ecbf",
            ],
        ]
        let url = ContainerFixtures.temporaryURL("encoded.flac")
        let tags = AudioTags(
            title: "T", artist: "A", album: "B", artwork: Artwork(data: Data([1, 2, 3]), mimeType: "image/png"))
        let writer = try FLACFileWriter(url: url, sampleRate: 44_100, channels: 2, bitsPerSample: bits, tags: tags)
        let samples = (0..<(frames * 2)).map { Float(($0 * 7919) % 65536 - 32768) / 32768 }
        try writer.write(samples)
        try writer.finish()
        let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == expected[bits]?[frames])
        #expect(try FLACMetadata.tags(in: url) == tags)
    }

    @Test func writesFramesDirectlyIntoTheStagedFile() throws {
        let url = ContainerFixtures.temporaryURL("streaming.flac")
        let writer = try FLACFileWriter(url: url, sampleRate: 48_000, channels: 1, bitsPerSample: 16, tags: AudioTags())
        let prefix = try Data(contentsOf: url)
        #expect(prefix.starts(with: FLACBlock.marker))
        try writer.write([Float](repeating: 0.25, count: 20_000))
        #expect(try Data(contentsOf: url).count > prefix.count)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("frames").path))
        try writer.finish()
        #expect(try FLACMetadata.tags(in: url).isEmpty)
    }

    @Test func refusesAnOccupiedDestinationWithoutChangingIt() throws {
        let url = ContainerFixtures.temporaryURL("occupied.flac")
        let original = Data("keep original".utf8)
        try original.write(to: url)
        #expect(throws: FormatError.self) {
            try FLACFileWriter(url: url, sampleRate: 48_000, channels: 1, bitsPerSample: 16, tags: AudioTags())
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func rejectsOversizedMetadataBeforeCreatingOutput() throws {
        let url = ContainerFixtures.temporaryURL("oversized.flac")
        let tags = AudioTags(title: String(repeating: "a", count: FLACBlock.maximumLength))
        #expect(throws: FormatError.unsupported("FLAC artwork over 16 MB")) {
            try FLACFileWriter(url: url, sampleRate: 48_000, channels: 1, bitsPerSample: 16, tags: tags)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
