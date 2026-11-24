import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public struct MediaSourceStamp: Codable, Hashable, Sendable {
    private let stamp: FileStamp
    var fileStamp: FileStamp { stamp }

    public init(url: URL) throws {
        try OperationPlanner.validateInput(url)
        stamp = try FileStamp(of: url, includingIdentity: true)
    }

    public func validate(_ url: URL, message: String? = nil) throws {
        guard stamp.matchesIdentity(url.path) else {
            throw EngineError.invalidInput(
                .malformed(
                    message
                        ?? String(
                            localized:
                                "The original changed while editing. Close the editor and reopen the file.")))
        }
    }
}

public struct EditCrop: Codable, Hashable, Sendable {
    public var x = 0.0
    public var y = 0.0
    public var width = 1.0
    public var height = 1.0

    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    func validate() throws {
        guard [x, y, width, height].allSatisfy(\.isFinite), x >= 0, y >= 0,
            width > 0, height > 0, x + width <= 1.000000001, y + height <= 1.000000001
        else { throw EngineError.invalidInput(.invalidNumericParameter) }
    }

    public func rect(in size: CGSize) -> CGRect {
        let left = (x * size.width).rounded()
        let bottom = ((1 - y - height) * size.height).rounded()
        let right = ((x + width) * size.width).rounded()
        let top = ((1 - y) * size.height).rounded()
        return CGRect(x: left, y: bottom, width: max(1, right - left), height: max(1, top - bottom))
    }
}

public struct EditGeometry: Codable, Hashable, Sendable {
    public var quarterTurns = 0
    public var straighten = 0.0
    public var flipHorizontal = false
    public var flipVertical = false
    public var crop = EditCrop()

    public init() {}

    public var isIdentity: Bool { self == Self() }

    public func validate() throws {
        guard (0...3).contains(quarterTurns), straighten.isFinite, (-45...45).contains(straighten) else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        try crop.validate()
    }

    public func canvasSize(_ source: CGSize) -> CGSize {
        quarterTurns.isMultiple(of: 2) ? source : CGSize(width: source.height, height: source.width)
    }

    public func outputSize(_ source: CGSize) -> CGSize {
        let canvas = canvasSize(source)
        return crop.rect(in: canvas).size
    }

    func transform(_ source: CGSize) -> CGAffineTransform {
        let canvas = canvasSize(source)
        var transform = CGAffineTransform(translationX: -source.width / 2, y: -source.height / 2)
            .concatenating(CGAffineTransform(rotationAngle: -Double(quarterTurns) * .pi / 2))
            .concatenating(CGAffineTransform(scaleX: flipHorizontal ? -1 : 1, y: flipVertical ? -1 : 1))
        let radians = -straighten * .pi / 180
        let cover = max(
            abs(cos(radians)) + canvas.height / canvas.width * abs(sin(radians)),
            abs(cos(radians)) + canvas.width / canvas.height * abs(sin(radians)))
        transform = transform.concatenating(CGAffineTransform(rotationAngle: radians))
            .concatenating(CGAffineTransform(scaleX: cover, y: cover))
            .concatenating(CGAffineTransform(translationX: canvas.width / 2, y: canvas.height / 2))
        return transform
    }

