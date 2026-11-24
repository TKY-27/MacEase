import Foundation
import MenuCatalog
import Synchronization

public enum Lane: Sendable {
    case cpu
    case hardwareVideo
    case download
}

public struct WorkItem: Sendable {
    public let inputs: [URL]
    public let lane: Lane
    let durableArchive: Bool
    let managesInputStamps: Bool
    var requiredInputStamps: [URL: FileStamp]?
    var newFileNaming: NewFileNaming?
    var omittedStreams: Set<UnpreservedStream> = []
    var unpreservedStreams = Settings.UnpreservedStreamsChoice.ask
    var omissionOptions: OperationOptions?
    var derivesOutput = false
    let body: @Sendable (ItemContext) async throws -> ItemResult

    public init(inputs: [URL], lane: Lane = .cpu, body: @escaping @Sendable (ItemContext) async throws -> ItemResult) {
        durableArchive = false
        managesInputStamps = false
        self.inputs = inputs
        self.lane = lane
        self.body = body
    }
    init(
        inputs: [URL], durableArchive: Bool = false, managesInputStamps: Bool = false,
        body: @escaping @Sendable (ItemContext) async throws -> ItemResult
    ) {
        self.inputs = inputs
        lane = .cpu
        self.durableArchive = durableArchive
        self.managesInputStamps = managesInputStamps
        self.body = body
    }
}

public struct Batch: Sendable {
    public let id = UUID()
    public let operation: OperationID
    public let items: [WorkItem]
    public let reportsMultipleTexts: Bool
    public let recipeExecution: RecipeExecution?

    public init(
        operation: OperationID, items: [WorkItem], reportsMultipleTexts: Bool = false,
        recipeExecution: RecipeExecution? = nil
    ) {
        self.operation = operation
        self.items = items
        self.reportsMultipleTexts = reportsMultipleTexts
        self.recipeExecution = recipeExecution
    }
}

public struct StagedFile: Sendable {
    public let url: URL
    public let name: String
    public let check: OutputCheck

    public init(url: URL, name: String, check: OutputCheck) {
        self.url = url
        self.name = name
        self.check = check
    }
}

public struct AgeAuthenticationProof: Sendable {
    init() {}
}

public enum NewFileCheck: Sendable {
    case empty
    case templateBytes(expectedCount: Int)
    case richText
    case wordDocument
}

public enum OutputCheck: Sendable {
    case image
    case media
    case downloadedMedia(MediaDownloadTools, duration: Double?)
    case sdrImage
    case sdrVideo
    /// Decoded fully with MacEase's own audio decoders.
    case audio
    case archive
    case archiveMember
    case archiveSelectionFolder
    case pdf
    case plist
    case text(String.Encoding)
    case svg
    case folder
    /// Its decompressor decoded it without error.
    case decompressed
    case ageAuthenticatedPlaintext(AgeAuthenticationProof)
    case newFile(NewFileCheck)
}

public struct RenamePlan: Codable, Hashable, Sendable {
    public let url: URL
    public let newName: String

    public init(url: URL, newName: String) {
        self.url = url
        self.newName = newName
    }
}

public enum TextDestination: Sendable {
    case clipboard
    case report
}

public enum RemovalCondition: Sendable {
    case duplicate(of: URL)
    case emptyFolder(FolderSettings)
}

public enum ItemResult: Sendable {
    case organize(OrganizationMovePlan)
    case groupedDerived(destination: URL, sources: [URL: FileStamp], output: StagedFile)
    case hatchExtraction(HatchExtractionResult)
    case replace(original: URL, output: StagedFile)
    case derived(nextTo: URL, outputs: [StagedFile])
    case created(in: URL, outputs: [StagedFile])
    case exported(
        from: URL, stamp: FileStamp, to: URL, outputs: [StagedFile], preservingAttributes: Bool = true)
    case rename([RenamePlan])
    case move(MoveItem, to: URL)
    case text(String, TextDestination)
    case trash([URL], permanently: Bool, condition: RemovalCondition? = nil)
    case trashDuplicates([DuplicateRemoval])
    case skipped(SkipReason)
}

public enum ItemWarning: Equatable, Sendable {
    case imageFlattened
    case imageTransparencyFlattened
    case imageToneMappedToSDR
    case imageMetadataDropped([MetadataField])
    case videoTransparencyFlattened
    case videoToneMappedToSDR
    case videoMetadataDropped([VideoMetadataProperty])
    case streamsOmitted([UnpreservedStream])
    case pngOptimizationSkipped
    case imagePaletteReduced(colors: Int)
    case imageDimensionsReduced
    case loudnessLimitedByPeak(reachedLUFS: Double)
    case keptAsDerived
    case originalKept
    case copiedAcrossVolumes(original: URL, destination: URL)
    case outputNameUnchanged
    case metadataDropped
    case archiveFolderAttributesNotRestored
    case hdrProvenanceUnknown
    case dolbyVisionRemoved
    case unmappableCharactersReplaced
    case documentLayoutChanged
    case htmlOfflineContent
    case structuredTextFormattingLost
    case markdownUnsafeContentOmitted
}

