import Formats
import Foundation

final class TimelinePCMSource {
    private static let chunkFrames: Int64 = 4_096
    private let inputs: [MediaInput]
    private let timeline: VideoTimeline
    private let stagingDirectory: URL
    private var segmentIndex = 0
    private var rendered: TimeStretchedAudio?
    private var converter: PCMConverter?
    private var pending: [Float] = []
    private var drained = false
    private var position: Int64 = 0
    private let continuity: PCMFrameContinuity
    let sampleRate: Double
    let channels: Int

    init(
        input: MediaInput, track: MediaTrack, timeline: VideoTimeline, inputs: [MediaInput]? = nil,
        stagingDirectory: URL
    ) throws {
        guard case .audio(let sampleRate, let channels) = track.kind else {
            throw EngineError.decodeFailed("not an audio track")
        }
        self.inputs = inputs ?? [input]
        self.timeline = timeline
        self.stagingDirectory = stagingDirectory
        self.sampleRate = inputs == nil ? sampleRate : 48_000
        self.channels = inputs == nil ? channels : 2
        try AudioMetadata.validate(sampleRate: self.sampleRate, channels: self.channels)
        continuity = PCMFrameContinuity(sampleRate: self.sampleRate, timestampQuantum: nil)
    }

    func next() async throws -> VideoPCMSource.Chunk? {
        while segmentIndex < timeline.segments.count {
            try Task.checkCancellation()
            let segment = timeline.segments[segmentIndex]
            let input = inputs[segment.sourceIndex]
            let end = try continuity.framePosition(Nanoseconds.from(seconds: timeline.outputEnd(at: segmentIndex)))
            guard position < end else {
                if let rendered { try FileManager.default.removeItem(at: rendered.sourceURL) }
                rendered = nil
                converter = nil
                pending.removeAll(keepingCapacity: true)
                drained = false
                segmentIndex += 1
                continue
            }
            if rendered == nil, segment.volume > 0, let track = input.audio {
                let source = try await TimeStretchedAudio(
                    input: input, track: track, start: Nanoseconds.from(seconds: segment.start),
                    end: Nanoseconds.from(seconds: segment.end), speed: segment.speed,
                    stagingDirectory: stagingDirectory)
                if source.sampleRate != sampleRate || source.channels != channels {
                    converter = try PCMConverter(
                        sampleRate: source.sampleRate, channels: source.channels,
                        toSampleRate: sampleRate, channels: channels)
                }
                rendered = source
            }
            let available = Int(min(Self.chunkFrames, end - position))
            var samples: [Float]
            if let rendered {
                while pending.count < available * channels, !drained {
                    if let next = try rendered.next() {
                        pending += try converter?.convert(next) ?? next
                    } else {
                        if let converter { pending += try converter.finish() }
                        drained = true
                    }
                }
                let count = min(available * channels, pending.count)
                samples = Array(pending.prefix(count))
                pending.removeFirst(count)
                if samples.count < available * channels {
                    let allowance = Int64(ceil(sampleRate / rendered.sampleRate * (0.5 / segment.speed + 0.5)))
                    guard end - position - Int64(samples.count / channels) <= allowance else {
                        throw EngineError.decodeFailed("audio segment ended early")
                    }
                    samples += [Float](repeating: 0, count: available * channels - samples.count)
                }
                if segment.volume != 1 { samples = samples.map { $0 * Float(segment.volume) } }
            } else {
                samples = [Float](repeating: 0, count: available * channels)
            }
            let timestamp = try Nanoseconds.from(seconds: Double(position) / sampleRate)
            position += Int64(samples.count / channels)
            return VideoPCMSource.Chunk(samples: samples, timestamp: timestamp, continuesPrevious: true)
        }
        return nil
    }
}
