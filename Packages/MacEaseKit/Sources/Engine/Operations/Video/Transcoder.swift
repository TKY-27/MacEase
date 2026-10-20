import AVFoundation
import CoreMedia
import Formats
import Foundation

struct TranscodePlan {
    enum Video {
        case copy
        case encode(VideoEncoding, FrameEdit)
    }

    enum Audio {
        case copy
    }

    var container: OutputContainer
    var video: Video?
    var audio: Audio?
    /// Source nanoseconds.
    var range: Range<Int64>?
    /// Copies start at the preceding keyframe.
    var startsAtKeyframe = true
    /// Display matrix for copied MP4 and MOV.
    var transform: CGAffineTransform?
}

/// Pulls one output stream in time order.
protocol StreamStage: AnyObject {
    var output: OutputTrack? { get }
    /// Next packet's source time; `nil` when drained.
    var nextTime: Int64? { get }
    func pull() async throws -> [MediaPacket]
}

enum Transcoder {
    static func run(
        _ input: MediaInput, plan: TranscodePlan, to url: URL, progress: (Double) -> Void
    ) async throws {
        let start = try await startTime(input, plan: plan)
        let end = plan.range?.upperBound ?? input.duration
        var stages: [any StreamStage] = []
        if let video = plan.video, let track = input.video {
            stages.append(try await videoStage(video, track: track, input: input, start: start, end: end))
        }
        if plan.audio != nil, let track = input.audio {
            stages.append(
                try await PacketCopyStage(input: input, track: track, number: stages.count + 1, start: start, end: end))
        }
        guard !stages.isEmpty else { throw EngineError.invalidInput(.emptyInput) }
        var primed: [[MediaPacket]] = []
        for stage in stages { primed.append(try await prime(stage)) }
        let tracks = try stages.map { stage in
            guard let output = stage.output else { throw EngineError.encodeFailed("stream produced nothing") }
            return output
        }
        let origin = min(start, primed.flatMap { $0 }.compactMap(\.decodeTimestamp).min() ?? start)
        let transform: CGAffineTransform =
            if case .copy = plan.video { plan.transform ?? input.transform } else { .identity }
        var sink = try Sinks.make(plan.container, url: url, tracks: tracks, transform: transform)
        var queues = primed
        while let index = earliest(stages, queues) {
            try Task.checkCancellation()
            if queues[index].isEmpty { queues[index] = try await stages[index].pull() }
            for packet in queues[index] {
                try await sink.write(rebased(packet, origin: origin))
                progress(Double(packet.timestamp - start) / Double(max(end - start, 1)))
            }
            queues[index] = []
        }
        try await sink.finish()
    }

    private static func earliest(_ stages: [any StreamStage], _ queues: [[MediaPacket]]) -> Int? {
        var best: (index: Int, time: Int64)?
        for index in stages.indices {
            guard let time = queues[index].first?.timestamp ?? stages[index].nextTime else { continue }
            if let current = best, current.time <= time { continue }
            best = (index, time)
        }
        return best?.index
    }

    private static func prime(_ stage: any StreamStage) async throws -> [MediaPacket] {
        var packets: [MediaPacket] = []
        while packets.isEmpty, stage.nextTime != nil { packets = try await stage.pull() }
        return packets
    }

    private static func rebased(_ packet: MediaPacket, origin: Int64) -> MediaPacket {
        var shifted = packet
        shifted.timestamp -= origin
        shifted.decodeTimestamp = packet.decodeTimestamp.map { $0 - origin }
        return shifted
    }

    private static func videoStage(
        _ video: TranscodePlan.Video, track: MediaTrack, input: MediaInput, start: Int64, end: Int64
    ) async throws -> any StreamStage {
        switch video {
        case .copy:
            try await PacketCopyStage(input: input, track: track, number: 1, start: start, end: end)
        case .encode(let encoding, let edit):
            try await FrameEncodeStage(input: input, encoding: encoding, edit: edit, start: start, end: end)
        }
    }

    /// Copied video must begin on a keyframe.
    private static func startTime(_ input: MediaInput, plan: TranscodePlan) async throws -> Int64 {
        guard let requested = plan.range?.lowerBound, requested > 0 else { return 0 }
        guard plan.startsAtKeyframe, case .copy = plan.video else { return requested }
        return try await keyframe(atOrBefore: requested, in: input)
    }

