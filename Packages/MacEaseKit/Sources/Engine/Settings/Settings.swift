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

public enum ForegroundMask: String, Codable, CaseIterable, Sendable {
    case subject
    case person

    public var source: MaskSource {
        switch self {
        case .subject: .subject
        case .person: .person
        }
    }
}

public enum UnmappablePolicy: String, Codable, CaseIterable, Sendable {
    case fail
    case questionMark
    case numericReference
    case custom
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

public enum SVGMode: String, Codable, CaseIterable, Sendable {
    case trace
    case embeddedPNG
}

public struct ImageSettings: Codable, Equatable, Sendable {
    public var jpegQuality = 85
    public var heicQuality = 80
    public var webpQuality = 80
    public var avifQuality = 70
    public var jxlQuality = 85
    public var optimizePNGOnConvert = true
    public var allowDownscale = true
    public var allowFrameRateReduction = true
    public var gifDithering = Dithering.ordered
    public var strippedMetadata = Set(MetadataField.allCases)
    public var keepGPSOnPlatformPresets = false
    public var colorKey = RGBColor.white
    public var colorKeyTolerance = 0.12
    public var greenBackground = RGBColor.chromaGreen
    public var blueBackground = RGBColor.chromaBlue
    public var customBackground = RGBColor.white
    public var backgroundMask = ForegroundMask.subject
    public var backgroundBlurRadius = Int(BackgroundOptions.defaultBlurRadius)
    public var rotationFillsWithColor = false
    public var rotationFill = RGBColor.white
    public var svgColors = SVGColors.default
    public var svgMode = SVGMode.trace

    public init() {}

    fileprivate enum CodingKeys: String, CodingKey {
        case jpegQuality, heicQuality, webpQuality, avifQuality, jxlQuality, optimizePNGOnConvert, allowDownscale,
            allowFrameRateReduction, gifDithering, strippedMetadata, keepGPSOnPlatformPresets, colorKey,
            colorKeyTolerance, greenBackground, blueBackground, customBackground, backgroundMask, backgroundBlurRadius,
            rotationFillsWithColor, rotationFill, svgColors, svgMode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jpegQuality = try container.decode(Int.self, forKey: .jpegQuality)
        heicQuality = try container.decode(Int.self, forKey: .heicQuality)
        webpQuality = try container.decode(Int.self, forKey: .webpQuality)
        avifQuality = try container.decode(Int.self, forKey: .avifQuality)
        jxlQuality = try container.decode(Int.self, forKey: .jxlQuality)
        optimizePNGOnConvert = try container.decode(Bool.self, forKey: .optimizePNGOnConvert)
        allowDownscale = try container.decodeIfPresent(Bool.self, forKey: .allowDownscale) ?? true
        allowFrameRateReduction = try container.decodeIfPresent(Bool.self, forKey: .allowFrameRateReduction) ?? true
        gifDithering = try container.decode(Dithering.self, forKey: .gifDithering)
        strippedMetadata = try container.decode(Set<MetadataField>.self, forKey: .strippedMetadata)
        keepGPSOnPlatformPresets = try container.decode(Bool.self, forKey: .keepGPSOnPlatformPresets)
        colorKey = try container.decode(RGBColor.self, forKey: .colorKey)
        colorKeyTolerance = try container.decode(Double.self, forKey: .colorKeyTolerance)
        greenBackground = try container.decode(RGBColor.self, forKey: .greenBackground)
        blueBackground = try container.decode(RGBColor.self, forKey: .blueBackground)
        customBackground = try container.decode(RGBColor.self, forKey: .customBackground)
        backgroundMask = try container.decode(ForegroundMask.self, forKey: .backgroundMask)
        backgroundBlurRadius = try container.decode(Int.self, forKey: .backgroundBlurRadius)
        rotationFillsWithColor = try container.decode(Bool.self, forKey: .rotationFillsWithColor)
        rotationFill = try container.decode(RGBColor.self, forKey: .rotationFill)
        svgColors = try container.decode(Int.self, forKey: .svgColors)
        svgMode = try container.decode(SVGMode.self, forKey: .svgMode)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jpegQuality, forKey: .jpegQuality)
        try container.encode(heicQuality, forKey: .heicQuality)
        try container.encode(webpQuality, forKey: .webpQuality)
        try container.encode(avifQuality, forKey: .avifQuality)
        try container.encode(jxlQuality, forKey: .jxlQuality)
        try container.encode(optimizePNGOnConvert, forKey: .optimizePNGOnConvert)
        try container.encode(allowDownscale, forKey: .allowDownscale)
        try container.encode(allowFrameRateReduction, forKey: .allowFrameRateReduction)
        try container.encode(gifDithering, forKey: .gifDithering)
        try container.encode(strippedMetadata.sorted { $0.rawValue < $1.rawValue }, forKey: .strippedMetadata)
        try container.encode(keepGPSOnPlatformPresets, forKey: .keepGPSOnPlatformPresets)
        try container.encode(colorKey, forKey: .colorKey)
        try container.encode(colorKeyTolerance, forKey: .colorKeyTolerance)
        try container.encode(greenBackground, forKey: .greenBackground)
        try container.encode(blueBackground, forKey: .blueBackground)
        try container.encode(customBackground, forKey: .customBackground)
        try container.encode(backgroundMask, forKey: .backgroundMask)
        try container.encode(backgroundBlurRadius, forKey: .backgroundBlurRadius)
        try container.encode(rotationFillsWithColor, forKey: .rotationFillsWithColor)
        try container.encode(rotationFill, forKey: .rotationFill)
        try container.encode(svgColors, forKey: .svgColors)
        try container.encode(svgMode, forKey: .svgMode)
    }
}

