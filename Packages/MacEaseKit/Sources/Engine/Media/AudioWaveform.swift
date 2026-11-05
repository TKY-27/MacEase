import AVFoundation
import Foundation

public struct AudioWaveformSnapshot: Sendable {
    public let peaks: [Float]
    public let start: Double
    public let duration: Double
    public let sampleRate: Double
}

public enum AudioWaveform {
    private static let maximumBins = 65_536
    private static let updateInterval = Duration.milliseconds(100)

    public static func load(
        url: URL, range: Range<Double>? = nil, bins: Int = 4_096,
        update: @escaping @Sendable (AudioWaveformSnapshot) -> Void = { _ in }
    ) async throws -> AudioWaveformSnapshot {
        let task = Task.detached(priority: .utility) {
            try read(url: url, range: range, bins: bins, update: update)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func read(
        url: URL, range: Range<Double>?, bins: Int,
        update: @Sendable (AudioWaveformSnapshot) -> Void
    ) throws -> AudioWaveformSnapshot {
        let stamp = try MediaSourceStamp(url: url)
        let input = try AudioInput(url: url)
        guard let duration = input.duration, duration > 0, bins > 0, bins <= maximumBins else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        let selected = range ?? 0..<duration
        guard selected.lowerBound.isFinite, selected.upperBound.isFinite, selected.lowerBound >= 0,
            selected.upperBound <= duration, !selected.isEmpty
        else { throw EngineError.invalidInput(.invalidNumericParameter) }
        let first = Int64((selected.lowerBound * input.sampleRate).rounded())
        let end = Int64((selected.upperBound * input.sampleRate).rounded())
        let count = max(1, end - first)
        let slots = min(bins, Int(min(count, Int64(maximumBins))))
        var peaks = [Float](repeating: 0, count: slots)
        let source = try input.open()
        var position: Int64 = 0
        var updated = ContinuousClock.now
        while let samples = try source.read() {
            try Task.checkCancellation()
            let frames = samples.count / input.channels
            let lower = Int(max(0, min(Int64(frames), first - position)))
            let upper = Int(max(0, min(Int64(frames), end - position)))
            for frame in lower..<max(lower, upper) {
                let index = min(slots - 1, Int(Double(position + Int64(frame) - first) / Double(count) * Double(slots)))
                for channel in 0..<input.channels {
                    let amplitude = samples[frame * input.channels + channel]
                    guard amplitude.isFinite else { throw EngineError.nonFiniteAudioSample }
                    peaks[index] = max(peaks[index], abs(amplitude))
                }
            }
            position += Int64(frames)
            if ContinuousClock.now - updated >= updateInterval {
                update(
                    AudioWaveformSnapshot(
                        peaks: peaks, start: selected.lowerBound, duration: selected.upperBound - selected.lowerBound,
                        sampleRate: input.sampleRate))
                updated = .now
            }
            if position >= end { break }
        }
        try Task.checkCancellation()
        try stamp.validate(url)
        let snapshot = AudioWaveformSnapshot(
            peaks: peaks, start: selected.lowerBound, duration: selected.upperBound - selected.lowerBound,
            sampleRate: input.sampleRate)
        update(snapshot)
        return snapshot
    }
}

public actor AudioPreviewSource {
    public let duration: Double
    public let sampleRate: Double
    public let stamp: MediaSourceStamp
    private let input: AudioInput
    private let staging: StagingArea
    private var directory: URL?
    private var closed = false

    public static func open(_ url: URL, staging: StagingArea) async throws -> AudioPreviewSource {
        let stamp = try MediaSourceStamp(url: url)
        let input = try AudioInput(url: url)
        guard let duration = input.duration, duration > 0 else {
            throw EngineError.decodeFailed("unknown audio duration")
        }
        try stamp.validate(url)
        return AudioPreviewSource(input: input, duration: duration, stamp: stamp, staging: staging)
    }

    private init(input: AudioInput, duration: Double, stamp: MediaSourceStamp, staging: StagingArea) {
        self.input = input
        self.duration = duration
        sampleRate = input.sampleRate
        self.stamp = stamp
        self.staging = staging
    }

    public func playbackURL() async throws -> URL {
        guard !closed else { throw CancellationError() }
        try stamp.validate(input.url)
        if input.container != .ogg, input.container != .flac,
            try await AVURLAsset(url: input.url).load(.isPlayable)
        {
            return input.url
        }
        if let directory { return directory.appending(path: "preview.wav") }
        let folder = try staging.makeDirectory(for: input.url)
        let output = folder.appending(path: "preview.wav")
        do {
            let encoder = try AudioFileEncoder(
                url: output, target: AudioTarget(format: .wav, kilobits: 0), sampleRate: sampleRate,
                channels: input.channels, bitDepth: 32, isFloat: true)
            let source = try input.open()
            while let samples = try source.read() {
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                try await encoder.write(samples)
            }
            try await encoder.finish()
            try stamp.validate(input.url)
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            directory = folder
            return output
        } catch {
            staging.remove(folder)
            throw error
        }
    }

    public func close() {
        closed = true
        if let directory { staging.remove(directory) }
        directory = nil
    }
}