    static func keyframe(atOrBefore time: Int64, in input: MediaInput) async throws -> Int64 {
        guard let video = input.video else { return time }
        if case .asset(_, let track?, _) = input.backend {
            return try AssetKeyframes.time(atOrBefore: time, in: track)
        }
        guard var demuxer = try input.demuxer else { return time }
        var keyframe: Int64 = 0
        while let packet = try demuxer.nextPacket(), packet.timestamp <= time {
            try Task.checkCancellation()
            if packet.track == video.number, packet.isKeyframe { keyframe = packet.timestamp }
        }
        return keyframe
    }
}

enum AssetKeyframes {
    static func time(atOrBefore time: Int64, in track: AVAssetTrack) throws -> Int64 {
        let target = CMTime(value: time, timescale: SampleBuffers.nanosecondScale)
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: target) else {
            throw EngineError.decodeFailed("track has no sample index")
        }
        while !cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue {
            guard cursor.stepInDecodeOrder(byCount: -1) == -1 else { return 0 }
        }
        return SampleBuffers.nanoseconds(cursor.presentationTimeStamp)
    }
}

/// Compressed packets of one track, unchanged.
final class PacketCopyStage: StreamStage {
    private enum Source {
        case asset(AssetTrackReader)
        case container(any MediaDemuxer, sourceTrack: Int)
    }

    private var source: Source
    private let number: Int
    private let start: Int64
    private let end: Int64
    private var upcoming: Int64?
    private(set) var output: OutputTrack?

    init(input: MediaInput, track: MediaTrack, number: Int, start: Int64, end: Int64) async throws {
        self.number = number
        self.start = start
        self.end = end
        upcoming = start
        var described = track
        described.number = number
        switch input.backend {
        case .asset(let asset, let video, let audio):
            guard let assetTrack = track.isVideo ? video : audio else {
                throw EngineError.decodeFailed("missing track")
            }
            let range = CMTimeRange(
                start: CMTime(value: start, timescale: SampleBuffers.nanosecondScale),
                end: CMTime(value: end, timescale: SampleBuffers.nanosecondScale))
            source = .asset(
                try AssetTrackReader(asset: asset, track: assetTrack, number: number, mode: .packets, range: range))
            let format = try await assetTrack.load(.formatDescriptions).first
            output = OutputTrack(track: described, format: format)
        default:
            guard let demuxer = try input.demuxer else { throw EngineError.decodeFailed("no demuxer") }
            source = .container(demuxer, sourceTrack: track.number)
            output = OutputTrack(track: described, format: nil)
        }
    }

    var nextTime: Int64? { upcoming }

    func pull() async throws -> [MediaPacket] {
        switch source {
        case .asset(let reader):
            guard let packets = try reader.nextPackets() else {
                upcoming = nil
                return []
            }
            upcoming = packets.last?.timestamp ?? upcoming
            return packets.filter { $0.timestamp < end && ($0.timestamp >= start || output?.track.isVideo == true) }
        case .container(var demuxer, let sourceTrack):
            defer { source = .container(demuxer, sourceTrack: sourceTrack) }
            while let packet = try demuxer.nextPacket() {
                guard packet.track == sourceTrack else { continue }
                guard packet.timestamp < end else { break }
                guard packet.timestamp >= start else { continue }
                upcoming = packet.timestamp
                var renumbered = packet
                renumbered.track = number
                return [renumbered]
            }
            upcoming = nil
            return []
        }
    }
}

/// Re-encoded at a constant frame rate.
final class FrameEncodeStage: StreamStage {
    private let sampler: FrameSampler
    private var encoder: any VideoFrameEncoder
    private var upcoming: Int64?

    init(input: MediaInput, encoding: VideoEncoding, edit: FrameEdit, start: Int64, end: Int64) async throws {
        sampler = try await FrameSampler(
            input: input, frameDuration: encoding.frameDuration, edit: edit, start: start, end: end)
        encoder = try VideoEncoders.make(encoding, track: 1)
        upcoming = start
    }

    var output: OutputTrack? {
        let track = encoder.track
        if [.h264, .hevc].contains(track.codec), track.codecPrivate == nil { return nil }
        return OutputTrack(track: track, format: nil)
    }

    var nextTime: Int64? { upcoming }

    func pull() async throws -> [MediaPacket] {
        guard upcoming != nil else { return [] }
        guard let frame = try sampler.next() else {
            upcoming = nil
            return try encoder.finish()
        }
        upcoming = sampler.position
        return try encoder.encode(frame.image, timestamp: frame.timestamp)
    }
}
