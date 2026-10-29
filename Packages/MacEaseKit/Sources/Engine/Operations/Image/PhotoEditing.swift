import CoreGraphics
import CoreImage
import Formats
import Foundation

public struct PhotoEditorDetails: Sendable {
    public let size: CGSize
    public let containsHDR: Bool
    public let requiresNewFile: Bool
    public let requiresSDRForGeometry: Bool
    public let fileExtension: String
    public let stamp: MediaSourceStamp
}

public actor PhotoEditorSource {
    public let details: PhotoEditorDetails
    private let document: ImageDocument
    private var sdr: ImageDocument?
    private var automaticFilters: [CIFilter]?
    private let context = CIContext(options: [.cacheIntermediates: false])

    public static func open(_ url: URL) async throws -> PhotoEditorSource {
        let stamp = try MediaSourceStamp(url: url)
        let document = try await ImageDocument.load(url)
        try PhotoEditing.requireStill(document)
        try stamp.validate(url)
        return PhotoEditorSource(document: document, stamp: stamp)
    }

    private init(document: ImageDocument, stamp: MediaSourceStamp) {
        self.document = document
        details = PhotoEditorDetails(
            size: CGSize(width: document.first.width, height: document.first.height),
            containsHDR: document.containsHDR, requiresNewFile: document.format == nil,
            requiresSDRForGeometry: document.containsHDRPixels, fileExtension: document.writableFormat.fileExtension,
            stamp: stamp)
    }

    public func render(
        _ edit: ImageEdit, maximumDimension: Int = 1600, cropPreview: Bool = false, allowsSDR: Bool = true
    ) throws -> CGImage {
        try Task.checkCancellation()
        try edit.validate()
        guard maximumDimension > 0, maximumDimension <= 8192 else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        let reference: ImageDocument
        if document.containsHDR && (edit.changesColor || document.containsHDRPixels || edit.geometry.straighten != 0) {
            guard edit.changesColor || allowsSDR else { throw EngineError.imageHDRUnsupported }
            if sdr == nil { sdr = try document.toneMappedToSDR() }
            guard let sdr else { throw EngineError.hdrConversionUnsupported }
            reference = sdr
        } else {
            reference = document
        }
        if edit.autoEnhance, automaticFilters == nil {
            automaticFilters = PhotoEditing.automaticFilters(for: reference.first)
        }
        var image = try PhotoEditing.image(
            reference.first, edit: edit,
            automaticFilters: edit.autoEnhance ? automaticFilters ?? [] : [], includingCrop: !cropPreview)
        let scale = min(1, Double(maximumDimension) / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard
            let rendered = context.createCGImage(
                image, from: image.extent.integral,
                format: .RGBA8, colorSpace: ImagePixels.workingSpace(of: reference.first))
        else {
            throw EngineError.encodeFailed("editor preview")
        }
        try Task.checkCancellation()
        return rendered
    }
}

enum PhotoEditing {
    static func requireStill(_ document: ImageDocument) throws {
        guard !document.isAnimated, !document.isMultiPage, document.frameCount == 1 else {
            throw EngineError.invalidInput(
                .malformed(
                    String(
                        localized:
                            "Edit Photo supports a single still image. Animated and multipage images are not supported."
                    )))
        }
    }

    static func automaticFilters(for image: CGImage) -> [CIFilter] {
        CIImage(cgImage: image).autoAdjustmentFilters(options: [
            .enhance: true, .redEye: false, .crop: false, .level: false,
        ])
    }

    static func image(_ source: CGImage, edit: ImageEdit, automaticFilters: [CIFilter], includingCrop: Bool = true)
        throws -> CIImage
    {
        var image = edit.geometry.applying(to: CIImage(cgImage: source), includingCrop: includingCrop)
        for filter in automaticFilters {
            filter.setValue(image, forKey: kCIInputImageKey)
            guard let output = filter.outputImage else { throw EngineError.encodeFailed("automatic correction") }
            image = output
        }
        return edit.adjustments.applying(to: image)
    }

    static func run(_ edit: ImageEdit, url: URL, context: ItemContext) async throws -> ItemResult {
        try edit.validate()
        try edit.sourceStamp?.validate(url)
        guard !edit.isIdentity else { return .skipped(.alreadyDone) }
        let loaded = try await ImageDocument.load(url)
        try requireStill(loaded)
        let forceNew = loaded.containsHDR && edit.changesColor
        let prepared = try ImageOutput.prepared(
            loaded, as: loaded.writableFormat, context: context,
            derived: forceNew, preservesGainMaps: !edit.changesColor && edit.geometry.straighten == 0)
        let filters = edit.autoEnhance ? automaticFilters(for: prepared.first) : []
        let result = try await ImageOutput.transformed(
            prepared, as: prepared.writableFormat, context: context,
            geometry: { source, output in
                let size = CGSize(width: source.width, height: source.height)
                let bounds = edit.geometry.crop.rect(in: edit.geometry.canvasSize(size))
                // Gain maps use top-left coordinates.
                let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
                let flipOutput = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: Double(output.height))
                let transform = flipSource.concatenating(edit.geometry.transform(size))
                    .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                    .concatenating(flipOutput)
                return GainMapGeometry(
                    source: size, output: CGSize(width: output.width, height: output.height),
                    transform: transform, swapsAxes: !edit.geometry.quarterTurns.isMultiple(of: 2))
            }
        ) { source in
            try ImagePixels.render(image(source, edit: edit, automaticFilters: filters), like: source)
        }
        try edit.sourceStamp?.validate(url)
        if forceNew, case .replace(_, let staged) = result {
            let name =
                url.deletingPathExtension().lastPathComponent + "_edited." + prepared.writableFormat.fileExtension
            return .derived(nextTo: url, outputs: [StagedFile(url: staged.url, name: name, check: .sdrImage)])
        }
        return result
    }
}

public struct EditorHistogram: Sendable {
    public var red: [Double]
    public var green: [Double]
    public var blue: [Double]
    public var luminance: [Double]

    public static func read(_ image: CGImage) throws -> EditorHistogram {
        let edge = 256
        let scale = min(1, Double(edge) / Double(max(image.width, image.height)))
        let small = try ImagePixels.scaled(
            image, width: max(1, Int(Double(image.width) * scale)),
            height: max(1, Int(Double(image.height) * scale)))
        let pixels = try PixelBuffer(cgImage: small)
        var result = EditorHistogram(
            red: Array(repeating: 0, count: edge), green: Array(repeating: 0, count: edge),
            blue: Array(repeating: 0, count: edge), luminance: Array(repeating: 0, count: edge))
        for offset in stride(from: 0, to: pixels.rgba.count, by: 4) {
            guard pixels.rgba[offset + 3] > 0 else { continue }
            let red = Int(pixels.rgba[offset])
            let green = Int(pixels.rgba[offset + 1])
            let blue = Int(pixels.rgba[offset + 2])
            result.red[red] += 1
            result.green[green] += 1
            result.blue[blue] += 1
            let luminance = 0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
            result.luminance[Int(luminance.rounded())] += 1
        }
        return result
    }
}
