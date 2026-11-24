import AVFoundation
import Formats
import Foundation
import ImageIO
import OSLog
import Synchronization

struct FallbackSourceDescription: Sendable {
    let originalURL: URL
    let containerFormat: String?
    let formatTags: [String: String]
    let videoCodec: String?
    let audioCodec: String?
    let sampleFormat: String?
    let bitDepth: Int?
    let isFloat: Bool
    let isLosslessAudio: Bool
    let channels: Int?
    let channelLayout: String?
    let pixelFormat: String?
    let hasAlpha: Bool
    let hasDolbyVision: Bool
    let hasVariableFrameTiming: Bool
    let codedSize: PixelSize?
    let displaySize: PixelSize?
    let rotationDegrees: Int
    let originalFieldOrder: String?
    let intermediateFieldOrder: String?
    let videoEnabled: Bool?
    let audioEnabled: Bool?
    let videoVolume: Float?
    let audioVolume: Float?
    let hasAlternateGroups: Bool
    let trackAttributesUnknown: Bool
    let videoTags: [String: String]
    let audioTags: [String: String]
    let attachedPictureCount: Int
    let attachedPicture: Artwork?
    let attachedPictureDropped: Bool
    let unreadableMetadataBlock: Bool

    private static let interlacedFieldOrders: Set<String> = ["tt", "bb", "tb", "bt"]
    static let supportedAudioTextKeys = ["title", "artist", "album"]
    private static let supportedAudioTagKeys: Set<String> = [
        "title", "artist", "album", "cover art (front)",
    ]
    private static let ignoredAudioTagKeys: Set<String> = [
        "encoder", "software", "vendor", "writing_application", "writing_library",
        "compatible_brands", "major_brand", "minor_version", "duration",
        "handler_name", "vendor_id", "bps", "number_of_frames", "number_of_bytes",
    ]

    var isInterlacedFieldOrderChanged: Bool {
        guard let original = originalFieldOrder?.lowercased(),
            Self.interlacedFieldOrders.contains(original)
        else { return false }
        return intermediateFieldOrder?.lowercased() != original
    }

    var hasUnsupportedAudioTags: Bool {
        if attachedPictureDropped || unreadableMetadataBlock || resolvedAudioTags().droppedDuplicateValues {
            return true
        }
        let allTags = formatTags.merging(audioTags) { current, _ in current }
        return allTags.contains { key, value in
            let lowered = key.lowercased()
            guard !value.isEmpty else { return false }
            if Self.supportedAudioTagKeys.contains(lowered) || Self.ignoredAudioTagKeys.contains(lowered) {
                return false
            }
            return !lowered.hasPrefix("_statistics_")
        }
    }

    var fallbackAudioTags: AudioTags {
        resolvedAudioTags().tags
    }

    /// Container values win; distinct stream values warn.
    func resolvedAudioTags() -> (tags: AudioTags, droppedDuplicateValues: Bool) {
        var tags = AudioTags()
        var droppedDuplicateValues = false
        for targetKey in Self.supportedAudioTextKeys {
            var values: [String] = []
            for source in [formatTags, audioTags] {
                for key in source.keys.sorted() where key.caseInsensitiveCompare(targetKey) == .orderedSame {
                    if let value = source[key], !value.isEmpty {
                        values.append(value)
                    }
                }
            }
            guard let kept = values.first else { continue }
            if values.dropFirst().contains(where: { $0 != kept }) {
                droppedDuplicateValues = true
            }
            switch targetKey {
            case "title": tags.title = kept
            case "artist": tags.artist = kept
            case "album": tags.album = kept
            default: break
            }
        }
        tags.artwork = attachedPictureDropped ? nil : attachedPicture
        return (tags, droppedDuplicateValues)
    }
}

enum StagedMediaFallback {
    struct OriginalTrackAttributes: Sendable {
        var videoEnabled: Bool?
        var audioEnabled: Bool?
        var videoVolume: Float?
        var audioVolume: Float?
        var hasAlternateGroups = false
        var trackAttributesUnknown = false
    }

    enum ChromaClass: Int, Comparable, Sendable {
        case yuv420 = 0
        case yuv422 = 1
        case yuv444 = 2

        static func < (lhs: ChromaClass, rhs: ChromaClass) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var label: String {
            switch self {
            case .yuv420: "4:2:0"
            case .yuv422: "4:2:2"
            case .yuv444: "4:4:4"
            }
        }
    }

    enum AudioPrecisionClass: String, Equatable, Sendable {
        case lossy
        case int16
        case int24
        case int32
        case float32
        case float64

        func preserves(_ original: AudioPrecisionClass) -> Bool {
            switch original {
            case .lossy:
                return self != .lossy
            case .int16:
                return self == .int16 || self == .int24 || self == .int32 || self == .float32 || self == .float64
            case .int24:
                return self == .int24 || self == .int32 || self == .float64
            case .int32:
                return self == .int32 || self == .float64
            case .float32:
                return self == .float32 || self == .float64
            case .float64:
                return self == .float64
            }
        }
    }

    enum VerificationKind: Sendable {
        case video(hasAudio: Bool)
        case audio
    }

    enum IntermediateFact: String, CaseIterable, Sendable {
        case mappedStreams = "mapped streams"
        case relativeStreamStart = "relative stream start"
        case videoDisplayDimensions = "video display dimensions"
        case videoPixelBitDepth = "video pixel bit depth"
        case videoChromaClass = "video chroma subsampling"
        case videoAlpha = "video alpha"
        case videoDuration = "video duration"
        case audioChannelCount = "audio channel count"
        case audioChannelLayout = "audio channel layout"
        case audioSampleRate = "audio sample rate"
        case audioPrecisionClass = "audio precision"
        case audioDuration = "audio duration"
    }

    struct Probe: Decodable, Sendable {
        struct Format: Decodable, Sendable {
            let formatName: String?
            let duration: String?
            let size: String?
            let tags: [String: String]?

            enum CodingKeys: String, CodingKey {
                case formatName = "format_name"
                case duration
                case size
                case tags
            }
        }

        struct Disposition: Decodable, Sendable {
            let attachedPic: Int?
            let timedThumbnails: Int?

            enum CodingKeys: String, CodingKey {
                case attachedPic = "attached_pic"
                case timedThumbnails = "timed_thumbnails"
            }
        }

        struct SideData: Decodable, Sendable {
            let sideDataType: String?
            let rotation: Double?

            enum CodingKeys: String, CodingKey {
                case sideDataType = "side_data_type"
                case rotation
            }
        }

        struct Stream: Decodable, Sendable {
            let index: Int
            let codecType: String?
            let codecName: String?
            let codecTagString: String?
            let width: Int?
            let height: Int?
            let pixelFormat: String?
            let bitsPerRawSample: String?
            let bitsPerSample: Int?
            let colorPrimaries: String?
            let colorTransfer: String?
            let colorSpace: String?
            let colorRange: String?
            let fieldOrder: String?
            let nbFrames: String?
            let rFrameRate: String?
            let channels: Int?
            let channelLayout: String?
            let sampleFormat: String?
            let sampleRate: String?
            let startTime: String?
            let duration: String?
            let disposition: Disposition?
            let tags: [String: String]?
            let sideDataList: [SideData]?

            init(
                index: Int, codecType: String?, codecName: String?, codecTagString: String?,
                width: Int?, height: Int?, pixelFormat: String?, bitsPerRawSample: String?, bitsPerSample: Int?,
                colorPrimaries: String?, colorTransfer: String?, colorSpace: String?, colorRange: String?,
                channels: Int?, channelLayout: String?, sampleFormat: String?, sampleRate: String?, duration: String?,
                disposition: Disposition?, tags: [String: String]?,
                fieldOrder: String? = nil, nbFrames: String? = nil, rFrameRate: String? = nil,
                startTime: String? = nil, sideDataList: [SideData]? = nil
            ) {
                self.index = index
                self.codecType = codecType
                self.codecName = codecName
                self.codecTagString = codecTagString
                self.width = width
                self.height = height
                self.pixelFormat = pixelFormat
                self.bitsPerRawSample = bitsPerRawSample
                self.bitsPerSample = bitsPerSample
                self.colorPrimaries = colorPrimaries
                self.colorTransfer = colorTransfer
                self.colorSpace = colorSpace
                self.colorRange = colorRange
                self.fieldOrder = fieldOrder
                self.nbFrames = nbFrames
                self.rFrameRate = rFrameRate
                self.channels = channels
                self.channelLayout = channelLayout
                self.sampleFormat = sampleFormat
                self.sampleRate = sampleRate
                self.startTime = startTime
                self.duration = duration
                self.disposition = disposition
                self.tags = tags
                self.sideDataList = sideDataList
            }

            enum CodingKeys: String, CodingKey {
                case index
                case codecType = "codec_type"
                case codecName = "codec_name"
                case codecTagString = "codec_tag_string"
                case width
                case height
                case pixelFormat = "pix_fmt"
                case bitsPerRawSample = "bits_per_raw_sample"
                case bitsPerSample = "bits_per_sample"
                case colorPrimaries = "color_primaries"
                case colorTransfer = "color_transfer"
                case colorSpace = "color_space"
                case colorRange = "color_range"
                case fieldOrder = "field_order"
                case nbFrames = "nb_frames"
                case rFrameRate = "r_frame_rate"
                case channels
                case channelLayout = "channel_layout"
                case sampleFormat = "sample_fmt"
                case sampleRate = "sample_rate"
                case startTime = "start_time"
                case duration
                case disposition
                case tags
                case sideDataList = "side_data_list"
            }

            var isAttachedPicture: Bool {
                disposition?.attachedPic == 1 || disposition?.timedThumbnails == 1
            }

            var hasAlphaModeTag: Bool {
                tags?.first(where: { $0.key.caseInsensitiveCompare("alpha_mode") == .orderedSame })?.value == "1"
            }

            var hasAlphaPixelFormat: Bool {
                let format = pixelFormat?.lowercased() ?? ""
                return StagedMediaFallback.alphaPixelFormatPrefixes.contains(where: { format.hasPrefix($0) })
            }

            var hasAlpha: Bool {
                hasAlphaPixelFormat || hasAlphaModeTag
            }

            var hasDolbyVision: Bool {
                if let tag = codecTagString?.lowercased(), StagedMediaFallback.dolbyVisionCodecTags.contains(tag) {
                    return true
                }
                return sideDataList?.contains(where: {
                    ($0.sideDataType ?? "").localizedCaseInsensitiveContains("dovi")
                }) == true
            }

