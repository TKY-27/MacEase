import CoreGraphics
import CoreMedia
import Foundation

public enum MediaCodec: Hashable, Sendable {
    case h264
    case hevc
    case vp8
    case vp9
    case av1
    case mjpeg
    case mpeg4Part2
    case prores
    case aac
    case alac
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
        case .h264, .hevc, .vp8, .vp9, .av1, .mjpeg, .mpeg4Part2, .prores: true
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
        case .prores: "ProRes"
        case .alac: "ALAC"
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

public struct VideoDisplayGeometry: Hashable, Sendable {
    public var displayWidth: Int?
    public var displayHeight: Int?
    public var displayUnit: Int
    public var cropTop: Int
    public var cropBottom: Int
    public var cropLeft: Int
    public var cropRight: Int

    public init(
        displayWidth: Int? = nil, displayHeight: Int? = nil, displayUnit: Int = 0,
        cropTop: Int = 0, cropBottom: Int = 0, cropLeft: Int = 0, cropRight: Int = 0
    ) {
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.displayUnit = displayUnit
        self.cropTop = cropTop
        self.cropBottom = cropBottom
        self.cropLeft = cropLeft
        self.cropRight = cropRight
    }

    public func validate(width: Int, height: Int) throws {
        guard width > 0, height > 0, displayUnit >= 0,
            cropTop >= 0, cropBottom >= 0, cropLeft >= 0, cropRight >= 0,
            cropLeft < width, cropRight < width - cropLeft,
            cropTop < height, cropBottom < height - cropTop,
            displayWidth.map({ $0 > 0 }) ?? true,
            displayHeight.map({ $0 > 0 }) ?? true,
            !(1...3).contains(displayUnit) || (displayWidth != nil && displayHeight != nil)
        else {
            throw FormatError.corrupt(
                String(localized: "Video dimensions out of range", comment: "Invalid video metadata"))
        }
    }

    public func cropRect(width: Int, height: Int) -> CGRect {
        CGRect(
            x: cropLeft, y: cropBottom,
            width: width - cropLeft - cropRight, height: height - cropTop - cropBottom)
    }

    public func presentationSize(width: Int, height: Int) -> CGSize? {
        guard (try? validate(width: width, height: height)) != nil else { return nil }
        let croppedWidth = width - cropLeft - cropRight
        let croppedHeight = height - cropTop - cropBottom
        let presentedWidth: Double
        let presentedHeight: Double
        switch displayUnit {
        case 0:
            presentedWidth = Double(displayWidth ?? croppedWidth)
            presentedHeight = Double(displayHeight ?? croppedHeight)
        case 1...3:
            guard let displayWidth, let displayHeight, displayWidth > 0, displayHeight > 0 else { return nil }
            presentedWidth = Double(croppedHeight) * Double(displayWidth) / Double(displayHeight)
            presentedHeight = Double(croppedHeight)
        default: return nil
        }
        guard presentedWidth.isFinite, presentedHeight.isFinite,
            presentedWidth >= 1, presentedHeight >= 1,
            presentedWidth <= Double(Int32.max), presentedHeight <= Double(Int32.max)
        else { return nil }
        return CGSize(width: presentedWidth, height: presentedHeight)
    }

    public func pixelAspectRatio(width: Int, height: Int) -> (horizontal: Int, vertical: Int)? {
        guard presentationSize(width: width, height: height) != nil else { return nil }
        let croppedWidth = width - cropLeft - cropRight
        let croppedHeight = height - cropTop - cropBottom
        let displayWidth = displayUnit == 0 ? self.displayWidth ?? croppedWidth : self.displayWidth
        let displayHeight = displayUnit == 0 ? self.displayHeight ?? croppedHeight : self.displayHeight
        guard let displayWidth, let displayHeight else { return nil }
        var numerator = [displayWidth, croppedHeight]
        var denominator = [displayHeight, croppedWidth]
        for upper in numerator.indices {
            for lower in denominator.indices {
                let divisor = Self.gcd(numerator[upper], denominator[lower])
                numerator[upper] /= divisor
                denominator[lower] /= divisor
            }
        }
        let (horizontal, horizontalOverflow) = numerator[0].multipliedReportingOverflow(by: numerator[1])
        let (vertical, verticalOverflow) = denominator[0].multipliedReportingOverflow(by: denominator[1])
        guard !horizontalOverflow, !verticalOverflow,
            horizontal <= Int32.max, vertical <= Int32.max
        else { return nil }
        return (horizontal, vertical)
    }

    private static func gcd(_ first: Int, _ second: Int) -> Int {
        var left = first
        var right = second
        while right != 0 { (left, right) = (right, left % right) }
        return left
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
    public var hasContainerHDR = false
    public var displayGeometry: VideoDisplayGeometry?
    public var timestampQuantum: Int64?
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
    public var outputTimestamp: Int64?
    /// Differs from `timestamp` with reordered frames.
    public var decodeTimestamp: Int64?
    public var duration: Int64?
    public var isKeyframe: Bool
    public var payload: Data
    public var additional: Data?
    public var trimDurationAtStart: Int64?
    var audioAttachments: AudioSampleAttachments?
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

// AVFoundation publishes immutable audio attachment values.
struct AudioSampleAttachments: @unchecked Sendable, Hashable {
    private let snapshot: CFDictionary

    init?(_ sample: CMSampleBuffer) {
        guard
            let snapshot = CMCopyDictionaryOfAttachments(
                allocator: nil, target: sample, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        else { return nil }
        self.snapshot = snapshot
    }

    func apply(to sample: CMSampleBuffer) {
        CMSetAttachments(sample, attachments: snapshot, attachmentMode: kCMAttachmentMode_ShouldPropagate)
    }
}

public protocol MediaDemuxer {
    var tracks: [MediaTrack] { get }
    var skippedStreams: Set<SkippedMediaStream> { get }
    /// Nanoseconds, when the container states it.
    var duration: Int64? { get }
    /// File order; `nil` at the end.
    mutating func nextPacket() throws -> MediaPacket?
}

public enum SkippedMediaStream: Hashable, Sendable {
    case track(Int)
    case attachment
    case chapter
    case metadata
    case unknown
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
    public static func scale(_ value: Int64, by numerator: Int64, over denominator: Int64) throws -> Int64 {
        let estimate = Double(value) * Double(numerator) / Double(denominator)
        guard denominator > 0, abs(estimate) < limit else { throw FormatError.corrupt("timestamp out of range") }
        return denominator.dividingFullWidth(value.multipliedFullWidth(by: numerator)).quotient
    }

    public static func from(seconds: Double) throws -> Int64 {
        let nanoseconds = seconds * Double(perSecond)
        guard nanoseconds.isFinite, abs(nanoseconds) < limit else { throw FormatError.corrupt("time out of range") }
        return Int64(nanoseconds)
    }
}
