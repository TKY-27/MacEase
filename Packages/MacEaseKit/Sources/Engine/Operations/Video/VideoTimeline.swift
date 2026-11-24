import Formats
import Foundation

public struct VideoEditSource: Codable, Hashable, Sendable {
    public let url: URL
    public let duration: Double
    public let stamp: MediaSourceStamp
    public let reversedOrigin: ReversedSegmentOrigin?
    public let reversedFrames: [ReversedSourceFrame]?

    public init(
        url: URL, duration: Double, stamp: MediaSourceStamp,
        reversedOrigin: ReversedSegmentOrigin? = nil, reversedFrames: [ReversedSourceFrame]? = nil
    ) {
        self.url = url
        self.duration = duration
        self.stamp = stamp
        self.reversedOrigin = reversedOrigin
        self.reversedFrames = reversedFrames
    }
}

public struct ReversedSourceFrame: Codable, Hashable, Sendable {
    public let stagedStart: Double
    public let stagedEnd: Double
    public let sourceStart: Double
    public let sourceEnd: Double

    public init(stagedStart: Double, stagedEnd: Double, sourceStart: Double, sourceEnd: Double) {
        self.stagedStart = stagedStart
        self.stagedEnd = stagedEnd
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
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

    func mappedTime(_ seconds: Double, stagedDuration: Double, toOriginal: Bool) -> Double {
        let lower = toOriginal ? 0 : start
        let upper = toOriginal ? stagedDuration : end
        let fraction = (min(max(seconds, lower), upper) - lower) / (upper - lower)
        let result = toOriginal ? end - fraction * (end - start) : stagedDuration * (1 - fraction)
        return toOriginal ? min(end, max(start, result)) : min(stagedDuration, max(0, result))
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
    public let music: BackgroundMusic?
    public let duration: Double
    private let starts: [Double]
    private let sourceDurations: [Double]
    private let reversedFrames: [[ReversedSourceFrame]]

    public init(edit: VideoEdit, sourceDuration: Double) throws {
        guard sourceDuration.isFinite, sourceDuration > 0 else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        if edit.segments == nil, !edit.overlays.isEmpty {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        var segments =
            edit.segments ?? [
                VideoSegment(
                    start: edit.start, end: edit.end ?? sourceDuration, speed: edit.speed,
                    volume: edit.volume, adjustments: edit.adjustments)
            ]
        if let sources = edit.sources {
            for index in segments.indices where sources.indices.contains(segments[index].sourceIndex) {
                if let origin = sources[segments[index].sourceIndex].reversedOrigin {
                    segments[index].reversedOrigin = origin
                }
            }
        }
        guard !segments.isEmpty else { throw EngineError.invalidInput(.emptyInput) }
        var duration = 0.0
        var starts: [Double] = []
        var identifiers = Set<UUID>()
        let durations = edit.sources?.map(\.duration) ?? [sourceDuration]
        guard !durations.isEmpty, durations.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        for (index, source) in (edit.sources ?? []).enumerated() {
            guard let frames = source.reversedFrames else { continue }
            guard let origin = source.reversedOrigin, durations.indices.contains(origin.sourceIndex),
                origin.sourceIndex != index, !frames.isEmpty
            else {
                throw EngineError.invalidInput(.invalidNumericParameter)
            }
            for frame in frames {
                guard [frame.stagedStart, frame.stagedEnd, frame.sourceStart, frame.sourceEnd].allSatisfy(\.isFinite),
                    frame.stagedStart >= 0, frame.stagedStart < frame.stagedEnd,
                    frame.stagedEnd <= source.duration + Self.rangeMergeTolerance,
                    frame.sourceStart >= 0, frame.sourceStart < frame.sourceEnd,
                    frame.sourceEnd <= durations[origin.sourceIndex] + Self.rangeMergeTolerance
                else { throw EngineError.invalidInput(.invalidNumericParameter) }
            }
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
                guard durations.indices.contains(origin.sourceIndex),
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
        try edit.music?.validate()
        self.segments = segments
        self.overlays = edit.overlays
        self.music = edit.music
        self.duration = duration
        self.starts = starts
        sourceDurations = durations
        reversedFrames = edit.sources?.map { $0.reversedFrames ?? [] } ?? [[]]
    }

    public func overlays(
        at outputSeconds: Double, sourceRange: ClosedRange<Double>? = nil, segmentID: UUID? = nil
    ) -> [EditOverlay] {
        guard !overlays.isEmpty else { return [] }
        let index: Int
        if let segmentID {
            guard let selected = segments.firstIndex(where: { $0.id == segmentID }) else { return [] }
            index = selected
        } else {
            index = self.index(at: outputSeconds)
        }
        let segment = segments[index]
        let source = sourceRange?.lowerBound ?? sourceTime(at: outputSeconds)
        let upper = sourceRange?.upperBound ?? source
        return overlays.compactMap { timed in
            let lowerBound: Double
            let upperBound: Double
            if timed.sourceIndex == segment.sourceIndex {
                lowerBound = source
                upperBound = upper
            } else if let origin = segment.reversedOrigin, timed.sourceIndex == origin.sourceIndex {
                let duration = sourceDurations[segment.sourceIndex]
                let frames = reversedFrames[segment.sourceIndex].filter {
                    if case .redaction = timed.overlay.mark {
                        return $0.stagedStart <= upper && $0.stagedEnd >= source
                    }
                    return $0.stagedStart <= source && $0.stagedEnd > source
                }
                lowerBound =
                    frames.map(\.sourceStart).min()
                    ?? origin.mappedTime(upper, stagedDuration: duration, toOriginal: true)
                upperBound =
                    frames.map(\.sourceEnd).max()
                    ?? origin.mappedTime(source, stagedDuration: duration, toOriginal: true)
            } else {
                return nil
            }
            if case .redaction = timed.overlay.mark, sourceRange != nil {
                // Boundary uncertainty must favor privacy.
                return timed.start <= upperBound && timed.end >= lowerBound ? timed.overlay : nil
            }
            return lowerBound >= timed.start && lowerBound < timed.end ? timed.overlay : nil
        }
    }

    public func outputRanges(of overlay: TimedOverlay) -> [ClosedRange<Double>] {
        guard overlay.start.isFinite, overlay.end.isFinite, overlay.start < overlay.end else { return [] }
        var ranges: [ClosedRange<Double>] = []
        for (index, segment) in segments.enumerated() {
            let sourceRange: Range<Double>
            if segment.sourceIndex == overlay.sourceIndex {
                sourceRange = overlay.start..<overlay.end
            } else if let origin = segment.reversedOrigin, origin.sourceIndex == overlay.sourceIndex {
                let duration = sourceDurations[segment.sourceIndex]
                let lower = origin.mappedTime(overlay.end, stagedDuration: duration, toOriginal: false)
                let upper = origin.mappedTime(overlay.start, stagedDuration: duration, toOriginal: false)
                guard lower < upper else { continue }
                sourceRange = lower..<upper
            } else {
                continue
            }
            let outStart: Double
            let outEnd: Double
            if segment.freezeDuration != nil {
                guard sourceRange.contains(segment.start) else { continue }
                outStart = starts[index]
                outEnd = starts[index] + segment.outputDuration
            } else {
                let lower = max(segment.start, sourceRange.lowerBound)
                let upper = min(segment.end, sourceRange.upperBound)
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

extension VideoEdit {
    func openedSources(
        primaryURL: URL, omittedStreams: Set<UnpreservedStream> = [],
        omissions: [URL: StreamOmission] = [:], context: ItemContext? = nil
    ) async throws -> (edit: VideoEdit, inputs: [MediaInput]) {
        try sourceStamp?.validate(primaryURL)
        var resolved = self
        var inputs: [MediaInput] = []
        if let sources {
            guard !sources.isEmpty else { throw EngineError.invalidInput(.emptyInput) }
            var validated: [VideoEditSource] = []
            for source in sources {
                try source.stamp.validate(source.url)
                let input = try await MediaInput.open(source.url)
                let consent =
                    source.url == primaryURL
                    ? omittedStreams : omissions[source.url]?.streams(covering: source.stamp) ?? []
                try input.requirePreservableStreams(omitting: consent, context: context)
                guard input.video != nil else { throw EngineError.decodeFailed("no video track") }
                inputs.append(input)
                validated.append(
                    VideoEditSource(
                        url: source.url, duration: Double(input.duration) / Double(Nanoseconds.perSecond),
                        stamp: source.stamp, reversedOrigin: source.reversedOrigin,
                        reversedFrames: source.reversedFrames))
            }
            resolved.sources = validated
        } else {
            let input = try await MediaInput.open(primaryURL)
            try input.requirePreservableStreams(omitting: omittedStreams, context: context)
            guard input.video != nil else { throw EngineError.decodeFailed("no video track") }
            inputs = [input]
        }
        return (resolved, inputs)
    }
}