    public func applying(to source: CIImage, includingCrop: Bool = true) -> CIImage {
        let size = source.extent.size
        let positioned = source.transformed(
            by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        let canvas = canvasSize(size)
        let bounds = includingCrop ? crop.rect(in: canvas) : CGRect(origin: .zero, size: canvas)
        let output = positioned.transformed(by: transform(size)).cropped(to: bounds)
            .transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        return output
    }

    public func outputPoint(_ point: EditPoint, canvas: CGSize, includingCrop: Bool = true) -> CGPoint {
        guard canvas.width > 0, canvas.height > 0 else { return CGPoint(x: point.x, y: point.y) }
        let rotated = canvasSize(canvas)
        let bounds = includingCrop ? crop.rect(in: rotated) : CGRect(origin: .zero, size: rotated)
        guard bounds.width > 0, bounds.height > 0 else { return CGPoint(x: point.x, y: point.y) }
        let source = CGPoint(x: point.x * canvas.width, y: (1 - point.y) * canvas.height)
        let mapped = source.applying(transform(canvas))
        return CGPoint(
            x: (mapped.x - bounds.minX) / bounds.width,
            y: 1 - (mapped.y - bounds.minY) / bounds.height)
    }

    public func canvasPoint(_ point: CGPoint, canvas: CGSize, includingCrop: Bool = true) -> EditPoint {
        guard canvas.width > 0, canvas.height > 0 else { return EditPoint(x: Double(point.x), y: Double(point.y)) }
        let rotated = canvasSize(canvas)
        let bounds = includingCrop ? crop.rect(in: rotated) : CGRect(origin: .zero, size: rotated)
        guard bounds.width > 0, bounds.height > 0 else { return EditPoint(x: Double(point.x), y: Double(point.y)) }
        let mapped = CGPoint(
            x: bounds.minX + point.x * bounds.width,
            y: bounds.minY + (1 - point.y) * bounds.height)
        let source = mapped.applying(transform(canvas).inverted())
        return EditPoint(x: Double(source.x / canvas.width), y: Double(1 - source.y / canvas.height))
    }

}

public enum MediaStyle: String, Codable, CaseIterable, Sendable {
    case original, vivid, warm, cool, dramatic, monochrome
}

public enum MediaAdjustment: String, CaseIterable, Sendable {
    case exposure, brightness, contrast, highlights, shadows, saturation, vibrance, warmth, tint
    case blackPoint, sharpness, noiseReduction, vignette

    public var range: ClosedRange<Double> {
        switch self {
        case .exposure: -3...3
        case .blackPoint, .sharpness, .noiseReduction, .vignette: 0...1
        default: -1...1
        }
    }

    public var photoOnly: Bool { [.blackPoint, .sharpness, .noiseReduction, .vignette].contains(self) }
}

public struct MediaAdjustments: Codable, Hashable, Sendable {
    private var values: [String: Double] = [:]
    public var style: MediaStyle = .original
    public var styleIntensity = 1.0

    public init() {}

    public subscript(_ adjustment: MediaAdjustment) -> Double {
        get { values[adjustment.rawValue] ?? 0 }
        set {
            if newValue == 0 {
                values.removeValue(forKey: adjustment.rawValue)
            } else {
                values[adjustment.rawValue] = newValue
            }
        }
    }

    public var isIdentity: Bool { values.values.allSatisfy { $0 == 0 } && (style == .original || styleIntensity == 0) }

    public func validate() throws {
        guard styleIntensity.isFinite, (0...1).contains(styleIntensity) else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        for (key, value) in values {
            guard let adjustment = MediaAdjustment(rawValue: key), value.isFinite, adjustment.range.contains(value)
            else { throw EngineError.invalidInput(.invalidNumericParameter) }
        }
    }

    public func applying(to original: CIImage) -> CIImage {
        var image = styled(original)
        if self[.exposure] != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": self[.exposure]])
        }
        if self[.warmth] != 0 || self[.tint] != 0 {
            image = image.applyingFilter(
                "CITemperatureAndTint",
                parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 6500 + self[.warmth] * 2500, y: self[.tint] * 100),
                ])
        }
        if self[.highlights] != 0 || self[.shadows] != 0 {
            image = image.applyingFilter(
                "CIHighlightShadowAdjust",
                parameters: [
                    "inputHighlightAmount": 1 + self[.highlights], "inputShadowAmount": self[.shadows],
                ])
        }
        if self[.brightness] != 0 || self[.contrast] != 0 || self[.saturation] != 0 {
            image = image.applyingFilter(
                "CIColorControls",
                parameters: [
                    "inputBrightness": self[.brightness] * 0.5, "inputContrast": 1 + self[.contrast] * 0.75,
                    "inputSaturation": 1 + self[.saturation],
                ])
        }
        if self[.vibrance] != 0 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": self[.vibrance]])
        }
        if self[.blackPoint] != 0 {
            let black = self[.blackPoint] * 0.25
            image = image.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: 1 / (1 - black), y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1 / (1 - black), z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1 / (1 - black), w: 0),
                    "inputBiasVector": CIVector(
                        x: -black / (1 - black), y: -black / (1 - black), z: -black / (1 - black), w: 0),
                ])
        }
        if self[.noiseReduction] != 0 {
            image = image.applyingFilter(
                "CINoiseReduction", parameters: ["inputNoiseLevel": self[.noiseReduction] * 0.1, "inputSharpness": 0])
        }
        if self[.sharpness] != 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": self[.sharpness] * 2])
        }
        if self[.vignette] != 0 {
            image = image.applyingFilter(
                "CIVignetteEffect",
                parameters: [
                    "inputCenter": CIVector(x: image.extent.midX, y: image.extent.midY),
                    "inputRadius": min(image.extent.width, image.extent.height) * 0.6,
                    "inputIntensity": self[.vignette],
                ])
        }
        return image.cropped(to: original.extent)
    }

    private func styled(_ image: CIImage) -> CIImage {
        guard style != .original, styleIntensity > 0 else { return image }
        let filtered: CIImage
        switch style {
        case .original: return image
        case .vivid:
            filtered = image.applyingFilter(
                "CIColorControls", parameters: ["inputSaturation": 1.35, "inputContrast": 1.08])
        case .warm, .cool:
            filtered = image.applyingFilter(
                "CITemperatureAndTint",
                parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: style == .warm ? 8500 : 4500, y: 0),
                ])
        case .dramatic: filtered = image.applyingFilter("CIPhotoEffectProcess")
        case .monochrome: filtered = image.applyingFilter("CIPhotoEffectMono")
        }
        return image.applyingFilter(
            "CIDissolveTransition", parameters: ["inputTargetImage": filtered, "inputTime": styleIntensity])
    }
}

