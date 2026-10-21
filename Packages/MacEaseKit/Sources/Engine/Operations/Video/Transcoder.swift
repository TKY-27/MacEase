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
        case encode(MediaCodec, kilobits: Int)
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
    /// Replaces backgrounds before encoding.
    var matte: BackgroundMatte?
}

/// Pulls one output stream in time order.
protocol StreamStage: AnyObject {
    var output: OutputTrack? { get }
    /// Next packet's source time; `nil` when drained.
    var nextTime: Int64? { get }
    func pull() async throws -> [MediaPacket]
}

enum Transcoder {
    /// Open ranges read to the end.
    static func readerTime(_ nanoseconds: Int64) -> CMTime {
        nanoseconds == .max ? .positiveInfinity : CMTime(value: nanoseconds, timescale: SampleBuffers.nanosecondScale)
    }

    static func run(
        _ input: MediaInput, plan: TranscodePlan, to url: URL, progress: (Double) -> Void
    ) async throws {
        if case .copy = plan.video, plan.container.fileType == nil,
            (plan.transform ?? input.transform) != .identity
        {
            throw EngineError.videoDisplayTransformUnsupported
        }
        let start = try await startTime(input, plan: plan)
        // Streams may outlast the container's stated duration.
        let end = plan.range?.upperBound ?? .max
        let progressEnd = plan.range?.upperBound ?? input.duration
        var stages: [any StreamStage] = []
        if let video = plan.video, let track = input.video {
            stages.append(
                try await videoStage(video, track: track, input: input, matte: plan.matte, start: start, end: end))
        }
        if let audio = plan.audio, let track = input.audio {
            let number = stages.count + 1
            switch audio {
            case .copy:
                stages.append(
                    try await PacketCopyStage(input: input, track: track, number: number, start: start, end: end))
            case .encode(let codec, let kilobits):
                stages.append(
                    try AudioEncodeStage(
                        input: input, track: track, number: number, codec: codec, kilobits: kilobits,
                        start: start, end: end))
            }
        }
        guard !stages.isEmpty else { throw EngineError.invalidInput(.emptyInput) }
        var primed: [[MediaPacket]] = []
        for stage in stages { primed.append(try await prime(stage)) }
        let tracks = try stages.map { stage in
            guard let output = stage.output else { throw EngineError.encodeFailed("stream produced nothing") }
            return output
        }
        // FLV alone cannot store negative decode times.
        let firstDecode = primed.flatMap { $0 }.compactMap(\.decodeTimestamp).min() ?? start
        let origin = plan.container == .flv ? min(start, firstDecode) : start
        let transform: CGAffineTransform =
            if case .copy = plan.video { plan.transform ?? input.transform } else { .identity }
        var sink = try Sinks.make(plan.container, url: url, tracks: tracks, transform: transform)
        var queues = primed
        do {
            while let index = try await earliest(stages, queues, sink: sink) {
                try Task.checkCancellation()
                guard !queues[index].isEmpty else {
                    queues[index] = try await stages[index].pull()
                    continue
                }
                // A blocked input must not starve others.
                let packet = queues[index].removeFirst()
                try await sink.write(rebased(packet, origin: origin))
                progress((Double(packet.timestamp) - Double(start)) / max(Double(progressEnd) - Double(start), 1))
            }
            try await sink.finish()
        } catch {
            sink.cancel()
            throw error
        }
    }

    private static let readinessPoll = Duration.milliseconds(2)

    /// Earliest stream the sink accepts now.
    private static func earliest(
        _ stages: [any StreamStage], _ queues: [[MediaPacket]], sink: any PacketSink
    ) async throws -> Int? {
        while true {
            try sink.checkHealth()
            try Task.checkCancellation()
            var candidates: [(index: Int, time: Int64)] = []
            for index in stages.indices {
                guard let time = queues[index].first?.timestamp ?? stages[index].nextTime else {
                    stages[index].output.map { sink.endTrack($0.track.number) }
                    continue
                }
                candidates.append((index, time))
            }
            guard !candidates.isEmpty else { return nil }
            let ordered = candidates.sorted { $0.time < $1.time }
            if let ready = ordered.first(where: { sink.accepts(track: stages[$0.index].output?.track.number ?? 0) }) {
                return ready.index
            }
            try await Task.sleep(for: readinessPoll)
        }
    }

