import Formats
import Foundation
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
    let codedSize: PixelSize?
    let videoTags: [String: String]
    let audioTags: [String: String]
    let attachedPictureCount: Int
    let attachedPicture: Artwork?

    private static let supportedAudioTagKeys: Set<String> = [
        "title", "artist", "album", "cover art (front)",
    ]
    private static let ignoredAudioTagKeys: Set<String> = [
        "encoder", "software", "vendor", "writing_application", "writing_library",
        "compatible_brands", "major_brand", "minor_version", "duration",
        "handler_name", "vendor_id", "bps", "number_of_frames", "number_of_bytes",
    ]

    var hasUnsupportedAudioTags: Bool {
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
        var tags = AudioTags()
        for (key, value) in formatTags where !value.isEmpty {
            switch key.lowercased() {
            case "title" where tags.title == nil: tags.title = value
            case "artist" where tags.artist == nil: tags.artist = value
            case "album" where tags.album == nil: tags.album = value
            default: break
            }
        }
        tags.artwork = attachedPicture
        return tags
    }
}

enum StagedMediaFallback {
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
            let channels: Int?
            let channelLayout: String?
            let sampleFormat: String?
            let sampleRate: String?
            let duration: String?
            let disposition: Disposition?
            let tags: [String: String]?

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
                case channels
                case channelLayout = "channel_layout"
                case sampleFormat = "sample_fmt"
                case sampleRate = "sample_rate"
                case duration
                case disposition
                case tags
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

            var hasOddDimensions: Bool {
                guard let width, let height, width > 0, height > 0 else { return false }
                return width % 2 != 0 || height % 2 != 0
            }

            var codedSize: PixelSize? {
                guard let width, let height, width > 0, height > 0 else { return nil }
                return PixelSize(width: width, height: height)
            }