public struct ImageEdit: Codable, Hashable, Sendable {
    public var geometry = EditGeometry()
    public var adjustments = MediaAdjustments()
    public var autoEnhance = false
    public var sourceStamp: MediaSourceStamp?
    public var overlays: [EditOverlay] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case geometry, adjustments, autoEnhance, sourceStamp, overlays
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        geometry = try values.decodeIfPresent(EditGeometry.self, forKey: .geometry) ?? EditGeometry()
        adjustments = try values.decodeIfPresent(MediaAdjustments.self, forKey: .adjustments) ?? MediaAdjustments()
        autoEnhance = try values.decodeIfPresent(Bool.self, forKey: .autoEnhance) ?? false
        sourceStamp = try values.decodeIfPresent(MediaSourceStamp.self, forKey: .sourceStamp)
        overlays = try values.decodeIfPresent([EditOverlay].self, forKey: .overlays) ?? []
    }

    public var changesColor: Bool { autoEnhance || !adjustments.isIdentity || !overlays.isEmpty }
    public var isIdentity: Bool { geometry.isIdentity && !changesColor }

    public func validate() throws {
        try geometry.validate()
        try adjustments.validate()
        try overlays.validate()
    }
}

public struct PhotoEditInput: Sendable {
    public let url: URL
    public let edit: ImageEdit

    public init(url: URL, edit: ImageEdit) {
        self.url = url
        self.edit = edit
    }
}

public enum MediaEditing {
    public static func photos(_ photos: [PhotoEditInput], settings: Settings) -> Batch {
        let work = photos.flatMap { photo in
            OperationPlanner.batch(
                for: OperationRequest(op: .imageEdit, options: .image(.edit(photo.edit)), inputs: [photo.url]),
                settings: settings
            ).items
        }
        return Batch(operation: .imageEdit, items: work)
    }

    public static func video(url: URL, edit: VideoEdit, settings: Settings) -> Batch {
        if (edit.sources?.count ?? 0) <= 1 {
            return OperationPlanner.batch(
                for: OperationRequest(op: .videoEdit, options: .video(.edit(edit)), inputs: [url]), settings: settings)
        }
        let inputs = edit.sources?.map(\.url) ?? [url]
        let work = WorkItem(inputs: inputs, lane: .hardwareVideo) { context in
            for input in inputs { try OperationPlanner.validateInput(input) }
            return try await VideoEdits.run(.edit(edit), url: url, context: context)
        }
        return Batch(operation: .videoEdit, items: [work])
    }

    public static func frame(url: URL, edit: VideoEdit, outputSeconds: Double, settings: Settings) -> Batch {
        if (edit.sources?.count ?? 0) <= 1 {
            return OperationPlanner.batch(
                for: OperationRequest(
                    op: .videoThumbnail, options: .video(.still(.edited(edit, outputSeconds: outputSeconds))),
                    inputs: [url]),
                settings: settings)
        }
        let inputs = edit.sources?.map(\.url) ?? [url]
        let work = WorkItem(inputs: inputs, lane: .cpu) { context in
            for input in inputs { try OperationPlanner.validateInput(input) }
            return try await VideoStills.run(.edited(edit, outputSeconds: outputSeconds), url: url, context: context)
        }
        return Batch(operation: .videoThumbnail, items: [work])
    }
}
