import Formats
import Foundation

public struct RGBColor: Codable, Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let chromaGreen = RGBColor(red: 0x00, green: 0xB1, blue: 0x40)
    public static let chromaBlue = RGBColor(red: 0x00, green: 0x47, blue: 0xBB)
    public static let white = RGBColor(red: 0xFF, green: 0xFF, blue: 0xFF)
    public static let black = RGBColor(red: 0x00, green: 0x00, blue: 0x00)
}

public enum MetadataField: String, Codable, CaseIterable, Sendable {
    case exif
    case gps
    case makerNotes
    case comments
    case xmp
    case iptc
}

public enum VideoCodecChoice: String, Codable, CaseIterable, Sendable {
    case auto
    case h264
    case hevc
}

public enum EncodePriority: String, Codable, CaseIterable, Sendable {
    case speed
    case quality
}

public enum TrimMode: String, Codable, CaseIterable, Sendable {
    case keyframe
    case exact
}

public enum TransparentVideoFormat: String, Codable, CaseIterable, Sendable {
    case hevcAlpha
    case proRes4444
    case vp9AlphaWebM
}

public enum StillFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg
}

public enum MP3Mode: String, Codable, CaseIterable, Sendable {
    case cbr
    case vbr
}

public enum ArchiveFormat: String, Codable, CaseIterable, Sendable {
    case zip
    case sevenZip = "7z"
    case tar
    case tarGzip = "tar.gz"
}

public enum UnmappablePolicy: String, Codable, CaseIterable, Sendable {
    case fail
    case questionMark
    case numericReference
}

public enum JSONIndent: String, Codable, CaseIterable, Sendable {
    case two
    case four
    case tab
}

public enum KeySortScope: String, Codable, CaseIterable, Sendable {
    case recursive
    case topLevel
}

public enum TextOutput: String, Codable, CaseIterable, Sendable {
    case clipboard
    case file
    case panel
}

public enum SubtitleFormat: String, Codable, CaseIterable, Sendable {
    case srt
    case vtt
    case txt
}

public struct ImageSettings: Codable, Equatable, Sendable {
    public var jpegQuality = 85
    public var heicQuality = 80
    public var webpQuality = 80
    public var avifQuality = 70
    public var jxlQuality = 85
    public var optimizePNGOnConvert = true
    public var gifDithering = Dithering.ordered
    public var strippedMetadata = Set(MetadataField.allCases)
    public var keepGPSOnPlatformPresets = false
    public var colorKey = RGBColor.white
    public var colorKeyTolerance = 0.12
    public var greenBackground = RGBColor.chromaGreen
    public var blueBackground = RGBColor.chromaBlue
    public var customBackground = RGBColor.white

    public init() {}
}

public struct VideoSettings: Codable, Equatable, Sendable {
    public var codec = VideoCodecChoice.auto
    public var priority = EncodePriority.quality
    public var allowDownscale = true
    public var allowFrameRateReduction = true
    public var trimMode = TrimMode.keyframe
    public var rotationFill = RGBColor.black
    public var gifWidth = 480
    public var gifFrameRate = 15
    public var gifColors = 256
    public var gifLoops = true
    public var transparentFormat = TransparentVideoFormat.hevcAlpha
    public var thumbnailFormat = StillFormat.png

    public init() {}
}

public struct AudioSettings: Codable, Equatable, Sendable {
    public var mp3Bitrate = 192
    public var aacBitrate = 192
    public var opusBitrate = 128
    public var vorbisBitrate = 192
    public var mp3Mode = MP3Mode.cbr
    public var mp3VBRQuality = 2
    public var loudnessTarget = -14.0
    public var extractFormat = "m4a"

    public init() {}
}

public struct FolderSettings: Codable, Equatable, Sendable {
    public static let defaultExcludedNames = [".git", "node_modules", ".Trash"]

    public var duplicatesIgnoreHidden = true
    public var excludedNames = FolderSettings.defaultExcludedNames
    public var emptyIgnoresDSStore = true
    public var renamePrefix = ""
    public var renameSuffix = ""
    public var renameStart = 1
    public var renameStep = 1
    public var renameDigits = 3
    public var archiveFormat = ArchiveFormat.zip
    public var archiveExcludesMacMetadata = true

    public init() {}
}

public struct TextSettings: Codable, Equatable, Sendable {
    public var unmappable = UnmappablePolicy.fail
    public var jsonIndent = JSONIndent.two
    public var keySortScope = KeySortScope.recursive
    public var csvTypeInference = false

    public init() {}
}

public struct IntelligenceSettings: Codable, Equatable, Sendable {
    /// Empty means automatic language detection.
    public var ocrLanguages: [String] = []
    public var ocrOutput = TextOutput.clipboard
    /// Empty means the system locale.
    public var subtitleLanguage = ""
    public var subtitleFormat = SubtitleFormat.srt
    public var translationTarget = "en"
    public var aiEnabled = true

    public init() {}
}

public struct Settings: Codable, Equatable, Sendable {
    public static let defaultsKey = "settings"

    public var permanentDelete = false
    /// Zero means half of the active processors.
    public var concurrencyLimit = 0
    public var image = ImageSettings()
    public var video = VideoSettings()
    public var audio = AudioSettings()
    public var folder = FolderSettings()
    public var text = TextSettings()
    public var intelligence = IntelligenceSettings()

    public init() {}

    public var effectiveConcurrency: Int {
        concurrencyLimit > 0 ? concurrencyLimit : max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }
}

extension Settings {
    /// Keys added later keep their defaults.
    public static func decode(_ stored: Data) throws -> Settings {
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings()))
        let saved = try JSONSerialization.jsonObject(with: stored)
        let merged = try JSONSerialization.data(withJSONObject: merge(saved, over: defaults))
        return try JSONDecoder().decode(Settings.self, from: merged)
    }

    private static func merge(_ saved: Any, over defaults: Any) -> Any {
        guard let savedObject = saved as? [String: Any], var result = defaults as? [String: Any] else { return saved }
        for (key, value) in savedObject {
            result[key] = result[key].map { merge(value, over: $0) } ?? value
        }
        return result
    }
}
