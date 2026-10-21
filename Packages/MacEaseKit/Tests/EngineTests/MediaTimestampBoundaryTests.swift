import CoreGraphics
import Formats
import Foundation
import Testing

@testable import Engine

@Suite struct MediaTimestampBoundaryTests {
    private let timestampScale: UInt64 = 270_000_000_000_000

    @Test func rejectsFrameSpacingBeyondInt64() async throws {
        let url = try writeContainer(
            "frame-spacing.mkv",
            clusters: [
                cluster(at: 0, block: [0x81, 0x80, 0x00, 0x80, 1]),
                cluster(at: 32_768, block: [0x81, 0, 0, 0x80, 2]),
            ])
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        var demuxer = try MatroskaDemuxer(url: url)
        #expect(try demuxer.nextPacket()?.timestamp == -8_847_360_000_000_000_000)
        #expect(try demuxer.nextPacket()?.timestamp == 8_847_360_000_000_000_000)
        await #expect(throws: EngineError.decodeFailed("video frame spacing out of range")) {
            try await MediaInput.open(url)
        }
    }

    @Test func rejectsPacketEndBeyondInt64() async throws {
        let block = element([0xA1], [0x81, 0, 0, 0, 1])
        let duration = element([0x9B], unsigned: 32_768)
        let group = element([0xA0], block + duration)
        let url = try writeContainer(
            "packet-end.mkv", clusters: [element([0x1F, 0x43, 0xB6, 0x75], element([0xE7], unsigned: 32_768) + group)])
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        var demuxer = try MatroskaDemuxer(url: url)
        let nextPacket = try demuxer.nextPacket()
        let packet = try #require(nextPacket)
        #expect(packet.timestamp == 8_847_360_000_000_000_000)
        #expect(packet.duration == 8_847_360_000_000_000_000)
        await #expect(throws: EngineError.decodeFailed("media duration out of range")) {
            try await MediaInput.open(url)
        }
    }

    @Test func rejectsReorderedVideoWithUnrepresentableDecodeSpan() async throws {
        let url = try writeContainer(
            "reordered-video.mkv",
            clusters: [
                cluster(at: 32_768, block: [0x81, 0, 0, 0x80, 1]),
                cluster(at: 0, block: [0x81, 0x80, 0x00, 0x80, 2]),
            ], codecID: "V_MPEG4/ISO/AVC")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        let sourceBytes = try Data(contentsOf: url)
        let demuxer = try MatroskaDemuxer(url: url)
        let input = MediaInput(
            url: url, backend: .matroska, video: demuxer.tracks.first, audio: nil,
            hasMultipleTracks: false, skippedStreams: [], duration: 0, transform: .identity)
        let output = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-reordered-output.mkv")
        await #expect(throws: EngineError.decodeFailed("media timestamp out of range")) {
            try await Transcoder.run(
                input, plan: TranscodePlan(container: .mkv, video: .copy, audio: nil), to: output
            ) { _ in }
        }
        #expect(try Data(contentsOf: url) == sourceBytes)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    private func writeContainer(_ name: String, clusters: [[UInt8]], codecID: String = "V_VP8") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(name)")
        let header = element([0x1A, 0x45, 0xDF, 0xA3], element([0x42, 0x82], Array("matroska".utf8)))
        let metadata = element([0x15, 0x49, 0xA9, 0x66], element([0x2A, 0xD7, 0xB1], unsigned: timestampScale))
        let video = element(
            [0xE0], element([0xB0], unsigned: 16) + element([0xBA], unsigned: 16))
        let track = element(
            [0xAE],
            element([0xD7], unsigned: 1) + element([0x83], unsigned: 1)
                + element([0x86], Array(codecID.utf8)) + video)
        let tracks = element([0x16, 0x54, 0xAE, 0x6B], track)
        let segment = element([0x18, 0x53, 0x80, 0x67], metadata + tracks + clusters.flatMap { $0 })
        try Data(header + segment).write(to: url)
        return url
    }

    private func cluster(at timestamp: UInt64, block: [UInt8]) -> [UInt8] {
        element([0x1F, 0x43, 0xB6, 0x75], element([0xE7], unsigned: timestamp) + element([0xA3], block))
    }

    private func element(_ identifier: [UInt8], unsigned value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(truncatingIfNeeded: remaining), at: 0)
            remaining >>= 8
        } while remaining > 0
        return element(identifier, bytes)
    }

    private func element(_ identifier: [UInt8], _ payload: [UInt8]) -> [UInt8] {
        identifier + [0x80 | UInt8(payload.count)] + payload
    }
}
