import Foundation
import MenuCatalog

public struct OperationRequest: Sendable {
    public let op: OperationID
    public let options: OperationOptions
    public let inputs: [URL]
    public let omittedStreams: Set<UnpreservedStream>
    /// Inputs must still match these when their item starts.
    public let inputStamps: [URL: MediaSourceStamp]

    public init(
        op: OperationID, options: OperationOptions, inputs: [URL], omittedStreams: Set<UnpreservedStream> = [],
        inputStamps: [URL: MediaSourceStamp] = [:]
    ) {
        self.op = op
        self.options = options
        self.inputs = inputs
        self.omittedStreams = omittedStreams
        self.inputStamps = inputStamps
    }
}

public enum OperationPlanner {
    public static func validateInput(_ url: URL) throws {
        _ = try ContentSniffer.inputValues(url)
    }

    /// `nil` when a panel must ask first.
    public static func options(for op: OperationID, preset: String?, settings: Settings) -> OperationOptions? {
        switch op.kind {
        case .any:
            switch op {
            case .anyChecksum: preset.flatMap(ChecksumAlgorithm.init(rawValue:)).map(OperationOptions.checksum)
            case .anyCopyPath:
                (preset.map(PathFormat.init(rawValue:)) ?? .posix).map(OperationOptions.copyPath)
            default: nil
            }
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
        let fallbackNaming = NewFileNaming(options: request.options)
        let naming = settings.outputMode == .newFile ? fallbackNaming : nil
        guard fallbackNaming != nil || !request.omittedStreams.isEmpty || !request.inputStamps.isEmpty else {
            return planned
        }
        let workItems = planned.items.map { workItem in
            var configured = workItem
            configured.newFileNaming = naming
            configured.fallbackNewFileNaming = fallbackNaming
            configured.omittedStreams = request.omittedStreams
            if !request.inputStamps.isEmpty {
                configured.requiredInputStamps = request.inputStamps.mapValues(\.fileStamp)
            }
            return configured
        }
        return Batch(
            operation: planned.operation, items: workItems,
            reportsMultipleTexts: planned.reportsMultipleTexts, recipeExecution: planned.recipeExecution)
    }

    private static func plannedBatch(for request: OperationRequest, settings: Settings) -> Batch {
        let inputs: [URL]
        let usesResolvedInputs: Bool
        switch request.options {
        case .rename(_), .move(_), .folder(.removeDuplicates(_, _)), .folder(.removeEmpty(_, _)),
            .folder(.exportAnalysis(_, _)):
            inputs = targeted(request.inputs, kind: request.op.kind)
            usesResolvedInputs = true
        case .folder(.newFile(_)), .copyPath(_):
            inputs = request.inputs
            usesResolvedInputs = false
        default:
            inputs = targeted(request.inputs, kind: request.op.kind)
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
        case .copyPath(let format):
            let workItem = WorkItem(inputs: inputs, managesInputStamps: true) { _ in
                .text(FinderPaths.copyText(for: inputs, format: format), .clipboard)
            }
            return Batch(operation: request.op, items: [workItem])
        case .rename(let plans):
            let items = plans.filter { $0.newName != $0.url.lastPathComponent }.map { plan in
                WorkItem(inputs: [plan.url]) { _ in
                    try validateInput(plan.url)
                    return .rename([plan])
                }
            }
            return Batch(operation: request.op, items: items)
        case .move(let plan):
            return MovePlanner.batch(plan, op: request.op)
        case .video(let operation):
            let batch = VideoPlanner.batch(operation, op: request.op, inputs: inputs)
            guard case .extractAudio(let format, let kilobits?) = operation, format.isLossy else { return batch }
            let checked = batch.items.map { planned in
                WorkItem(inputs: planned.inputs, lane: planned.lane) { context in
                    for source in planned.inputs {
                        let audioParameters = try await audioParametersForExtract(source, context: context)
                        let supported = try format.supportedKilobits(
                            sampleRate: audioParameters.sampleRate, channels: audioParameters.channels)
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

    private static func audioParametersForExtract(
        _ source: URL, context: ItemContext
    ) async throws -> (sampleRate: Double, channels: Int) {
        do {
            let media = try await MediaInput.open(source)
            guard let audio = media.audio, case .audio(let sampleRate, let channels) = audio.kind else {
                throw EngineError.invalidInput(.unsupportedFileType)
            }
            return (sampleRate, channels)
        } catch {
            let wrapped = EngineError.wrapping(error, path: source.path)
            switch wrapped {
            case .decodeFailed, .unsupportedCodec:
                let probe = try await StagedMediaFallback.probe(source)
                guard let audio = probe.audioStreams.first, let channels = audio.channels else {
                    throw EngineError.invalidInput(.unsupportedFileType)
                }
                return (audio.parsedSampleRate, channels)
            default:
                throw wrapped
            }
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