            var rotationDegrees: Int {
                let raw: Double?
                if let matrixRotation = sideDataList?.first(where: { $0.rotation != nil })?.rotation {
                    raw = matrixRotation
                } else {
                    raw = tags?.first(where: { $0.key.caseInsensitiveCompare("rotate") == .orderedSame })
                        .flatMap { Double($0.value) }
                }
                guard let raw, raw.isFinite else { return 0 }
                return ((Int(raw.rounded()) % 360) + 360) % 360
            }

            var codedSize: PixelSize? {
                guard let width, let height, width > 0, height > 0 else { return nil }
                return PixelSize(width: width, height: height)
            }

            var displaySize: PixelSize? {
                guard let coded = codedSize else { return nil }
                if rotationDegrees == 90 || rotationDegrees == 270 {
                    return PixelSize(width: coded.height, height: coded.width)
                }
                return coded
            }

            var hasOddDimensions: Bool {
                guard let size = displaySize else { return false }
                return size.width % 2 != 0 || size.height % 2 != 0
            }

            var parsedBitsPerRawSample: Int? {
                bitsPerRawSample.flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
            }

            var videoBitDepth: Int {
                if let raw = parsedBitsPerRawSample { return raw }
                let format = pixelFormat?.lowercased() ?? ""
                if format.contains("16") { return 16 }
                if format.contains("14") { return 14 }
                if format.contains("12") { return 12 }
                if format.contains("10") { return 10 }
                return 8
            }

            var chromaClass: ChromaClass {
                let format = pixelFormat?.lowercased() ?? ""
                if StagedMediaFallback.chroma444Prefixes.contains(where: { format.hasPrefix($0) })
                    || StagedMediaFallback.chroma444AlphaPrefixes.contains(where: { format.hasPrefix($0) })
                {
                    return .yuv444
                }
                if StagedMediaFallback.chroma422Prefixes.contains(where: { format.hasPrefix($0) }) {
                    return .yuv422
                }
                return .yuv420
            }

            var parsedFrameCount: Int? {
                nbFrames.flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
            }

            var parsedFrameDuration: Double? {
                guard let rFrameRate else { return nil }
                let parts = rFrameRate.split(separator: "/")
                guard parts.count == 2,
                    let numerator = Double(parts[0]), let denominator = Double(parts[1]),
                    numerator > 0, denominator > 0
                else { return nil }
                return denominator / numerator
            }

            var parsedStartTime: Double? {
                startTime.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
            }

            // Matroska DURATION means end or elapsed.
            var candidateElapsedDurations: [Double] {
                if let direct = duration.flatMap(Double.init), direct.isFinite, direct > 0 {
                    return [direct]
                }
                guard
                    let tag = tags?.first(where: { $0.key.caseInsensitiveCompare("duration") == .orderedSame })?.value,
                    let tagged = StagedMediaFallback.parseTimestampDuration(tag)
                else { return [] }
                var candidates: [Double] = []
                if let start = parsedStartTime, start != 0 {
                    let fromEnd = tagged - start
                    if fromEnd.isFinite, fromEnd > 0 {
                        candidates.append(fromEnd)
                    }
                }
                candidates.append(tagged)
                return candidates
            }

            var parsedDuration: Double? {
                candidateElapsedDurations.first
            }

            var effectiveAudioBitDepth: Int? {
                guard isLosslessAudioCodec else { return nil }
                if let raw = parsedBitsPerRawSample { return raw }
                if let sampleBits = bitsPerSample, sampleBits > 0 { return sampleBits }
                let codec = codecName?.lowercased() ?? ""
                if codec.contains("64") { return 64 }
                if codec.contains("32") { return 32 }
                if codec.contains("24") { return 24 }
                if codec.contains("16") { return 16 }
                if codec.hasPrefix("pcm_u8") || codec.hasPrefix("pcm_s8") { return 8 }
                switch sampleFormat?.lowercased() {
                case "u8", "u8p": return 8
                case "s16", "s16p": return 16
                case "s32", "s32p", "flt", "fltp": return 32
                case "dbl", "dblp": return 64
                default: return nil
                }
            }

            var parsedSampleRate: Double {
                sampleRate.flatMap(Double.init) ?? StagedMediaFallback.defaultAudioSampleRate
            }

            var isLosslessAudioCodec: Bool {
                guard let name = codecName?.lowercased() else { return false }
                return name.hasPrefix("pcm_") || StagedMediaFallback.losslessAudioCodecs.contains(name)
            }

            var isFloatingPointAudioSource: Bool {
                guard isLosslessAudioCodec else { return false }
                if codecName?.lowercased().hasPrefix("pcm_f") == true { return true }
                guard let sampleFormat = sampleFormat?.lowercased() else { return false }
                return StagedMediaFallback.floatingSampleFormats.contains(sampleFormat)
            }

            var audioPrecisionClass: AudioPrecisionClass {
                if isFloatingPointAudioSource {
                    let codec = codecName?.lowercased() ?? ""
                    let format = sampleFormat?.lowercased() ?? ""
                    if effectiveAudioBitDepth == 64 || codec.hasPrefix("pcm_f64") || format == "dbl" || format == "dblp"
                    {
                        return .float64
                    }
                    return .float32
                }
                guard isLosslessAudioCodec else { return .lossy }
                switch effectiveAudioBitDepth ?? 16 {
                case ...16: return .int16
                case 17...24: return .int24
                default: return .int32
                }
            }

            var isLowBitDepthIntegerAudio: Bool {
                audioPrecisionClass == .int16
            }

            var isALACLayoutExact: Bool {
                StagedMediaFallback.isALACLayoutExact(channels: channels, channelLayout: channelLayout)
            }

            var canonicalSpeakerSet: Set<String>? {
                guard let rawLayout = channelLayout?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !rawLayout.isEmpty
                else { return nil }
                let lowered = rawLayout.lowercased()
                if let known = StagedMediaFallback.standardSpeakerSets[lowered] {
                    return known
                }
                if let open = rawLayout.firstIndex(of: "("),
                    let close = rawLayout.lastIndex(of: ")"),
                    open < close
                {
                    let inner = rawLayout[rawLayout.index(after: open)..<close]
                    let speakers = inner.split(separator: "+").map { $0.uppercased() }
                    if !speakers.isEmpty { return Set(speakers) }
                }
                if rawLayout.contains("+") {
                    let speakers = rawLayout.split(separator: "+").map { $0.uppercased() }
                    if !speakers.isEmpty { return Set(speakers) }
                }
                return [lowered]
            }

            var isM4ACompatibleImage: Bool {
                guard let codec = codecName?.lowercased() else { return false }
                return codec == "mjpeg" || codec == "png"
            }

            var preferredAlphaInputDecoder: String? {
                guard hasAlphaModeTag, !hasAlphaPixelFormat else { return nil }
                return codecName?.lowercased() == "vp9" ? "libvpx-vp9" : nil
            }
        }

        struct Chapter: Decodable, Sendable {}

        let format: Format?
        let streams: [Stream]
        let chapters: [Chapter]?

        var isQuickTimeFamily: Bool {
            guard let formatName = format?.formatName else { return false }
            return formatName.split(separator: ",").contains("mov")
        }

        var isMatroskaFamily: Bool {
            guard let formatName = format?.formatName else { return false }
            let tokens = formatName.split(separator: ",")
            return tokens.contains("matroska") || tokens.contains("webm")
        }

        var durationSeconds: Double? {
            let candidates = [format?.duration] + streams.map(\.duration)
            let parsed = candidates.compactMap { $0.flatMap(Double.init) }.filter { $0.isFinite && $0 > 0 }
            return parsed.max()
        }

        var videoStreams: [Stream] {
            streams.filter { $0.codecType == "video" && !$0.isAttachedPicture }
        }

        var audioStreams: [Stream] {
            streams.filter { $0.codecType == "audio" }
        }

        var attachedPictureStreams: [Stream] {
            streams.filter { $0.codecType == "video" && $0.isAttachedPicture }
        }

        func sourceDescription(
            originalURL: URL,
            intermediateProbe: Probe? = nil,
            trackAttributes: OriginalTrackAttributes = OriginalTrackAttributes(),
            hasVariableFrameTiming: Bool = false,
            attachedPicture: Artwork? = nil,
            attachedPictureDropped: Bool = false,
            unreadableMetadataBlock: Bool = false
        ) -> FallbackSourceDescription {
            let video = videoStreams.first
            let audio = audioStreams.first
            return FallbackSourceDescription(
                originalURL: originalURL,
                containerFormat: format?.formatName,
                formatTags: StagedMediaFallback.userTags(from: format?.tags),
                videoCodec: video?.codecName,
                audioCodec: audio?.codecName,
                sampleFormat: audio?.sampleFormat,
                bitDepth: audio?.effectiveAudioBitDepth,
                isFloat: audio?.isFloatingPointAudioSource ?? false,
                isLosslessAudio: audio?.isLosslessAudioCodec ?? false,
                channels: audio?.channels,
                channelLayout: audio?.channelLayout,
                pixelFormat: video?.pixelFormat,
                hasAlpha: video?.hasAlpha ?? false,
                hasDolbyVision: video?.hasDolbyVision ?? false,
                hasVariableFrameTiming: hasVariableFrameTiming,
                codedSize: video?.codedSize,
                displaySize: video?.displaySize,
                rotationDegrees: video?.rotationDegrees ?? 0,
                originalFieldOrder: video?.fieldOrder,
                intermediateFieldOrder: intermediateProbe?.videoStreams.first?.fieldOrder,
                videoEnabled: trackAttributes.videoEnabled,
                audioEnabled: trackAttributes.audioEnabled,
                videoVolume: trackAttributes.videoVolume,
                audioVolume: trackAttributes.audioVolume,
                hasAlternateGroups: trackAttributes.hasAlternateGroups,
                trackAttributesUnknown: trackAttributes.trackAttributesUnknown,
                videoTags: StagedMediaFallback.userTags(from: video?.tags),
                audioTags: StagedMediaFallback.userTags(from: audio?.tags),
                attachedPictureCount: attachedPictureStreams.count,
                attachedPicture: attachedPicture,
                attachedPictureDropped: attachedPictureDropped,
                unreadableMetadataBlock: unreadableMetadataBlock)
        }
    }

    enum VideoProfile: Equatable, Sendable {
        case hevcSDR
        case hevcMain10
        case proresStandard422
        case prores4444
        case prores4444Alpha
    }

