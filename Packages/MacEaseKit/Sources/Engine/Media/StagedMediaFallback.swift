import Foundation
import Synchronization

enum StagedMediaFallback {
    struct Probe: Decodable, Sendable {
        struct Format: Decodable, Sendable {
            let formatName: String?
            let duration: String?
            let size: String?

            enum CodingKeys: String, CodingKey {
                case formatName = "format_name"
                case duration
                case size
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
            let colorPrimaries: String?
            let colorTransfer: String?
            let colorSpace: String?
            let colorRange: String?
            let channels: Int?
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
                case colorPrimaries = "color_primaries"
                case colorTransfer = "color_transfer"
                case colorSpace = "color_space"
                case colorRange = "color_range"
                case channels
                case sampleFormat = "sample_fmt"
                case sampleRate = "sample_rate"
                case duration
                case disposition
                case tags
            }

            var isAttachedPicture: Bool {
                disposition?.attachedPic == 1 || disposition?.timedThumbnails == 1
            }

            var parsedBitsPerRawSample: Int? {
                bitsPerRawSample.flatMap(Int.init)
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
                if let bits = parsedBitsPerRawSample, bits > 16 { return false }
                guard let sampleFormat = sampleFormat?.lowercased() else { return false }
                return StagedMediaFallback.sixteenBitOrLessSampleFormats.contains(sampleFormat)
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
        case pcmFloat32
        case alacM4A
        case cafPCM24
        case cafPCMFloat32

        var fileExtension: String {
            switch self {
            case .alacM4A: "m4a"
            case .cafPCM24, .cafPCMFloat32: "caf"
            case .pcm16, .pcm24, .pcmFloat32: "mov"
            }
        }

        var muxerFormat: String {
            switch self {
            case .alacM4A: "ipod"
            case .cafPCM24, .cafPCMFloat32: "caf"
            case .pcm16, .pcm24, .pcmFloat32: "mov"
            }
        }

        var ffmpegCodec: String {
            switch self {
            case .pcm16: "pcm_s16le"
            case .pcm24, .cafPCM24: "pcm_s24le"
            case .pcmFloat32, .cafPCMFloat32: "pcm_f32le"
            case .alacM4A: "alac"
            }
        }

        var bytesPerSample: Int {
            switch self {
            case .pcm16: 2
            case .pcm24, .cafPCM24, .alacM4A: 3
            case .pcmFloat32, .cafPCMFloat32: 4
            }
        }
    }

    struct StagedVideo: Sendable {
        let originalURL: URL
        let stagedURL: URL
        let profile: VideoProfile
        let omittedStreams: [UnpreservedStream]
    }

    struct StagedAudio: Sendable {
        let originalURL: URL
        let stagedURL: URL
        let profile: AudioProfile
        let sourceIsLossy: Bool
        let omittedStreams: [UnpreservedStream]
    }

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
    private static let maximumALACChannels = 6
    private static let estimateSafetyMultiplier = 1.25
    private static let fixedOverheadBytes: Int64 = 64_000_000
    private static let unknownDurationSizeMultiplier: Int64 = 4
    private static let minimumUnknownDurationBytes: Int64 = 256_000_000
    static let diskHeadroomBytes: Int64 = 512_000_000
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

