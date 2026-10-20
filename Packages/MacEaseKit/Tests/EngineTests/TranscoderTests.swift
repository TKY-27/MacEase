import AVFoundation
import Formats
import Foundation
import Testing

@testable import Engine

@Suite struct TranscoderTests {
    private static let frameDuration = Nanoseconds.perSecond / 24

    private func resource(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"))
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(name)")
    }

    private func transcode(_ source: URL, _ plan: TranscodePlan) async throws -> URL {
        let url = temporaryURL("out.\(plan.container.fileExtension)")
        let input = try await MediaInput.open(source)
        try await Transcoder.run(input, plan: plan, to: url) { _ in }
        return url
    }

    private func packets(of url: URL) throws -> [MediaPacket] {
        var demuxer: any MediaDemuxer =
            switch url.pathExtension {
            case "avi": try AVIDemuxer(url: url)
            case "flv": try FLVDemuxer(url: url)
            default: try MatroskaDemuxer(url: url)
            }
        var packets: [MediaPacket] = []
        while let packet = try demuxer.nextPacket() { packets.append(packet) }
        return packets
    }

    private func encoding(_ codec: VideoEncoding.Codec, width: Int = 160, height: Int = 96) -> VideoEncoding {
        VideoEncoding(codec: codec, width: width, height: height, frameDuration: Self.frameDuration, bitrate: 500_000)
    }

    @Test func remuxesMP4IntoMatroskaAndBack() async throws {
        let mkv = try await transcode(
            try resource("ffmpeg-h264-aac.mp4"), TranscodePlan(container: .mkv, video: .copy, audio: .copy))
        defer { try? FileManager.default.removeItem(at: mkv) }
        let demuxer = try MatroskaDemuxer(url: mkv)
        #expect(demuxer.tracks.map(\.codec) == [.h264, .aac])
        let copied = try packets(of: mkv)
        #expect(copied.filter { $0.track == 1 }.count == 48)
        #expect(copied.filter { $0.track == 2 }.count >= 90)

        let mp4 = try await transcode(mkv, TranscodePlan(container: .mp4, video: .copy, audio: .copy))
        defer { try? FileManager.default.removeItem(at: mp4) }
        let asset = AVURLAsset(url: mp4)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2) < 0.1)
        for track in try await asset.load(.tracks) { #expect(try await track.load(.isPlayable)) }
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func reencodesWithResizeAndKeepsAudio() async throws {
        let plan = TranscodePlan(
            container: .mp4,
            video: .encode(encoding(.h264, width: 80, height: 48), FrameEdit(size: PixelSize(width: 80, height: 48))),
            audio: .copy)
        let url = try await transcode(try resource("ffmpeg-h264-aac.mp4"), plan)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 80, height: 48))
        #expect(try await video.load(.nominalFrameRate) == 24)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func bakesSourceRotationWhenReencoding() async throws {
        let source = try resource("ffmpeg-rotated.mov")
        let input = try await MediaInput.open(source)
        #expect(input.transform != .identity)
        let plan = TranscodePlan(
            container: .mkv,
            video: .encode(encoding(.h264, width: 96, height: 160), FrameEdit(rotation: input.displayRotation)),
            audio: nil)
        let url = try await transcode(source, plan)
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = try MatroskaDemuxer(url: url)
        #expect(demuxer.tracks.first?.kind == .video(width: 96, height: 160))
    }

    @Test func keyframeTrimStartsOnAKeyframe() async throws {
        var plan = TranscodePlan(container: .mkv, video: .copy, audio: .copy)
        plan.range = 700_000_000..<1_500_000_000
        let url = try await transcode(try resource("ffmpeg-h264-aac.mp4"), plan)
        defer { try? FileManager.default.removeItem(at: url) }
        let video = try packets(of: url).filter { $0.track == 1 }
        #expect(video.first?.isKeyframe == true)
        #expect(video.first?.timestamp == 0)
        #expect(video.count == 24)
    }

    @Test func exactTrimAndFrameRateChange() async throws {
        var settings = encoding(.h264)
        settings.frameDuration = Nanoseconds.perSecond / 12
        var plan = TranscodePlan(container: .mkv, video: .encode(settings, FrameEdit()), audio: nil)
        plan.range = 750_000_000..<1_250_000_000
        let url = try await transcode(try resource("ffmpeg-h264-aac.mp4"), plan)
        defer { try? FileManager.default.removeItem(at: url) }
        let video = try packets(of: url).filter { $0.track == 1 }
        #expect(video.count == 6)
        #expect(video.map(\.timestamp).sorted().first == 0)
    }

    @Test(arguments: [(OutputContainer.avi, VideoEncoding.Codec.mjpeg), (.webm, .vp9), (.flv, .h264)])
    func encodesForInHouseContainers(container: OutputContainer, codec: VideoEncoding.Codec) async throws {
        let plan = TranscodePlan(container: container, video: .encode(encoding(codec), FrameEdit()), audio: nil)
        let url = try await transcode(try resource("ffmpeg-h264-aac.mp4"), plan)
        defer { try? FileManager.default.removeItem(at: url) }
        let video = try packets(of: url)
        #expect(video.count == 48)
        #expect(video.first?.isKeyframe == true)
    }
}