public struct VideoSettings: Codable, Equatable, Sendable {
    public static let frameRateRange = 1...120
    public static let animationTimeRange = 0.0...86_400.0

    public var codec = VideoCodecChoice.auto
    public var priority = EncodePriority.quality
    public var allowDownscale = true
    public var allowFrameRateReduction = true
    public var frameRateFilm = 24
    public var frameRateStandard = 30
    public var frameRateSmooth = 60
    public var trimMode = TrimMode.keyframe
    public var rotationFill = RGBColor.black
    public var gifWidth = 480
    public var gifFrameRate = 15
    public var gifColors = 256
    public var gifLoops = true
    public var gifStartSeconds = 0.0
    public var gifEndSeconds = 0.0
    public var backgroundMask = ForegroundMask.person
    public var transparentFormat = TransparentVideoFormat.hevcAlpha
    public var thumbnailFormat = StillFormat.png

    public init() {}
}

public struct AudioSettings: Codable, Equatable, Sendable {
    public static let loudnessRange = -40.0 ... -5.0

    public var mp3Bitrate = 192
    public var aacBitrate = 192
    public var opusBitrate = 128
    public var vorbisBitrate = 192
    public var mp3Mode = MP3Mode.cbr
    public var mp3VBRQuality = 2
    public var loudnessTarget = -14.0
    public var loudnessStreaming = -16.0
    public var loudnessBroadcast = -23.0
    public var extractFormat = "m4a"
    public var extractedAudioBitrate: Int?

    public init() {}
}

public enum DuplicateKeepPolicy: String, Codable, CaseIterable, Sendable {
    case ask
    case oldest
    case newest
}

public struct FolderExclusions: Codable, Equatable, Sendable {
    public var folders = ""
    public var files = ""
    public var extensions = ""

    public init(folders: String = "", files: String = "", extensions: String = "") {
        self.folders = folders
        self.files = files
        self.extensions = extensions
    }
}

public struct FolderSettings: Codable, Equatable, Sendable {
    public static let defaultExcludedNames = [".git", "node_modules", ".Trash"]

    public var duplicatesIgnoreHidden = true
    public var duplicateMinimumBytes: Int64 = 0
    public var duplicatesIgnoreEmpty = true
    public var duplicatesMatchNames = false
    public var duplicatesMatchModificationSecond = false
    public var duplicateKeepPolicy = DuplicateKeepPolicy.ask
    public var excludedNames = FolderSettings.defaultExcludedNames
    public var scanExclusions = FolderExclusions()
    public var duplicateExclusions = FolderExclusions()
    public var emptyExclusions = FolderExclusions()
    public var treeExclusions = FolderExclusions()
    public var analyzeExclusions = FolderExclusions()
    public var renameExclusions = FolderExclusions()
    public var emptyIgnoresDSStore = true
    public var renamePrefix = ""
    public var renameSuffix = ""
    public var renameStart = 1
    public var renameStep = 1
    public var renameDigits = 3
    public var archiveFormat = ArchiveFormat.zip
    public var archiveExcludesMacMetadata = true
    public var treeFoldersOnly = false
    public var analysisExportFormat = AnalysisExportFormat.csv

    public init() {}
}