    static func resolveTools() throws -> MediaDownloadTools {
        do {
            if let directory = ProcessInfo.processInfo.environment["MACEASE_MEDIA_TOOLS"],
                Bundle.main.bundleIdentifier?.hasPrefix("io.github.tky27.MacEase") != true
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
        var arguments = hardenedInputArguments(for: input, isQuickTimeFamily: probe.isQuickTimeFamily)
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
        for input: URL, probe: Probe, audioStream: Probe.Stream, profile: AudioProfile, output: URL
    ) -> [String] {
        var arguments = hardenedInputArguments(for: input, isQuickTimeFamily: probe.isQuickTimeFamily)
        arguments += [
            "-map", "0:\(audioStream.index)", "-vn", "-sn", "-dn", "-map_chapters", "-1", "-map_metadata", "0",
            "-max_muxing_queue_size", String(maxMuxingQueueSize),
            "-c:a", profile.ffmpegCodec,
            "-progress", "pipe:1", "-nostats",
            "-f", profile.muxerFormat, fileURI(for: output),
        ]
        return arguments
    }

    static func probe(
        _ input: URL, workingDirectory: URL, tools: MediaDownloadTools? = nil
    ) async throws -> Probe {
        try await rejectExternalReferencesIfApplicable(input)
        let resolvedTools = try tools ?? resolveTools()
        let result = try await MediaToolProcess().run(
            executable: resolvedTools.ffprobe,
            arguments: probeArguments(for: input),
            directory: workingDirectory,
            tools: resolvedTools,
            captureOutput: true,
            includeTLSCertificate: false)
        do {
            return try JSONDecoder().decode(Probe.self, from: result.stdout)
        } catch {
            throw EngineError.decodeFailed("ffprobe output could not be decoded")
        }
    }

    static func selectVideoProfile(for stream: Probe.Stream) -> VideoProfile {
        let pixelFormat = stream.pixelFormat?.lowercased() ?? ""
        if alphaPixelFormatPrefixes.contains(where: { pixelFormat.hasPrefix($0) }) {
            return .prores4444Alpha
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
        if stream.isLowBitDepthIntegerAudio { return .pcm16 }
        return .pcm24
    }

    static func selectAudioOnlyProfile(for stream: Probe.Stream) -> AudioProfile {
        let channels = stream.channels ?? defaultAudioChannels
        if stream.isFloatingPointAudioSource { return .cafPCMFloat32 }
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
        tools: MediaDownloadTools? = nil,
        availableBytes: ((URL) throws -> Int64)? = nil
    ) async throws -> StagedVideo {
        let stagingDirectory = try context.stagingDirectory(for: originalURL)
        let resolvedTools = try tools ?? resolveTools()
        let probed = try await probe(originalURL, workingDirectory: stagingDirectory, tools: resolvedTools)
        let omitted = try videoUnpreservedStreams(in: probed)
        if enforceStreamConsent {
            try requireConsent(for: omitted, consented: context.omittedStreams)
        }
        guard let videoStream = probed.videoStreams.first else {
            throw EngineError.decodeFailed("no video track")
        }
        let audioStream = probed.audioStreams.first
        let videoProfile = selectVideoProfile(for: videoStream)
        let audioProfile = audioStream.map(selectVideoAudioProfile(for:))
        let estimatedBytes = try estimateVideoBytes(
            originalURL: originalURL, probe: probed, videoStream: videoStream, audioStream: audioStream,
            videoProfile: videoProfile, audioProfile: audioProfile)
        let budget = try checkDiskSpace(
            requiredIntermediateBytes: estimatedBytes, in: stagingDirectory, availableBytes: availableBytes)
        let outputURL = stagingDirectory.appending(path: "fallback.mov", directoryHint: .notDirectory)
        let arguments = videoTranscodeArguments(
            for: originalURL, probe: probed, videoStream: videoStream, audioStream: audioStream,
            videoProfile: videoProfile, audioProfile: audioProfile, output: outputURL)
        context.phase(.convertingInput)
        try await runTranscode(
            arguments: arguments, duration: probed.durationSeconds, outputURL: outputURL,
            workingDirectory: stagingDirectory, tools: resolvedTools, spaceBudget: budget,
            progress: context.progress)
        try await UntrustedMediaAsset.rejectExternalReferences(in: outputURL)
        if enforceStreamConsent, !omitted.isEmpty { context.warnStreamsOmitted(omitted) }
        return StagedVideo(
            originalURL: originalURL, stagedURL: outputURL, profile: videoProfile, omittedStreams: omitted)
    }

    static func prepareAudio(
        _ originalURL: URL,
        context: ItemContext,
        enforceStreamConsent: Bool = true,
        tools: MediaDownloadTools? = nil,
        availableBytes: ((URL) throws -> Int64)? = nil
    ) async throws -> StagedAudio {
        let stagingDirectory = try context.stagingDirectory(for: originalURL)
        let resolvedTools = try tools ?? resolveTools()
        let probed = try await probe(originalURL, workingDirectory: stagingDirectory, tools: resolvedTools)
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
        let budget = try checkDiskSpace(
            requiredIntermediateBytes: estimatedBytes, in: stagingDirectory, availableBytes: availableBytes)
        let outputURL = stagingDirectory.appending(
            path: "fallback.\(profile.fileExtension)", directoryHint: .notDirectory)
        let arguments = audioTranscodeArguments(
            for: originalURL, probe: probed, audioStream: audioStream, profile: profile, output: outputURL)
        context.phase(.convertingInput)
        try await runTranscode(
            arguments: arguments, duration: probed.durationSeconds, outputURL: outputURL,
            workingDirectory: stagingDirectory, tools: resolvedTools, spaceBudget: budget,
            progress: context.progress)
        try await UntrustedMediaAsset.rejectExternalReferences(in: outputURL)
        if enforceStreamConsent, !omitted.isEmpty { context.warnStreamsOmitted(omitted) }
        return StagedAudio(
            originalURL: originalURL, stagedURL: outputURL, profile: profile,
            sourceIsLossy: !audioStream.isLosslessAudioCodec, omittedStreams: omitted)
    }

    // Shared hardened prefix for fallback ffmpeg.
    private static func hardenedInputArguments(for input: URL, isQuickTimeFamily: Bool) -> [String] {
        var arguments = [
            "-hide_banner", "-nostdin", "-v", "error", "-n",
            "-threads", String(threadLimit),
            "-protocol_whitelist", "file",
            "-format_whitelist", isQuickTimeFamily ? quickTimeDemuxers : nonQuickTimeDemuxers,
        ]
        if isQuickTimeFamily {
            arguments += ["-enable_drefs", "0", "-use_absolute_path", "0"]
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

    private struct DiskSpaceBudget {
        let availableBytes: Int64
        let headroomBytes: Int64
        var writeLimitBytes: Int64 { max(0, availableBytes - headroomBytes) }
    }

    private static func checkDiskSpace(
        requiredIntermediateBytes: Int64, in directory: URL, availableBytes: ((URL) throws -> Int64)?
    ) throws -> DiskSpaceBudget {
        let budget: DiskSpaceBudget
        if let availableBytes {
            budget = DiskSpaceBudget(availableBytes: try availableBytes(directory), headroomBytes: diskHeadroomBytes)
        } else {
            budget = try volumeDiskBudget(for: directory)
        }
        let (required, overflow) = requiredIntermediateBytes.addingReportingOverflow(budget.headroomBytes)
        let totalRequired = overflow ? Int64.max : required
        guard budget.availableBytes >= totalRequired else {
            throw EngineError.insufficientDiskSpace(
                requiredBytes: totalRequired, availableBytes: max(0, budget.availableBytes))
        }
        return budget
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
        tools: MediaDownloadTools, spaceBudget: DiskSpaceBudget, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let process = MediaToolProcess()
        let diskBudget = spaceBudget.writeLimitBytes
        let exceededBytes = Mutex<Int64?>(nil)
        do {
            _ = try await process.run(
                executable: tools.ffmpeg,
                arguments: arguments,
                directory: workingDirectory,
                tools: tools,
                captureOutput: false,
                includeTLSCertificate: false
            ) { line in
                if line.hasPrefix(progressTimePrefix), let duration, duration > 0,
                    let microseconds = Double(line.dropFirst(progressTimePrefix.count)), microseconds.isFinite
                {
                    progress(min(max(microseconds / microsecondsPerSecond / duration, 0), 1))
                }
                if let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
                    let size = attributes[.size] as? Int64, size > diskBudget
                {
                    exceededBytes.withLock { if $0 == nil { $0 = size } }
                    process.cancel()
                }
            }
        } catch is CancellationError {
            if let written = exceededBytes.withLock({ $0 }) {
                let (required, overflow) = written.addingReportingOverflow(spaceBudget.headroomBytes)
                throw EngineError.insufficientDiskSpace(
                    requiredBytes: overflow ? Int64.max : required, availableBytes: max(0, spaceBudget.availableBytes))
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
