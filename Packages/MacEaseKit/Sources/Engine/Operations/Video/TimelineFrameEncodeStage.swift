import CoreVideo
import Formats
import Foundation

final class TimelineFrameSource {
    private let inputs: [MediaInput]
    private let frameDuration: Int64
    private let edit: FrameEdit
    private let timeline: VideoTimeline
    private let hdr: VideoHDRConfiguration?
    private let toneMapToSDR: Bool
    private let duration: Int64
    private var sampler: FrameSampler?
    private var segmentIndex: Int?

    init(
        inputs: [MediaInput], frameDuration: Int64, edit: FrameEdit, timeline: VideoTimeline,
        hdr: VideoHDRConfiguration? = nil, toneMapToSDR: Bool
    ) throws {
        self.inputs = inputs
        self.frameDuration = frameDuration
        self.edit = edit
        self.timeline = timeline
        self.hdr = hdr
        self.toneMapToSDR = toneMapToSDR
        duration = try Nanoseconds.from(seconds: timeline.duration)
        guard duration > 0 else { throw EngineError.encodeFailed("video timeline out of range") }
    }

    func frame(at timestamp: Int64) async throws -> CVPixelBuffer {
        guard timestamp >= 0, timestamp < duration else {
            throw EngineError.encodeFailed("video timeline out of range")
        }
        let seconds = Double(timestamp) / Double(Nanoseconds.perSecond)
        let index = timeline.index(at: seconds)
        if segmentIndex != index {
            let segment = timeline.segments[index]
            let input = inputs[segment.sourceIndex]
            var frameEdit = edit
            frameEdit.displayOrientation = try input.displayOrientation
            if inputs.count > 1 { frameEdit.fitCanvas = inputs[0].displaySize }
            frameEdit.adjustments = segment.adjustments.isIdentity ? nil : segment.adjustments
            frameEdit.hasOverlays = !timeline.overlays.isEmpty
            let sourceHDR = try await VideoProperties.hdrConfiguration(input)
            sampler = try await FrameSampler(
                input: input, frameDuration: frameDuration, edit: frameEdit,
                start: Nanoseconds.from(seconds: segment.start), end: Nanoseconds.from(seconds: segment.end),
                hdr: hdr, toneMapToSDR: toneMapToSDR && sourceHDR != nil, holdsLastFrame: true)
            segmentIndex = index
        }
        let (center, overflow) = timestamp.addingReportingOverflow(frameDuration / 2)
        guard !overflow else { throw EngineError.encodeFailed("video timeline out of range") }
        let sampleSeconds = min(Double(center) / Double(Nanoseconds.perSecond), timeline.outputEnd(at: index).nextDown)
        let sourceEnd = try Nanoseconds.from(seconds: timeline.segments[index].end)
        let sourceTime = min(sourceEnd - 1, try Nanoseconds.from(seconds: timeline.sourceTime(at: sampleSeconds)))
        let fade = timeline.fadeGain(at: Double(timestamp) / Double(Nanoseconds.perSecond))
        let selection: (@Sendable (ClosedRange<Double>) -> [EditOverlay])? =
            timeline.overlays.isEmpty
            ? nil
            : { @Sendable [timeline] (range: ClosedRange<Double>) in
                timeline.overlays(at: seconds, sourceRange: range)
            }
        guard
            let frame = try await sampler?.next(
                sourceTime: sourceTime, timestamp: timestamp, fade: fade,
                overlaySelection: selection)
        else {
            throw EngineError.decodeFailed("no frame in selected segment")
        }
        return frame.image
    }
}

final class TimelineFrameEncodeStage: StreamStage {
    private let source: TimelineFrameSource
    private let frameDuration: Int64
    private let duration: Int64
    private var encoder: any VideoFrameEncoder
    private var upcoming: Int64? = 0

    init(
        input: MediaInput, encoding: VideoEncoding, edit: FrameEdit, timeline: VideoTimeline,
        toneMapToSDR: Bool, inputs: [MediaInput]? = nil
    ) throws {
        encoder = try VideoEncoders.make(encoding, track: 1)
        source = try TimelineFrameSource(
            inputs: inputs ?? [input], frameDuration: encoding.frameDuration, edit: edit,
            timeline: timeline, hdr: encoding.hdr, toneMapToSDR: toneMapToSDR)
        frameDuration = encoding.frameDuration
        duration = try Nanoseconds.from(seconds: timeline.duration)
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
        guard timestamp < duration else {
            upcoming = nil
            return clamped(try encoder.finish())
        }
        let image = try await source.frame(at: timestamp)
        let (following, overflow) = timestamp.addingReportingOverflow(frameDuration)
        guard !overflow else { throw EngineError.encodeFailed("video timeline out of range") }
        upcoming = following
        return clamped(try encoder.encode(image, timestamp: timestamp))
    }

    private func clamped(_ packets: [MediaPacket]) -> [MediaPacket] {
        packets.map { packet in
            var timed = packet
            timed.duration = min(packet.duration ?? frameDuration, max(1, duration - packet.timestamp))
            return timed
        }
    }
}
