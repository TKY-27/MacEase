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
    public static func validateInput(_ url: URL) throws {
        _ = try ContentSniffer.inputValues(url)
    }

    /// `nil` when a panel must ask first.
    public static func options(for op: OperationID, preset: String?, settings: Settings) -> OperationOptions? {
        switch op.kind {
        case .any: preset.flatMap(ChecksumAlgorithm.init(rawValue:)).map(OperationOptions.checksum)
        case .video: VideoPlanner.options(for: op, preset: preset, settings: settings).map(OperationOptions.video)
        case .folder:
            FolderPlanner.options(for: op, preset: preset, settings: settings.folder).map(OperationOptions.folder)
        case .archive: ArchivePlanner.options(for: op, preset: preset).map(OperationOptions.archive)
        case .pdf: PDFPlanner.operation(for: op, preset: preset, settings: settings).map(OperationOptions.pdf)
        case .text: TextPlanner.operation(for: op, preset: preset).map(OperationOptions.text)
        case .document: preset.flatMap(DocumentOutput.init(rawValue:)).map(OperationOptions.document)
        case .plist: preset == "json" ? .plistToJSON : nil
        case .jar: JARDecompiler.bundledOperation.map(OperationOptions.jar)
        case .audio: AudioPlanner.options(for: op, preset: preset, settings: settings).map(OperationOptions.audio)
        case .image: ImagePlanner.operation(for: op, preset: preset, settings: settings).map(OperationOptions.image)
        }
    }

    /// No file I/O; items validate when run.
    public static func batch(for request: OperationRequest, settings: Settings) -> Batch {
        let planned = plannedBatch(for: request, settings: settings)
        guard settings.outputMode == .newFile, let naming = NewFileNaming(options: request.options) else {
            return planned
        }
        let workItems = planned.items.map { workItem in
            var configured = workItem
            configured.newFileNaming = naming
            return configured
        }
        return Batch(operation: planned.operation, items: workItems, reportsMultipleTexts: planned.reportsMultipleTexts)
    }

    private static func plannedBatch(for request: OperationRequest, settings: Settings) -> Batch {
        let inputs = targeted(request.inputs, kind: request.op.kind)
        let usesResolvedInputs: Bool
        switch request.options {
        case .rename(_), .folder(.removeDuplicates(_, _)), .folder(.removeEmpty(_, _)),
            .folder(.exportAnalysis(_, _)):
            usesResolvedInputs = true
        default:
            usesResolvedInputs = false
        }
        if (!usesResolvedInputs && inputs.count < request.op.minimumSelection)
            || request.op.maximumSelection.map({ inputs.count > $0 }) ?? false
        {
            let rejected = WorkItem(inputs: inputs) { _ in
                if inputs.count < request.op.minimumSelection {
                    throw EngineError.invalidInput(.tooFewFiles(minimum: request.op.minimumSelection))
                }
                throw EngineError.invalidInput(
                    .malformed(
                        String(
                            localized: "This operation cannot use the selected number of files.",
                            comment: "Rejects stale selection counts")))
            }
            return Batch(operation: request.op, items: [rejected])
        }
        if request.op == .imageHDRToSDR || request.op == .videoHDRToSDR {
            let entry = MenuEntry(op: request.op, preset: nil, path: [])
            if !MenuLayout.isApplicable(entry, selection: inputs) {
                let rejected = WorkItem(inputs: inputs) { _ in
                    throw EngineError.invalidInput(.unsupportedFileType)
                }
                return Batch(operation: request.op, items: [rejected])
            }
        }
        switch request.options {
        case .checksum(let algorithm):
            let items = inputs.map { url in
                validated(url, kind: .any) { context in
                    try Checksum.text(for: url, algorithm: algorithm, context: context)
                }
            }
            return Batch(operation: request.op, items: items, reportsMultipleTexts: true)
        case .rename(let plans):
            let items = plans.map { plan in
                WorkItem(inputs: [plan.url]) { _ in
                    try validateInput(plan.url)
                    return .rename([plan])
                }
            }
            return Batch(operation: request.op, items: items)
        case .video(let operation):
            let batch = VideoPlanner.batch(operation, op: request.op, inputs: inputs)
            guard case .extractAudio(let format, let kilobits?) = operation, format.isLossy else { return batch }
            let checked = batch.items.map { planned in
                WorkItem(inputs: planned.inputs, lane: planned.lane) { context in
                    for source in planned.inputs {
                        let media = try await MediaInput.open(source)
                        guard let audio = media.audio, case .audio(let sampleRate, let channels) = audio.kind else {
                            throw EngineError.invalidInput(.unsupportedFileType)
                        }
                        let supported = try format.supportedKilobits(sampleRate: sampleRate, channels: channels)
                        guard supported.contains(kilobits) else {
                            throw EngineError.invalidInput(
                                .malformed(
                                    String(
                                        localized:
                                            "The selected audio bitrate is unavailable for this format and source.",
                                        comment: "Prevents silent bitrate changes")))
                        }
                    }
                    return try await planned.body(context)
                }
            }
            return Batch(operation: batch.operation, items: checked)
        case .folder(let operation):
            return FolderPlanner.batch(operation, op: request.op, folders: inputs, settings: settings)
        case .archive(let operation):
            return ArchivePlanner.batch(operation, op: request.op, archives: inputs)
        case .pdf(let operation):
            return PDFPlanner.batch(operation, op: request.op, inputs: inputs)
        case .text(let operation):
            return TextPlanner.batch(operation, op: request.op, inputs: inputs)
        case .document(let output):
            return DocumentPlanner.batch(output, inputs: inputs)
        case .plistToJSON:
            return DocumentPlanner.propertyLists(inputs: inputs)
        case .jar(let operation):
            return JARDecompiler.batch(operation, op: request.op, inputs: inputs)
        case .audio(let operation):
            return AudioPlanner.batch(for: request, operation: operation)
        case .image(let operation):
            return ImagePlanner.batch(for: operation, request: request, inputs: inputs)
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
        validated([url], kind: kind, lane: lane, body: body)
    }

    static func validated(
        _ urls: [URL],
        kind: FileKind,
        lane: Lane = .cpu,
        body: @escaping @Sendable (ItemContext) async throws -> ItemResult
    ) -> WorkItem {
        WorkItem(inputs: urls, lane: lane) { context in
            for url in urls {
                let values = try ContentSniffer.inputValues(url)
                let richTextPackage = kind == .document && url.pathExtension.lowercased() == "rtfd"
                if kind != .folder, values.isDirectory == true, !richTextPackage { return .skipped(.isDirectory) }
                guard try ContentSniffer.matches(url, kind: kind) else {
                    return .skipped(.kindMismatch(expected: kind))
                }
            }
            return try await body(context)
        }
    }
}
