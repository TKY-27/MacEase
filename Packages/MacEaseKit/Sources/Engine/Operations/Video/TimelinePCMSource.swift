import Formats
import Foundation

final class TimelinePCMSource {
    private static let chunkFrames: Int64 = 4_096
    private let input: MediaInput
    private let track: MediaTrack
    private let timeline: VideoTimeline
    private let stagingDirectory: URL
    private var segmentIndex = 0
    private var rendered: TimeStretchedAudio?
    private var position: Int64 = 0
    private let continuity: PCMFrameContinuity
    let sampleRate: Double
    let channels: Int

    init(input: MediaInput, track: MediaTrack, timeline: VideoTimeline, stagingDirectory: URL) throws {
        guard case .audio(let sampleRate, let channels) = track.kind else {
            throw EngineError.decodeFailed("not an audio track")
        }
        guard channels <= 2 || timeline.segments.allSatisfy({ $0.speed == 1 }) else {
            throw EngineError.audioChannelLayoutUnsupported
        }
        try AudioMetadata.validate(sampleRate: sampleRate, channels: channels)
        self.input = input
        self.track = track
        self.timeline = timeline
        self.stagingDirectory = stagingDirectory
        self.sampleRate = sampleRate
        self.channels = channels
        continuity = PCMFrameContinuity(sampleRate: sampleRate, timestampQuantum: nil)
    }

    func next() async throws -> VideoPCMSource.Chunk? {
        while segmentIndex < timeline.segments.count {
            try Task.checkCancellation()
            let segment = timeline.segments[segmentIndex]
            let end = try continuity.framePosition(Nanoseconds.from(seconds: timeline.outputEnd(at: segmentIndex)))
            guard position < end else {
                if let rendered { try FileManager.default.removeItem(at: rendered.sourceURL) }
                rendered = nil
                segmentIndex += 1
                continue
            }
            if rendered == nil, segment.volume > 0 {
                rendered = try await TimeStretchedAudio(
                    input: input, track: track, start: Nanoseconds.from(seconds: segment.start),
                    end: Nanoseconds.from(seconds: segment.end), speed: segment.speed,
                    stagingDirectory: stagingDirectory)
            }
            let available = Int(min(Self.chunkFrames, end - position))
            var samples: [Float]
            if let rendered {
                if let next = try rendered.next() {
                    samples = Array(next.prefix(available * channels))
                } else {
                    let roundingAllowance = Int64(ceil(0.5 / segment.speed + 0.5))
                    guard end - position <= roundingAllowance else {
                        throw EngineError.decodeFailed("audio segment ended early")
                    }
                    samples = [Float](repeating: 0, count: available * channels)
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
