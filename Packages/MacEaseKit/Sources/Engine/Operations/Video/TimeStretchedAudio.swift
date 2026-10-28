import AVFoundation
import Formats
import Foundation

final class TimeStretchedAudio {
    private static let chunkFrames: AVAudioFrameCount = 4_096
    private static let maximumSilentSeconds = 600.0
    private static let maximumRenderRetries = 32
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let sourceFile: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private let frameCount: Int64
    private(set) var position: Int64 = 0
    let sampleRate: Double
    let channels: Int

    init(
        input: MediaInput, track: MediaTrack, start: Int64, end: Int64, speed: Double, stagingDirectory: URL
    ) async throws {
        _ = try VideoTiming(start: start, speed: speed)
        let source = try VideoPCMSource(input: input, track: track, start: start, end: end)
        guard source.channels <= 2 else { throw EngineError.audioChannelLayoutUnsupported }
        let url = stagingDirectory.appending(path: "audio-\(UUID().uuidString).caf")
        try await Self.writeContinuous(source, track: track, start: start, end: end, to: url)
        sourceFile = try AVAudioFile(forReading: url)
        let format = sourceFile.processingFormat
        sampleRate = format.sampleRate
        channels = Int(format.channelCount)
        guard let frameCount = Int64(exactly: (Double(sourceFile.length) / speed).rounded()), frameCount > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.chunkFrames)
        else { throw EngineError.decodeFailed("empty or oversized audio timeline") }
        self.frameCount = frameCount
        self.buffer = buffer
        try startPlayback(format: format, speed: speed)
    }

    private func startPlayback(format: AVAudioFormat, speed: Double) throws {
        engine.attach(player)
        engine.attach(pitch)
        pitch.rate = Float(speed)
        pitch.pitch = 0
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: Self.chunkFrames)
        player.scheduleFile(sourceFile, at: nil, completionHandler: nil)
        try engine.start()
        player.play()
    }

    deinit {
        player.stop()
        engine.stop()
    }

    func next() throws -> [Float]? {
        guard position < frameCount else { return nil }
        let requested = AVAudioFrameCount(min(Int64(Self.chunkFrames), frameCount - position))
        for _ in 0..<Self.maximumRenderRetries {
            try Task.checkCancellation()
            let status = try engine.renderOffline(requested, to: buffer)
            guard status != .error else { throw EngineError.encodeFailed("audio time stretching failed") }
            if buffer.frameLength > 0 {
                guard let planes = buffer.floatChannelData else {
                    throw EngineError.encodeFailed("missing time-stretched audio samples")
                }
                let count = Int(buffer.frameLength)
                var samples = [Float](repeating: 0, count: count * channels)
                for frame in 0..<count {
                    for channel in 0..<channels { samples[frame * channels + channel] = planes[channel][frame] }
                }
                guard samples.allSatisfy(\.isFinite) else { throw EngineError.nonFiniteAudioSample }
                position += Int64(count)
                return samples
            }
            if status == .insufficientDataFromInputNode {
                throw EngineError.decodeFailed("audio time stretching ended early")
            }
        }
        throw EngineError.encodeFailed("audio time stretching made no progress")
    }

    private static func writeContinuous(
        _ source: VideoPCMSource, track: MediaTrack, start: Int64, end: Int64, to url: URL
    ) async throws {
        guard let channelCount = AVAudioChannelCount(exactly: source.channels),
            let format = AVAudioFormat(standardFormatWithSampleRate: source.sampleRate, channels: channelCount),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
            let planes = buffer.floatChannelData
        else { throw EngineError.audioChannelLayoutUnsupported }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let continuity = PCMFrameContinuity(sampleRate: source.sampleRate, timestampQuantum: track.timestampQuantum)
        let maximumFrames = try continuity.framePosition(end - start)
        let maximumSilence = Int64(maximumSilentSeconds * source.sampleRate)
        var written: Int64 = 0
        var silence: Int64 = 0
        func appendSilence(_ frames: Int64) throws {
            guard frames <= maximumSilence - silence else {
                throw EngineError.decodeFailed("audio synthesized silence exceeds 10 minutes")
            }
            silence += frames
            var remaining = frames
            while remaining > 0 {
                try Task.checkCancellation()
                let count = Int(min(remaining, Int64(chunkFrames)))
                for channel in 0..<source.channels { planes[channel].update(repeating: 0, count: count) }
                buffer.frameLength = AVAudioFrameCount(count)
                try file.write(from: buffer)
                remaining -= Int64(count)
                written += Int64(count)
            }
        }
        while let chunk = try await source.next() {
            try Task.checkCancellation()
            let gap = try continuity.gap(
                at: chunk.timestamp, relativeTo: start, after: written, continuesPrevious: chunk.continuesPrevious)
            if gap > 0 {
                try appendSilence(min(gap, max(0, maximumFrames - written)))
            }
            let frames = chunk.samples.count / source.channels
            var offset = Int(min(UInt64(frames), gap < 0 ? gap.magnitude : 0))
            while offset < frames, written < maximumFrames {
                try Task.checkCancellation()
                let count = min(
                    frames - offset, Int(chunkFrames), Int(min(Int64(chunkFrames), maximumFrames - written)))
                for frame in 0..<count {
                    for channel in 0..<source.channels {
                        planes[channel][frame] = chunk.samples[(offset + frame) * source.channels + channel]
                    }
                }
                buffer.frameLength = AVAudioFrameCount(count)
                try file.write(from: buffer)
                written += Int64(count)
                offset += count
            }
            if written >= maximumFrames { break }
        }
        try appendSilence(max(0, maximumFrames - written))
    }
}