    enum AudioProfile: Equatable, Sendable {
        case pcm16
        case pcm24
        case pcm32
        case pcmFloat32
        case pcmFloat64
        case alacM4A
        case cafPCM24
        case cafPCM32
        case cafPCMFloat32
        case cafPCMFloat64

        var fileExtension: String {
            switch self {
            case .alacM4A: "m4a"
            case .cafPCM24, .cafPCM32, .cafPCMFloat32, .cafPCMFloat64: "caf"
            case .pcm16, .pcm24, .pcm32, .pcmFloat32, .pcmFloat64: "mov"
            }
        }

        var muxerFormat: String {
            switch self {
            case .alacM4A: "ipod"
            case .cafPCM24, .cafPCM32, .cafPCMFloat32, .cafPCMFloat64: "caf"
            case .pcm16, .pcm24, .pcm32, .pcmFloat32, .pcmFloat64: "mov"
            }
        }

        var ffmpegCodec: String {
            switch self {
            case .pcm16: "pcm_s16le"
            case .pcm24, .cafPCM24: "pcm_s24le"
            case .pcm32, .cafPCM32: "pcm_s32le"
            case .pcmFloat32, .cafPCMFloat32: "pcm_f32le"
            case .pcmFloat64, .cafPCMFloat64: "pcm_f64le"
            case .alacM4A: "alac"
            }
        }

        var bytesPerSample: Int {
            switch self {
            case .pcm16: 2
            case .pcm24, .cafPCM24, .alacM4A: 3
            case .pcm32, .cafPCM32, .pcmFloat32, .cafPCMFloat32: 4
            case .pcmFloat64, .cafPCMFloat64: 8
            }
        }
    }

    struct StagedVideo: Sendable {
        let originalURL: URL
        let stagedURL: URL
        let profile: VideoProfile
        let origin: FallbackSourceDescription
        let omittedStreams: [UnpreservedStream]
    }

    struct StagedAudio: Sendable {
        let originalURL: URL
        let stagedURL: URL
        let profile: AudioProfile
        let origin: FallbackSourceDescription
        let omittedStreams: [UnpreservedStream]
    }

    private static let logger = Logger(subsystem: "io.github.tky27.MacEase", category: "fallback")

    // Hard wall-clock cap for metadata probe.
    static let probeNoProgressTimeout = Duration.seconds(30)
    // Max stall between advancing out_time_us.
    static let transcodeNoProgressTimeout = Duration.seconds(60)
    // Poll staged growth every second.
    static let diskMonitorInterval = Duration.seconds(1)
    static let maximumALACBitDepth = 24
    static let diskHeadroomBytes: Int64 = 512_000_000
    static let maximumArtworkBytes = Artwork.maximumBytes
    static let maximumArtworkPixels = Artwork.maximumPixels
    static let maximumArtworkDimension = 16_384
    /// FFmpeg skips APEv2 tags over 16 MiB.
    static let ffmpegAPETagSizeLimit: UInt32 = 16 * 1_024 * 1_024
    private static let apeTagPreamble: [UInt8] = Array("APETAGEX".utf8)
    private static let apeHeaderFlag: UInt32 = 1 << 29
    private static let apeFooterLength: UInt64 = 32
    private static let id3v1TagLength: UInt64 = 128
    private static let id3v1Preamble: [UInt8] = Array("TAG".utf8)
    /// Relative interval deviation signalling variable timing.
    static let variableFrameTimingTolerance = 0.15
    /// Ignores 1 ms Matroska timestamp quantization.
    static let variableFrameTimingMinimumDeltaSeconds = 0.0025
    private static let maximumInspectedFrameTimestamps = 4_000_000

    private static let videoDurationMinimumTolerance = 0.05
    private static let audioDurationTolerance = 0.1
    private static let quickTimeDemuxers = "mov,mp4,m4a,3gp,3g2,mj2"
    private static let nonQuickTimeDemuxers = [
        "matroska", "webm", "avi", "asf", "mpeg", "mpegts", "flv", "rm",
        "ogg", "flac", "wav", "aiff", "caf",
        "mp3", "aac", "ac3", "eac3", "dts", "truehd", "mlp",
        "wv", "ape", "tta", "mxf", "dv", "nut", "ivf", "amr", "swf",
        "mpc", "mpc8", "shorten", "tak",
    ].joined(separator: ",")
    static let formatWhitelist = quickTimeDemuxers + "," + nonQuickTimeDemuxers

    private static let threadLimit = 4
    private static let maxMuxingQueueSize = 4_096
    private static let hevcQuality = 90
    private static let hevcKeyframeInterval = 30
    private static let referencePixels = 1920.0 * 1080.0
    private static let hevcBytesPerSecondAt1080p = 4_500_000.0
    private static let proresStandardBytesPerSecondAt1080p = 11_000_000.0
    private static let prores4444BytesPerSecondAt1080p = 22_000_000.0
    private static let minimumHEVCBytesPerSecond = 1_000_000.0
    private static let maximumHEVCBytesPerSecond = 40_000_000.0
    private static let minimumProResStandardBytesPerSecond = 2_000_000.0
    private static let maximumProResStandardBytesPerSecond = 80_000_000.0
    private static let minimumProRes4444BytesPerSecond = 4_000_000.0
    private static let maximumProRes4444BytesPerSecond = 160_000_000.0
    private static let defaultAudioSampleRate = 48_000.0
    private static let defaultAudioChannels = 2
    private static let estimateSafetyMultiplier = 1.25
    private static let fixedOverheadBytes: Int64 = 64_000_000
    private static let unknownDurationSizeMultiplier: Int64 = 4
    private static let minimumUnknownDurationBytes: Int64 = 256_000_000
    private static let nonRootHeadroomDivisor: Int64 = 10
    private static let microsecondsPerSecond = 1_000_000.0
    private static let progressTimePrefix = "out_time_us="

    private static let exactALACLayouts: Set<String> = [
        "mono", "stereo", "3.0", "4.0", "5.0", "5.1",
    ]

    static func isALACLayoutExact(channels: Int?, channelLayout: String?) -> Bool {
        let count = channels ?? defaultAudioChannels
        if let layout = channelLayout?.lowercased(), !layout.isEmpty {
            return exactALACLayouts.contains(layout)
        }
        return count <= 2
    }
    private static let standardSpeakerSets: [String: Set<String>] = [
        "mono": ["FC"],
        "stereo": ["FL", "FR"],
        "2.1": ["FL", "FR", "LFE"],
        "3.0": ["FL", "FR", "FC"],
        "3.0(back)": ["FL", "FR", "BC"],
        "4.0": ["FL", "FR", "FC", "BC"],
        "quad": ["FL", "FR", "BL", "BR"],
        "quad(side)": ["FL", "FR", "SL", "SR"],
        "3.1": ["FL", "FR", "FC", "LFE"],
        "5.0": ["FL", "FR", "FC", "BL", "BR"],
        "5.0(side)": ["FL", "FR", "FC", "SL", "SR"],
        "4.1": ["FL", "FR", "FC", "LFE", "BC"],
        "5.1": ["FL", "FR", "FC", "LFE", "BL", "BR"],
        "5.1(side)": ["FL", "FR", "FC", "LFE", "SL", "SR"],
        "6.0": ["FL", "FR", "FC", "BC", "SL", "SR"],
        "6.0(front)": ["FL", "FR", "FLC", "FRC", "SL", "SR"],
        "hexagonal": ["FL", "FR", "FC", "BL", "BR", "BC"],
        "6.1": ["FL", "FR", "FC", "LFE", "BC", "SL", "SR"],
        "6.1(back)": ["FL", "FR", "FC", "LFE", "BL", "BR", "BC"],
        "6.1(front)": ["FL", "FR", "LFE", "FLC", "FRC", "SL", "SR"],
        "7.0": ["FL", "FR", "FC", "BL", "BR", "SL", "SR"],
        "7.0(front)": ["FL", "FR", "FC", "FLC", "FRC", "SL", "SR"],
        "7.1": ["FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR"],
        "7.1(wide)": ["FL", "FR", "FC", "LFE", "BL", "BR", "FLC", "FRC"],
        "7.1(wide-side)": ["FL", "FR", "FC", "LFE", "FLC", "FRC", "SL", "SR"],
        "octagonal": ["FL", "FR", "FC", "BL", "BR", "BC", "SL", "SR"],
    ]
    private static let dolbyVisionCodecTags: Set<String> = ["dvhe", "dvh1", "dvav", "dva1"]
    private static let losslessAudioCodecs: Set<String> = [
        "alac", "flac", "wavpack", "ape", "tta", "tak", "shorten", "mlp", "truehd", "wmalossless", "als", "dst",
    ]
    private static let floatingSampleFormats: Set<String> = ["flt", "fltp", "dbl", "dblp"]
    private static let closedCaptionCodecs: Set<String> = ["eia_608", "cea_608", "cea_708"]
    private static let alphaPixelFormatPrefixes = [
        "yuva", "rgba", "bgra", "argb", "abgr", "gbrap", "ya8", "ya16", "ayuv", "vuya",
    ]
    private static let chroma444AlphaPrefixes = [
        "yuva444", "rgba", "bgra", "argb", "abgr", "gbrap", "ayuv", "vuya",
    ]
    private static let chroma444Prefixes = [
        "yuv444", "yuvj444", "gbrp", "rgb24", "bgr24", "rgb48", "bgr48", "0rgb", "rgb0", "0bgr", "bgr0", "p410", "p416",
    ]
    private static let chroma422Prefixes = ["yuv422", "yuvj422", "uyvy", "yuyv", "p210", "p216", "v210"]
    private static let highBitDepthTokens = ["10", "12", "14", "16", "p010", "p016"]
    private static let hdrTransfers: Set<String> = ["smpte2084", "arib-std-b67"]
    private static let ignoredMetadataTagKeys: Set<String> = [
        "encoder", "writing_application", "writing_library", "compatible_brands", "major_brand", "minor_version",
        "muxingapp", "writingapp", "duration", "handler_name", "vendor_id", "bps", "number_of_frames",
        "number_of_bytes", "alpha_mode", "rotate",
    ]
    private static let allowedColorPrimaries: Set<String> = [
        "bt709", "bt470m", "bt470bg", "smpte170m", "smpte240m", "film", "bt2020", "smpte428", "smpte431", "smpte432",
    ]
    private static let allowedColorTransfers: Set<String> = [
        "bt709", "bt470m", "bt470bg", "smpte170m", "smpte240m", "linear", "iec61966-2-4", "bt1361e",
        "iec61966-2-1", "bt2020-10", "bt2020-12", "smpte2084", "smpte428", "arib-std-b67",
    ]
    private static let allowedColorSpaces: Set<String> = [
        "rgb", "bt709", "fcc", "bt470bg", "smpte170m", "smpte240m", "bt2020nc", "bt2020c",
    ]
    private static let allowedColorRanges: Set<String> = ["tv", "pc"]

