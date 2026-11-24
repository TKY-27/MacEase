import Formats
import Foundation

public struct VideoEditSource: Codable, Hashable, Sendable {
    public let url: URL
    public let duration: Double
    public let stamp: MediaSourceStamp

    public init(url: URL, duration: Double, stamp: MediaSourceStamp) {
        self.url = url
        self.duration = duration
        self.stamp = stamp
    }
}

public struct ReversedSegmentOrigin: Codable, Hashable, Sendable {
    public var sourceIndex: Int
    public var start: Double
    public var end: Double

    public init(sourceIndex: Int, start: Double, end: Double) {
        self.sourceIndex = sourceIndex
        self.start = start
        self.end = end
    }
}

public struct VideoSegment: Codable, Hashable, Sendable, Identifiable {
    public static let freezeDurationRange = 0.1...30.0

    public var id: UUID
    public var sourceIndex: Int
    public var start: Double
    public var end: Double
    public var speed: Double
    public var volume: Double
    public var adjustments: MediaAdjustments
    /// Output seconds.
    public var fadeIn = 0.0
    public var fadeOut = 0.0
    public var freezeDuration: Double?
    public var reversedOrigin: ReversedSegmentOrigin?

    public var isFreeze: Bool { freezeDuration != nil }
    public var isReversed: Bool { reversedOrigin != nil }

    public var outputDuration: Double {
        freezeDuration ?? (end - start) / speed
    }

    public init(
        id: UUID = UUID(), start: Double, end: Double, speed: Double = 1,
        volume: Double = 1, adjustments: MediaAdjustments = MediaAdjustments(), sourceIndex: Int = 0,
        freezeDuration: Double? = nil, reversedOrigin: ReversedSegmentOrigin? = nil
    ) {
        self.id = id
        self.sourceIndex = sourceIndex
        self.start = start
        self.end = end
        self.speed = speed
        self.volume = volume
        self.adjustments = adjustments
        self.freezeDuration = freezeDuration
        self.reversedOrigin = reversedOrigin
    }
    private enum CodingKeys: String, CodingKey {
        case id, sourceIndex, start, end, speed, volume, adjustments, fadeIn, fadeOut, freezeDuration, reversedOrigin
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        sourceIndex = try values.decodeIfPresent(Int.self, forKey: .sourceIndex) ?? 0
        start = try values.decode(Double.self, forKey: .start)
        end = try values.decode(Double.self, forKey: .end)
        speed = try values.decode(Double.self, forKey: .speed)
        volume = try values.decode(Double.self, forKey: .volume)
        adjustments = try values.decode(MediaAdjustments.self, forKey: .adjustments)
        fadeIn = try values.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try values.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
        freezeDuration = try values.decodeIfPresent(Double.self, forKey: .freezeDuration)
        reversedOrigin = try values.decodeIfPresent(ReversedSegmentOrigin.self, forKey: .reversedOrigin)
    }
}

public struct VideoTimeline: Hashable, Sendable {
    private static let rangeMergeTolerance = 1e-9

    public let segments: [VideoSegment]
    public let overlays: [TimedOverlay]
    public let duration: Double
    private let starts: [Double]

