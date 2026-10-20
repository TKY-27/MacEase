import Foundation
import MenuCatalog

public struct OperationRequest: Sendable {
    public let op: OperationID
    public let options: OperationOptions
    public let inputs: [URL]

    public init(op: OperationID, options: OperationOptions, inputs: [URL]) {
        self.op = op
        self.options = options
        self.inputs = inputs
    }
}

public enum OperationPlanner {
    /// `nil` when a panel must ask first.
    public static func options(for op: OperationID, preset: String?, settings: Settings) -> OperationOptions? {
        switch op.kind {
        case .any: preset.flatMap(ChecksumAlgorithm.init(rawValue:)).map(OperationOptions.checksum)
        case .folder: FolderPlanner.options(for: op, preset: preset).map(OperationOptions.folder)
        case .archive: ArchivePlanner.options(for: op, preset: preset).map(OperationOptions.archive)
        default: nil
        }
    }

    /// No file I/O; items validate when run.
    public static func batch(for request: OperationRequest, settings: Settings) -> Batch {
        let inputs = targeted(request.inputs, kind: request.op.kind)
        switch request.options {
        case .checksum(let algorithm):
            let items = inputs.map { url in
                validated(url, kind: .any) { context in
                    try Checksum.text(for: url, algorithm: algorithm, context: context)
                }
            }
            return Batch(operation: request.op, items: items, reportsMultipleTexts: true)
        case .folder(let operation):
            return FolderPlanner.batch(operation, op: request.op, folders: inputs, settings: settings)
        case .archive(let operation):
            return ArchivePlanner.batch(operation, op: request.op, archives: inputs)
        }
    }

    static func targeted(_ inputs: [URL], kind: FileKind) -> [URL] {
        var seen = Set<String>()
        return inputs.filter { url in
            guard seen.insert(url.path).inserted else { return false }
            let claimed = FileKind(fileURL: url)
            return kind == .any ? claimed != .folder : claimed == kind
        }
    }

    static func validated(
        _ url: URL,
        kind: FileKind,
        lane: Lane = .cpu,
        body: @escaping @Sendable (ItemContext) async throws -> ItemResult
    ) -> WorkItem {
        WorkItem(inputs: [url], lane: lane) { context in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if kind != .folder, values.isDirectory == true { return .skipped(.isDirectory) }
            guard try ContentSniffer.matches(url, kind: kind) else { return .skipped(.kindMismatch(expected: kind)) }
            return try await body(context)
        }
    }
}