    static func userTags(from tags: [String: String]?) -> [String: String] {
        guard let tags else { return [:] }
        var filtered: [String: String] = [:]
        for (key, value) in tags where !value.isEmpty {
            let lowered = key.lowercased()
            if ignoredMetadataTagKeys.contains(lowered) || lowered.hasPrefix("_statistics_") { continue }
            if lowered == "creation_time", value.lowercased() == "1970-01-01t00:00:00.000000z" { continue }
            filtered[key] = value
        }
        return filtered
    }

    static func resolveTools(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws -> MediaDownloadTools {
        do {
            if let directory = environment["MACEASE_MEDIA_TOOLS"],
                bundleIdentifier?.hasPrefix("io.github.tky27.MacEase") != true
            {
                return try MediaDownloadTools(directory: URL(filePath: directory))
            }
            return try MediaDownloadTools.bundled()
        } catch {
            throw EngineError.fallbackToolMissing
        }
    }

    static func fileURI(for url: URL) -> String {
        "file:" + url.standardizedFileURL.path
    }

    static func probeArguments(for input: URL) -> [String] {
        [
            "-hide_banner", "-v", "error",
            "-protocol_whitelist", "file",
            "-format_whitelist", formatWhitelist,
            "-enable_drefs", "0", "-use_absolute_path", "0",
            "-show_format", "-show_streams", "-show_chapters",
            "-of", "json",
            "-i", fileURI(for: input),
        ]
    }

    static func videoTranscodeArguments(
        for input: URL, probe: Probe, videoStream: Probe.Stream, audioStream: Probe.Stream?,
        videoProfile: VideoProfile, audioProfile: AudioProfile?, output: URL
    ) -> [String] {
        var arguments = hardenedInputArguments(
            for: input, isQuickTimeFamily: probe.isQuickTimeFamily,
            videoInputDecoder: videoStream.preferredAlphaInputDecoder)
        arguments += ["-map", "0:\(videoStream.index)"]
        if let audioStream {
            arguments += ["-map", "0:\(audioStream.index)"]
        } else {
            arguments += ["-an"]
        }
        arguments += [
            "-sn", "-dn", "-map_chapters", "-1", "-map_metadata", "0",
            "-fps_mode", "passthrough",
            "-max_muxing_queue_size", String(maxMuxingQueueSize),
        ]
        arguments += videoCodecArguments(for: videoProfile, stream: videoStream)
        if let audioProfile {
            arguments += ["-c:a", audioProfile.ffmpegCodec]
        }
        arguments += ["-progress", "pipe:1", "-nostats", "-f", "mov", fileURI(for: output)]
        return arguments
    }

    static func audioTranscodeArguments(
        for input: URL, probe: Probe, audioStream: Probe.Stream,
        profile: AudioProfile, output: URL
    ) -> [String] {
        var arguments = hardenedInputArguments(for: input, isQuickTimeFamily: probe.isQuickTimeFamily)
        arguments += [
            "-map", "0:\(audioStream.index)",
            "-vn", "-sn", "-dn", "-map_chapters", "-1", "-map_metadata", "0",
            "-max_muxing_queue_size", String(maxMuxingQueueSize),
            "-c:a", profile.ffmpegCodec,
            "-progress", "pipe:1", "-nostats", "-f", profile.muxerFormat, fileURI(for: output),
        ]
        return arguments
    }

    static func pictureExtractArguments(
        for input: URL, probe: Probe, pictureStream: Probe.Stream, output: URL
    ) -> [String] {
        var arguments = hardenedInputArguments(for: input, isQuickTimeFamily: probe.isQuickTimeFamily)
        arguments += [
            "-map", "0:\(pictureStream.index)", "-an", "-sn", "-dn", "-frames:v", "1",
            "-c:v", pictureStream.isM4ACompatibleImage ? "copy" : "png",
            "-f", "rawvideo", fileURI(for: output),
        ]
        return arguments
    }

    static func probe(
        _ input: URL, workingDirectory: URL? = nil, tools: MediaDownloadTools? = nil,
        noProgressTimeout: Duration = probeNoProgressTimeout
    ) async throws -> Probe {
        try await rejectExternalReferencesIfApplicable(input)
        let resolvedTools = try tools ?? resolveTools()
        let directory: URL
        let ownsDirectory: Bool
        if let workingDirectory {
            directory = workingDirectory
            ownsDirectory = false
        } else {
            directory = FileManager.default.temporaryDirectory.appending(
                path: "MacEaseProbe-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            ownsDirectory = true
        }
        defer {
            if ownsDirectory {
                do {
                    try FileManager.default.removeItem(at: directory)
                } catch {
                    logger.error("Probe directory cleanup failed: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
        let result = try await MediaToolProcess().runTyped(
            executable: resolvedTools.ffprobe,
            arguments: probeArguments(for: input),
            directory: directory,
            tools: resolvedTools,
            captureOutput: true,
            includeTLSCertificate: false,
            noProgressTimeout: noProgressTimeout)
        do {
            return try JSONDecoder().decode(Probe.self, from: result.stdout)
        } catch {
            throw EngineError.decodeFailed("ffprobe output could not be decoded")
        }
    }

    static func selectVideoProfile(for stream: Probe.Stream) -> VideoProfile {
        let pixelFormat = stream.pixelFormat?.lowercased() ?? ""
        if stream.hasAlpha {
            return .prores4444Alpha
        }
        if stream.hasOddDimensions {
            return .prores4444
        }
        if chroma444Prefixes.contains(where: { pixelFormat.hasPrefix($0) }) {
            return .prores4444
        }
        if chroma422Prefixes.contains(where: { pixelFormat.hasPrefix($0) }) {
            return .proresStandard422
        }
        let isHighBitDepth =
            (stream.parsedBitsPerRawSample ?? 8) >= 10
            || highBitDepthTokens.contains(where: { pixelFormat.contains($0) })
        let isHDR = stream.colorTransfer.map { hdrTransfers.contains($0.lowercased()) } ?? false
        if isHighBitDepth || isHDR {
            return .hevcMain10
        }
        return .hevcSDR
    }

    static func selectVideoAudioProfile(for stream: Probe.Stream) -> AudioProfile {
        switch stream.audioPrecisionClass {
        case .float64: return .pcmFloat64
        case .float32: return .pcmFloat32
        case .int32: return .pcm32
        case .int16: return .pcm16
        case .lossy, .int24: return .pcm24
        }
    }

    static func selectAudioOnlyProfile(for stream: Probe.Stream) -> AudioProfile {
        switch stream.audioPrecisionClass {
        case .float64: return .cafPCMFloat64
        case .float32: return .cafPCMFloat32
        case .int32: return .cafPCM32
        case .lossy, .int16, .int24:
            return stream.isALACLayoutExact ? .alacM4A : .cafPCM24
        }
    }

    static func parseTimestampDuration(_ value: String) -> Double? {
        let parts = value.split(separator: ":")
        guard parts.count == 3,
            let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2])
        else { return nil }
        let total = hours * 3_600 + minutes * 60 + seconds
        return total.isFinite && total > 0 ? total : nil
    }

    static func verifyIntermediate(
        original: Probe, intermediate: Probe, kind: VerificationKind
    ) throws {
        let originalVideo = original.videoStreams.first
        let intermediateVideo = intermediate.videoStreams.first
        let originalAudio = original.audioStreams.first
        let intermediateAudio = intermediate.audioStreams.first

        for fact in IntermediateFact.allCases {
            switch fact {
            case .mappedStreams:
                switch kind {
                case .video(let hasAudio):
                    guard intermediate.videoStreams.count == 1,
                        intermediate.audioStreams.count == (hasAudio ? 1 : 0)
                    else {
                        throw EngineError.fallbackConversionUnfaithful(
                            "\(fact.rawValue): expected 1 video and \(hasAudio ? 1 : 0) audio stream")
                    }
                case .audio:
                    guard intermediate.videoStreams.isEmpty, intermediate.audioStreams.count == 1 else {
                        throw EngineError.fallbackConversionUnfaithful(
                            "\(fact.rawValue): expected 1 audio stream")
                    }
                }
            case .relativeStreamStart:
                guard case .video(hasAudio: true) = kind,
                    let originalVideo, let intermediateVideo, let originalAudio, let intermediateAudio,
                    let originalVideoStart = originalVideo.parsedStartTime,
                    let originalAudioStart = originalAudio.parsedStartTime
                else { continue }
                guard let intermediateVideoStart = intermediateVideo.parsedStartTime,
                    let intermediateAudioStart = intermediateAudio.parsedStartTime
                else {
                    throw EngineError.fallbackConversionUnfaithful(
                        "\(fact.rawValue): intermediate stream start times unavailable")
                }
                let originalEarliest = min(originalVideoStart, originalAudioStart)
                let intermediateEarliest = min(intermediateVideoStart, intermediateAudioStart)
                let videoTolerance = max(originalVideo.parsedFrameDuration ?? 0, videoDurationMinimumTolerance)
                let expectedVideoOffset = originalVideoStart - originalEarliest
                let actualVideoOffset = intermediateVideoStart - intermediateEarliest
                guard abs(actualVideoOffset - expectedVideoOffset) <= videoTolerance else {
                    throw EngineError.fallbackConversionUnfaithful(
                        "\(fact.rawValue): video original +\(String(format: "%.3f", expectedVideoOffset))s became +\(String(format: "%.3f", actualVideoOffset))s"
                    )
                }
                let expectedAudioOffset = originalAudioStart - originalEarliest
                let actualAudioOffset = intermediateAudioStart - intermediateEarliest
                guard abs(actualAudioOffset - expectedAudioOffset) <= audioDurationTolerance else {
                    throw EngineError.fallbackConversionUnfaithful(
                        "\(fact.rawValue): audio original +\(String(format: "%.3f", expectedAudioOffset))s became +\(String(format: "%.3f", actualAudioOffset))s"
                    )
                }
            case .videoDisplayDimensions:
                guard case .video = kind, let originalVideo, let intermediateVideo else { continue }
                guard let expected = originalVideo.displaySize, let actual = intermediateVideo.displaySize,
                    expected == actual, intermediateVideo.rotationDegrees == 0
                else {
                    throw EngineError.fallbackConversionUnfaithful(
                        "\(fact.rawValue): original \(originalVideo.displaySize.map { "\($0.width)x\($0.height)" } ?? "unknown") became \(intermediateVideo.displaySize.map { "\($0.width)x\($0.height)" } ?? "unknown") (rotation \(intermediateVideo.rotationDegrees))"
                    )
                }
            case .videoPixelBitDepth:
                guard case .video = kind, let originalVideo, let intermediateVideo else { continue }
                guard intermediateVideo.videoBitDepth >= originalVideo.videoBitDepth else {
                    throw EngineError.fallbackConversionUnfaithful(
                        "\(fact.rawValue): original \(originalVideo.videoBitDepth)-bit became \(intermediateVideo.videoBitDepth)-bit"
                    )
                }
            case .videoChromaClass:
                guard case .video = kind, let originalVideo, let intermediateVideo else { continue }
                guard intermediateVideo.chromaClass >= originalVideo.chromaClass else {
                    throw EngineError.fallbackConversionUnfaithful(
                        "\(fact.rawValue): original \(originalVideo.chromaClass.label) became \(intermediateVideo.chromaClass.label)"
                    )
                }
            case .videoAlpha:
                guard case .video = kind, let originalVideo, let intermediateVideo, originalVideo.hasAlpha else {
                    continue
                }
                guard intermediateVideo.hasAlpha else {
                    throw EngineError.fallbackConversionUnfaithful(
                        "\(fact.rawValue): alpha channel lost in intermediate")
                }
            case .videoDuration:
                guard case .video = kind, let originalVideo, let intermediateVideo else { continue }
                if let expectedFrames = originalVideo.parsedFrameCount,
                    let actualFrames = intermediateVideo.parsedFrameCount
                {
                    guard abs(actualFrames - expectedFrames) <= 1 else {
                        throw EngineError.fallbackConversionUnfaithful(
                            "\(fact.rawValue): original \(expectedFrames) frames became \(actualFrames)")
                    }
                } else {
                    let tolerance = max(originalVideo.parsedFrameDuration ?? 0, videoDurationMinimumTolerance)
                    if !originalVideo.candidateElapsedDurations.isEmpty,
                        let actual = intermediateVideo.parsedDuration
                    {
                        guard
                            originalVideo.candidateElapsedDurations.contains(where: { abs(actual - $0) <= tolerance })
                        else {
                            let expected = originalVideo.candidateElapsedDurations[0]
                            throw EngineError.fallbackConversionUnfaithful(
                                "\(fact.rawValue): original \(String(format: "%.3f", expected))s became \(String(format: "%.3f", actual))s"
                            )
                        }
                    } else if let expected = original.durationSeconds, let actual = intermediate.durationSeconds {
                        guard abs(actual - expected) <= tolerance else {
                            throw EngineError.fallbackConversionUnfaithful(
                                "\(fact.rawValue): original \(String(format: "%.3f", expected))s became \(String(format: "%.3f", actual))s"
                            )
                        }
                    }
                }
            case .audioChannelCount:
                guard expectsAudio(kind), let originalAudio, let intermediateAudio else { continue }
                guard originalAudio.channels == intermediateAudio.channels else {
                    throw EngineError.fallbackConversionUnfaithful(
                        "\(fact.rawValue): original \(originalAudio.channels.map(String.init) ?? "unknown") became \(intermediateAudio.channels.map(String.init) ?? "unknown")"
                    )
                }
            case .audioChannelLayout:
                guard expectsAudio(kind), let originalAudio, let intermediateAudio else { continue }
                if let expectedSpeakers = originalAudio.canonicalSpeakerSet {
                    guard let actualSpeakers = intermediateAudio.canonicalSpeakerSet,
                        actualSpeakers == expectedSpeakers
                    else {
                        throw EngineError.fallbackConversionUnfaithful(
                            "\(fact.rawValue): original \(originalAudio.channelLayout ?? "unknown") became \(intermediateAudio.channelLayout ?? "unknown")"
                        )
                    }
                }
            case .audioSampleRate:
                guard expectsAudio(kind), let originalAudio, let intermediateAudio else { continue }
                guard abs(originalAudio.parsedSampleRate - intermediateAudio.parsedSampleRate) < 1 else {
                    throw EngineError.fallbackConversionUnfaithful(
                        "\(fact.rawValue): original \(Int(originalAudio.parsedSampleRate)) Hz became \(Int(intermediateAudio.parsedSampleRate)) Hz"
                    )
                }
            case .audioPrecisionClass:
                guard expectsAudio(kind), let originalAudio, let intermediateAudio else { continue }
                guard intermediateAudio.audioPrecisionClass.preserves(originalAudio.audioPrecisionClass) else {
                    throw EngineError.fallbackConversionUnfaithful(
                        "\(fact.rawValue): original \(originalAudio.audioPrecisionClass.rawValue) became \(intermediateAudio.audioPrecisionClass.rawValue)"
                    )
                }
            case .audioDuration:
                guard expectsAudio(kind), let originalAudio, let intermediateAudio else { continue }
                if !originalAudio.candidateElapsedDurations.isEmpty,
                    let actual = intermediateAudio.parsedDuration
                {
                    guard
                        originalAudio.candidateElapsedDurations.contains(where: {
                            abs(actual - $0) <= audioDurationTolerance
                        })
                    else {
                        let expected = originalAudio.candidateElapsedDurations[0]
                        throw EngineError.fallbackConversionUnfaithful(
                            "\(fact.rawValue): original \(String(format: "%.3f", expected))s became \(String(format: "%.3f", actual))s"
                        )
                    }
                } else if let expected = original.durationSeconds, let actual = intermediate.durationSeconds {
                    guard abs(actual - expected) <= audioDurationTolerance else {
                        throw EngineError.fallbackConversionUnfaithful(
                            "\(fact.rawValue): original \(String(format: "%.3f", expected))s became \(String(format: "%.3f", actual))s"
                        )
                    }
                }
            }
        }
    }

    private static func expectsAudio(_ kind: VerificationKind) -> Bool {
        switch kind {
        case .audio, .video(hasAudio: true): true
        case .video(hasAudio: false): false
        }
    }

    static func videoUnpreservedStreams(
        in probe: Probe, allowMultipleTracks: Bool = false
    ) throws -> [UnpreservedStream] {
        guard !probe.videoStreams.isEmpty else {
            throw EngineError.decodeFailed("no video track")
        }
        if !allowMultipleTracks, probe.videoStreams.count > 1 || probe.audioStreams.count > 1 {
            throw EngineError.invalidInput(.multipleTracks)
        }
        var found: Set<UnpreservedStream> = []
        if probe.videoStreams.count > 1 { found.insert(.video) }
        if probe.audioStreams.count > 1 { found.insert(.audio) }
        if !probe.attachedPictureStreams.isEmpty { found.insert(.attachment) }
        if !(probe.chapters ?? []).isEmpty { found.insert(.chapter) }
        for stream in probe.streams where stream.codecType != "video" && stream.codecType != "audio" {
            found.insert(unpreservedKind(for: stream))
        }
        return UnpreservedStream.allCases.filter(found.contains)
    }

    static func audioUnpreservedStreams(in probe: Probe) throws -> [UnpreservedStream] {
        guard !probe.audioStreams.isEmpty else {
            throw EngineError.decodeFailed("no audio track")
        }
        var found: Set<UnpreservedStream> = []
        if probe.audioStreams.count > 1 { found.insert(.audio) }
        if !probe.videoStreams.isEmpty { found.insert(.video) }
        if probe.attachedPictureStreams.count > 1 { found.insert(.attachment) }
        if !(probe.chapters ?? []).isEmpty { found.insert(.chapter) }
        for stream in probe.streams where stream.codecType != "video" && stream.codecType != "audio" {
            found.insert(unpreservedKind(for: stream))
        }
        return UnpreservedStream.allCases.filter(found.contains)
    }

    static func prepareVideo(
        _ originalURL: URL,
        context: ItemContext,
        enforceStreamConsent: Bool = true,
        consentedStreams: Set<UnpreservedStream>? = nil,
        tools: MediaDownloadTools? = nil,
        availableBytes: (@Sendable (URL) throws -> Int64)? = nil,
        noProgressTimeout: Duration = transcodeNoProgressTimeout,
        probeNoProgressTimeout: Duration = Self.probeNoProgressTimeout,
        diskMonitorInterval: Duration = Self.diskMonitorInterval,
        nativeError: EngineError? = nil
    ) async throws -> StagedVideo {
        let resolvedTools = try tools ?? resolveTools()
        let probed = try await restoringNativeError(nativeError, path: originalURL.path) {
            try await probe(originalURL, tools: resolvedTools, noProgressTimeout: probeNoProgressTimeout)
        }
        let omitted = try await restoringNativeError(nativeError, path: originalURL.path) {
            try videoUnpreservedStreams(in: probed, allowMultipleTracks: !enforceStreamConsent)
        }
        context.markFallbackInputUsed()
        if enforceStreamConsent {
            try requireConsent(for: omitted, consented: consentedStreams ?? context.omittedStreams)
        }
        guard let videoStream = probed.videoStreams.first else {
            throw nativeError ?? EngineError.decodeFailed("no video track")
        }
        if videoStream.hasAlphaModeTag, !videoStream.hasAlphaPixelFormat,
            videoStream.preferredAlphaInputDecoder == nil
        {
            throw EngineError.fallbackConversionUnfaithful(
                "\(IntermediateFact.videoAlpha.rawValue): \(videoStream.codecName ?? "video") alpha cannot be decoded")
        }
        let audioStream = probed.audioStreams.first
        let videoProfile = selectVideoProfile(for: videoStream)
        let audioProfile = audioStream.map(selectVideoAudioProfile(for:))
        let estimatedBytes = try estimateVideoBytes(
            originalURL: originalURL, probe: probed, videoStream: videoStream, audioStream: audioStream,
            videoProfile: videoProfile, audioProfile: audioProfile)
        let parentDirectory = originalURL.deletingLastPathComponent()
        let budget = try checkDiskSpace(
            requiredIntermediateBytes: estimatedBytes, in: parentDirectory, availableBytes: availableBytes)
        let stagingDirectory = try context.stagingDirectory(for: originalURL)
        let outputURL = stagingDirectory.appending(path: "fallback.mov", directoryHint: .notDirectory)
        let arguments = videoTranscodeArguments(
            for: originalURL, probe: probed, videoStream: videoStream, audioStream: audioStream,
            videoProfile: videoProfile, audioProfile: audioProfile, output: outputURL)
        context.phase(.convertingInput)
        try await restoringNativeError(nativeError, path: originalURL.path) {
            try await runTranscode(
                arguments: arguments, duration: probed.durationSeconds, outputURL: outputURL,
                workingDirectory: stagingDirectory, tools: resolvedTools, spaceBudget: budget,
                availableBytes: availableBytes, noProgressTimeout: noProgressTimeout,
                diskMonitorInterval: diskMonitorInterval, progress: context.progress)
        }
        try await UntrustedMediaAsset.rejectExternalReferences(in: outputURL)
        let intermediateProbe = try await probeIntermediate(
            outputURL, workingDirectory: stagingDirectory, tools: resolvedTools,
            noProgressTimeout: probeNoProgressTimeout)
        try verifyIntermediate(
            original: probed, intermediate: intermediateProbe, kind: .video(hasAudio: audioStream != nil))
        let hasVariableFrameTiming = try await detectVariableFrameTiming(in: outputURL)
        let trackAttributes = try await inspectOriginalTrackAttributes(originalURL, probe: probed)
        if !omitted.isEmpty { context.warnStreamsOmitted(omitted) }
        return StagedVideo(
            originalURL: originalURL, stagedURL: outputURL, profile: videoProfile,
            origin: probed.sourceDescription(
                originalURL: originalURL, intermediateProbe: intermediateProbe, trackAttributes: trackAttributes,
                hasVariableFrameTiming: hasVariableFrameTiming),
            omittedStreams: omitted)
    }

    static func prepareAudio(
        _ originalURL: URL,
        context: ItemContext,
        enforceStreamConsent: Bool = true,
        tools: MediaDownloadTools? = nil,
        availableBytes: (@Sendable (URL) throws -> Int64)? = nil,
        noProgressTimeout: Duration = transcodeNoProgressTimeout,
        probeNoProgressTimeout: Duration = Self.probeNoProgressTimeout,
        diskMonitorInterval: Duration = Self.diskMonitorInterval,
        maximumArtworkBytes: Int = Self.maximumArtworkBytes,
        maximumArtworkPixels: Int = Self.maximumArtworkPixels,
        nativeError: EngineError? = nil
    ) async throws -> StagedAudio {
        let resolvedTools = try tools ?? resolveTools()
        let probed = try await restoringNativeError(nativeError, path: originalURL.path) {
            try await probe(originalURL, tools: resolvedTools, noProgressTimeout: probeNoProgressTimeout)
        }
        let omitted = try await restoringNativeError(nativeError, path: originalURL.path) {
            try audioUnpreservedStreams(in: probed)
        }
        context.markFallbackInputUsed()
        if enforceStreamConsent {
            try requireConsent(for: omitted, consented: context.omittedStreams)
        }
        guard let audioStream = probed.audioStreams.first else {
            throw nativeError ?? EngineError.decodeFailed("no audio track")
        }
        let profile = selectAudioOnlyProfile(for: audioStream)
        let estimatedBytes = try estimateAudioBytes(
            originalURL: originalURL, probe: probed, audioStream: audioStream, profile: profile)
        let parentDirectory = originalURL.deletingLastPathComponent()
        let budget = try checkDiskSpace(
            requiredIntermediateBytes: estimatedBytes, in: parentDirectory, availableBytes: availableBytes)
        let stagingDirectory = try context.stagingDirectory(for: originalURL)
        let outputURL = stagingDirectory.appending(
            path: "fallback.\(profile.fileExtension)", directoryHint: .notDirectory)
        var attachedPictureStream = probed.attachedPictureStreams.count == 1 ? probed.attachedPictureStreams.first : nil
        var attachedPictureDropped = false
        if let picture = attachedPictureStream, let width = picture.width, let height = picture.height,
            !artworkFitsPixelLimit(width: width, height: height, maximumPixels: maximumArtworkPixels)
        {
            attachedPictureStream = nil
            attachedPictureDropped = true
        }
        let arguments = audioTranscodeArguments(
            for: originalURL, probe: probed, audioStream: audioStream, profile: profile, output: outputURL)
        context.phase(.convertingInput)
        try await restoringNativeError(nativeError, path: originalURL.path) {
            try await runTranscode(
                arguments: arguments, duration: probed.durationSeconds, outputURL: outputURL,
                workingDirectory: stagingDirectory, tools: resolvedTools, spaceBudget: budget,
                availableBytes: availableBytes, noProgressTimeout: noProgressTimeout,
                diskMonitorInterval: diskMonitorInterval, progress: context.progress)
        }
        try await UntrustedMediaAsset.rejectExternalReferences(in: outputURL)
        let intermediateProbe = try await probeIntermediate(
            outputURL, workingDirectory: stagingDirectory, tools: resolvedTools,
            noProgressTimeout: probeNoProgressTimeout)
        try verifyIntermediate(original: probed, intermediate: intermediateProbe, kind: .audio)
        var extractedArtwork: Artwork?
        if let attachedPictureStream {
            extractedArtwork = try await extractAttachedPicture(
                from: originalURL, probe: probed, stream: attachedPictureStream,
                workingDirectory: stagingDirectory, tools: resolvedTools,
                availableBytes: availableBytes, noProgressTimeout: noProgressTimeout,
                diskMonitorInterval: diskMonitorInterval,
                maximumBytes: maximumArtworkBytes, maximumPixels: maximumArtworkPixels)
            if extractedArtwork == nil {
                attachedPictureDropped = true
            }
        }
        let unreadableMetadataBlock = try hasUnreadableAPETag(in: originalURL, probe: probed)
        if !omitted.isEmpty { context.warnStreamsOmitted(omitted) }
        return StagedAudio(
            originalURL: originalURL, stagedURL: outputURL, profile: profile,
            origin: probed.sourceDescription(
                originalURL: originalURL, intermediateProbe: intermediateProbe,
                attachedPicture: extractedArtwork, attachedPictureDropped: attachedPictureDropped,
                unreadableMetadataBlock: unreadableMetadataBlock),
            omittedStreams: omitted)
    }

    static func acceptsNativeFailure(_ error: EngineError) -> Bool {
        switch error {
        case .decodeFailed, .unsupportedCodec: true
        default: false
        }
    }

    // Restore native error only for media rejections.
    static func restoringNativeError<T>(
        _ nativeError: EngineError?, path: String, _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch MediaToolProcess.Failure.exited(_, let reason) {
            throw nativeError ?? EngineError.decodeFailed(reason)
        } catch let failure as MediaToolProcess.Failure {
            throw failure.engineError(path: path)
        } catch EngineError.decodeFailed(let detail) {
            throw nativeError ?? EngineError.decodeFailed(detail)
        }
    }

    private static func probeIntermediate(
        _ outputURL: URL, workingDirectory: URL, tools: MediaDownloadTools, noProgressTimeout: Duration
    ) async throws -> Probe {
        do {
            return try await probe(
                outputURL, workingDirectory: workingDirectory, tools: tools, noProgressTimeout: noProgressTimeout)
        } catch MediaToolProcess.Failure.exited(_, let detail) {
            throw EngineError.fallbackConversionUnfaithful("intermediate probe failed: \(detail)")
        } catch let failure as MediaToolProcess.Failure {
            throw failure.engineError(path: outputURL.path)
        } catch EngineError.decodeFailed(let detail) {
            throw EngineError.fallbackConversionUnfaithful("intermediate probe failed: \(detail)")
        }
    }

    static func hasVariableFrameIntervals(_ intervals: [Double]) -> Bool {
        let positive = intervals.filter { $0.isFinite && $0 > 0 }
        guard positive.count >= 2 else { return false }
        let sorted = positive.sorted()
        let median = sorted[sorted.count / 2]
        let allowed = max(median * variableFrameTimingTolerance, variableFrameTimingMinimumDeltaSeconds)
        return sorted.contains { abs($0 - median) > allowed }
    }

    static func detectVariableFrameTiming(in outputURL: URL) async throws -> Bool {
        let asset = UntrustedMediaAsset.make(outputURL, preciseTiming: true)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
            let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder()
        else { return false }
        var timestamps: [Double] = []
        var nonMonotonic = false
        var previous = -Double.infinity
        repeat {
            try Task.checkCancellation()
            let stamp = cursor.presentationTimeStamp
            if stamp.isNumeric {
                let seconds = CMTimeGetSeconds(stamp)
                if seconds.isFinite {
                    if seconds < previous { nonMonotonic = true }
                    previous = seconds
                    timestamps.append(seconds)
                }
            }
            if timestamps.count >= maximumInspectedFrameTimestamps { break }
        } while cursor.stepInDecodeOrder(byCount: 1) == 1
        guard timestamps.count >= 3 else { return false }
        if nonMonotonic { timestamps.sort() }
        var intervals: [Double] = []
        intervals.reserveCapacity(timestamps.count - 1)
        for index in 1..<timestamps.count {
            intervals.append(timestamps[index] - timestamps[index - 1])
        }
        return hasVariableFrameIntervals(intervals)
    }

    static func inspectOriginalTrackAttributes(
        _ originalURL: URL, probe: Probe
    ) async throws -> OriginalTrackAttributes {
        var attributes = OriginalTrackAttributes()
        if probe.isQuickTimeFamily {
            let asset = UntrustedMediaAsset.make(originalURL)
            do {
                if let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
                    attributes.videoEnabled = try await videoTrack.load(.isEnabled)
                    attributes.videoVolume = try await videoTrack.load(.preferredVolume)
                }
                if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                    attributes.audioEnabled = try await audioTrack.load(.isEnabled)
                    attributes.audioVolume = try await audioTrack.load(.preferredVolume)
                }
                let groups = try await asset.load(.trackGroups)
                attributes.hasAlternateGroups = groups.contains { $0.trackIDs.count > 1 }
            } catch {
                try handleQuickTimeAttributeError(error, attributes: &attributes)
            }
        } else if probe.isMatroskaFamily {
            do {
                let demuxer = try MatroskaDemuxer(url: originalURL)
                if let video = demuxer.tracks.first(where: \.isVideo) {
                    attributes.videoEnabled = !demuxer.disabledTrackNumbers.contains(video.number)
                }
                if let audio = demuxer.tracks.first(where: { !$0.isVideo }) {
                    attributes.audioEnabled = !demuxer.disabledTrackNumbers.contains(audio.number)
                }
            } catch {
                try handleMatroskaAttributeError(error, attributes: &attributes)
            }
        }
        return attributes
    }

    static func handleQuickTimeAttributeError(
        _ error: any Error, attributes: inout OriginalTrackAttributes
    ) throws {
        if error is CancellationError { throw CancellationError() }
        if UntrustedMediaAsset.isReferenceForbidden(error) {
            throw EngineError.invalidInput(.externalMediaReference)
        }
        guard !isAccessOrIOError(error), isExpectedAssetInspectionUnavailable(error) else {
            throw error
        }
        attributes.trackAttributesUnknown = true
    }

    static func handleMatroskaAttributeError(
        _ error: any Error, attributes: inout OriginalTrackAttributes
    ) throws {
        if error is CancellationError { throw CancellationError() }
        if let format = error as? FormatError {
            switch format {
            case .corrupt, .unsupported, .decoderFailure:
                attributes.trackAttributesUnknown = true
                return
            case .io, .inputTooLarge, .frameMemoryExceeded, .nonFiniteAudioSample, .encoderFailure:
                throw format
            }
        }
        throw error
    }

    private static func isAccessOrIOError(_ error: any Error) -> Bool {
        var current: NSError? = error as NSError
        while let nsError = current {
            if nsError.domain == NSPOSIXErrorDomain { return true }
            if nsError.domain == NSCocoaErrorDomain {
                let code = CocoaError.Code(rawValue: nsError.code)
                switch code {
                case .fileReadNoPermission, .fileNoSuchFile, .fileReadNoSuchFile,
                    .fileReadInvalidFileName, .fileReadTooLarge, .fileReadUnknown:
                    return true
                default:
                    break
                }
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private static func isExpectedAssetInspectionUnavailable(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain {
            switch AVError.Code(rawValue: nsError.code) {
            case .fileFormatNotRecognized, .fileFailedToParse, .decodeFailed, .decoderNotFound,
                .formatUnsupported, .unknown:
                return true
            default:
                return false
            }
        }
        return nsError.domain == NSOSStatusErrorDomain
    }

    static func artworkFitsPixelLimit(width: Int, height: Int, maximumPixels: Int = maximumArtworkPixels) -> Bool {
        guard width > 0, height > 0, width <= maximumArtworkDimension, height <= maximumArtworkDimension else {
            return false
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return !overflow && pixels <= maximumPixels
    }

    private static func artworkFitsLimits(_ bytes: Data, maximumBytes: Int, maximumPixels: Int) -> Bool {
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { return false }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        return artworkFitsPixelLimit(width: width, height: height, maximumPixels: maximumPixels)
    }

    private static func extractAttachedPicture(
        from input: URL, probe: Probe, stream: Probe.Stream, workingDirectory: URL, tools: MediaDownloadTools,
        availableBytes: (@Sendable (URL) throws -> Int64)?,
        noProgressTimeout: Duration, diskMonitorInterval: Duration,
        maximumBytes: Int, maximumPixels: Int
    ) async throws -> Artwork? {
        let coverURL = workingDirectory.appending(path: "cover.bin", directoryHint: .notDirectory)
        let runner = MediaToolProcess()
        let exceededDisk = Mutex<(required: Int64, available: Int64)?>(nil)
        let exceededArtwork = Mutex(false)
        let checkLimits: @Sendable () -> Void = {
            do {
                let live = try currentDiskBudget(in: workingDirectory, availableBytes: availableBytes)
                if live.availableBytes < live.headroomBytes {
                    exceededDisk.withLock {
                        if $0 == nil { $0 = (required: live.headroomBytes, available: max(0, live.availableBytes)) }
                    }
                    runner.cancel()
                    return
                }
            } catch {
                logger.error("Artwork disk budget check failed: \(error.localizedDescription, privacy: .private)")
            }
            if FileManager.default.fileExists(atPath: coverURL.path) {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: coverURL.path)
                    if let size = attributes[.size] as? Int64, size > Int64(maximumBytes) {
                        exceededArtwork.withLock { $0 = true }
                        runner.cancel()
                    }
                } catch {
                    logger.error("Artwork size check failed: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
        do {
            _ = try await runner.runTyped(
                executable: tools.ffmpeg,
                arguments: pictureExtractArguments(for: input, probe: probe, pictureStream: stream, output: coverURL),
                directory: workingDirectory,
                tools: tools,
                captureOutput: false,
                includeTLSCertificate: false,
                noProgressTimeout: noProgressTimeout,
                monitor: MediaToolProcess.Monitor(interval: diskMonitorInterval, tick: checkLimits))
        } catch is CancellationError {
            if let breach = exceededDisk.withLock({ $0 }) {
                throw EngineError.insufficientDiskSpace(
                    requiredBytes: breach.required, availableBytes: breach.available)
            }
            if exceededArtwork.withLock({ $0 }) { return nil }
            throw CancellationError()
        } catch MediaToolProcess.Failure.exited {
            // Drop undecodable covers instead of failing conversion.
            return nil
        } catch let failure as MediaToolProcess.Failure {
            throw failure.engineError(path: input.path)
        }
        guard FileManager.default.fileExists(atPath: coverURL.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: coverURL.path)
        guard let written = attributes[.size] as? Int64, written > 0, written <= Int64(maximumBytes) else {
            return nil
        }
        let bytes = try Data(contentsOf: coverURL)
        guard artworkFitsLimits(bytes, maximumBytes: maximumBytes, maximumPixels: maximumPixels) else { return nil }
        let mimeType: String
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            mimeType = "image/png"
        } else if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            mimeType = "image/jpeg"
        } else {
            return nil
        }
        return Artwork(data: bytes, mimeType: mimeType)
    }

    static func hasUnreadableAPETag(in url: URL, probe: Probe) throws -> Bool {
        let reader = try FileHandle(forReadingFrom: url)
        defer {
            do {
                try reader.close()
            } catch {
                logger.error("APE tag probe close failed: \(error.localizedDescription, privacy: .private)")
            }
        }
        let fileSize = try reader.seekToEnd()
        guard fileSize >= apeFooterLength else { return false }
        let readLength = min(fileSize, apeFooterLength + id3v1TagLength)
        try reader.seek(toOffset: fileSize - readLength)
        guard let tailBytes = try reader.read(upToCount: Int(readLength)),
            tailBytes.count >= Int(apeFooterLength)
        else { return false }
        var footerOffsets = [tailBytes.count - Int(apeFooterLength)]
        if tailBytes.count >= Int(apeFooterLength + id3v1TagLength) {
            let id3Start = tailBytes.count - Int(id3v1TagLength)
            if tailBytes[id3Start..<(id3Start + id3v1Preamble.count)].elementsEqual(id3v1Preamble) {
                footerOffsets.append(id3Start - Int(apeFooterLength))
            }
        }
        let probeHasNoMetadata = (probe.format?.tags ?? [:]).isEmpty && probe.attachedPictureStreams.isEmpty
        for offset in footerOffsets {
            let footer = tailBytes[offset..<(offset + Int(apeFooterLength))]
            guard footer.starts(with: apeTagPreamble) else { continue }
            let version = readLittleEndianUInt32(footer, at: 8)
            guard version == 1_000 || version == 2_000 else { continue }
            let tagSize = readLittleEndianUInt32(footer, at: 12)
            let itemCount = readLittleEndianUInt32(footer, at: 16)
            let flags = readLittleEndianUInt32(footer, at: 20)
            guard (flags & apeHeaderFlag) == 0, tagSize >= UInt32(apeFooterLength) else { continue }
            if tagSize > ffmpegAPETagSizeLimit || (itemCount > 0 && probeHasNoMetadata) {
                return true
            }
        }
        return false
    }

    private static func readLittleEndianUInt32(_ slice: Data, at relativeOffset: Int) -> UInt32 {
        let base = slice.startIndex + relativeOffset
        return UInt32(slice[base])
            | (UInt32(slice[base + 1]) << 8)
            | (UInt32(slice[base + 2]) << 16)
            | (UInt32(slice[base + 3]) << 24)
    }

    // Shared hardened prefix for fallback ffmpeg.
    private static func hardenedInputArguments(
        for input: URL, isQuickTimeFamily: Bool, videoInputDecoder: String? = nil
    ) -> [String] {
        var arguments = [
            "-hide_banner", "-nostdin", "-v", "error", "-n",
            "-threads", String(threadLimit),
            "-protocol_whitelist", "file",
            "-format_whitelist", isQuickTimeFamily ? quickTimeDemuxers : nonQuickTimeDemuxers,
        ]
        if isQuickTimeFamily {
            arguments += ["-enable_drefs", "0", "-use_absolute_path", "0"]
        }
        if let videoInputDecoder {
            arguments += ["-c:v", videoInputDecoder]
        }
        arguments += ["-i", fileURI(for: input)]
        return arguments
    }

    private static func videoCodecArguments(for profile: VideoProfile, stream: Probe.Stream) -> [String] {
        var arguments: [String]
        switch profile {
        case .hevcSDR:
            arguments = [
                "-c:v", "hevc_videotoolbox", "-q:v", String(hevcQuality),
                "-g", String(hevcKeyframeInterval), "-bf", "0", "-tag:v", "hvc1",
                "-pix_fmt", "yuv420p",
            ]
        case .hevcMain10:
            arguments = [
                "-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-q:v", String(hevcQuality),
                "-g", String(hevcKeyframeInterval), "-bf", "0", "-tag:v", "hvc1",
                "-pix_fmt", "p010le",
            ]
        case .proresStandard422:
            // Explicit pix_fmt avoids yuv420p ProRes corruption.
            arguments = ["-c:v", "prores_videotoolbox", "-profile:v", "standard", "-pix_fmt", "p210le"]
        case .prores4444:
            arguments = ["-c:v", "prores_videotoolbox", "-profile:v", "4444", "-pix_fmt", "p410le"]
        case .prores4444Alpha:
            arguments = ["-c:v", "prores_videotoolbox", "-profile:v", "4444", "-pix_fmt", "bgra"]
        }
        if let primaries = stream.colorPrimaries?.lowercased(), allowedColorPrimaries.contains(primaries) {
            arguments += ["-color_primaries", primaries]
        }
        if let transfer = stream.colorTransfer?.lowercased(), allowedColorTransfers.contains(transfer) {
            arguments += ["-color_trc", transfer]
        }
        if let space = stream.colorSpace?.lowercased(), allowedColorSpaces.contains(space) {
            arguments += ["-colorspace", space]
        }
        if let range = stream.colorRange?.lowercased(), allowedColorRanges.contains(range) {
            arguments += ["-color_range", range]
        }
        return arguments
    }

    private static func unpreservedKind(for stream: Probe.Stream) -> UnpreservedStream {
        switch stream.codecType {
        case "subtitle":
            let name = stream.codecName?.lowercased() ?? ""
            return closedCaptionCodecs.contains(name) ? .closedCaption : .subtitle
        case "attachment":
            return .attachment
        case "data":
            let tag = stream.codecTagString?.lowercased() ?? ""
            let handler = stream.tags?["handler_name"]?.lowercased() ?? ""
            if tag == "tmcd" || stream.tags?["timecode"] != nil || handler.contains("timecode") {
                return .timecode
            }
            if tag == "mebx" || handler.contains("metadata") {
                return .metadata
            }
            return .data
        default:
            return .data
        }
    }

    private static func requireConsent(for omitted: [UnpreservedStream], consented: Set<UnpreservedStream>) throws {
        let unconsented = omitted.filter { !consented.contains($0) }
        if !unconsented.isEmpty {
            throw EngineError.invalidInput(.unpreservedStreams(unconsented))
        }
    }

    private static func estimateVideoBytes(
        originalURL: URL, probe: Probe, videoStream: Probe.Stream, audioStream: Probe.Stream?,
        videoProfile: VideoProfile, audioProfile: AudioProfile?
    ) throws -> Int64 {
        guard let duration = probe.durationSeconds, duration > 0 else {
            return try unknownDurationEstimate(for: originalURL)
        }
        let width = max(1, videoStream.width ?? 1920)
        let height = max(1, videoStream.height ?? 1080)
        let pixelScale = Double(width) * Double(height) / referencePixels
        let videoBytesPerSecond: Double
        switch videoProfile {
        case .hevcSDR, .hevcMain10:
            videoBytesPerSecond = min(
                maximumHEVCBytesPerSecond, max(minimumHEVCBytesPerSecond, hevcBytesPerSecondAt1080p * pixelScale))
        case .proresStandard422:
            videoBytesPerSecond = min(
                maximumProResStandardBytesPerSecond,
                max(minimumProResStandardBytesPerSecond, proresStandardBytesPerSecondAt1080p * pixelScale))
        case .prores4444, .prores4444Alpha:
            videoBytesPerSecond = min(
                maximumProRes4444BytesPerSecond,
                max(minimumProRes4444BytesPerSecond, prores4444BytesPerSecondAt1080p * pixelScale))
        }
        let audioBytesPerSecond: Double
        if let audioStream, let audioProfile {
            let channels = max(1, audioStream.channels ?? defaultAudioChannels)
            audioBytesPerSecond = audioStream.parsedSampleRate * Double(channels) * Double(audioProfile.bytesPerSample)
        } else {
            audioBytesPerSecond = 0
        }
        let scaled = duration * (videoBytesPerSecond + audioBytesPerSecond) * estimateSafetyMultiplier
        guard scaled.isFinite, scaled < Double(Int64.max - fixedOverheadBytes - diskHeadroomBytes) else {
            return Int64.max / 2
        }
        return Int64(scaled.rounded(.up)) + fixedOverheadBytes
    }

    private static func estimateAudioBytes(
        originalURL: URL, probe: Probe, audioStream: Probe.Stream, profile: AudioProfile
    ) throws -> Int64 {
        guard let duration = probe.durationSeconds, duration > 0 else {
            return try unknownDurationEstimate(for: originalURL)
        }
        let channels = max(1, audioStream.channels ?? defaultAudioChannels)
        let bytesPerSecond = audioStream.parsedSampleRate * Double(channels) * Double(profile.bytesPerSample)
        let scaled = duration * bytesPerSecond * estimateSafetyMultiplier
        guard scaled.isFinite, scaled < Double(Int64.max - fixedOverheadBytes - diskHeadroomBytes) else {
            return Int64.max / 2
        }
        return Int64(scaled.rounded(.up)) + fixedOverheadBytes
    }

    private static func unknownDurationEstimate(for url: URL) throws -> Int64 {
        let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let (multiplied, overflow) = size.multipliedReportingOverflow(by: unknownDurationSizeMultiplier)
        guard !overflow else { return Int64.max / 2 }
        return max(multiplied, minimumUnknownDurationBytes)
    }

    private struct DiskSpaceBudget: Sendable {
        let availableBytes: Int64
        let headroomBytes: Int64
        var writeLimitBytes: Int64 { max(0, availableBytes - headroomBytes) }
    }

    private static func checkDiskSpace(
        requiredIntermediateBytes: Int64, in directory: URL, availableBytes: (@Sendable (URL) throws -> Int64)?
    ) throws -> DiskSpaceBudget {
        let budget = try currentDiskBudget(in: directory, availableBytes: availableBytes)
        let (required, overflow) = requiredIntermediateBytes.addingReportingOverflow(budget.headroomBytes)
        let totalRequired = overflow ? Int64.max : required
        guard budget.availableBytes >= totalRequired else {
            throw EngineError.insufficientDiskSpace(
                requiredBytes: totalRequired, availableBytes: max(0, budget.availableBytes))
        }
        return budget
    }

    private static func currentDiskBudget(
        in directory: URL, availableBytes: (@Sendable (URL) throws -> Int64)?
    ) throws -> DiskSpaceBudget {
        if let availableBytes {
            return DiskSpaceBudget(availableBytes: try availableBytes(directory), headroomBytes: diskHeadroomBytes)
        }
        return try volumeDiskBudget(for: directory)
    }

    private static func volumeDiskBudget(for directory: URL) throws -> DiskSpaceBudget {
        let values = try directory.resourceValues(forKeys: [
            .volumeIsRootFileSystemKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        let isRoot = values.volumeIsRootFileSystem == true
        let available: Int64
        if isRoot, let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            available = important
        } else if let capacity = values.volumeAvailableCapacity {
            available = Int64(capacity)
        } else if let important = values.volumeAvailableCapacityForImportantUsage {
            available = important
        } else {
            throw EngineError.commitFailed("available disk space is unavailable")
        }
        let headroom: Int64
        if !isRoot, let total = values.volumeTotalCapacity, total > 0 {
            // Removable volumes may be under 512 MB.
            headroom = min(diskHeadroomBytes, Int64(total) / nonRootHeadroomDivisor)
        } else {
            headroom = diskHeadroomBytes
        }
        return DiskSpaceBudget(availableBytes: available, headroomBytes: headroom)
    }

    static func makeProgressWatchdogReset() -> @Sendable (String) -> Bool {
        let lastOutTime = Mutex<Int64?>(nil)
        return { line in
            guard line.hasPrefix(progressTimePrefix),
                let value = Int64(line.dropFirst(progressTimePrefix.count))
            else { return false }
            return lastOutTime.withLock { previous in
                guard previous.map({ value > $0 }) ?? (value > 0) else { return false }
                previous = value
                return true
            }
        }
    }

    private static func runTranscode(
        arguments: [String], duration: Double?, outputURL: URL, workingDirectory: URL,
        tools: MediaDownloadTools, spaceBudget: DiskSpaceBudget,
        availableBytes: (@Sendable (URL) throws -> Int64)?, noProgressTimeout: Duration,
        diskMonitorInterval: Duration, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let runner = MediaToolProcess()
        let diskLimit = spaceBudget.writeLimitBytes
        let exceeded = Mutex<(required: Int64, available: Int64)?>(nil)
        let checkCapacity: @Sendable () -> Void = {
            do {
                let live = try currentDiskBudget(in: workingDirectory, availableBytes: availableBytes)
                if live.availableBytes < live.headroomBytes {
                    exceeded.withLock {
                        if $0 == nil { $0 = (required: live.headroomBytes, available: max(0, live.availableBytes)) }
                    }
                    runner.cancel()
                    return
                }
            } catch {
                logger.error("Live disk budget check failed: \(error.localizedDescription, privacy: .private)")
            }
            if FileManager.default.fileExists(atPath: outputURL.path) {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
                    if let size = attributes[.size] as? Int64, size > diskLimit {
                        let (required, overflow) = size.addingReportingOverflow(spaceBudget.headroomBytes)
                        exceeded.withLock {
                            if $0 == nil {
                                $0 = (
                                    required: overflow ? Int64.max : required,
                                    available: max(0, spaceBudget.availableBytes)
                                )
                            }
                        }
                        runner.cancel()
                    }
                } catch {
                    logger.error("Staged file size check failed: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
        do {
            _ = try await runner.runTyped(
                executable: tools.ffmpeg,
                arguments: arguments,
                directory: workingDirectory,
                tools: tools,
                captureOutput: false,
                includeTLSCertificate: false,
                noProgressTimeout: noProgressTimeout,
                watchdogReset: MediaToolProcess.WatchdogReset(matches: makeProgressWatchdogReset()),
                monitor: MediaToolProcess.Monitor(interval: diskMonitorInterval, tick: checkCapacity)
            ) { line in
                if line.hasPrefix(progressTimePrefix), let duration, duration > 0,
                    let microseconds = Double(line.dropFirst(progressTimePrefix.count)), microseconds.isFinite
                {
                    progress(min(max(microseconds / microsecondsPerSecond / duration, 0), 1))
                }
            }
        } catch is CancellationError {
            if let breach = exceeded.withLock({ $0 }) {
                throw EngineError.insufficientDiskSpace(
                    requiredBytes: breach.required, availableBytes: breach.available)
            }
            throw CancellationError()
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        guard let written = attributes[.size] as? Int64, written > 0 else {
            throw EngineError.fallbackConversionUnfaithful("staged intermediate is empty")
        }
    }

    private static func rejectExternalReferencesIfApplicable(_ url: URL) async throws {
        do {
            try await UntrustedMediaAsset.rejectExternalReferences(in: url)
        } catch EngineError.invalidInput(.externalMediaReference) {
            throw EngineError.invalidInput(.externalMediaReference)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Non-AVFoundation formats probe via ffprobe.
            let wrapped = EngineError.wrapping(error, path: url.path)
            if case .permissionDenied = wrapped { throw wrapped }
        }
    }
}
