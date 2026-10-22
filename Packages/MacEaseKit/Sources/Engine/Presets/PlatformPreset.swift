import Formats
import Foundation

public struct AspectRatio: Codable, Hashable, Sendable {
    public let width: Double
    public let height: Double

    public var value: Double { width / height }

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// Parses "9:16" or "1.91:1".
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "bad ratio \(text)"))
        }
        self.init(width: parts[0], height: parts[1])
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode("\(width):\(height)")
    }
}

public enum AspectFit: String, Codable, CaseIterable, Sendable {
    case crop
    case letterbox
}

public struct AspectRange: Codable, Hashable, Sendable {
    public var min: AspectRatio
    public var max: AspectRatio
    public var fit: AspectFit

    var isValid: Bool {
        let values = [min.width, min.height, max.width, max.height]
        let lower = min.value
        let upper = max.value
        return values.allSatisfy { $0.isFinite && $0 > 0 }
            && lower.isFinite && upper.isFinite && lower > 0 && lower <= upper
    }

    public init(min: AspectRatio, max: AspectRatio, fit: AspectFit) {
        self.min = min
        self.max = max
        self.fit = fit
    }
}

public struct MediaLimits: Codable, Hashable, Sendable {
    /// Leaves 3% headroom under platform limits.
    public static let targetShare = 0.97

    public var maxBytes: Int64?
    public var maxWidth: Int?
    public var maxHeight: Int?
    public var maxFrames: Int?
    public var maxDurationSeconds: Double?
    public var aspect: AspectRange?
    /// Unlisted sources convert to the first.
    public var formats: [String]?
    public var videoCodec: String?
    public var audioCodec: String?
    public var quality: Int?

    public init() {}

    /// Preset limits are reduced to leave headroom.
    public var targetBytes: Int64? {
        maxBytes.map { Int64((Double($0) * Self.targetShare).rounded(.down)) }
    }

    public var hasSupportedVideoOutput: Bool {
        let names = formats ?? [OutputContainer.mp4.rawValue]
        guard !names.isEmpty,
            let video = Self.videoCodec(videoCodec), let audio = Self.audioCodec(audioCodec)
        else { return false }
        return names.allSatisfy { name in
            guard let container = OutputContainer(rawValue: name.lowercased()),
                [.mp4, .mov, .m4v, .webm, .mkv].contains(container)
            else { return false }
            return container.holds(video.media) && container.holds(audio)
        }
    }

    func videoOutput(source: OutputContainer) -> (
        container: OutputContainer, video: VideoEncoding.Codec, mediaCodec: MediaCodec, audio: MediaCodec
    )? {
        guard hasSupportedVideoOutput,
            let video = Self.videoCodec(videoCodec), let audio = Self.audioCodec(audioCodec)
        else { return nil }
        let names = formats ?? [OutputContainer.mp4.rawValue]
        let selected = names.contains { $0.lowercased() == source.rawValue } ? source.rawValue : names[0]
        guard let container = OutputContainer(rawValue: selected.lowercased()) else { return nil }
        return (container, video.encoding, video.media, audio)
    }

    private static func videoCodec(_ name: String?) -> (encoding: VideoEncoding.Codec, media: MediaCodec)? {
        switch name?.lowercased() ?? "h264" {
        case "h264": (.h264, .h264)
        case "hevc": (.hevc, .hevc)
        case "vp9": (.vp9, .vp9)
        default: nil
        }
    }

    private static func audioCodec(_ name: String?) -> MediaCodec? {
        switch name?.lowercased() ?? "aac" {
        case "aac": .aac
        case "opus": .opus
        default: nil
        }
    }
}

public struct LocalizedName: Codable, Hashable, Sendable {
    public var en: String
    public var ja: String

    public func localized(languageCode: String?) -> String {
        languageCode == "ja" ? ja : en
    }
}

public struct PlatformPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: LocalizedName
    public var image: MediaLimits?
    public var gif: MediaLimits?
    public var video: MediaLimits?
    public var audio: MediaLimits?
}

/// User edits override bundled presets per ID.
public struct PresetLibrary: Sendable {
    public static let fileName = "platform-presets.json"

    public let bundled: [PlatformPreset]
    private let userFile: URL

    /// Bundled, so failure means a broken build.
    public static let bundledPresets: [PlatformPreset] = {
        guard let url = Bundle.module.url(forResource: "platform-presets", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let presets = try? JSONDecoder().decode([PlatformPreset].self, from: data)
        else { preconditionFailure("platform-presets.json is missing or invalid") }
        return presets
    }()

    public init(supportDirectory: URL) {
        bundled = Self.bundledPresets
        userFile = supportDirectory.appending(path: Self.fileName)
    }

    public func overrides() throws -> [PlatformPreset] {
        guard FileManager.default.fileExists(atPath: userFile.path) else { return [] }
        return try JSONDecoder().decode([PlatformPreset].self, from: Data(contentsOf: userFile))
    }

    public func presets() throws -> [PlatformPreset] {
        let edited = Dictionary(try overrides().map { ($0.id, $0) }) { _, last in last }
        return bundled.map { edited[$0.id] ?? $0 }
    }

    public func preset(id: String) throws -> PlatformPreset? {
        try presets().first { $0.id == id }
    }

    public func save(_ preset: PlatformPreset) throws {
        guard preset.video?.hasSupportedVideoOutput ?? true else {
            throw EngineError.invalidInput(.unsupportedVideoPreset)
        }
        var edited = try overrides().filter { $0.id != preset.id }
        if bundled.first(where: { $0.id == preset.id }) != preset { edited.append(preset) }
        try write(edited)
    }

    public func reset(id: String) throws {
        try write(try overrides().filter { $0.id != id })
    }

    private func write(_ presets: [PlatformPreset]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(presets).write(to: userFile, options: .atomic)
    }
}
