import Accelerate
import Formats
import Foundation

/// SPEC 8.10's audio rule, public for video.
public enum AudioTargetSize {
    /// Container framing and index overhead.
    public static let overheadShare = 0.02

    /// The largest fitting supported bitrate.
    public static func kilobits(forBytes bytes: Int64, seconds: Double, supported: [Int]) -> Int? {
        guard seconds > 0, bytes > 0 else { return nil }
        let budget = Double(bytes) * 8 / seconds / 1_000 * (1 - overheadShare)
        return supported.last { Double($0) <= budget }
    }
}

enum AudioJob {
    private static let peakCeiling = -1.0
    /// Gain changes below this are inaudible.
    private static let negligibleDecibels = 0.05
    private static let measureShare = 0.5
    private static let maximumSizeAttempts = 6

    static func run(_ operation: AudioOperation, on url: URL, context: ItemContext) async throws -> ItemResult {
        let input = try AudioInput(url: url)
        switch operation {
        case .convert(let format):
            guard format != input.exactFormat else { return .skipped(.alreadyDone) }
            let target = AudioTarget.defaults(for: format, settings: context.settings.audio)
            return try await replace(url, with: input, target: target, context: context)
        case .compress(.kilobits(let kilobits)):
            let target = AudioTarget(format: try compressedFormat(input, kilobits: kilobits), kilobits: kilobits)
            let result = try await replace(url, with: input, target: target, context: context)
            return try isSmaller(result, than: url) ? result : .skipped(.outputNotSmaller)
        case .compress(.targetBytes(let bytes)):
            return try await compress(url, input: input, toBytes: bytes, context: context)
        case .normalize(let loudness):
            return try await normalize(url, input: input, to: loudness, context: context)
        case .trim(let start, let end):
            return try await trim(url, input: input, start: start, end: end, context: context)
        }
    }

    /// Lossless sources become AAC in M4A.
    private static func compressedFormat(_ input: AudioInput, kilobits: Int?) throws -> AudioFormat {
        let format = input.codec.isLossy && input.sameFormat.isLossy ? input.sameFormat : .m4aAAC
        let supported = try format.supportedKilobits(sampleRate: input.sampleRate, channels: input.channels)
        guard format == .mp3, let kilobits, let lowest = supported.first, kilobits < lowest else { return format }
        // The in-house encoder stops at 128 kbps.
        return .m4aAAC
    }

    private static func compress(_ url: URL, input: AudioInput, toBytes bytes: Int64, context: ItemContext)
        async throws -> ItemResult
    {
        guard try fileSize(url) > bytes else { return .skipped(.alreadyDone) }
        guard let seconds = input.duration, seconds > 0 else { throw EngineError.decodeFailed("unknown duration") }
        let tags = await tags(of: input, context: context)
        let budget = bytes - Int64(tags.artwork?.data.count ?? 0)
        var format = try compressedFormat(input, kilobits: nil)
        var supported = try format.supportedKilobits(sampleRate: input.sampleRate, channels: input.channels)
        var planned = AudioTargetSize.kilobits(forBytes: budget, seconds: seconds, supported: supported)
        if planned == nil, format == .mp3 {
            format = .m4aAAC
            supported = try format.supportedKilobits(sampleRate: input.sampleRate, channels: input.channels)
            planned = AudioTargetSize.kilobits(forBytes: budget, seconds: seconds, supported: supported)
        }
        let candidates = supported.filter { $0 <= planned ?? supported.first ?? 0 }.reversed().prefix(
            maximumSizeAttempts)
        guard !candidates.isEmpty else { throw EngineError.unsupportedCodec("\(format.fileExtension) bitrates") }
        var smallest = Int64.max
        for kilobits in candidates {
            let staged = try context.stagingURL(for: url, name: outputName(for: url, format: format))
            try await encode(
                input, to: AudioTarget(format: format, kilobits: kilobits), at: staged, tags: tags, context: context)
            let size = try fileSize(staged)
            if size <= bytes {
                return .replace(
                    original: url, output: StagedFile(url: staged, name: staged.lastPathComponent, check: .audio))
            }
            smallest = min(smallest, size)
            try FileManager.default.removeItem(at: staged)
        }
        throw EngineError.targetUnreachable(smallestBytes: smallest)
    }

    private static func normalize(_ url: URL, input: AudioInput, to target: Double, context: ItemContext)
        async throws -> ItemResult
    {
        let meter: LoudnessMeter
        do {
            meter = try LoudnessMeter(sampleRate: input.sampleRate, channels: input.channels)
        } catch {
            throw EngineError.fromAudio(error)
        }
        let source = try input.open()
        var measured: Int64 = 0
        while let chunk = try source.read() {
            try Task.checkCancellation()
            meter.add(chunk)
            measured += Int64(chunk.count / input.channels)
            context.progress(measureShare * fraction(measured, of: input.frameCount))
        }
        guard let loudness = meter.integratedLoudness else { return .skipped(.alreadyDone) }
        let wanted = target - loudness
        let gain = min(wanted, peakCeiling - meter.truePeak)
        guard abs(gain) >= negligibleDecibels else { return .skipped(.alreadyDone) }
        if wanted - gain >= negligibleDecibels {
            context.warn(.loudnessLimitedByPeak(reachedLUFS: loudness + gain))
        }
        let output = AudioTarget.defaults(for: input.sameFormat, settings: context.settings.audio)
        return try await replace(
            url, with: input, target: output, gain: Float(pow(10, gain / 20)), progressStart: measureShare,
            context: context)
    }

