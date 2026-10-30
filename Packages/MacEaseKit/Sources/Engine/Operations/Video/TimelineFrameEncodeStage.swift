import Formats
import Foundation

final class TimelineFrameEncodeStage: StreamStage {
    private let input: MediaInput
    private let encoding: VideoEncoding
    private let edit: FrameEdit
    private let timeline: VideoTimeline
    private let toneMapToSDR: Bool
    private var encoder: any VideoFrameEncoder
    private var sampler: FrameSampler?
    private var segmentIndex: Int?
    private var upcoming: Int64? = 0

    init(
        input: MediaInput, encoding: VideoEncoding, edit: FrameEdit, timeline: VideoTimeline,
        toneMapToSDR: Bool
    ) throws {
        encoder = try VideoEncoders.make(encoding, track: 1)
        self.input = input
        self.encoding = encoding
        self.edit = edit
        self.timeline = timeline
        self.toneMapToSDR = toneMapToSDR
    }

    var output: OutputTrack? {
        let track = encoder.track
        let toolboxCodecs: Set<MediaCodec> = [.h264, .hevc, .prores]
        if toolboxCodecs.contains(track.codec), encoder.formatDescription == nil { return nil }
        return OutputTrack(track: track, format: encoder.formatDescription)
    }

    var nextTime: Int64? { upcoming }

    func pull() async throws -> [MediaPacket] {
        guard let timestamp = upcoming else { return [] }
        let duration = try Nanoseconds.from(seconds: timeline.duration)
        guard timestamp < duration else {
            upcoming = nil
            return try encoder.finish()
        }
        let (frameCenter, centerOverflow) = timestamp.addingReportingOverflow(encoding.frameDuration / 2)
        guard !centerOverflow else { throw EngineError.encodeFailed("video timeline out of range") }
        let center = min(frameCenter, duration - 1)
        let seconds = Double(center) / Double(Nanoseconds.perSecond)
        let index = timeline.index(at: seconds)
        if segmentIndex != index {
            let segment = timeline.segments[index]
            var frameEdit = edit
            frameEdit.adjustments = segment.adjustments.isIdentity ? nil : segment.adjustments
            sampler = try await FrameSampler(
                input: input, frameDuration: encoding.frameDuration, edit: frameEdit,
                start: Nanoseconds.from(seconds: segment.start), end: Nanoseconds.from(seconds: segment.end),
                hdr: encoding.hdr, toneMapToSDR: toneMapToSDR)
            segmentIndex = index
        }
        let sourceEnd = try Nanoseconds.from(seconds: timeline.segments[index].end)
        let sourceTime = min(sourceEnd - 1, try Nanoseconds.from(seconds: timeline.sourceTime(at: seconds)))
        guard let frame = try await sampler?.next(sourceTime: sourceTime, timestamp: timestamp) else {
            throw EngineError.decodeFailed("no frame in selected segment")
        }
        let (following, overflow) = timestamp.addingReportingOverflow(encoding.frameDuration)
        guard !overflow else { throw EngineError.encodeFailed("video timeline out of range") }
        upcoming = following
        return try encoder.encode(frame.image, timestamp: timestamp)
    }
}
