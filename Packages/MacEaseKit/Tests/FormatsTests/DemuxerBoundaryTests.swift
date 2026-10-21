import Foundation
import Testing

@testable import Formats

@Suite struct DemuxerBoundaryTests {
    @Test func aviRejectsListTypeOutsideChunk() throws {
        let bytes =
            Data("RIFF".utf8) + [16, 0, 0, 0] + Data("AVI LIST".utf8)
            + [1, 0, 0, 0] + Data("movi".utf8)
        #expect(bytes.count == 24)
        let url = ContainerFixtures.temporaryURL("short-list.avi")
        try bytes.write(to: url)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        #expect(throws: FormatError.self) { try AVIDemuxer(url: url) }
    }

    @Test(arguments: ["-1dc", "+1dc", "١١dc", "00dc", "99wb"])
    func aviStreamNumbersRequireTwoASCIIDigits(identifier: String) {
        let expected = identifier == "00dc" ? 0 : identifier == "99wb" ? 99 : nil
        #expect(AVIDemuxer.streamNumber(identifier) == expected)
    }

    @Test func aviIgnoresNegativeLegacyStreamNumber() throws {
        var bytes = try Data(contentsOf: ContainerFixtures.resource("ffmpeg-mjpeg-pcm.avi"))
        let index = try #require(bytes.range(of: Data("idx1".utf8)))
        let entry = index.upperBound + MemoryLayout<UInt32>.size
        bytes.replaceSubrange(entry..<(entry + 4), with: "-1dc".utf8)
        let url = ContainerFixtures.temporaryURL("negative-stream.avi")
        try bytes.write(to: url)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        var demuxer = try AVIDemuxer(url: url)
        #expect(!(try ContainerFixtures.packets(&demuxer)).isEmpty)
    }

    @Test func aviRejectsMissingLegacyStream() throws {
        var bytes = try Data(contentsOf: ContainerFixtures.resource("ffmpeg-mjpeg-pcm.avi"))
        let index = try #require(bytes.range(of: Data("idx1".utf8)))
        let entry = index.upperBound + MemoryLayout<UInt32>.size
        bytes.replaceSubrange(entry..<(entry + 4), with: "99dc".utf8)
        let url = ContainerFixtures.temporaryURL("missing-stream.avi")
        try bytes.write(to: url)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        #expect(throws: FormatError.corrupt("idx1 names a missing stream")) { try AVIDemuxer(url: url) }
    }

    @Test(arguments: 1...4)
    func flvRejectsIncompletePreviousTagSize(missingBytes: Int) throws {
        let original = try Data(contentsOf: ContainerFixtures.resource("ffmpeg-h264-aac.flv"))
        let url = ContainerFixtures.temporaryURL("missing-size.flv")
        try original.dropLast(missingBytes).write(to: url)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        #expect(throws: FormatError.self) {
            var demuxer = try FLVDemuxer(url: url)
            _ = try ContainerFixtures.packets(&demuxer)
        }
    }

    @Test func matroskaRejectsOverflowingLacedTimestamp() throws {
        let track = EBML.element(
            MatroskaID.trackEntry,
            EBML.element(MatroskaID.trackNumber, unsigned: 1)
                + EBML.element(MatroskaID.trackType, unsigned: 2)
                + EBML.element(MatroskaID.codecID, string: "A_MPEG/L3")
                + EBML.element(MatroskaID.defaultDuration, unsigned: UInt64(Nanoseconds.perMillisecond)))
        let clusterTimestamp = UInt64(Int64.max / Nanoseconds.perMillisecond)
        let cluster = EBML.element(
            MatroskaID.cluster,
            EBML.element(MatroskaID.clusterTimestamp, unsigned: clusterTimestamp)
                + EBML.element(MatroskaID.simpleBlock, [0x81, 0, 0, 0x84, 1, 0xFF, 0xFF]))
        let bytes = Data(
            EBML.element(MatroskaID.ebml, EBML.element(MatroskaID.docType, string: "webm"))
                + EBML.element(MatroskaID.segment, EBML.element(MatroskaID.tracks, track) + cluster))
        let url = ContainerFixtures.temporaryURL("laced-overflow.webm")
        try bytes.write(to: url)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        var demuxer = try MatroskaDemuxer(url: url)
        #expect(throws: FormatError.self) { try demuxer.nextPacket() }
    }
}
