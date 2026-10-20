import CoreVideo
import Foundation
import Testing
import VideoToolbox

@testable import Formats

@Suite struct VideoDecodingTests {
    private func decodeAll(_ demuxer: inout some MediaDemuxer, decoder: inout any VideoFrameDecoder) throws
        -> [DecodedFrame]
    {
        let videoTrack = try #require(demuxer.tracks.first { $0.isVideo }).number
        var frames: [DecodedFrame] = []
        while let packet = try demuxer.nextPacket() {
            if packet.track == videoTrack { frames += try decoder.decode(packet) }
        }
        return frames + (try decoder.finish())
    }

    private func check(_ frames: [DecodedFrame], count: Int, frameDuration: Int64) {
        #expect(frames.count == count)
        #expect(frames.map(\.timestamp) == frames.map(\.timestamp).sorted())
        if let first = frames.first?.timestamp, let last = frames.last?.timestamp {
            #expect(abs(last - first - Int64(count - 1) * frameDuration) < Nanoseconds.perMillisecond * 2)
        }
        for frame in frames {
            #expect(CVPixelBufferGetWidth(frame.image) == 96)
            #expect(CVPixelBufferGetHeight(frame.image) == 64)
            #expect(CVPixelBufferGetPixelFormatType(frame.image) == kCVPixelFormatType_32BGRA)
        }
    }

    /// testsrc frame 0 is yellow there.
    private func showsYellowBar(_ frame: DecodedFrame) -> Bool {
        CVPixelBufferLockBaseAddress(frame.image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame.image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(frame.image) else { return false }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(frame.image)
        let pixel = (0..<3).map { Int(pixels[30 * rowBytes + 50 * 4 + $0]) }
        return pixel[0] < 90 && pixel[1] > 180 && pixel[2] > 180
    }

    @Test(arguments: [
        ("ffmpeg-h264-aac.flv", 20, Int64(100)), ("ffmpeg-mjpeg-pcm.avi", 10, 100), ("ffmpeg-mpeg4-ac3.avi", 20, 100),
        ("ffmpeg-mpeg4-ac3-srt.mkv", 60, 33), ("ffmpeg-h264.avi", 10, 100), ("ffmpeg-av1.mkv", 10, 100),
    ])
    func decodesThirdPartyStreams(name: String, count: Int, milliseconds: Int64) throws {
        let url = try ContainerFixtures.resource(name)
        var frames: [DecodedFrame]
        switch url.pathExtension {
        case "flv":
            var demuxer = try FLVDemuxer(url: url)
            var decoder = try VideoDecoders.make(for: demuxer.tracks[0])
            frames = try decodeAll(&demuxer, decoder: &decoder)
        case "avi":
            var demuxer = try AVIDemuxer(url: url)
            var decoder = try VideoDecoders.make(for: demuxer.tracks[0])
            frames = try decodeAll(&demuxer, decoder: &decoder)
        default:
            var demuxer = try MatroskaDemuxer(url: url)
            var decoder = try VideoDecoders.make(for: demuxer.tracks[0])
            frames = try decodeAll(&demuxer, decoder: &decoder)
        }
        let frameDuration = milliseconds == 33 ? Nanoseconds.perSecond * 1001 / 30_000 : milliseconds * 1_000_000
        check(frames, count: count, frameDuration: frameDuration)
        #expect(frames.first.map(showsYellowBar) == true)
    }

    @Test func dav1dDecodesWithoutHardware() throws {
        var demuxer = try MatroskaDemuxer(url: ContainerFixtures.resource("ffmpeg-av1.mkv"))
        var decoder: any VideoFrameDecoder = try Dav1dFrameDecoder()
        let frames = try decodeAll(&demuxer, decoder: &decoder)
        check(frames, count: 10, frameDuration: 100 * Nanoseconds.perMillisecond)
        #expect(frames.first.map(showsYellowBar) == true)
    }
}
