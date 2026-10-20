import Foundation
import MenuCatalog
import os

public enum ImagePlanner {
    /// `nil` when a panel must ask first.
    public static func operation(for op: OperationID, preset: String?, settings: Settings) -> ImageOperation? {
        switch op {
        case .imageTrimBorders: return .trimBorders
        case .imageToPDF: return .toPDF
        case .imageCopyBase64: return .copyBase64
        default: break
        }
        guard let preset else { return nil }
        switch op {
        case .imageResize: return resize(preset)
        case .imageCompress: return compression(preset, settings: settings).map(ImageOperation.compress)
        case .imageConvert: return ImageFormat(rawValue: preset).map { .convert(ImageConversion(format: $0)) }
        case .imageRotate: return rotationDegrees[preset].map { .rotate(degrees: $0, fill: nil) }
        case .imageFlip: return FlipAxis(rawValue: preset).map(ImageOperation.flip)
        case .imageBackground: return background(preset, settings: settings.image).map(ImageOperation.background)
        case .imageStripMetadata:
            return strippedFields(preset, settings: settings.image).map(ImageOperation.stripMetadata)
        case .imageOCR: return ocrOutputs[preset].map(ImageOperation.ocr)
        case .imageIconSet: return IconSetKind(rawValue: preset).map(ImageOperation.iconSet)
        default: return nil
        }
    }

    /// For presets edited in Settings.
    public static func compression(for preset: PlatformPreset, settings: Settings) -> ImageCompression {
        ImageCompression(
            goal: .platform(preset), allowsDownscale: settings.video.allowDownscale,
            allowsFrameRateReduction: settings.video.allowFrameRateReduction,
            stripsGPS: !settings.image.keepGPSOnPlatformPresets)
    }

    static func batch(for operation: ImageOperation, request: OperationRequest, inputs: [URL]) -> Batch {
        if operation == .toPDF {
            let item = WorkItem(inputs: inputs) { context in try await ImageExports.pdf(from: inputs, context: context)
            }
            return Batch(operation: request.op, items: inputs.isEmpty ? [] : [item])
        }
        let items = inputs.map { url in
            OperationPlanner.validated(url, kind: .image) { context in
                try await run(operation, on: url, context: context)
            }
        }
        return Batch(operation: request.op, items: items)
    }

    private static func run(_ operation: ImageOperation, on url: URL, context: ItemContext) async throws -> ItemResult {
        switch operation {
        case .resize(let resize): try await ImageEdits.resize(url, resize, context: context)
        case .compress(let compression): try await ImageCompressor.compress(url, compression, context: context)
        case .convert(let conversion): try await ImageEdits.convert(url, conversion, context: context)
        case .rotate(let degrees, let fill):
            try await ImageEdits.rotate(url, degrees: degrees, fill: fill, context: context)
        case .flip(let axis): try await ImageEdits.flip(url, axis, context: context)
        case .trimBorders: try await ImageEdits.trimBorders(url, context: context)
        case .background(let options): try await ImageBackground.replace(url, options, context: context)
        case .stripMetadata(let fields): try await ImageMetadata.strip(url, fields: fields, context: context)
        case .ocr(let output): try await ImageExports.recognizeText(url, output: output, context: context)
        case .toPDF: try await ImageExports.pdf(from: [url], context: context)
        case .iconSet(let kind): try await ImageExports.iconSet(url, kind: kind, context: context)
        case .copyBase64: try ImageExports.base64(url)
        }
    }

    private static let rotationDegrees: [String: Double] = ["right-90": 90, "left-90": -90, "180": 180]
    private static let ocrOutputs: [String: TextOutput] = ["copy": .clipboard, "save": .file, "show": .panel]
    private static let qualityPresets: [String: QualityLevel] = [
        "quality-high": .high, "quality-medium": .medium, "quality-low": .low,
    ]
    private static let resizePresets: [String: ImageSize] = [
        "percent-25": .percent(25), "percent-50": .percent(50), "percent-75": .percent(75),
        "long-1080": .longEdge(1080), "long-1920": .longEdge(1920), "long-2560": .longEdge(2560),
        "long-3840": .longEdge(3840),
    ]

    private static func resize(_ preset: String) -> ImageOperation? {
        resizePresets[preset].map { .resize(ImageResize(size: $0)) }
    }

    private static func compression(_ preset: String, settings: Settings) -> ImageCompression? {
        if let level = qualityPresets[preset] {
            return ImageCompression(
                goal: .level(level), allowsDownscale: false, allowsFrameRateReduction: false, stripsGPS: false)
        }
        return settings.platformPresets.first { $0.id == preset }.map { compression(for: $0, settings: settings) }
    }

    private static let logger = Logger(category: "image")

    private static func background(_ preset: String, settings: ImageSettings) -> BackgroundOptions? {
        switch preset {
        case "remove": BackgroundOptions(mask: .subject, fill: .transparent)
        case "green": BackgroundOptions(mask: .subject, fill: .color(settings.greenBackground))
        case "blue": BackgroundOptions(mask: .subject, fill: .color(settings.blueBackground))
        case "color": BackgroundOptions(mask: .subject, fill: .color(settings.customBackground))
        case "blur": BackgroundOptions(mask: .subject, fill: .blur(radius: BackgroundOptions.defaultBlurRadius))
        case "color-key":
            BackgroundOptions(
                mask: .colorKey(settings.colorKey, tolerance: settings.colorKeyTolerance), fill: .transparent)
        default: nil
        }
    }

    private static func strippedFields(_ preset: String, settings: ImageSettings) -> Set<MetadataField>? {
        switch preset {
        case "all": Set(MetadataField.allCases)
        case "gps": [.gps]
        case "settings": settings.strippedMetadata
        default: nil
        }
    }
}
