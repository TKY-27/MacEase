import AVFoundation
import CoreVideo
import Formats
import Foundation
import Testing

@testable import Engine

@Suite struct TranscoderTests {
    private static let frameDuration = Nanoseconds.perSecond / 24
    private static let formatsResources = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../FormatsTests/Resources")

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

    @Test func cancelledAssetWriterReportsHealth() async throws {
        let source = try resource("ffmpeg-h264-aac.mp4")
        let asset = AVURLAsset(url: source)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let described = try await AssetTracks.describe(track, number: 1)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let url = temporaryURL("failed.mov")
        defer {
            if FileManager.default.fileExists(atPath: url.path) {
                #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) }
            }
        }
        let sink = try AssetWriterSink(
            url: url, fileType: .mov, tracks: [OutputTrack(track: described, format: format)], transform: .identity)
        try sink.checkHealth()
        sink.cancel()
        do {
            try sink.checkHealth()
            Issue.record("cancelled writer must report encode failure")
        } catch EngineError.encodeFailed {
        }
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

    @Test(arguments: [
        (
            "ffmpeg-mjpeg-pcm.avi", OutputContainer.avi, Int64(500_000_000), Int64(1_000_000_000), Int64(500_000_000),
            5, 5
        ),
        ("ffmpeg-mpeg4-ac3-srt.mkv", .mkv, 500_000_000, 1_000_000_000, 334_000_000, 10, 20),
        ("ffmpeg-h264-aac.flv", .flv, 500_000_000, 1_000_000_000, 23_000_000, 0, 10),
        ("ffmpeg-h264-aac.flv", .flv, 750_000_000, 1_500_000_000, 523_000_000, 5, 10),
    ])
    func keyframeTrimSkipsEarlierContainerPackets(
        name: String, container: OutputContainer, start: Int64, end: Int64, keyframe: Int64,
        firstFrame: Int, frameCount: Int
    ) async throws {
        let source = Self.formatsResources.appending(path: name)
        let input = try await MediaInput.open(source)
        #expect(try await Transcoder.keyframe(atOrBefore: start, in: input) == keyframe)
        var plan = TranscodePlan(container: container, video: .copy, audio: .copy)
        plan.range = start..<end
        let url = temporaryURL("trim.\(container.fileExtension)")
        defer {
            if FileManager.default.fileExists(atPath: url.path) {
                #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) }
            }
        }
        try await Transcoder.run(input, plan: plan, to: url) { _ in }
        let copied = try packets(of: url)
        let video = copied.filter { $0.track == 1 }
        let firstVideo = try #require(video.first)
        let firstAudio = try #require(copied.first { $0.track == 2 })
        #expect(firstVideo.isKeyframe)
        #expect(firstVideo.timestamp == 0)
        #expect(video.count == frameCount)
        #expect(video.allSatisfy { $0.timestamp >= 0 })
        #expect(abs(firstAudio.timestamp - firstVideo.timestamp) < input.frameDuration)
        let originalVideo = try packets(of: source).filter { $0.track == input.video?.number }
        #expect(video.map(\.payload) == originalVideo.dropFirst(firstFrame).prefix(frameCount).map(\.payload))
        let output = try await MediaInput.open(url)
        #expect(abs(output.duration - (end - keyframe)) <= input.frameDuration)
    }

    @Test(arguments: [1, 2])
    func keyframeCopyPreservesFileOrderAfterStart(leadingTrack: Int) async throws {
        let url = temporaryURL("reordered.mkv")
        defer {
            if FileManager.default.fileExists(atPath: url.path) {
                #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) }
            }
        }
        var video = MediaTrack(number: 1, kind: .video(width: 16, height: 16), codec: .h264)
        video.defaultDuration = 100 * Nanoseconds.perMillisecond
        let audio = MediaTrack(
            number: 2, kind: .audio(sampleRate: 8_000, channels: 1),
            codec: .pcm(bits: 16, float: false, bigEndian: false))
        var muxer = try MatroskaMuxer(url: url, tracks: [video, audio], webm: false)
        let timeline: [(track: Int, milliseconds: Int64, keyframe: Bool)] = [
            (1, 0, true), (leadingTrack, 900, false), (1, 600, true),
            (1, 400, true), (1, 800, false), (1, 500, false),
        ]
        for (index, entry) in timeline.enumerated() {
            try muxer.write(
                MediaPacket(
                    track: entry.track, timestamp: entry.milliseconds * Nanoseconds.perMillisecond,
                    isKeyframe: entry.keyframe, payload: Data([UInt8(index)])))
        }
        try muxer.finish()
        let input = try await MediaInput.open(url)
        let selected = try await Transcoder.keyframe(atOrBefore: 650 * Nanoseconds.perMillisecond, in: input)
        #expect(selected == 600 * Nanoseconds.perMillisecond)
        let track = try #require(input.video)
        let stage = try await PacketCopyStage(input: input, track: track, number: 1, start: selected, end: .max)
        var copied: [MediaPacket] = []
        while stage.nextTime != nil { copied += try await stage.pull() }
        #expect(copied.map(\.timestamp) == [600, 400, 800, 500].map { $0 * Nanoseconds.perMillisecond })
        #expect(copied.map(\.payload) == [2, 3, 4, 5].map { Data([UInt8($0)]) })
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

    @Test func reorderedH264RemuxesFromMatroskaWithSynthesizedDecodeTimes() async throws {
        let mkv = try await transcode(
            try resource("ffmpeg-h264-aac.mp4"),
            TranscodePlan(container: .mkv, video: .encode(encoding(.h264), FrameEdit()), audio: .copy))
        defer { try? FileManager.default.removeItem(at: mkv) }
        let stored = try packets(of: mkv).filter { $0.track == 1 }.map(\.timestamp)
        #expect(stored != stored.sorted(), "fixture needs B-frames")

        let flv = try await transcode(mkv, TranscodePlan(container: .flv, video: .copy, audio: .copy))
        defer { try? FileManager.default.removeItem(at: flv) }
        let video = try packets(of: flv).filter { $0.track == 1 }
        let decodeTimes = video.compactMap(\.decodeTimestamp)
        #expect(decodeTimes.count == 48)
        #expect(decodeTimes == decodeTimes.sorted())
        #expect(zip(decodeTimes, video).allSatisfy { $0 <= $1.timestamp })

        let mp4 = try await transcode(mkv, TranscodePlan(container: .mp4, video: .copy, audio: .copy))
        defer { try? FileManager.default.removeItem(at: mp4) }
        let asset = AVURLAsset(url: mp4)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AssetTrackReader(asset: asset, track: track, number: 1, mode: .frames)
        var times: [Int64] = []
        while let frame = try await reader.nextFrame() { times.append(frame.timestamp) }
        #expect(times.count == 48)
        #expect(times == times.sorted())
    }

    @Test func keyframeTrimKeepsAudioInSync() async throws {
        var plan = TranscodePlan(container: .mkv, video: .copy, audio: .copy)
        plan.range = 700_000_000..<1_500_000_000
        let url = try await transcode(try resource("ffmpeg-h264-aac.mp4"), plan)
        defer { try? FileManager.default.removeItem(at: url) }
        let all = try packets(of: url)
        let firstVideo = try #require(all.first { $0.track == 1 }).timestamp
        let firstAudio = try #require(all.first { $0.track == 2 }).timestamp
        #expect(firstVideo == 0)
        #expect(firstAudio >= 0 && firstAudio < 25 * Nanoseconds.perMillisecond)
    }

    @Test func vp9ExactTrimStartsAtZero() async throws {
        var plan = TranscodePlan(container: .webm, video: .encode(encoding(.vp9), FrameEdit()), audio: nil)
        plan.range = 500_000_000..<1_000_000_000
        let url = try await transcode(try resource("ffmpeg-h264-aac.mp4"), plan)
        defer { try? FileManager.default.removeItem(at: url) }
        let times = try packets(of: url).map(\.timestamp)
        #expect(times.first == 0)
        #expect(times.count == 12)
        #expect(times.allSatisfy { $0 >= 0 })
    }

    @Test func frameRateUpsamplingKeepsTheFullDuration() async throws {
        var settings = encoding(.h264)
        settings.frameDuration = Nanoseconds.perSecond / 60
        let url = try await transcode(
            try resource("ffmpeg-h264-aac.mp4"),
            TranscodePlan(container: .mkv, video: .encode(settings, FrameEdit()), audio: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try packets(of: url).count == 120)
    }
}