    private static func trim(_ url: URL, input: AudioInput, start: Double, end: Double, context: ItemContext)
        async throws -> ItemResult
    {
        let first = Int64((max(start, 0) * input.sampleRate).rounded())
        var last = Int64((end * input.sampleRate).rounded())
        if let total = input.frameCount {
            if first == 0, last >= total { return .skipped(.alreadyDone) }
            last = min(last, total)
        }
        guard last > first else { throw EngineError.invalidInput(.malformed("the trim range is empty")) }
        let target = AudioTarget.defaults(for: input.sameFormat, settings: context.settings.audio)
        return try await replace(url, with: input, target: target, frames: first..<last, context: context)
    }

    private static func replace(
        _ url: URL, with input: AudioInput, target: AudioTarget, frames: Range<Int64>? = nil, gain: Float = 1,
        progressStart: Double = 0, context: ItemContext
    ) async throws -> ItemResult {
        let tags = await tags(of: input, context: context)
        if !tags.isEmpty, !target.format.holdsTags { context.warn(.metadataDropped) }
        let staged = try context.stagingURL(for: url, name: outputName(for: url, format: target.format))
        try await encode(
            input, to: target, at: staged, tags: tags, frames: frames, gain: gain, progressStart: progressStart,
            context: context)
        return .replace(original: url, output: StagedFile(url: staged, name: staged.lastPathComponent, check: .audio))
    }

    /// Unreadable tags are dropped with a warning.
    private static func tags(of input: AudioInput, context: ItemContext) async -> AudioTags {
        do {
            return try await input.tags()
        } catch {
            context.warn(.metadataDropped)
            return AudioTags()
        }
    }

    private static func encode(
        _ input: AudioInput, to target: AudioTarget, at staged: URL, tags: AudioTags, frames: Range<Int64>? = nil,
        gain: Float = 1, progressStart: Double = 0, context: ItemContext
    ) async throws {
        let source = try input.open()
        let encoder = try AudioFileEncoder(
            url: staged, target: target, sampleRate: input.sampleRate, channels: input.channels,
            bitDepth: input.bitDepth, isFloat: input.isFloat, tags: tags)
        let channels = input.channels
        let total = frames.map { Int64($0.count) } ?? input.frameCount
        var position: Int64 = 0
        var written: Int64 = 0
        while let chunk = try source.read() {
            try Task.checkCancellation()
            let count = Int64(chunk.count / channels)
            let range = frames ?? 0..<Int64.max
            let lower = max(range.lowerBound - position, 0)
            let upper = min(range.upperBound - position, count)
            position += count
            guard upper > lower else {
                if position >= range.upperBound { break }
                continue
            }
            var samples = Array(chunk[Int(lower) * channels..<Int(upper) * channels])
            if gain != 1 { vDSP.multiply(gain, samples, result: &samples) }
            try await encoder.write(samples)
            written += upper - lower
            context.progress(progressStart + (1 - progressStart) * fraction(written, of: total))
        }
        try await encoder.finish()
    }

    private static func outputName(for url: URL, format: AudioFormat) -> String {
        let pathExtension = url.pathExtension
        let kept = format.keptExtensions.contains(pathExtension.lowercased()) ? pathExtension : format.fileExtension
        return url.deletingPathExtension().lastPathComponent + "." + kept
    }

    private static func fraction(_ done: Int64, of total: Int64?) -> Double {
        guard let total, total > 0 else { return 0 }
        return Double(done) / Double(total)
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    private static func isSmaller(_ result: ItemResult, than original: URL) throws -> Bool {
        guard case .replace(_, let output) = result else { return true }
        return try fileSize(output.url) < fileSize(original)
    }
}

extension AudioInput {
    /// What same-format operations write.
    var sameFormat: AudioFormat {
        switch (container, codec) {
        case (.mp3, _): .mp3
        case (.adts, _): .aac
        case (.wave, _): .wav
        case (.aiff, _): .aiff
        case (.flac, _): .flac
        case (.ogg, .opus): .opus
        case (.ogg, _): .ogg
        case (.caf, .pcm): .cafPCM
        case (.caf, .alac), (.caf, .flac): .cafALAC
        case (.mpeg4, .alac), (.mpeg4, .flac), (.mpeg4, .pcm): .m4aALAC
        default: .m4aAAC
        }
    }
}

extension AudioFormat {
    var holdsTags: Bool {
        switch self {
        case .mp3, .m4aAAC, .m4aALAC, .flac, .ogg, .opus: true
        default: false
        }
    }
}
