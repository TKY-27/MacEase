import Formats
import Foundation

public struct SilenceRule: Codable, Hashable, Sendable {
    public static let thresholdRange: ClosedRange<Double> = -60...(-20)
    public static let minimumDurationRange: ClosedRange<Double> = 0.3...5.0
    public static let defaultThreshold = -40.0
    public static let defaultMinimumDuration = 0.75
    public static let padding = 0.12

    public var threshold: Double
    public var minimumDuration: Double

    public init(
        threshold: Double = defaultThreshold,
        minimumDuration: Double = defaultMinimumDuration
    ) {
        self.threshold = threshold
        self.minimumDuration = minimumDuration
    }

    public func validate() throws {
        guard threshold.isFinite, Self.thresholdRange.contains(threshold),
            minimumDuration.isFinite, Self.minimumDurationRange.contains(minimumDuration)
        else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
    }
}

public struct AudioLevels: Hashable, Sendable {
    public static let defaultWindow = 0.02
    private static let durationTolerance = 1e-9

    public let decibels: [Double]
    public let window: Double
    public let duration: Double

    public init(decibels: [Double], window: Double, duration: Double) {
        self.decibels = decibels
        self.window = window
        self.duration = duration
    }

    public func silentRanges(_ rule: SilenceRule) -> [Range<Double>] {
        guard window.isFinite, window > 0, duration.isFinite, duration > 0, !decibels.isEmpty else { return [] }
        guard rule.threshold.isFinite, SilenceRule.thresholdRange.contains(rule.threshold),
            rule.minimumDuration.isFinite, SilenceRule.minimumDurationRange.contains(rule.minimumDuration)
        else { return [] }
        var ranges: [Range<Double>] = []
        var runStart: Int?
        for index in 0...decibels.count {
            let silent = index < decibels.count && decibels[index] <= rule.threshold
            if silent {
                if runStart == nil { runStart = index }
                continue
            }
            guard let startIndex = runStart else { continue }
            runStart = nil
            let rawStart = Double(startIndex) * window
            guard rawStart < duration else { continue }
            let unclampedEnd = Double(index) * window
            let atEnd = unclampedEnd >= duration - Self.durationTolerance
            let rawEnd = atEnd ? duration : unclampedEnd
            guard rawEnd - rawStart + Self.durationTolerance >= rule.minimumDuration else { continue }
            let cutStart = startIndex == 0 ? 0 : rawStart + SilenceRule.padding
            let cutEnd = atEnd ? duration : rawEnd - SilenceRule.padding
            guard cutStart < cutEnd else { continue }
            ranges.append(cutStart..<cutEnd)
        }
        return ranges
    }
}

public enum SilenceRemoval {
    private static let durationTolerance = 1e-9

    public static func segments(
        _ segments: [VideoSegment],
        silences: [Int: [Range<Double>]],
        minimumKept: Double
    ) throws -> [VideoSegment] {
        guard minimumKept.isFinite, minimumKept >= 0 else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        var result: [VideoSegment] = []
        for segment in segments {
            guard segment.start.isFinite, segment.end.isFinite,
                segment.start >= 0, segment.end > segment.start
            else {
                throw EngineError.invalidInput(.invalidNumericParameter)
            }
            if segment.volume == 0 {
                result.append(segment)
                continue
            }
            let merged = try clampedMergedSilences(for: segment, from: silences[segment.sourceIndex] ?? [])
            if merged.isEmpty {
                result.append(segment)
                continue
            }
            result += try cut(segment, silences: merged, minimumKept: minimumKept)
        }
        guard !result.isEmpty else { throw EngineError.invalidInput(.emptyInput) }
        return result
    }

    private static func clampedMergedSilences(
        for segment: VideoSegment,
        from ranges: [Range<Double>]
    ) throws -> [Range<Double>] {
        var clamped: [Range<Double>] = []
        for range in ranges {
            guard range.lowerBound.isFinite, range.upperBound.isFinite else {
                throw EngineError.invalidInput(.invalidNumericParameter)
            }
            let lower = max(segment.start, range.lowerBound)
            let upper = min(segment.end, range.upperBound)
            if lower < upper { clamped.append(lower..<upper) }
        }
        guard !clamped.isEmpty else { return [] }
        clamped.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Double>] = [clamped[0]]
        for range in clamped.dropFirst() {
            let lastIndex = merged.count - 1
            if range.lowerBound <= merged[lastIndex].upperBound {
                merged[lastIndex] = merged[lastIndex].lowerBound..<max(merged[lastIndex].upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func cut(
        _ segment: VideoSegment,
        silences: [Range<Double>],
        minimumKept: Double
    ) throws -> [VideoSegment] {
        var kept: [Range<Double>] = []
        var cursor = segment.start
        for silence in silences {
            if silence.lowerBound > cursor {
                try appendIfKept(cursor..<silence.lowerBound, minimumKept: minimumKept, to: &kept)
            }
            cursor = silence.upperBound
        }
        if segment.end > cursor {
            try appendIfKept(cursor..<segment.end, minimumKept: minimumKept, to: &kept)
        }
        return kept.enumerated().map { index, piece in
            var copy = segment
            copy.id = UUID()
            copy.start = piece.lowerBound
            copy.end = piece.upperBound
            copy.fadeIn = index == 0 ? segment.fadeIn : 0
            copy.fadeOut = index == kept.count - 1 ? segment.fadeOut : 0
            return copy
        }
    }

    private static func appendIfKept(
        _ piece: Range<Double>,
        minimumKept: Double,
        to kept: inout [Range<Double>]
    ) throws {
        let span = piece.upperBound - piece.lowerBound
        guard span > 0, span + durationTolerance >= minimumKept else { return }
        let start = try Nanoseconds.from(seconds: piece.lowerBound)
        let end = try Nanoseconds.from(seconds: piece.upperBound)
        if end > start { kept.append(piece) }
    }
}
