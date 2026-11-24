import Formats
import Foundation

final class TimelinePCMSource {
    private static let chunkFrames: Int64 = 4_096
    private static let defaultSampleRate = 48_000.0
    private static let defaultChannels = 2

    private let inputs: [MediaInput]
    private let timeline: VideoTimeline
    private let stagingDirectory: URL
    private let music: MusicPCMSource?
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
        input: MediaInput, track: MediaTrack?, timeline: VideoTimeline, inputs: [MediaInput]? = nil,
        stagingDirectory: URL
    ) async throws {
        let targetRate: Double
        let targetChannels: Int
        if inputs == nil, timeline.music == nil, let track {
            guard case .audio(let sampleRate, let channels) = track.kind else {
                throw EngineError.decodeFailed("not an audio track")
            }
            targetRate = sampleRate
            targetChannels = channels
        } else {
            targetRate = Self.defaultSampleRate
            targetChannels = Self.defaultChannels
        }
        self.inputs = inputs ?? [input]
        self.timeline = timeline
        self.stagingDirectory = stagingDirectory
        self.sampleRate = targetRate
        self.channels = targetChannels
        try AudioMetadata.validate(sampleRate: self.sampleRate, channels: self.channels)
        continuity = PCMFrameContinuity(sampleRate: self.sampleRate, timestampQuantum: nil)
        if let backgroundMusic = timeline.music {
            music = try await MusicPCMSource(
                music: backgroundMusic, outputDuration: timeline.duration, sampleRate: targetRate,
                channels: targetChannels)
        } else {
            music = nil
        }
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
                let segmentStart = try continuity.framePosition(
                    Nanoseconds.from(seconds: timeline.outputStart(at: segmentIndex)))
                timeline.fade(at: segmentIndex).apply(
                    to: &samples, channels: channels, firstFrame: position - segmentStart, sampleRate: sampleRate)
            } else {
                samples = [Float](repeating: 0, count: available * channels)
            }
            try music?.mix(into: &samples, at: position)
            let timestamp = try Nanoseconds.from(seconds: Double(position) / sampleRate)
            position += Int64(samples.count / channels)
            return VideoPCMSource.Chunk(samples: samples, timestamp: timestamp, continuesPrevious: true)
        }
        return nil
    }
}

private final class MusicPCMSource {
    private static let compactThreshold = 65_536

    private let url: URL
    private let reader: any PCMSource
    private let converter: PCMConverter?
    private let channels: Int
    private let sampleRate: Double
    private let volume: Float
    private let fade: FadeRamp
    private let totalFrames: Int64
    private var skipSourceFrames: Int64
    private let sourceChannels: Int
    private var pending: [Float] = []
    private var pendingOffset = 0
    private var drained = false

    init(music: BackgroundMusic, outputDuration: Double, sampleRate: Double, channels: Int) async throws {
        try music.validate()
        try music.validateSource()
        let reader: any PCMSource
        do {
            try await UntrustedMediaAsset.rejectExternalReferences(in: music.url)
            let input = try AudioInput(url: music.url)
            reader = try input.open()
        } catch {
            throw EngineError.wrapping(error, path: music.url.path)
        }
        url = music.url
        self.reader = reader
        self.channels = channels
        self.sampleRate = sampleRate
        sourceChannels = reader.channels
        volume = Float(music.volume)
        fade = music.fade(forOutputDuration: outputDuration)
        let continuity = PCMFrameContinuity(sampleRate: sampleRate, timestampQuantum: nil)
        let playedSeconds = music.playDuration(forOutputDuration: outputDuration)
        totalFrames = try continuity.framePosition(Nanoseconds.from(seconds: playedSeconds))
        skipSourceFrames = Int64((music.start * reader.sampleRate).rounded())
        converter =
            reader.sampleRate == sampleRate && reader.channels == channels
            ? nil
            : try PCMConverter(
                sampleRate: reader.sampleRate, channels: reader.channels,
                toSampleRate: sampleRate, channels: channels)
    }

    func mix(into samples: inout [Float], at outputFrame: Int64) throws {
        guard volume > 0, outputFrame < totalFrames else { return }
        let frames = samples.count / channels
        let activeFrames = Int(min(Int64(frames), totalFrames - outputFrame))
        guard activeFrames > 0 else { return }
        let neededSamples = activeFrames * channels
        while pending.count - pendingOffset < neededSamples, !drained {
            try Task.checkCancellation()
            let chunk: [Float]?
            do {
                chunk = try reader.read()
            } catch {
                throw EngineError.wrapping(error, path: url.path)
            }
            guard let chunk else {
                if let converter { pending += try converter.finish() }
                drained = true
                break
            }
            let kept = dropLeadingFrames(from: chunk)
            guard !kept.isEmpty else { continue }
            pending += try converter?.convert(kept) ?? kept
        }
        let availableFrames = min(activeFrames, (pending.count - pendingOffset) / channels)
        for frame in 0..<availableFrames {
            let fadeGain =
                fade.isIdentity ? Float(1) : Float(fade.gain(at: Double(outputFrame + Int64(frame)) / sampleRate))
            let gain = volume * fadeGain
            let videoBase = frame * channels
            let musicBase = pendingOffset + videoBase
            for channel in 0..<channels {
                let sum = samples[videoBase + channel] + pending[musicBase + channel] * gain
                samples[videoBase + channel] = min(1, max(-1, sum))
            }
        }
        pendingOffset += availableFrames * channels
        if pendingOffset == pending.count {
            pending.removeAll(keepingCapacity: true)
            pendingOffset = 0
        } else if pendingOffset >= Self.compactThreshold {
            pending.removeFirst(pendingOffset)
            pendingOffset = 0
        }
    }

    private func dropLeadingFrames(from chunk: [Float]) -> [Float] {
        guard skipSourceFrames > 0 else { return chunk }
        let frames = Int64(chunk.count / sourceChannels)
        if frames <= skipSourceFrames {
            skipSourceFrames -= frames
            return []
        }
        let dropSamples = Int(skipSourceFrames) * sourceChannels
        skipSourceFrames = 0
        return Array(chunk.dropFirst(dropSamples))
    }
}