            var parsedBitsPerRawSample: Int? {
                bitsPerRawSample.flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
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

            var isLowBitDepthIntegerAudio: Bool {
                guard isLosslessAudioCodec, !isFloatingPointAudioSource else { return false }
                if let bits = effectiveAudioBitDepth, bits > 16 { return false }
                guard let sampleFormat = sampleFormat?.lowercased() else { return false }
                return StagedMediaFallback.sixteenBitOrLessSampleFormats.contains(sampleFormat)
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

        func sourceDescription(originalURL: URL, attachedPicture: Artwork? = nil) -> FallbackSourceDescription {
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
                codedSize: video?.codedSize,
                videoTags: StagedMediaFallback.userTags(from: video?.tags),
                audioTags: StagedMediaFallback.userTags(from: audio?.tags),
                attachedPictureCount: attachedPictureStreams.count,
                attachedPicture: attachedPicture)
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
        case alacM4A
        case cafPCM24
        case cafPCM32
        case cafPCMFloat32

        var fileExtension: String {
            switch self {
            case .alacM4A: "m4a"
            case .cafPCM24, .cafPCM32, .cafPCMFloat32: "caf"
            case .pcm16, .pcm24, .pcm32, .pcmFloat32: "mov"
            }
        }

        var muxerFormat: String {
            switch self {
            case .alacM4A: "ipod"
            case .cafPCM24, .cafPCM32, .cafPCMFloat32: "caf"
            case .pcm16, .pcm24, .pcm32, .pcmFloat32: "mov"
            }
        }

        var ffmpegCodec: String {
            switch self {
            case .pcm16: "pcm_s16le"
            case .pcm24, .cafPCM24: "pcm_s24le"
            case .pcm32, .cafPCM32: "pcm_s32le"
            case .pcmFloat32, .cafPCMFloat32: "pcm_f32le"
            case .alacM4A: "alac"
            }
        }

        var bytesPerSample: Int {
            switch self {
            case .pcm16: 2
            case .pcm24, .cafPCM24, .alacM4A: 3
            case .pcm32, .cafPCM32, .pcmFloat32, .cafPCMFloat32: 4
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

    static let probeNoProgressTimeout = Duration.seconds(30)
    static let transcodeNoProgressTimeout = Duration.seconds(60)
    static let diskMonitorInterval = Duration.seconds(1)
    static let maximumALACChannels = 6
    static let maximumALACBitDepth = 24
    static let diskHeadroomBytes: Int64 = 512_000_000

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

    private static let losslessAudioCodecs: Set<String> = [
        "alac", "flac", "wavpack", "ape", "tta", "tak", "shorten", "mlp", "truehd", "wmalossless", "als", "dst",
    ]
    private static let floatingSampleFormats: Set<String> = ["flt", "fltp", "dbl", "dblp"]
    private static let sixteenBitOrLessSampleFormats: Set<String> = ["u8", "u8p", "s16", "s16p"]
    private static let closedCaptionCodecs: Set<String> = ["eia_608", "cea_608", "cea_708"]
    private static let alphaPixelFormatPrefixes = [
        "yuva", "rgba", "bgra", "argb", "abgr", "gbrap", "ya8", "ya16", "ayuv", "vuya",
    ]
    private static let chroma444Prefixes = [
        "yuv444", "yuvj444", "gbrp", "rgb24", "bgr24", "rgb48", "bgr48", "0rgb", "rgb0", "0bgr", "bgr0",
    ]
    private static let chroma422Prefixes = ["yuv422", "yuvj422", "uyvy", "yuyv", "p210", "p216", "v210"]
    private static let highBitDepthTokens = ["10", "12", "14", "16", "p010", "p016"]
    private static let hdrTransfers: Set<String> = ["smpte2084", "arib-std-b67"]
    private static let ignoredMetadataTagKeys: Set<String> = [
        "encoder", "writing_application", "writing_library", "compatible_brands", "major_brand", "minor_version",
        "muxingapp", "writingapp", "duration", "handler_name", "vendor_id", "bps", "number_of_frames",
        "number_of_bytes", "alpha_mode",
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
        for input: URL, probe: Probe, audioStream: Probe.Stream, attachedPicture: Probe.Stream? = nil,
        profile: AudioProfile, output: URL
    ) -> [String] {
        var arguments = hardenedInputArguments(for: input, isQuickTimeFamily: probe.isQuickTimeFamily)
        arguments += ["-map", "0:\(audioStream.index)"]
        if profile == .alacM4A, let attachedPicture {
            arguments += [
                "-map", "0:\(attachedPicture.index)", "-sn", "-dn", "-map_chapters", "-1", "-map_metadata", "0",
                "-max_muxing_queue_size", String(maxMuxingQueueSize),
                "-c:a", profile.ffmpegCodec,
                "-c:v", attachedPicture.isM4ACompatibleImage ? "copy" : "png",
                "-disposition:v:0", "attached_pic",
            ]
        } else {
            arguments += [
                "-vn", "-sn", "-dn", "-map_chapters", "-1", "-map_metadata", "0",
                "-max_muxing_queue_size", String(maxMuxingQueueSize),
                "-c:a", profile.ffmpegCodec,
            ]
        }
        arguments += ["-progress", "pipe:1", "-nostats", "-f", profile.muxerFormat, fileURI(for: output)]
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
        let result = try await MediaToolProcess().run(
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
        if stream.isFloatingPointAudioSource { return .pcmFloat32 }
        if let bits = stream.effectiveAudioBitDepth, bits > maximumALACBitDepth { return .pcm32 }
        if stream.isLowBitDepthIntegerAudio { return .pcm16 }
        return .pcm24
    }

    static func selectAudioOnlyProfile(for stream: Probe.Stream) -> AudioProfile {
        let channels = stream.channels ?? defaultAudioChannels
        if stream.isFloatingPointAudioSource { return .cafPCMFloat32 }
        if let bits = stream.effectiveAudioBitDepth, bits > maximumALACBitDepth { return .cafPCM32 }
        if channels > maximumALACChannels { return .cafPCM24 }
        return .alacM4A
    }

    static func videoUnpreservedStreams(in probe: Probe) throws -> [UnpreservedStream] {
        guard !probe.videoStreams.isEmpty else {
            throw EngineError.decodeFailed("no video track")
        }
        if probe.videoStreams.count > 1 || probe.audioStreams.count > 1 {
            throw EngineError.invalidInput(.multipleTracks)
        }
        var found: Set<UnpreservedStream> = []
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
        diskMonitorInterval: Duration = Self.diskMonitorInterval
    ) async throws -> StagedVideo {
        let resolvedTools = try tools ?? resolveTools()
        let probed = try await probe(originalURL, tools: resolvedTools)
        let omitted = try videoUnpreservedStreams(in: probed)
        if enforceStreamConsent {
            try requireConsent(for: omitted, consented: consentedStreams ?? context.omittedStreams)
        }
        guard let videoStream = probed.videoStreams.first else {
            throw EngineError.decodeFailed("no video track")
        }
        if videoStream.hasAlphaModeTag, !videoStream.hasAlphaPixelFormat,
            videoStream.preferredAlphaInputDecoder == nil
        {
            throw EngineError.videoAlphaUnsupported
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
        try await runTranscode(
            arguments: arguments, duration: probed.durationSeconds, outputURL: outputURL,
            workingDirectory: stagingDirectory, tools: resolvedTools, spaceBudget: budget,
            availableBytes: availableBytes, noProgressTimeout: noProgressTimeout,
            diskMonitorInterval: diskMonitorInterval, progress: context.progress)
        try await UntrustedMediaAsset.rejectExternalReferences(in: outputURL)
        if enforceStreamConsent, !omitted.isEmpty { context.warnStreamsOmitted(omitted) }
        return StagedVideo(
            originalURL: originalURL, stagedURL: outputURL, profile: videoProfile,
            origin: probed.sourceDescription(originalURL: originalURL), omittedStreams: omitted)
    }

    static func prepareAudio(
        _ originalURL: URL,
        context: ItemContext,
        enforceStreamConsent: Bool = true,
        tools: MediaDownloadTools? = nil,
        availableBytes: (@Sendable (URL) throws -> Int64)? = nil,
        noProgressTimeout: Duration = transcodeNoProgressTimeout,
        diskMonitorInterval: Duration = Self.diskMonitorInterval
    ) async throws -> StagedAudio {
        let resolvedTools = try tools ?? resolveTools()
        let probed = try await probe(originalURL, tools: resolvedTools)
        let omitted = try audioUnpreservedStreams(in: probed)
        if enforceStreamConsent {
            try requireConsent(for: omitted, consented: context.omittedStreams)
        }
        guard let audioStream = probed.audioStreams.first else {
            throw EngineError.decodeFailed("no audio track")
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
        let attachedPictureStream = probed.attachedPictureStreams.count == 1 ? probed.attachedPictureStreams.first : nil
        let arguments = audioTranscodeArguments(
            for: originalURL, probe: probed, audioStream: audioStream, attachedPicture: attachedPictureStream,
            profile: profile, output: outputURL)
        context.phase(.convertingInput)
        try await runTranscode(
            arguments: arguments, duration: probed.durationSeconds, outputURL: outputURL,
            workingDirectory: stagingDirectory, tools: resolvedTools, spaceBudget: budget,
            availableBytes: availableBytes, noProgressTimeout: noProgressTimeout,
            diskMonitorInterval: diskMonitorInterval, progress: context.progress)
        try await UntrustedMediaAsset.rejectExternalReferences(in: outputURL)
        var extractedArtwork: Artwork?
        if profile != .alacM4A, let attachedPictureStream {
            extractedArtwork = try await extractAttachedPicture(
                from: originalURL, probe: probed, stream: attachedPictureStream,
                workingDirectory: stagingDirectory, tools: resolvedTools, noProgressTimeout: noProgressTimeout)
        }
        if enforceStreamConsent, !omitted.isEmpty { context.warnStreamsOmitted(omitted) }
        return StagedAudio(
            originalURL: originalURL, stagedURL: outputURL, profile: profile,
            origin: probed.sourceDescription(originalURL: originalURL, attachedPicture: extractedArtwork),
            omittedStreams: omitted)
    }

    private static func extractAttachedPicture(
        from input: URL, probe: Probe, stream: Probe.Stream, workingDirectory: URL, tools: MediaDownloadTools,
        noProgressTimeout: Duration
    ) async throws -> Artwork {
        let coverURL = workingDirectory.appending(path: "cover.bin", directoryHint: .notDirectory)
        _ = try await MediaToolProcess().run(
            executable: tools.ffmpeg,
            arguments: pictureExtractArguments(for: input, probe: probe, pictureStream: stream, output: coverURL),
            directory: workingDirectory,
            tools: tools,
            captureOutput: false,
            includeTLSCertificate: false,
            noProgressTimeout: noProgressTimeout)
        let bytes = try Data(contentsOf: coverURL)
        guard !bytes.isEmpty else { throw EngineError.decodeFailed("extracted cover artwork is empty") }
        let mimeType = bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
        return Artwork(data: bytes, mimeType: mimeType)
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
            _ = try await runner.run(
                executable: tools.ffmpeg,
                arguments: arguments,
                directory: workingDirectory,
                tools: tools,
                captureOutput: false,
                includeTLSCertificate: false,
                noProgressTimeout: noProgressTimeout,
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
            throw EngineError.decodeFailed("staged intermediate is empty")
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
