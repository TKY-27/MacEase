import Foundation

public enum MediaCodec: Hashable, Sendable {
    case h264
    case hevc
    case vp8
    case vp9
    case av1
    case mjpeg
    case mpeg4Part2
    case aac
    case opus
    case vorbis
    case flac
    case mp3
    case ac3
    /// `float` means 32 or 64 bits.
    case pcm(bits: Int, float: Bool, bigEndian: Bool)
    /// Named for the failure message.
    case unsupported(String)

    public var isVideo: Bool {
        switch self {
        case .h264, .hevc, .vp8, .vp9, .av1, .mjpeg, .mpeg4Part2: true
        default: false
        }
    }

    public var displayName: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .vp8: "VP8"
        case .vp9: "VP9"
        case .av1: "AV1"
        case .mjpeg: "Motion JPEG"
        case .mpeg4Part2: "MPEG-4 Part 2"
        case .aac: "AAC"
        case .opus: "Opus"
        case .vorbis: "Vorbis"
        case .flac: "FLAC"
        case .mp3: "MP3"
        case .ac3: "AC-3"
        case .pcm: "PCM"
        case .unsupported(let name): name
        }
    }
}

public struct MediaTrack: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case video(width: Int, height: Int)
        case audio(sampleRate: Double, channels: Int)
    }

    public var number: Int
    public var kind: Kind
    public var codec: MediaCodec
    /// avcC, hvcC, AudioSpecificConfig, Xiph headers or similar.
    public var codecPrivate: Data?
    public var defaultDuration: Int64?
    public var language: String?
    /// VP9 alpha travels in BlockAdditions.
    public var hasAlpha = false
    public var codecDelay: Int64 = 0
    public var seekPreRoll: Int64 = 0

    public init(number: Int, kind: Kind, codec: MediaCodec, codecPrivate: Data? = nil) {
        self.number = number
        self.kind = kind
        self.codec = codec
        self.codecPrivate = codecPrivate
    }

    public var isVideo: Bool {
        if case .video = kind { true } else { false }
    }
}

/// Timestamps and durations are nanoseconds.
public struct MediaPacket: Hashable, Sendable {
    public var track: Int
    /// Presentation time.
    public var timestamp: Int64
    /// Differs from `timestamp` with reordered frames.
    public var decodeTimestamp: Int64?
    public var duration: Int64?
    public var isKeyframe: Bool
    public var payload: Data
    public var additional: Data?
    /// Trailing padding the decoder drops.
    public var discardPadding: Int64?

    public init(
        track: Int, timestamp: Int64, decodeTimestamp: Int64? = nil, duration: Int64? = nil, isKeyframe: Bool,
        payload: Data, additional: Data? = nil
    ) {
        self.track = track
        self.timestamp = timestamp
        self.decodeTimestamp = decodeTimestamp
        self.duration = duration
        self.isKeyframe = isKeyframe
        self.payload = payload
        self.additional = additional
    }
}

public protocol MediaDemuxer {
    var tracks: [MediaTrack] { get }
    /// Nanoseconds, when the container states it.
    var duration: Int64? { get }
    /// File order; `nil` at the end.
    mutating func nextPacket() throws -> MediaPacket?
}

public protocol MediaMuxer {
    mutating func write(_ packet: MediaPacket) throws
    mutating func finish() throws
}

public enum Nanoseconds {
    public static let perSecond: Int64 = 1_000_000_000
    public static let perMillisecond: Int64 = 1_000_000
    /// Below `Int64.max` by more than Double error.
    private static let limit = 9e18

    /// `value × numerator ÷ denominator` without intermediate overflow.
    static func scale(_ value: Int64, by numerator: Int64, over denominator: Int64) throws -> Int64 {
        let estimate = Double(value) * Double(numerator) / Double(denominator)
        guard denominator > 0, abs(estimate) < limit else { throw FormatError.corrupt("timestamp out of range") }
        return denominator.dividingFullWidth(value.multipliedFullWidth(by: numerator)).quotient
    }

    static func from(seconds: Double) throws -> Int64 {
        let nanoseconds = seconds * Double(perSecond)
        guard nanoseconds.isFinite, abs(nanoseconds) < limit else { throw FormatError.corrupt("time out of range") }
        return Int64(nanoseconds)
    }
}
