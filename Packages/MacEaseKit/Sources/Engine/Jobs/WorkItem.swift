import Foundation
import MenuCatalog
import Synchronization

public enum Lane: Sendable {
    case cpu
    case hardwareVideo
}

public struct WorkItem: Sendable {
    public let inputs: [URL]
    public let lane: Lane
    var newFileNaming: NewFileNaming?
    let body: @Sendable (ItemContext) async throws -> ItemResult

    public init(inputs: [URL], lane: Lane = .cpu, body: @escaping @Sendable (ItemContext) async throws -> ItemResult) {
        self.inputs = inputs
        self.lane = lane
        self.body = body
    }
}

public struct Batch: Sendable {
    public let id = UUID()
    public let operation: OperationID
    public let items: [WorkItem]
    public let reportsMultipleTexts: Bool

    public init(operation: OperationID, items: [WorkItem], reportsMultipleTexts: Bool = false) {
        self.operation = operation
        self.items = items
        self.reportsMultipleTexts = reportsMultipleTexts
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

public enum OutputCheck: Sendable {
    case image
    case media
    case sdrImage
    case sdrVideo
    /// Decoded fully with MacEase's own audio decoders.
    case audio
    case archive
    case pdf
    case plist
    case text(String.Encoding)
    case svg
    case folder
    /// Its decompressor decoded it without error.
    case decompressed
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
    case replace(original: URL, output: StagedFile)
    case derived(nextTo: URL, outputs: [StagedFile])
    case rename([RenamePlan])
    case text(String, TextDestination)
    case trash([URL], permanently: Bool, condition: RemovalCondition? = nil)
    case trashDuplicates([DuplicateRemoval])
    case skipped(SkipReason)
}

public enum ItemWarning: Equatable, Sendable {
    case imageFlattened
    case imageTransparencyFlattened
    case imageToneMappedToSDR
    case pngOptimizationSkipped
    case loudnessLimitedByPeak(reachedLUFS: Double)
    case keptAsDerived
    case originalKept
    case outputNameUnchanged
    case metadataDropped
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
    let staging: StagingArea
    private let state = Mutex(State())
    private let progressHandler: @Sendable (Double) -> Void

    private struct State {
        var directories: [URL] = []
        var warnings: [ItemWarning] = []
    }

    init(settings: Settings, staging: StagingArea, progress: @escaping @Sendable (Double) -> Void) {
        self.settings = settings
        self.staging = staging
        self.progressHandler = progress
    }

    public func progress(_ fraction: Double) {
        progressHandler(min(max(fraction, 0), 1))
    }

    public func warn(_ warning: ItemWarning) {
        state.withLock { $0.warnings.append(warning) }
    }

    /// On `original`'s volume.
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
