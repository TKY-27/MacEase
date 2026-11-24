import CoreGraphics
import CoreImage
import CoreText
import Formats
import Foundation

public struct EditPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }

    func validate() throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
    }
}

public enum RedactionStyle: String, Codable, CaseIterable, Sendable {
    case mosaic, blur, solid
}

public enum MarkColor: String, Codable, CaseIterable, Sendable {
    case red, yellow, green, blue, white, black

    public var cgColor: CGColor {
        switch self {
        case .red: CGColor(srgbRed: 0.95, green: 0.22, blue: 0.20, alpha: 1)
        case .yellow: CGColor(srgbRed: 0.98, green: 0.80, blue: 0.12, alpha: 1)
        case .green: CGColor(srgbRed: 0.18, green: 0.78, blue: 0.35, alpha: 1)
        case .blue: CGColor(srgbRed: 0.14, green: 0.50, blue: 0.98, alpha: 1)
        case .white: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .black: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        }
    }

    public var strokeColor: CGColor {
        switch self {
        case .black, .blue: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .red, .yellow, .green, .white: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        }
    }
}

public enum MarkSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    public var strokeFraction: Double {
        switch self {
        case .small: 0.004
        case .medium: 0.0075
        case .large: 0.012
        }
    }

    public var fontFraction: Double {
        switch self {
        case .small: 0.035
        case .medium: 0.055
        case .large: 0.08
        }
    }
}

public enum EditMark: Codable, Hashable, Sendable {
    case redaction(rect: EditCrop, style: RedactionStyle)
    case box(rect: EditCrop, color: MarkColor, size: MarkSize)
    case arrow(from: EditPoint, to: EditPoint, color: MarkColor, size: MarkSize)
    case text(String, at: EditPoint, color: MarkColor, size: MarkSize)

    public var isAnnotation: Bool {
        switch self {
        case .redaction: false
        case .box, .arrow, .text: true
        }
    }

    public func validate() throws {
        switch self {
        case .redaction(let rect, _), .box(let rect, _, _):
            try rect.validate()
        case .arrow(let from, let to, _, _):
            try from.validate()
            try to.validate()
            guard
                hypot(to.x - from.x, to.y - from.y) > EditOverlay.minimumArrowLength + EditOverlay.arrowLengthTolerance
            else {
                throw EngineError.invalidInput(.invalidNumericParameter)
            }
        case .text(let raw, let at, _, _):
            try at.validate()
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= EditOverlay.maximumTextLength,
                !trimmed.contains(where: \.isNewline)
            else {
                throw EngineError.invalidInput(.invalidNumericParameter)
            }
        }
    }
}

public struct EditOverlay: Codable, Hashable, Sendable, Identifiable {
    public static let maximumCount = 50
    public static let maximumTextLength = 200
    public static let minimumArrowLength = 0.01

    static let mosaicBlockFraction = 1.0 / 32.0
    static let arrowLengthTolerance = 1e-12
    static let blurRadiusFraction = 0.035
    static let minimumBlurRadius = 12.0
    static let maximumBlurFraction = 0.05
    private static let minimumStrokeWidth = 1.0
    private static let minimumFontSize = 8.0
    private static let arrowHeadLengthScale = 3.8
    private static let arrowHeadMaxRatio = 0.45
    private static let arrowHeadWidthRatio = 0.48
    private static let arrowShaftInsetRatio = 0.75
    private static let heavyWeightTrait = 0.56
    private static let textStrokePercent = 12.0

    public var id: UUID
    public var mark: EditMark

    public init(id: UUID = UUID(), mark: EditMark) {
        self.id = id
        self.mark = mark
    }

    var isAnnotation: Bool { mark.isAnnotation }

    func validate() throws {
        try mark.validate()
    }

    fileprivate static func strokeWidth(for size: MarkSize, shortSide: Double) -> CGFloat {
        CGFloat(max(minimumStrokeWidth, shortSide * size.strokeFraction))
    }

