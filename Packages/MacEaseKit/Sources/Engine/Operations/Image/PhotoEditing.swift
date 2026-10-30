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
    private var previewSource: (dimension: Int, sdr: Bool, image: CGImage)?
    private var interactiveSource: (dimension: Int, sdr: Bool, image: CGImage)?
    private var renderedPreview: (edit: ImageEdit, dimension: Int, crop: Bool, allowsSDR: Bool, image: CGImage)?

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
        if let renderedPreview, renderedPreview.edit == edit, renderedPreview.dimension == maximumDimension,
            renderedPreview.crop == cropPreview, renderedPreview.allowsSDR == allowsSDR
        {
            return renderedPreview.image
        }
        let reference: ImageDocument
        let usesSDR =
            document.containsHDR && (edit.changesColor || document.containsHDRPixels || edit.geometry.straighten != 0)
        if usesSDR {
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
        let dimensions = CGSize(width: reference.first.width, height: reference.first.height)
        let output = cropPreview ? edit.geometry.canvasSize(dimensions) : edit.geometry.outputSize(dimensions)
        let sourceScale = min(1, Double(maximumDimension) / max(output.width, output.height))
        let sourceDimension = min(8192, max(1, Int(ceil(max(dimensions.width, dimensions.height) * sourceScale))))
        let source = try previewImage(
            reference.first, maximumDimension: sourceDimension, isSDR: usesSDR, interactive: maximumDimension <= 960)
        var image = try PhotoEditing.image(
            source, edit: edit,
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
        renderedPreview = (edit, maximumDimension, cropPreview, allowsSDR, rendered)
        return rendered
    }

    private func previewImage(_ source: CGImage, maximumDimension: Int, isSDR: Bool, interactive: Bool) throws
        -> CGImage
    {
        if interactive, let interactiveSource, interactiveSource.dimension == maximumDimension,
            interactiveSource.sdr == isSDR
        {
            return interactiveSource.image
        }
        if let previewSource, previewSource.dimension == maximumDimension, previewSource.sdr == isSDR {
            return previewSource.image
        }
        let scale = min(1, Double(maximumDimension) / Double(max(source.width, source.height)))
        let preview =
            scale == 1
            ? source
            : try ImagePixels.scaled(
                source, width: max(1, Int(Double(source.width) * scale)),
                height: max(1, Int(Double(source.height) * scale)))
        if interactive {
            interactiveSource = (maximumDimension, isSDR, preview)
        } else {
            previewSource = (maximumDimension, isSDR, preview)
        }
        return preview
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
