import CoreVideo
import Foundation
import Testing

@testable import Formats

@Suite struct VideoEncodingTests {
    private static let width = 160
    private static let height = 96
    private static let frameCount = 24
    private static let frameDuration = Nanoseconds.perSecond / 24

    /// Moving square; the left half is translucent.
    private func frame(_ index: Int) throws -> CVPixelBuffer {
        let image = try VideoDecoders.makeImage(width: Self.width, height: Self.height)
        CVPixelBufferLockBaseAddress(image, [])
        defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let pixels = try #require(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(image)
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let inSquare = (x - index * 4 + 200) % 160 < 40 && y > 30 && y < 70
                let base = y * rowBytes + x * 4
                let opacity = x < Self.width / 2 ? 128 : 255
                let straight = inSquare ? [30, 200, 240] : [x * 255 / Self.width, y * 255 / Self.height, 90]
                for channel in 0..<3 { pixels[base + channel] = UInt8(straight[channel] * opacity / 255) }
                pixels[base + 3] = UInt8(opacity)
            }
        }
        return image
    }

    private func meanDifference(_ first: CVPixelBuffer, _ second: CVPixelBuffer, channels: Range<Int>) -> Double {
        CVPixelBufferLockBaseAddress(first, .readOnly)
        CVPixelBufferLockBaseAddress(second, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(first, .readOnly)
            CVPixelBufferUnlockBaseAddress(second, .readOnly)
        }
        guard let a = CVPixelBufferGetBaseAddress(first)?.assumingMemoryBound(to: UInt8.self),
            let b = CVPixelBufferGetBaseAddress(second)?.assumingMemoryBound(to: UInt8.self)
        else { return .infinity }
        let rowA = CVPixelBufferGetBytesPerRow(first)
        let rowB = CVPixelBufferGetBytesPerRow(second)
        var total = 0
        for y in 0..<Self.height {
            for x in Self.width / 2..<Self.width {
                for channel in channels {
                    total += abs(Int(a[y * rowA + x * 4 + channel]) - Int(b[y * rowB + x * 4 + channel]))
                }
            }
        }
        return Double(total) / Double(Self.height * Self.width / 2 * channels.count)
    }

    private func roundTrip(
        _ settings: VideoEncoding, mux: (URL, MediaTrack, [MediaPacket]) throws -> Void,
        demux: (URL) throws -> any MediaDemuxer
    ) throws -> (frames: [DecodedFrame], track: MediaTrack) {
        var encoder = try VideoEncoders.make(settings, track: 1)
        var packets: [MediaPacket] = []
        for index in 0..<Self.frameCount {
            packets += try encoder.encode(try frame(index), timestamp: Int64(index) * Self.frameDuration)
        }
        packets += try encoder.finish()
        #expect(packets.count == Self.frameCount)
        #expect(packets.first?.isKeyframe == true)
        let url = ContainerFixtures.temporaryURL("encoded")
        defer { try? FileManager.default.removeItem(at: url) }
        try mux(url, encoder.track, packets)
        var demuxer = try demux(url)
        let track = try #require(demuxer.tracks.first)
        var decoder = try VideoDecoders.make(for: track)
        var frames: [DecodedFrame] = []
        while let packet = try demuxer.nextPacket() { frames += try decoder.decode(packet) }
        frames += try decoder.finish()
        return (frames, track)
    }

    private func expectFaithful(_ frames: [DecodedFrame], tolerance: Double) throws {
        #expect(frames.count == Self.frameCount)
        for (index, decoded) in frames.enumerated() {
            #expect(abs(decoded.timestamp - Int64(index) * Self.frameDuration) <= Nanoseconds.perMillisecond)
            #expect(meanDifference(decoded.image, try frame(index), channels: 0..<3) < tolerance, "frame \(index)")
        }
    }

    @Test(arguments: [VideoEncoding.Codec.h264, .hevc])
    func toolboxStreamsSurviveMatroska(codec: VideoEncoding.Codec) throws {
        let settings = VideoEncoding(
            codec: codec, width: Self.width, height: Self.height, frameDuration: Self.frameDuration, bitrate: 2_000_000)
        let (frames, track) = try roundTrip(settings) { url, track, packets in
            #expect(track.codecPrivate != nil)
            var muxer = try MatroskaMuxer(url: url, tracks: [track], webm: false)
            for packet in packets.sorted(by: { ($0.decodeTimestamp ?? 0) < ($1.decodeTimestamp ?? 0) }) {
                try muxer.write(packet)
            }
            try muxer.finish()
        } demux: {
            try MatroskaDemuxer(url: $0)
        }
        #expect(track.kind == .video(width: Self.width, height: Self.height))
        try expectFaithful(frames, tolerance: 8)
    }

    @Test func h264SurvivesFLV() throws {
        let settings = VideoEncoding(
            codec: .h264, width: Self.width, height: Self.height, frameDuration: Self.frameDuration, bitrate: 2_000_000)
        let (frames, _) = try roundTrip(settings) { url, track, packets in
            var muxer = try FLVMuxer(url: url, tracks: [track])
            for packet in packets { try muxer.write(packet) }
            try muxer.finish()
        } demux: {
            try FLVDemuxer(url: $0)
        }
        try expectFaithful(frames, tolerance: 8)
    }

    @Test func motionJPEGSurvivesAVI() throws {
        var settings = VideoEncoding(
            codec: .mjpeg, width: Self.width, height: Self.height, frameDuration: Self.frameDuration, bitrate: nil)
        settings.quality = 0.9
        let (frames, _) = try roundTrip(settings) { url, track, packets in
            var muxer = try AVIMuxer(url: url, tracks: [track])
            for packet in packets { try muxer.write(packet) }
            try muxer.finish()
        } demux: {
            try AVIDemuxer(url: $0)
        }
        try expectFaithful(frames, tolerance: 6)
    }

    @Test func vp9KeepsAlphaInWebM() throws {
        var settings = VideoEncoding(
            codec: .vp9, width: Self.width, height: Self.height, frameDuration: Self.frameDuration, bitrate: nil)
        settings.alpha = true
        settings.quality = 0.8
        let (frames, track) = try roundTrip(settings) { url, track, packets in
            var muxer = try MatroskaMuxer(url: url, tracks: [track], webm: true)
            for packet in packets { try muxer.write(packet) }
            try muxer.finish()
        } demux: {
            try MatroskaDemuxer(url: $0)
        }
        #expect(track.hasAlpha)
        try expectFaithful(frames, tolerance: 8)
        let opacity = try frames.map { decoded -> (Int, Int) in
            CVPixelBufferLockBaseAddress(decoded.image, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(decoded.image, .readOnly) }
            let pixels = try #require(CVPixelBufferGetBaseAddress(decoded.image)).assumingMemoryBound(to: UInt8.self)
            let row = 10 * CVPixelBufferGetBytesPerRow(decoded.image)
            return (Int(pixels[row + 10 * 4 + 3]), Int(pixels[row + 150 * 4 + 3]))
        }
        #expect(opacity.allSatisfy { abs($0.0 - 128) < 12 && $0.1 > 240 })
    }
}