    fileprivate static func fontSize(for size: MarkSize, shortSide: Double) -> CGFloat {
        CGFloat(max(minimumFontSize, shortSide * size.fontFraction))
    }

    fileprivate static func heavyFont(size: CGFloat) -> CTFont {
        let base =
            CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let traits: [CFString: Any] = [kCTFontWeightTrait: heavyWeightTrait]
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base), [kCTFontTraitsAttribute: traits] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    fileprivate static func drawBox(
        _ rect: EditCrop, color: MarkColor, size: MarkSize, in context: CGContext,
        geometry: EditGeometry, canvas: CGSize, outputSize: CGSize, includingCrop: Bool
    ) {
        let corners = [
            EditPoint(x: rect.x, y: rect.y),
            EditPoint(x: rect.x + rect.width, y: rect.y),
            EditPoint(x: rect.x + rect.width, y: rect.y + rect.height),
            EditPoint(x: rect.x, y: rect.y + rect.height),
        ].map {
            pixelPoint($0, geometry: geometry, canvas: canvas, outputSize: outputSize, includingCrop: includingCrop)
        }
        guard let first = corners.first else { return }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for corner in corners.dropFirst() {
            minX = min(minX, corner.x)
            maxX = max(maxX, corner.x)
            minY = min(minY, corner.y)
            maxY = max(maxY, corner.y)
        }
        let shortSide = Double(min(outputSize.width, outputSize.height))
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(strokeWidth(for: size, shortSide: shortSide))
        context.setLineJoin(.round)
        context.stroke(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        context.restoreGState()
    }

    fileprivate static func drawArrow(
        from: EditPoint, to: EditPoint, color: MarkColor, size: MarkSize, in context: CGContext,
        geometry: EditGeometry, canvas: CGSize, outputSize: CGSize, includingCrop: Bool
    ) {
        let start = pixelPoint(
            from, geometry: geometry, canvas: canvas, outputSize: outputSize, includingCrop: includingCrop)
        let end = pixelPoint(
            to, geometry: geometry, canvas: canvas, outputSize: outputSize, includingCrop: includingCrop)
        let dx = Double(end.x - start.x)
        let dy = Double(end.y - start.y)
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }
        let shortSide = Double(min(outputSize.width, outputSize.height))
        let width = strokeWidth(for: size, shortSide: shortSide)
        let headLength = min(length * arrowHeadMaxRatio, Double(width) * arrowHeadLengthScale)
        let headHalfWidth = headLength * arrowHeadWidthRatio
        let ux = dx / length
        let uy = dy / length
        let px = -uy
        let py = ux
        let shaftEnd = CGPoint(
            x: Double(end.x) - ux * headLength * arrowShaftInsetRatio,
            y: Double(end.y) - uy * headLength * arrowShaftInsetRatio)
        let leftWing = CGPoint(
            x: Double(end.x) - ux * headLength + px * headHalfWidth,
            y: Double(end.y) - uy * headLength + py * headHalfWidth)
        let rightWing = CGPoint(
            x: Double(end.x) - ux * headLength - px * headHalfWidth,
            y: Double(end.y) - uy * headLength - py * headHalfWidth)
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.move(to: start)
        context.addLine(to: shaftEnd)
        context.strokePath()
        context.setFillColor(color.cgColor)
        context.move(to: end)
        context.addLine(to: leftWing)
        context.addLine(to: rightWing)
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    fileprivate static func drawText(
        _ raw: String, at point: EditPoint, color: MarkColor, size: MarkSize, in context: CGContext,
        geometry: EditGeometry, canvas: CGSize, outputSize: CGSize, includingCrop: Bool
    ) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let center = pixelPoint(
            point, geometry: geometry, canvas: canvas, outputSize: outputSize, includingCrop: includingCrop)
        let shortSide = Double(min(outputSize.width, outputSize.height))
        let font = heavyFont(size: fontSize(for: size, shortSide: shortSide))
        let strokeAttributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color.cgColor,
            kCTStrokeColorAttributeName: color.strokeColor,
            kCTStrokeWidthAttributeName: textStrokePercent,
        ]
        let fillAttributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color.cgColor,
        ]
        let strokeLine = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, text as CFString, strokeAttributes as CFDictionary))
        let fillLine = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, text as CFString, fillAttributes as CFDictionary))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineWidth = CTLineGetTypographicBounds(fillLine, &ascent, &descent, &leading)
        let origin = CGPoint(x: center.x - lineWidth / 2, y: center.y - (ascent - descent) / 2)
        context.saveGState()
        context.textMatrix = .identity
        context.setLineJoin(.round)
        // Stroke first to preserve glyph stems.
        context.textPosition = origin
        CTLineDraw(strokeLine, context)
        context.textPosition = origin
        CTLineDraw(fillLine, context)
        context.restoreGState()
    }

    private static func pixelPoint(
        _ point: EditPoint, geometry: EditGeometry, canvas: CGSize, outputSize: CGSize, includingCrop: Bool
    ) -> CGPoint {
        let normalized = geometry.outputPoint(point, canvas: canvas, includingCrop: includingCrop)
        return CGPoint(x: normalized.x * outputSize.width, y: (1 - normalized.y) * outputSize.height)
    }
}

