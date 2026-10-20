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
        try container.encode(
            "\(width.formatted(.number.grouping(.never))):\(height.formatted(.number.grouping(.never)))")
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
