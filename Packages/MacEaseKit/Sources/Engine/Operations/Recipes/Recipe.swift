import Foundation
import MenuCatalog

public enum RecipeOutput: String, Codable, CaseIterable, Sendable {
    case imageJPEG, imagePNG, imageHEIC, imageWebP, imageAVIF, imageTIFF
    case videoMP4, videoMOV, videoWebM, videoThumbnail
    case pdf, pdfPagesPNG, pdfPagesJPEG, pdfText

    public var kind: FileKind {
        switch self {
        case .imageJPEG, .imagePNG, .imageHEIC, .imageWebP, .imageAVIF, .imageTIFF: .image
        case .videoMP4, .videoMOV, .videoWebM, .videoThumbnail: .video
        case .pdf, .pdfPagesPNG, .pdfPagesJPEG, .pdfText: .pdf
        }
    }

    var imageFormat: ImageFormat? {
        switch self {
        case .imageJPEG: .jpeg
        case .imagePNG: .png
        case .imageHEIC: .heic
        case .imageWebP: .webp
        case .imageAVIF: .avif
        case .imageTIFF: .tiff
        default: nil
        }
    }

    var videoFormat: String? {
        switch self {
        case .videoMP4: "mp4"
        case .videoMOV: "mov"
        case .videoWebM: "webm"
        default: nil
        }
    }

    public var supportsByteTarget: Bool { imageFormat != nil || videoFormat != nil }
    public var supportsResize: Bool { supportsByteTarget }
}

public struct OutputVariant: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var output: RecipeOutput
    public var suffix: String
    public var maximumEdge: Int?
    public var quality: Int
    public var targetBytes: Int64?
    public var compressPDF: Bool
    public var pdfDPI: Int

    public init(
        id: UUID = UUID(), output: RecipeOutput, suffix: String = "", maximumEdge: Int? = nil,
        quality: Int = 85, targetBytes: Int64? = nil, compressPDF: Bool = false, pdfDPI: Int = 144
    ) {
        self.id = id
        self.output = output
        self.suffix = suffix
        self.maximumEdge = maximumEdge
        self.quality = quality
        self.targetBytes = targetBytes
        self.compressPDF = compressPDF
        self.pdfDPI = pdfDPI
    }
}

public struct Recipe: Codable, Hashable, Identifiable, Sendable {
    public enum Packaging: String, Codable, CaseIterable, Sendable {
        case folder, zip
    }

    public var id: UUID
    public var revision: Int
    public var name: String
    public var variants: [OutputVariant]
    public var packaging: Packaging
    public var totalBytes: Int64?

    public init(
        id: UUID = UUID(), revision: Int = 1, name: String, variants: [OutputVariant],
        packaging: Packaging = .folder, totalBytes: Int64? = nil
    ) {
        self.id = id
        self.revision = revision
        self.name = name
        self.variants = variants
        self.packaging = packaging
        self.totalBytes = totalBytes
    }

    public static let builtIns: [Recipe] = [
        Recipe(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)), name: String(localized: "Web Publishing"),
            variants: [
                OutputVariant(output: .imageWebP, suffix: "_web", maximumEdge: 1920, quality: 80),
                OutputVariant(output: .videoMP4, suffix: "_web", maximumEdge: 1920, quality: 75),
                OutputVariant(output: .videoThumbnail, suffix: "_thumbnail"),
                OutputVariant(output: .pdf, compressPDF: true),
            ]),
        Recipe(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)), name: String(localized: "Submission"),
            variants: [
                OutputVariant(output: .imageJPEG, maximumEdge: 2400, quality: 85),
                OutputVariant(output: .videoMP4, maximumEdge: 1920, quality: 80),
                OutputVariant(output: .pdf, compressPDF: true),
            ], packaging: .zip),
    ]

    public func validate() throws {
        guard AvailableName.checkedName(name), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            revision > 0, !variants.isEmpty, variants.count <= Self.maximumVariants,
            Set(variants.map(\.id)).count == variants.count,
            totalBytes.map({ $0 > 0 && $0 <= Self.maximumByteTarget }) ?? true
        else { throw RecipeError.invalidRecipe }
        for variant in variants {
            guard AvailableName.checkedName("source" + variant.suffix), (1...100).contains(variant.quality),
                variant.maximumEdge.map({ (1...Self.maximumDimension).contains($0) }) ?? true,
                variant.targetBytes.map({ $0 > 0 && $0 <= Self.maximumByteTarget }) ?? true,
                variant.targetBytes == nil || variant.output.supportsByteTarget,
                variant.maximumEdge == nil || variant.output.supportsResize,
                (36...1200).contains(variant.pdfDPI)
            else { throw RecipeError.invalidRecipe }
        }
    }

    public static let maximumVariants = 32
    public static let maximumDimension = 16_384
    public static let maximumByteTarget: Int64 = 1_000_000_000_000

    public var supportedKinds: Set<FileKind> { Set(variants.map { $0.output.kind }) }
}

public struct RecipeExecution: Codable, Equatable, Sendable {
    public let recipe: Recipe
    public let settings: Settings

    public init(recipe: Recipe, settings: Settings) {
        self.recipe = recipe
        self.settings = settings
    }
}

public enum RecipeError: LocalizedError, Equatable {
    case invalidRecipe
    case unsupportedSchema(Int)
    case unsupportedInput(String)
    case destinationRequired
    case invalidDestination
    case sourceChanged(String)
    case noOutputs

    public var errorDescription: String? {
        switch self {
        case .invalidRecipe: String(localized: "The recipe contains invalid output settings.")
        case .unsupportedSchema(let schema):
            String(localized: "This recipe library uses an unsupported version: \(schema).")
        case .unsupportedInput(let name): String(localized: "The recipe has no supported output for \(name).")
        case .destinationRequired: String(localized: "Choose an output folder for files from different folders.")
        case .invalidDestination: String(localized: "The output destination must be a writable folder.")
        case .sourceChanged(let name): String(localized: "The source changed while finishing: \(name).")
        case .noOutputs: String(localized: "The recipe produced no required outputs.")
        }
    }
}
