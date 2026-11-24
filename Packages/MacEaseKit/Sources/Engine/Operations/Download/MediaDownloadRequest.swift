import Foundation

public struct MediaSubtitle: Hashable, Sendable {
    public let language: String
    public let automatic: Bool

    public init(language: String, automatic: Bool) {
        self.language = language
        self.automatic = automatic
    }
}

public struct MediaSource: Identifiable, Hashable, Sendable {
    public let id: String
    public let webpageURL: URL
    public let title: String
    public let duration: Double?
    public let resolutions: [Int]
    public let videoDimensions: [MediaVideoDimensions]
    public let availableFormats: [String]
    public let subtitles: [MediaSubtitle]
    public let isPlaylistEntry: Bool
    public let playlistIndex: Int?
    /// HTTPS only.
    public let thumbnailURL: URL?
    public let galleryCount: Int?

    public init(
        id: String, webpageURL: URL, title: String, duration: Double?, resolutions: [Int],
        subtitles: [MediaSubtitle], isPlaylistEntry: Bool, availableFormats: [String] = [], playlistIndex: Int? = nil,
        videoDimensions: [MediaVideoDimensions] = [], thumbnailURL: URL? = nil, galleryCount: Int? = nil
    ) {
        self.thumbnailURL = thumbnailURL
        self.galleryCount = galleryCount
        self.id = id
        self.webpageURL = webpageURL
        self.title = title
        self.duration = duration
        self.resolutions = resolutions
        self.videoDimensions = videoDimensions
        self.availableFormats = availableFormats
        self.subtitles = subtitles
        self.isPlaylistEntry = isPlaylistEntry
        self.playlistIndex = playlistIndex
    }
}

public struct MediaVideoDimensions: Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum MediaDownloadFormat: String, CaseIterable, Sendable {
    case source, mp4, mkv, webm, audio, m4a, mp3, wav, flac

    public var requiresReencoding: Bool { [.mp4, .webm, .m4a, .mp3, .wav, .flac].contains(self) }
    public var acceptsAudioBitrate: Bool { [.m4a, .mp3].contains(self) }
    public var audioOnly: Bool { [.audio, .m4a, .mp3, .wav, .flac].contains(self) }
}

public enum MediaSubtitleFormat: String, CaseIterable, Sendable {
    case srt, vtt
}

public struct MediaDownloadSelection: Hashable, Sendable {
    public static let audioBitrates = [128, 192, 256, 320]

    public let source: MediaSource
    public let format: MediaDownloadFormat
    public let resolution: Int?
    public let subtitle: MediaSubtitle?
    public let subtitleFormat: MediaSubtitleFormat
    /// Kilobits per second; `nil` is default.
    public let audioBitrate: Int?

    public init(
        source: MediaSource, format: MediaDownloadFormat = .source, resolution: Int? = nil,
        subtitle: MediaSubtitle? = nil, subtitleFormat: MediaSubtitleFormat = .vtt, audioBitrate: Int? = nil
    ) {
        self.source = source
        self.format = format
        self.resolution = resolution
        self.subtitle = subtitle
        self.subtitleFormat = subtitleFormat
        self.audioBitrate = audioBitrate
    }
}

public struct MediaDownloadRequest: Sendable {
    public let destination: URL
    public let selections: [MediaDownloadSelection]

    public init(destination: URL, selections: [MediaDownloadSelection]) {
        self.destination = destination
        self.selections = selections
    }

    public func retryingFailed(_ outcome: BatchOutcome) -> MediaDownloadRequest? {
        guard outcome.outcomes.count == selections.count else { return nil }
        let failed = selections.indices.compactMap { index -> MediaDownloadSelection? in
            guard case .failed(let error) = outcome.outcomes[index], error != .cancelled,
                outcome.details.indices.contains(index), outcome.details[index].outputStamps.isEmpty
            else { return nil }
            return selections[index]
        }
        return failed.isEmpty ? nil : MediaDownloadRequest(destination: destination, selections: failed)
    }
}

public struct MediaAnalysisFailure: Sendable {
    public let url: URL
    public let message: String
}

public struct MediaAnalysis: Sendable {
    public let sources: [MediaSource]
    public let failures: [MediaAnalysisFailure]
}

public struct MediaDownloadTools: Sendable {
    public let directory: URL
    public var python: URL { directory.appending(path: "python3") }
    public var quickJS: URL { directory.appending(path: "qjs") }
    public var ffmpeg: URL { directory.appending(path: "ffmpeg") }
    public var ffprobe: URL { directory.appending(path: "ffprobe") }

    public init(directory: URL) throws {
        for executable in ["python3", "qjs", "ffmpeg", "ffprobe"] {
            guard FileManager.default.isExecutableFile(atPath: directory.appending(path: executable).path) else {
                throw EngineError.unsupportedCodec("Bundled media tools are unavailable")
            }
        }
        self.directory = directory
    }

    public static func bundled() throws -> MediaDownloadTools {
        guard let resources = Bundle.main.resourceURL else {
            throw EngineError.unsupportedCodec("Bundled media tools are unavailable")
        }
        return try MediaDownloadTools(directory: resources.appending(path: "media-tools/bin"))
    }

    /// CLI and test hosts override runtime path.
    public static func resolved() throws -> MediaDownloadTools {
        if let directory = ProcessInfo.processInfo.environment["MACEASE_MEDIA_TOOLS"],
            Bundle.main.bundleIdentifier?.hasPrefix("io.github.tky27.MacEase") != true
        {
            return try MediaDownloadTools(directory: URL(filePath: directory))
        }
        return try bundled()
    }
}