public struct TimedOverlay: Codable, Hashable, Sendable, Identifiable {
    public var overlay: EditOverlay
    public var sourceIndex: Int
    public var start: Double
    public var end: Double
    public var id: UUID { overlay.id }

    public init(overlay: EditOverlay, sourceIndex: Int = 0, start: Double, end: Double) {
        self.overlay = overlay
        self.sourceIndex = sourceIndex
        self.start = start
        self.end = end
    }
}

extension [EditOverlay] {
    func validate() throws {
        guard count <= EditOverlay.maximumCount else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        var identifiers = Set<UUID>()
        for overlay in self {
            guard identifiers.insert(overlay.id).inserted else {
                throw EngineError.invalidInput(.invalidNumericParameter)
            }
            try overlay.validate()
        }
    }

    func redacting(_ canvas: CIImage, fullCanvasSize: CGSize? = nil) -> CIImage {
        let redactions = compactMap { overlay -> (EditCrop, RedactionStyle)? in
            guard case .redaction(let rect, let style) = overlay.mark else { return nil }
            return (rect, style)
        }
        guard !redactions.isEmpty else { return canvas }
        let extent = canvas.extent
        let shortSide = Swift.min(extent.width, extent.height)
        guard shortSide > 0 else { return canvas }
        let reference = fullCanvasSize ?? extent.size
        let referenceShortSide = Swift.min(reference.width, reference.height)
        let renderScale = shortSide / referenceShortSide
        var current = canvas
        let clear = CIImage(color: .clear).cropped(to: extent)
        for (crop, style) in redactions {
            let left = floor(extent.minX + crop.x * extent.width)
            let right = ceil(extent.minX + (crop.x + crop.width) * extent.width)
            let bottom = floor(extent.minY + (1 - crop.y - crop.height) * extent.height)
            let top = ceil(extent.minY + (1 - crop.y) * extent.height)
            let region = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
                .intersection(extent)
            guard !region.isEmpty else { continue }
            let replacement: CIImage
            switch style {
            case .mosaic:
                let block = Swift.max(1, referenceShortSide * EditOverlay.mosaicBlockFraction) * renderScale
                if region.width < block || region.height < block {
                    replacement = current.cropped(to: region)
                        .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: region)])
                        .clampedToExtent().cropped(to: region)
                } else {
                    // Pixellate samples; the box averages each block.
                    replacement = current.cropped(to: region).clampedToExtent()
                        .applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: block])
                        .applyingFilter(
                            "CIPixellate",
                            parameters: [
                                kCIInputCenterKey: CIVector(x: region.minX, y: region.minY),
                                kCIInputScaleKey: block,
                            ]
                        )
                        .cropped(to: region)
                }
            case .blur:
                let radius =
                    Swift.min(
                        referenceShortSide * EditOverlay.maximumBlurFraction,
                        Swift.max(EditOverlay.minimumBlurRadius, referenceShortSide * EditOverlay.blurRadiusFraction))
                    * renderScale
                replacement = current.cropped(to: region).clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                    .cropped(to: region)
            case .solid:
                replacement = CIImage(color: .black).cropped(to: region)
            }
            // Alpha mask replaces semi-transparent pixels cleanly.
            let mask = CIImage(color: .white).cropped(to: region).composited(over: clear)
            current = replacement.applyingFilter(
                "CIBlendWithAlphaMask",
                parameters: [
                    kCIInputBackgroundImageKey: current,
                    kCIInputMaskImageKey: mask,
                ]
            ).cropped(to: extent)
        }
        return current
    }

    func annotating(
        _ image: CIImage, geometry: EditGeometry, canvas: CGSize, includingCrop: Bool = true,
        fullOutputSize: CGSize? = nil
    ) -> CIImage {
        let extent = image.extent
        guard
            let layer = annotationLayer(
                size: extent.size, geometry: geometry, canvas: canvas, includingCrop: includingCrop,
                fullOutputSize: fullOutputSize)
        else { return image }
        let positioned =
            extent.origin == .zero
            ? layer
            : layer.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return positioned.composited(over: image).cropped(to: extent)
    }

    func annotationLayer(
        size: CGSize, geometry: EditGeometry, canvas: CGSize, includingCrop: Bool = true,
        fullOutputSize: CGSize? = nil
    ) -> CIImage? {
        let annotations = filter(\.isAnnotation)
        guard !annotations.isEmpty else { return nil }
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0, canvas.width > 0, canvas.height > 0 else { return nil }
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: PixelBuffer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        let outputSize = fullOutputSize ?? (includingCrop ? geometry.outputSize(canvas) : geometry.canvasSize(canvas))
        context.scaleBy(x: CGFloat(width) / outputSize.width, y: CGFloat(height) / outputSize.height)
        for overlay in annotations {
            switch overlay.mark {
            case .redaction:
                break
            case .box(let rect, let color, let markSize):
                EditOverlay.drawBox(
                    rect, color: color, size: markSize, in: context, geometry: geometry, canvas: canvas,
                    outputSize: outputSize, includingCrop: includingCrop)
            case .arrow(let from, let to, let color, let markSize):
                EditOverlay.drawArrow(
                    from: from, to: to, color: color, size: markSize, in: context, geometry: geometry, canvas: canvas,
                    outputSize: outputSize, includingCrop: includingCrop)
            case .text(let raw, let at, let color, let markSize):
                EditOverlay.drawText(
                    raw, at: at, color: color, size: markSize, in: context, geometry: geometry, canvas: canvas,
                    outputSize: outputSize, includingCrop: includingCrop)
            }
        }
        guard let rendered = context.makeImage() else { return nil }
        return CIImage(cgImage: rendered)
    }
}

// Filter requests may render concurrently.
final class EditAnnotationCache: @unchecked Sendable {
    private struct Key: Equatable {
        let overlays: [EditOverlay]
        let size: CGSize
        let geometry: EditGeometry
        let canvas: CGSize
        let fullOutputSize: CGSize
    }

    private let lock = NSLock()
    private var cached: (key: Key, layer: CIImage)?

    func layer(
        for overlays: [EditOverlay], size: CGSize, geometry: EditGeometry, canvas: CGSize,
        fullOutputSize: CGSize
    ) -> CIImage? {
        let annotations = overlays.filter(\.isAnnotation)
        guard !annotations.isEmpty else { return nil }
        let key = Key(
            overlays: annotations, size: size, geometry: geometry, canvas: canvas, fullOutputSize: fullOutputSize)
        if let layer = lock.withLock({ cached?.key == key ? cached?.layer : nil }) { return layer }
        guard
            let layer = annotations.annotationLayer(
                size: size, geometry: geometry, canvas: canvas, fullOutputSize: fullOutputSize)
        else { return nil }
        lock.withLock { cached = (key, layer) }
        return layer
    }
}