public final class ItemContext: Sendable {
    public let settings: Settings
    public var omittedStreams: Set<UnpreservedStream> { state.withLock { $0.omittedStreams } }
    let staging: StagingArea
    let hatchExtractions: HatchExtractionStore
    private let state = Mutex(State())
    private let phaseHandler: @Sendable (ItemPhase) -> Void
    private let progressHandler: @Sendable (Double) -> Void

    private struct State {
        var omittedStreams: Set<UnpreservedStream> = []
        var beganEncoding = false
        var directories: [URL] = []
        var warnings: [ItemWarning] = []
        var details = ItemDetails()
    }

    init(
        settings: Settings, staging: StagingArea, hatchExtractions: HatchExtractionStore? = nil,
        omittedStreams: Set<UnpreservedStream> = [],
        phase: @escaping @Sendable (ItemPhase) -> Void = { _ in },
        progress: @escaping @Sendable (Double) -> Void
    ) {
        self.settings = settings
        state.withLock { $0.omittedStreams = omittedStreams }
        self.staging = staging
        self.hatchExtractions = hatchExtractions ?? HatchExtractionStore(supportDirectory: staging.supportDirectory)
        self.progressHandler = progress
        self.phaseHandler = phase
    }

    public func progress(_ fraction: Double) {
        progressHandler(min(max(fraction, 0), 1))
    }

    public func phase(_ phase: ItemPhase) {
        if phase == .encoding || phase == .optimizing || phase == .verifying {
            state.withLock { $0.beganEncoding = true }
        }
        phaseHandler(phase)
    }

    // Staging may already contain encoded media.
    var canContinueBeforeEncoding: Bool {
        state.withLock { !$0.beganEncoding && $0.directories.isEmpty }
    }

    func omitStreams(_ streams: Set<UnpreservedStream>) {
        state.withLock {
            $0.warnings = []
            $0.omittedStreams.formUnion(streams)
        }
    }

    public func reportImageResult(
        originalWidth: Int, originalHeight: Int, outputWidth: Int, outputHeight: Int,
        reducedDimensions: Bool, quantized: Bool, paletteColors: Int? = nil,
        frameCount: Int = 1, isMultiPage: Bool = false
    ) {
        state.withLock {
            $0.details.image = ImageResultDetails(
                originalWidth: originalWidth, originalHeight: originalHeight,
                outputWidth: outputWidth, outputHeight: outputHeight,
                reducedDimensions: reducedDimensions, quantized: quantized, paletteColors: paletteColors,
                frameCount: frameCount, isMultiPage: isMultiPage)
        }
    }

    var details: ItemDetails { state.withLock { $0.details } }

    func recordInputs(_ stamps: [URL: FileStamp]) { state.withLock { $0.details.inputStamps = stamps } }

    func recordOutput(_ url: URL, stamp: FileStamp) {
        state.withLock { $0.details.outputStamps[url] = stamp }
    }

    public func warn(_ warning: ItemWarning) {
        if case .streamsOmitted(let streams) = warning {
            warnStreamsOmitted(streams)
        } else {
            state.withLock { $0.warnings.append(warning) }
        }
    }

    func warnStreamsOmitted(_ streams: [UnpreservedStream]) {
        guard !streams.isEmpty else { return }
        state.withLock { state in
            if let index = state.warnings.firstIndex(where: {
                if case .streamsOmitted = $0 { true } else { false }
            }), case .streamsOmitted(let existing) = state.warnings[index] {
                let merged = Set(existing).union(streams)
                state.warnings[index] = .streamsOmitted(UnpreservedStream.allCases.filter(merged.contains))
            } else {
                let unique = Set(streams)
                state.warnings.append(.streamsOmitted(UnpreservedStream.allCases.filter(unique.contains)))
            }
        }
    }

    // Automatic omission consent ends when staging starts.
    public func stagingDirectory(for original: URL) throws -> URL {
        let directory = try staging.makeDirectory(for: original)
        state.withLock { $0.directories.append(directory) }
        return directory
    }

    public func stagingURL(for original: URL, name: String) throws -> URL {
        try stagingDirectory(for: original).appending(path: name, directoryHint: .notDirectory)
    }

    var warnings: [ItemWarning] { state.withLock { $0.warnings } }

    func removeStaging() {
        let directories = state.withLock { state in
            defer { state.directories = [] }
            return state.directories
        }
        for directory in directories { staging.remove(directory) }
    }
}
