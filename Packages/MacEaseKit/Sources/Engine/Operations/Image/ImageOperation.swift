import Foundation
import UniformTypeIdentifiers

public enum ImageFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg
    case heic
    case webp
    case avif
    case jxl
    case gif
    case tiff
    case bmp
    case ico
    case icns
    case svg
    case pdf

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        default: rawValue
        }
    }

    var holdsAnimation: Bool { [.gif, .png, .webp].contains(self) }

    var holdsAlpha: Bool { ![.jpeg, .bmp, .pdf].contains(self) }

    var usesQuality: Bool { [.jpeg, .heic, .webp, .avif, .jxl].contains(self) }

    var holdsMetadata: Bool { [.jpeg, .png, .heic, .webp, .avif, .jxl, .tiff].contains(self) }

    var contentType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .webp: .webP
        case .avif: UTType("public.avif") ?? .image
        case .jxl: UTType("public.jpeg-xl") ?? .image
        case .gif: .gif
        case .tiff: .tiff
        case .bmp: .bmp
        case .ico: .ico
        case .icns: .icns
        case .svg: .svg
        case .pdf: .pdf
        }
    }

    /// `nil` for unwritable formats such as RAW.
    init?(contentType: UTType) {
        if contentType.conforms(to: .rawImage) { return nil }
        if contentType.conforms(to: .heics) {
            self = .heic
            return
        }
        guard let format = Self.allCases.first(where: { contentType.conforms(to: $0.contentType) }) else {
            return nil
        }
        self = format
    }
}

public enum ImageSize: Codable, Hashable, Sendable {
    case percent(Double)
    case width(Int)
    case height(Int)
    case fit(width: Int, height: Int)
    /// Aspect lock off.
    case exact(width: Int, height: Int)
    case longEdge(Int)
}

public struct ImageResize: Codable, Hashable, Sendable {
    public var size: ImageSize
    public var allowsUpscale: Bool

    public init(size: ImageSize, allowsUpscale: Bool = false) {
        self.size = size
        self.allowsUpscale = allowsUpscale
    }
}

public enum QualityLevel: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case low
}

public enum CompressionGoal: Codable, Hashable, Sendable {
    case level(QualityLevel)
    case quality(Int)
    /// The final target, without headroom.
    case bytes(Int64)
    case platform(PlatformPreset)
}

public struct ImageCompression: Codable, Hashable, Sendable {
    public var goal: CompressionGoal
    public var allowsDownscale: Bool
    public var allowsFrameRateReduction: Bool
    public var stripsGPS: Bool

    public init(goal: CompressionGoal, allowsDownscale: Bool, allowsFrameRateReduction: Bool, stripsGPS: Bool) {
        self.goal = goal
        self.allowsDownscale = allowsDownscale
        self.allowsFrameRateReduction = allowsFrameRateReduction
        self.stripsGPS = stripsGPS
    }
}

public struct ImageConversion: Codable, Hashable, Sendable {
    public var format: ImageFormat
    /// `nil` uses the settings default.
    public var quality: Int?
    public var svgColors: Int

    public init(format: ImageFormat, quality: Int? = nil, svgColors: Int = SVGColors.default) {
        self.format = format
        self.quality = quality
        self.svgColors = svgColors
    }
}

public enum SVGColors {
    public static let `default` = 8
}

public enum FlipAxis: String, Codable, CaseIterable, Sendable {
    case horizontal
    case vertical
}

public enum MaskSource: Codable, Hashable, Sendable {
    case subject
    case person
    /// Tolerance is a fraction of RGB range.
    case colorKey(RGBColor, tolerance: Double)
}

public enum BackgroundFill: Codable, Hashable, Sendable {
    case transparent
    case color(RGBColor)
    /// Radius in pixels.
    case blur(radius: Double)
}

public struct BackgroundOptions: Codable, Hashable, Sendable {
    public static let defaultBlurRadius = 24.0

    public var mask: MaskSource
    public var fill: BackgroundFill

    public init(mask: MaskSource, fill: BackgroundFill) {
        self.mask = mask
        self.fill = fill
    }
}

public enum IconSetKind: String, Codable, CaseIterable, Sendable {
    case icns
    case appIconSet = "appiconset"
    case ico
}

public enum ImageOperation: Codable, Hashable, Sendable {
    case resize(ImageResize)
    case compress(ImageCompression)
    case convert(ImageConversion)
    /// Clockwise; `nil` fill means transparent corners.
    case rotate(degrees: Double, fill: RGBColor?)
    case flip(FlipAxis)
    case trimBorders
    case background(BackgroundOptions)
    case stripMetadata(Set<MetadataField>)
    case ocr(TextOutput)
    case toPDF
    case iconSet(IconSetKind)
    case copyBase64
}
