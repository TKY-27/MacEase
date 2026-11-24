import AVFoundation
import Formats
import Foundation

public struct AudioWaveformSnapshot: Sendable {
    public let peaks: [Float]
    public let start: Double
    public let duration: Double
    public let sampleRate: Double

    public init(peaks: [Float], start: Double, duration: Double, sampleRate: Double) {
        self.peaks = peaks
        self.start = start
        self.duration = duration
        self.sampleRate = sampleRate
    }
}

public enum AudioWaveform {
    private static let maximumBins = 65_536
    private static let minimumWindowSeconds = 0.001
    private static let maximumLevelWindows = 4_000_000
    private static let windowRoundingTolerance = 1e-9
    private static let powerToDecibels = 10.0
    private static let updateInterval = Duration.milliseconds(100)

    public static func load(
        url: URL, range: Range<Double>? = nil, bins: Int = 4_096,
        update: @escaping @Sendable (AudioWaveformSnapshot) -> Void = { _ in }
    ) async throws -> AudioWaveformSnapshot {
        try await UntrustedMediaAsset.rejectExternalReferences(in: url)
        let task = Task.detached(priority: .utility) {
            try read(url: url, range: range, bins: bins, update: update)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// `nil` for videos without audio.
    public static func load(videoURL url: URL, bins: Int = 4_096) async throws -> AudioWaveformSnapshot? {
        let task = Task.detached(priority: .utility) { try await readVideo(url: url, bins: bins) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public static func levels(videoAt url: URL, window: Double = AudioLevels.defaultWindow) async throws -> AudioLevels
    {
        let task = Task.detached(priority: .utility) { try await readVideoLevels(url: url, window: window) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func readVideo(url: URL, bins: Int) async throws -> AudioWaveformSnapshot? {
        var peaks: [Float] = []
        let metadata = try await decodeVideoAudio(url: url) { _, _ in
            guard bins > 0, bins <= maximumBins else {
                throw EngineError.invalidInput(.invalidNumericParameter)
            }
            peaks = [Float](repeating: 0, count: bins)
        } consume: { chunk, sampleRate, channels, duration in
            let origin = Double(chunk.timestamp) / Double(Nanoseconds.perSecond)
            for frame in 0..<(chunk.samples.count / channels) {
                let time = origin + Double(frame) / sampleRate
                let index = min(bins - 1, max(0, Int(time / duration * Double(bins))))
                for channel in 0..<channels {
                    peaks[index] = max(peaks[index], abs(chunk.samples[frame * channels + channel]))
                }
            }
        }
        guard let metadata else { return nil }
        return AudioWaveformSnapshot(
            peaks: peaks, start: 0, duration: metadata.duration, sampleRate: metadata.sampleRate)
    }

    private static func readVideoLevels(url: URL, window: Double) async throws -> AudioLevels {
        guard window.isFinite, window >= minimumWindowSeconds else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        var sumSquares: [Double] = []
        var sampleCounts: [Int] = []
        var windowCount = 0
        let decoded = try await decodeVideoAudio(url: url) { duration, _ in
            let rawCount = duration / window
            guard rawCount.isFinite, rawCount <= Double(maximumLevelWindows) else {
                throw EngineError.invalidInput(.invalidNumericParameter)
            }
            windowCount = max(1, Int(ceil(rawCount - windowRoundingTolerance)))
            guard windowCount <= maximumLevelWindows else {
                throw EngineError.invalidInput(.invalidNumericParameter)
            }
            sumSquares = [Double](repeating: 0, count: windowCount)
            sampleCounts = [Int](repeating: 0, count: windowCount)
        } consume: { chunk, sampleRate, channels, duration in
            let origin = Double(chunk.timestamp) / Double(Nanoseconds.perSecond)
            let frames = chunk.samples.count / channels
            for frame in 0..<frames {
                let time = origin + Double(frame) / sampleRate
                guard time >= 0, time < duration else { continue }
                let index = min(windowCount - 1, Int(time / window))
                var frameEnergy = 0.0
                for channel in 0..<channels {
                    let sample = Double(chunk.samples[frame * channels + channel])
                    frameEnergy += sample * sample
                }
                sumSquares[index] += frameEnergy
                sampleCounts[index] += channels
            }
        }
        guard let decoded else {
            throw EngineError.invalidInput(.malformed("no audio track"))
        }
        let decibels = (0..<windowCount).map { index -> Double in
            let count = sampleCounts[index]
            guard count > 0 else { return -.infinity }
            let meanSquare = sumSquares[index] / Double(count)
            guard meanSquare > 0 else { return -.infinity }
            return powerToDecibels * log10(meanSquare)
        }
        return AudioLevels(decibels: decibels, window: window, duration: decoded.duration)
    }

    private static func decodeVideoAudio(
        url: URL,
        prepare: (_ duration: Double, _ sampleRate: Double) throws -> Void,
        consume: (_ chunk: VideoPCMSource.Chunk, _ sampleRate: Double, _ channels: Int, _ duration: Double) throws ->
            Void
    ) async throws -> (duration: Double, sampleRate: Double)? {
        let stamp = try MediaSourceStamp(url: url)
        let input = try await MediaInput.open(url)
        guard let track = input.audio else { return nil }
        let duration = Double(input.duration) / Double(Nanoseconds.perSecond)
        guard duration > 0 else { throw EngineError.invalidInput(.invalidNumericParameter) }
        let source = try VideoPCMSource(input: input, track: track, start: 0, end: .max)
        try prepare(duration, source.sampleRate)
        while let chunk = try await source.next() {
            try Task.checkCancellation()
            guard chunk.samples.allSatisfy(\.isFinite) else { throw EngineError.nonFiniteAudioSample }
            try consume(chunk, source.sampleRate, source.channels, duration)
        }
        try Task.checkCancellation()
        try stamp.validate(url)
        return (duration, source.sampleRate)
    }

    private static func read(
        url: URL, range: Range<Double>?, bins: Int,
        update: @Sendable (AudioWaveformSnapshot) -> Void
    ) throws -> AudioWaveformSnapshot {
        let stamp = try MediaSourceStamp(url: url)
        // Previews decode only the first stream.
        let input = try AudioInput(url: url, allowsMultiplexedOgg: true)
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
    private static let previewAACKilobits = 192
    private static let maximumAACChannels = 6

    public let duration: Double
    public let sampleRate: Double
    public let stamp: MediaSourceStamp
    private let input: AudioInput
    private let staging: StagingArea
    private let compactPlayback: Bool
    private var directory: URL?
    private var closed = false

    public static func open(
        _ url: URL, staging: StagingArea, omission: StreamOmission? = nil
    ) async throws -> AudioPreviewSource {
        try await open(url, staging: staging, compactPlayback: false) { input, stamp in
            let omitted = omission?.streams(covering: stamp) ?? []
            let unconsented = try await AudioJob.unpreservedStreams(in: input).filter { !omitted.contains($0) }
            if !unconsented.isEmpty { throw EngineError.invalidInput(.unpreservedStreams(unconsented)) }
        }
    }

    /// Throwaway playback copies only; trims use `open`.
    public static func openForPreviewPlayback(_ url: URL, staging: StagingArea) async throws -> AudioPreviewSource {
        try await open(url, staging: staging, compactPlayback: true) { _, _ in }
    }

    private static func open(
        _ url: URL, staging: StagingArea, compactPlayback: Bool,
        validate: (AudioInput, MediaSourceStamp) async throws -> Void
    ) async throws -> AudioPreviewSource {
        let stamp = try MediaSourceStamp(url: url)
        try await UntrustedMediaAsset.rejectExternalReferences(in: url)
        let input = try AudioInput(url: url, allowsMultiplexedOgg: true)
        try await validate(input, stamp)
        guard let duration = input.duration, duration > 0 else {
            throw EngineError.decodeFailed("unknown audio duration")
        }
        try stamp.validate(url)
        return AudioPreviewSource(
            input: input, duration: duration, stamp: stamp, staging: staging, compactPlayback: compactPlayback)
    }

    private init(
        input: AudioInput, duration: Double, stamp: MediaSourceStamp, staging: StagingArea, compactPlayback: Bool
    ) {
        self.input = input
        self.duration = duration
        sampleRate = input.sampleRate
        self.stamp = stamp
        self.staging = staging
        self.compactPlayback = compactPlayback
    }

    private var stagedFileName: String {
        guard compactPlayback else { return "preview.wav" }
        return input.channels <= Self.maximumAACChannels ? "preview.m4a" : "preview.caf"
    }

    public nonisolated var url: URL { input.url }
    public nonisolated var backgroundMusic: BackgroundMusic {
        BackgroundMusic(url: input.url, stamp: stamp, duration: duration)
    }

    public func playbackURL() async throws -> URL {
        guard !closed else { throw CancellationError() }
        try stamp.validate(input.url)
        if try await Self.canPlayDirectly(input) { return input.url }
        if let directory { return directory.appending(path: stagedFileName) }
        let folder = try staging.makeDirectory(for: input.url)
        let output = folder.appending(path: stagedFileName)
        do {
            if compactPlayback {
                let target =
                    input.channels <= Self.maximumAACChannels
                    ? AudioTarget(format: .m4aAAC, kilobits: Self.previewAACKilobits)
                    : AudioTarget(format: .cafALAC, kilobits: 0)
                try await Self.writePreview(for: input, target: target, to: output) { [weak self] in
                    guard let self else { return true }
                    return await self.closed
                }
            } else {
                try await Self.writePreviewWAV(for: input, to: output) { [weak self] in
                    guard let self else { return true }
                    return await self.closed
                }
            }
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

    static func canPlayDirectly(_ input: AudioInput) async throws -> Bool {
        guard input.container != .ogg, input.container != .flac else { return false }
        let asset = UntrustedMediaAsset.make(input.url)
        guard try await asset.load(.isPlayable) else { return false }
        return try await asset.loadTracks(withMediaType: .audio).first != nil
    }

    static func writePreviewWAV(
        for input: AudioInput, to output: URL, isCancelled: () async -> Bool = { false }
    ) async throws {
        let encoder = try AudioFileEncoder(
            url: output, target: AudioTarget(format: .wav, kilobits: 0), sampleRate: input.sampleRate,
            channels: input.channels, bitDepth: 32, isFloat: true)
        try await encodePreview(for: input, with: encoder, isCancelled: isCancelled)
    }

    private static func writePreview(
        for input: AudioInput, target: AudioTarget, to output: URL, isCancelled: () async -> Bool
    ) async throws {
        let encoder = try AudioFileEncoder(
            url: output, target: target, sampleRate: input.sampleRate, channels: input.channels)
        try await encodePreview(for: input, with: encoder, isCancelled: isCancelled)
    }

    private static func encodePreview(
        for input: AudioInput, with encoder: AudioFileEncoder, isCancelled: () async -> Bool
    ) async throws {
        let source = try input.open()
        while let samples = try source.read() {
            try Task.checkCancellation()
            if await isCancelled() { throw CancellationError() }
            try await encoder.write(samples)
        }
        try await encoder.finish()
    }

    public func close() {
        closed = true
        if let directory { staging.remove(directory) }
        directory = nil
    }
}