    public init(edit: VideoEdit, sourceDuration: Double) throws {
        guard sourceDuration.isFinite, sourceDuration > 0 else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        if edit.segments == nil, !edit.overlays.isEmpty {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        let segments =
            edit.segments ?? [
                VideoSegment(
                    start: edit.start, end: edit.end ?? sourceDuration, speed: edit.speed,
                    volume: edit.volume, adjustments: edit.adjustments)
            ]
        guard !segments.isEmpty else { throw EngineError.invalidInput(.emptyInput) }
        var duration = 0.0
        var starts: [Double] = []
        var identifiers = Set<UUID>()
        let durations = edit.sources?.map(\.duration) ?? [sourceDuration]
        guard !durations.isEmpty, durations.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        for segment in segments {
            guard durations.indices.contains(segment.sourceIndex) else {
                throw EngineError.invalidInput(.invalidNumericParameter)
            }
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0,
                segment.end > segment.start, segment.end <= durations[segment.sourceIndex],
                segment.speed.isFinite, VideoEdit.speedRange.contains(segment.speed),
                segment.volume.isFinite, (0...1).contains(segment.volume),
                identifiers.insert(segment.id).inserted
            else { throw EngineError.invalidInput(.invalidNumericParameter) }
            try segment.adjustments.validate()
            try FadeRamp.validate(fadeIn: segment.fadeIn, fadeOut: segment.fadeOut)
            if let freezeDuration = segment.freezeDuration {
                guard freezeDuration.isFinite, VideoSegment.freezeDurationRange.contains(freezeDuration),
                    segment.speed == 1, segment.volume == 0
                else { throw EngineError.invalidInput(.invalidNumericParameter) }
            }
            if let origin = segment.reversedOrigin {
                guard segment.freezeDuration == nil,
                    durations.indices.contains(origin.sourceIndex),
                    origin.sourceIndex != segment.sourceIndex,
                    origin.start.isFinite, origin.end.isFinite,
                    origin.start >= 0, origin.end > origin.start, origin.end <= durations[origin.sourceIndex]
                else { throw EngineError.invalidInput(.invalidNumericParameter) }
            }
            let start = try Nanoseconds.from(seconds: segment.start)
            let end = try Nanoseconds.from(seconds: segment.end)
            guard end > start else { throw EngineError.invalidInput(.invalidNumericParameter) }
            starts.append(duration)
            duration += segment.outputDuration
        }
        guard try Nanoseconds.from(seconds: duration) > 0 else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        guard edit.overlays.count <= EditOverlay.maximumCount else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        var overlayIDs = Set<UUID>()
        for timed in edit.overlays {
            guard overlayIDs.insert(timed.id).inserted,
                durations.indices.contains(timed.sourceIndex),
                timed.start.isFinite, timed.end.isFinite,
                timed.start >= 0, timed.start < timed.end, timed.end <= durations[timed.sourceIndex]
            else { throw EngineError.invalidInput(.invalidNumericParameter) }
            try timed.overlay.validate()
        }
        self.segments = segments
        self.overlays = edit.overlays
        self.duration = duration
        self.starts = starts
    }

    public func overlays(at outputSeconds: Double) -> [EditOverlay] {
        guard !overlays.isEmpty else { return [] }
        let segment = segment(at: outputSeconds)
        let source = sourceTime(at: outputSeconds)
        return overlays.compactMap { timed in
            timed.sourceIndex == segment.sourceIndex && source >= timed.start && source < timed.end
                ? timed.overlay : nil
        }
    }

    public func outputRanges(of overlay: TimedOverlay) -> [ClosedRange<Double>] {
        guard overlay.start.isFinite, overlay.end.isFinite, overlay.start < overlay.end else { return [] }
        var ranges: [ClosedRange<Double>] = []
        for (index, segment) in segments.enumerated() {
            guard segment.sourceIndex == overlay.sourceIndex else { continue }
            let outStart: Double
            let outEnd: Double
            if segment.freezeDuration != nil {
                guard segment.start >= overlay.start, segment.start < overlay.end else { continue }
                outStart = starts[index]
                outEnd = starts[index] + segment.outputDuration
            } else {
                let lower = max(segment.start, overlay.start)
                let upper = min(segment.end, overlay.end)
                guard lower < upper else { continue }
                outStart = starts[index] + (lower - segment.start) / segment.speed
                outEnd = starts[index] + (upper - segment.start) / segment.speed
            }
            if let previous = ranges.last, outStart <= previous.upperBound + Self.rangeMergeTolerance {
                ranges[ranges.count - 1] = previous.lowerBound...max(previous.upperBound, outEnd)
            } else {
                ranges.append(outStart...outEnd)
            }
        }
        return ranges
    }

    public func segment(at outputSeconds: Double) -> VideoSegment {
        segments[index(at: outputSeconds)]
    }

    public func sourceTime(at outputSeconds: Double) -> Double {
        let index = index(at: outputSeconds)
        let segment = segments[index]
        if segment.freezeDuration != nil { return segment.start }
        let time = outputSeconds.isFinite ? min(max(0, outputSeconds), duration) : 0
        return min(segment.end, segment.start + max(0, time - starts[index]) * segment.speed)
    }

    public func outputTime(for sourceSeconds: Double, segmentID: UUID) -> Double? {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }), sourceSeconds.isFinite else {
            return nil
        }
        let segment = segments[index]
        guard (segment.start...segment.end).contains(sourceSeconds) else { return nil }
        if segment.freezeDuration != nil { return starts[index] }
        return starts[index] + (sourceSeconds - segment.start) / segment.speed
    }

    public var hasFades: Bool { segments.contains { $0.fadeIn > 0 || $0.fadeOut > 0 } }

    public func fade(at index: Int) -> FadeRamp {
        let segment = segments[index]
        return FadeRamp(
            duration: outputEnd(at: index) - outputStart(at: index), fadeIn: segment.fadeIn, fadeOut: segment.fadeOut)
    }

    public func fadeGain(at outputSeconds: Double) -> Double {
        let index = index(at: outputSeconds)
        return fade(at: index).gain(at: outputSeconds - outputStart(at: index))
    }

    func outputStart(at index: Int) -> Double { starts[index] }

    func outputEnd(at index: Int) -> Double {
        index + 1 < starts.count ? starts[index + 1] : duration
    }

    func index(at outputSeconds: Double) -> Int {
        guard outputSeconds.isFinite else { return 0 }
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if starts[middle] <= outputSeconds { lower = middle + 1 } else { upper = middle }
        }
        return max(0, lower - 1)
    }
}
