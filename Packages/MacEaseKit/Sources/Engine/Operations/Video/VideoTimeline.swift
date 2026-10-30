import Formats
import Foundation

public struct VideoSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var speed: Double
    public var volume: Double
    public var adjustments: MediaAdjustments

    public init(
        id: UUID = UUID(), start: Double, end: Double, speed: Double = 1,
        volume: Double = 1, adjustments: MediaAdjustments = MediaAdjustments()
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.speed = speed
        self.volume = volume
        self.adjustments = adjustments
    }
}

public struct VideoTimeline: Hashable, Sendable {
    public let segments: [VideoSegment]
    public let duration: Double
    private let starts: [Double]

    public init(edit: VideoEdit, sourceDuration: Double) throws {
        guard sourceDuration.isFinite, sourceDuration > 0 else {
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
        for segment in segments {
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0,
                segment.end > segment.start, segment.end <= sourceDuration,
                segment.speed.isFinite, VideoEdit.speedRange.contains(segment.speed),
                segment.volume.isFinite, (0...1).contains(segment.volume),
                identifiers.insert(segment.id).inserted
            else { throw EngineError.invalidInput(.invalidNumericParameter) }
            try segment.adjustments.validate()
            let start = try Nanoseconds.from(seconds: segment.start)
            let end = try Nanoseconds.from(seconds: segment.end)
            guard end > start else { throw EngineError.invalidInput(.invalidNumericParameter) }
            starts.append(duration)
            duration += (segment.end - segment.start) / segment.speed
        }
        guard try Nanoseconds.from(seconds: duration) > 0 else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        self.segments = segments
        self.duration = duration
        self.starts = starts
    }

    public func segment(at outputSeconds: Double) -> VideoSegment {
        segments[index(at: outputSeconds)]
    }

    public func sourceTime(at outputSeconds: Double) -> Double {
        let index = index(at: outputSeconds)
        let segment = segments[index]
        let time = outputSeconds.isFinite ? min(max(0, outputSeconds), duration) : 0
        return min(segment.end, segment.start + max(0, time - starts[index]) * segment.speed)
    }

    public func outputTime(for sourceSeconds: Double, segmentID: UUID) -> Double? {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }), sourceSeconds.isFinite else {
            return nil
        }
        let segment = segments[index]
        guard (segment.start...segment.end).contains(sourceSeconds) else { return nil }
        return starts[index] + (sourceSeconds - segment.start) / segment.speed
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