public enum PDFImageLayout: String, Codable, CaseIterable, Sendable {
    case pagesFolder
    case looseFiles
}

public struct TextSettings: Codable, Equatable, Sendable {
    public var unmappable = UnmappablePolicy.fail
    public var shiftJISSubstitute = "?"
    public var jsonIndent = JSONIndent.two
    public var keySortScope = KeySortScope.recursive
    public var jsonKeyComparison = JSONKeyComparison.ordinal
    public var jsonDescending = false
    public var jsonPinnedKeys: [String] = []
    public var jsonSortPrimitiveArrays = false
    public var csvTypeInference = false
    public var pdfImageDPI = PDFOperation.defaultDPI
    public var pdfImageLayout = PDFImageLayout.pagesFolder

    public init() {}
}

public struct IntelligenceSettings: Codable, Equatable, Sendable {
    /// Empty means automatic language detection.
    public var ocrLanguages: [String] = []
    public var ocrOutput = TextOutput.clipboard
    public var ocrFileEncoding = TextEncodingTarget.utf8
    /// Empty means the system locale.
    public var subtitleLanguage = ""
    public var subtitleFormat = SubtitleFormat.srt
    public var translationTarget = "en"
    public var aiEnabled = true

    public init() {}
}

public struct Settings: Codable, Equatable, Sendable {
    public static let extraRotationRange = -360.0...360.0

    public enum OutputMode: String, Codable, CaseIterable, Sendable {
        case newFile
        case replace
    }

    public static let defaultsKey = "settings"

    public var outputMode = OutputMode.newFile
    public var permanentDelete = false
    /// Zero means half of the active processors.
    public var concurrencyLimit = 0
    public var extraRotationEnabled = false
    public var extraRotationDegrees = 45.0
    public var menuValues = MenuValues()
    public var image = ImageSettings()
    public var video = VideoSettings()
    public var audio = AudioSettings()
    public var folder = FolderSettings()
    public var text = TextSettings()
    public var intelligence = IntelligenceSettings()
    /// Stored by `PresetLibrary`; the host fills it.
    public var platformPresets = PresetLibrary.bundledPresets

    private enum CodingKeys: String, CodingKey {
        case outputMode, permanentDelete, concurrencyLimit, extraRotationEnabled, extraRotationDegrees, menuValues
        case image, video, audio, folder, text, intelligence
    }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outputMode = try container.decode(OutputMode.self, forKey: .outputMode)
        permanentDelete = try container.decode(Bool.self, forKey: .permanentDelete)
        concurrencyLimit = try container.decode(Int.self, forKey: .concurrencyLimit)
        extraRotationEnabled = try container.decode(Bool.self, forKey: .extraRotationEnabled)
        extraRotationDegrees = try container.decode(Double.self, forKey: .extraRotationDegrees)
        menuValues = try container.decode(MenuValues.self, forKey: .menuValues)
        image = try container.decode(ImageSettings.self, forKey: .image)
        video = try container.decode(VideoSettings.self, forKey: .video)
        audio = try container.decode(AudioSettings.self, forKey: .audio)
        folder = try container.decode(FolderSettings.self, forKey: .folder)
        text = try container.decode(TextSettings.self, forKey: .text)
        intelligence = try container.decode(IntelligenceSettings.self, forKey: .intelligence)
        let imageKeys = try container.nestedContainer(keyedBy: ImageSettings.CodingKeys.self, forKey: .image)
        if !imageKeys.contains(.allowDownscale) { image.allowDownscale = video.allowDownscale }
        if !imageKeys.contains(.allowFrameRateReduction) {
            image.allowFrameRateReduction = video.allowFrameRateReduction
        }
    }

    public var effectiveConcurrency: Int {
        concurrencyLimit > 0 ? concurrencyLimit : max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }
}

extension Settings {
    /// Keys added later keep their defaults.
    public static func decode(_ stored: Data) throws -> Settings {
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings()))
        var saved = try JSONSerialization.jsonObject(with: stored)
        if var savedSettings = saved as? [String: Any], let video = savedSettings["video"] as? [String: Any],
            savedSettings["image"] == nil || savedSettings["image"] is [String: Any]
        {
            var image = savedSettings["image"] as? [String: Any] ?? [:]
            for key in ["allowDownscale", "allowFrameRateReduction"] where image[key] == nil {
                image[key] = video[key]
            }
            savedSettings["image"] = image
            saved = savedSettings
        }
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