    private static func prime(_ stage: any StreamStage) async throws -> [MediaPacket] {
        var packets: [MediaPacket] = []
        while packets.isEmpty, stage.nextTime != nil { packets = try await stage.pull() }
        return packets
    }

    private static func rebased(_ packet: MediaPacket, origin: Int64) throws -> MediaPacket {
        var shifted = packet
        let (timestamp, timestampOverflow) = packet.timestamp.subtractingReportingOverflow(origin)
        guard !timestampOverflow else { throw EngineError.decodeFailed("media timestamp out of range") }
        shifted.timestamp = timestamp
        if let decodeTimestamp = packet.decodeTimestamp {
            let (rebasedDecode, decodeOverflow) = decodeTimestamp.subtractingReportingOverflow(origin)
            guard !decodeOverflow else { throw EngineError.decodeFailed("media timestamp out of range") }
            shifted.decodeTimestamp = rebasedDecode
        }
        return shifted
    }

    private static func videoStage(
        _ video: TranscodePlan.Video, track: MediaTrack, input: MediaInput, matte: BackgroundMatte?, start: Int64,
        end: Int64
    ) async throws -> any StreamStage {
        switch video {
        case .copy:
            try await PacketCopyStage(input: input, track: track, number: 1, start: start, end: end)
        case .encode(let encoding, let edit):
            try await FrameEncodeStage(
                input: input, encoding: encoding, edit: edit, matte: matte, start: start, end: end)
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
        while let packet = try demuxer.nextPacket() {
            try Task.checkCancellation()
            if packet.track == video.number, packet.isKeyframe, packet.timestamp <= time {
                keyframe = max(keyframe, packet.timestamp)
            }
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

    /// Deeper than any B-frame pyramid in practice.
    private static let reorderWindow = 16
    private static let reorderingCodecs: Set<MediaCodec> = [.h264, .hevc, .mpeg4Part2]

    private var source: Source
    private let number: Int
    private let start: Int64
    private let end: Int64
    private let isVideo: Bool
    private let synthesizesDecodeTimes: Bool
    private var window: [MediaPacket] = []
    private var sourceEnded = false
    private var seenKeyframe = false
    private var lastDecodeTime: Int64?
    private var reorderShift: Int64?
    private var pendingAsset: [MediaPacket] = []
    private(set) var output: OutputTrack?

    init(input: MediaInput, track: MediaTrack, number: Int, start: Int64, end: Int64) async throws {
        self.number = number
        self.start = start
        self.end = end
        isVideo = track.isVideo
        var described = track
        described.number = number
        switch input.backend {
        case .asset(let asset, let video, let audio):
            guard let assetTrack = track.isVideo ? video : audio else {
                throw EngineError.decodeFailed("missing track")
            }
            let range = CMTimeRange(
                start: CMTime(value: start, timescale: SampleBuffers.nanosecondScale),
                end: Transcoder.readerTime(end))
            source = .asset(
                try AssetTrackReader(asset: asset, track: assetTrack, number: number, mode: .packets, range: range))
            output = OutputTrack(track: described, format: try await assetTrack.load(.formatDescriptions).first)
            synthesizesDecodeTimes = false
        default:
            guard let demuxer = try input.demuxer else { throw EngineError.decodeFailed("no demuxer") }
            source = .container(demuxer, sourceTrack: track.number)
            output = OutputTrack(track: described, format: nil)
            synthesizesDecodeTimes = Self.reorderingCodecs.contains(track.codec)
        }
    }

    var nextTime: Int64? {
        if let first = window.first { return first.timestamp }
        return sourceEnded ? nil : start
    }

    func pull() async throws -> [MediaPacket] {
        while !sourceEnded, window.count < Self.reorderWindow {
            guard let packet = try await nextRaw() else {
                sourceEnded = true
                break
            }
            guard packet.timestamp >= start || isVideo else { continue }
            if isVideo, !seenKeyframe {
                guard packet.isKeyframe, packet.timestamp >= start else { continue }
                seenKeyframe = true
            }
            window.append(packet)
        }
        guard !window.isEmpty else { return [] }
        if reorderShift == nil { reorderShift = synthesizesDecodeTimes ? try shift(for: window) : 0 }
        // Keep late frames that earlier frames reference.
        guard window.contains(where: { $0.timestamp < end }) else {
            window = []
            sourceEnded = true
            return []
        }
        var packet = window.removeFirst()
        if synthesizesDecodeTimes, packet.decodeTimestamp == nil {
            packet.decodeTimestamp = try decodeTime(for: packet)
        }
        packet.track = number
        return [packet]
    }

    private func nextRaw() async throws -> MediaPacket? {
        switch source {
        case .asset(let reader):
            while pendingAsset.isEmpty, let packets = try await reader.nextPackets() { pendingAsset = packets }
            return pendingAsset.isEmpty ? nil : pendingAsset.removeFirst()
        case .container(var demuxer, let sourceTrack):
            defer { source = .container(demuxer, sourceTrack: sourceTrack) }
            while let packet = try demuxer.nextPacket() {
                try Task.checkCancellation()
                if packet.track == sourceTrack { return packet }
            }
            return nil
        }
    }

    /// Keeps decode times at or before presentation.
    private func shift(for packets: [MediaPacket]) throws -> Int64 {
        let sorted = packets.map(\.timestamp).sorted()
        var shift: Int64 = 0
        for (presentation, packet) in zip(sorted, packets) {
            let (difference, overflow) = presentation.subtractingReportingOverflow(packet.timestamp)
            guard !overflow else { throw EngineError.decodeFailed("media timestamp out of range") }
            shift = max(shift, difference)
        }
        return shift
    }

    private func decodeTime(for packet: MediaPacket) throws -> Int64 {
        let next = ([packet] + window).map(\.timestamp).min() ?? packet.timestamp
        let (candidate, overflow) = next.subtractingReportingOverflow(reorderShift ?? 0)
        guard !overflow else { throw EngineError.decodeFailed("media timestamp out of range") }
        var time = min(candidate, packet.timestamp)
        if let last = lastDecodeTime, time <= last {
            let (following, incrementOverflow) = last.addingReportingOverflow(1)
            guard !incrementOverflow else { throw EngineError.decodeFailed("media timestamp out of range") }
            time = following
        }
        lastDecodeTime = time
        return time
    }
}

/// Re-encoded at a constant frame rate.
final class FrameEncodeStage: StreamStage {
    private let sampler: FrameSampler
    private var encoder: any VideoFrameEncoder
    private var upcoming: Int64?

    private let matte: BackgroundMatte?

    init(
        input: MediaInput, encoding: VideoEncoding, edit: FrameEdit, matte: BackgroundMatte?, start: Int64,
        end: Int64
    ) async throws {
        sampler = try await FrameSampler(
            input: input, frameDuration: encoding.frameDuration, edit: edit, start: start, end: end)
        encoder = try VideoEncoders.make(encoding, track: 1)
        self.matte = matte
        upcoming = start
    }

    var output: OutputTrack? {
        let track = encoder.track
        let fromToolbox: Set<MediaCodec> = [.h264, .hevc, .prores]
        if fromToolbox.contains(track.codec), encoder.formatDescription == nil { return nil }
        return OutputTrack(track: track, format: encoder.formatDescription)
    }

    var nextTime: Int64? { upcoming }

    func pull() async throws -> [MediaPacket] {
        guard upcoming != nil else { return [] }
        guard let frame = try await sampler.next() else {
            upcoming = nil
            return try encoder.finish()
        }
        upcoming = sampler.position
        let image = try await matte?.apply(frame.image) ?? frame.image
        return try encoder.encode(image, timestamp: frame.timestamp)
    }
}
