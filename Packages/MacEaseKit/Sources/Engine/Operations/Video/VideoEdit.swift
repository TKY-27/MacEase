import Formats
import Foundation

public struct VideoEdit: Codable, Hashable, Sendable {
    public static let speedRange = 0.5...4.0
    public var start: Double
    public var end: Double?
    public var speed: Double
    public var resize: VideoResize?
    public var trimMode: TrimMode
    public var geometry = EditGeometry()
    public var adjustments = MediaAdjustments()
    public var volume = 1.0
    public var sourceStamp: MediaSourceStamp?
    public var segments: [VideoSegment]?
    public var sources: [VideoEditSource]?

    public var changesColor: Bool {
        segments.map { $0.contains { !$0.adjustments.isIdentity } } ?? !adjustments.isIdentity
    }

    public var changesAppearance: Bool { !geometry.isIdentity || changesColor }

    public init(
        start: Double = 0, end: Double? = nil, speed: Double = 1,
        resize: VideoResize? = nil, trimMode: TrimMode = .exact
    ) {
        self.start = start
        self.end = end
        self.speed = speed
        self.resize = resize
        self.trimMode = trimMode
    }

    private enum CodingKeys: String, CodingKey {
        case start, end, speed, resize, trimMode, geometry, adjustments, volume, sourceStamp, segments, sources
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        start = try values.decode(Double.self, forKey: .start)
        end = try values.decodeIfPresent(Double.self, forKey: .end)
        speed = try values.decode(Double.self, forKey: .speed)
        resize = try values.decodeIfPresent(VideoResize.self, forKey: .resize)
        trimMode = try values.decode(TrimMode.self, forKey: .trimMode)
        geometry = try values.decodeIfPresent(EditGeometry.self, forKey: .geometry) ?? EditGeometry()
        adjustments = try values.decodeIfPresent(MediaAdjustments.self, forKey: .adjustments) ?? MediaAdjustments()
        volume = try values.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        sourceStamp = try values.decodeIfPresent(MediaSourceStamp.self, forKey: .sourceStamp)
        segments = try values.decodeIfPresent([VideoSegment].self, forKey: .segments)
        sources = try values.decodeIfPresent([VideoEditSource].self, forKey: .sources)
    }
}

struct VideoTiming {
    let start: Int64
    let speed: Double

    init(start: Int64, speed: Double) throws {
        guard VideoEdit.speedRange.contains(speed), speed.isFinite else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        self.start = start
        self.speed = speed
    }

    func sourceTime(_ output: Int64) throws -> Int64 {
        try mapped(output, multiplier: speed)
    }

    func outputTime(_ source: Int64) throws -> Int64 {
        try mapped(source, multiplier: 1 / speed)
    }

    private func mapped(_ timestamp: Int64, multiplier: Double) throws -> Int64 {
        let (offset, overflow) = timestamp.subtractingReportingOverflow(start)
        guard !overflow, let scaled = Int64(exactly: (Double(offset) * multiplier).rounded()) else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        let (result, resultOverflow) = start.addingReportingOverflow(scaled)
        guard !resultOverflow else { throw EngineError.invalidInput(.invalidNumericParameter) }
        return result
    }
}

extension VideoResize {
    public func dimensions(width: Int, height: Int) throws -> (width: Int, height: Int) {
        let result = try outputSize(PixelSize(width: width, height: height))
        return (result.width, result.height)
    }

    func outputSize(_ display: PixelSize) throws -> PixelSize {
        guard display.width > 0, display.height > 0 else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        let scale: Double =
            switch self {
            case .percent(let percent): Double(percent) / 100
            case .lines(let lines): Double(lines) / Double(min(display.width, display.height))
            case .size(let width, let height):
                min(Double(width) / Double(display.width), Double(height) / Double(display.height))
            }
        guard scale.isFinite, scale > 0 else { throw EngineError.invalidInput(.invalidNumericParameter) }
        guard scale < 1 else { return display }
        guard let width = Int(exactly: (Double(display.width) * scale).rounded()),
            let height = Int(exactly: (Double(display.height) * scale).rounded())
        else { throw EngineError.invalidInput(.invalidNumericParameter) }
        return PixelSize(width: width, height: height).evened()
    }
}
