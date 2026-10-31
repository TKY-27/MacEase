import Formats
import Foundation
import MenuCatalog

public enum RecipePlanner {
    private static let maximumAttempts = 3
    private static let retryShare = 0.94

    public static func validate(recipe: Recipe, inputs: [URL]) throws {
        try recipe.validate()
        guard !inputs.isEmpty else { throw EngineError.invalidInput(.emptyInput) }
        for input in inputs {
            let values = try input.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard let kind = FileKind(fileURL: input), recipe.variants.contains(where: { $0.output.kind == kind }),
                values.isSymbolicLink != true, values.isRegularFile == true,
                try ContentSniffer.matches(input, kind: kind)
            else { throw RecipeError.unsupportedInput(input.lastPathComponent) }
        }
    }

    public static func requiresDestination(for inputs: [URL]) -> Bool {
        Set(inputs.map { $0.deletingLastPathComponent().standardizedFileURL }).count > 1
    }

    public static func batch(recipe: Recipe, inputs: [URL], destination: URL? = nil, settings: Settings) throws -> Batch
    {
        try recipe.validate()
        guard let first = inputs.first else { throw EngineError.invalidInput(.emptyInput) }
        guard destination != nil || !requiresDestination(for: inputs) else { throw RecipeError.destinationRequired }
        let folder = destination ?? first.deletingLastPathComponent()
        guard folder.isFileURL else { throw RecipeError.invalidDestination }
        let suffix = recipe.packaging == .zip ? ".zip" : ""
        let output = folder.appending(path: recipe.name + suffix)
        var fixedSettings = settings
        fixedSettings.outputMode = .newFile
        fixedSettings.text.pdfImageLayout = .pagesFolder
        fixedSettings.video.thumbnailFormat = .png
        let execution = RecipeExecution(recipe: recipe, settings: fixedSettings)
        let work = WorkItem(
            inputs: inputs, lane: inputs.contains { FileKind(fileURL: $0) == .video } ? .hardwareVideo : .cpu
        ) {
            context in
            try await run(execution, inputs: inputs, destination: output, context: context)
        }
        return Batch(operation: .filesFinish, items: [work], recipeExecution: execution)
    }

    private struct Source {
        let original: URL
        let copy: URL
    }

    private struct VariantRun {
        let source: Source
        let variant: OutputVariant
    }

    private static func run(
        _ execution: RecipeExecution, inputs: [URL], destination: URL, context: ItemContext
    ) async throws -> ItemResult {
        try validate(recipe: execution.recipe, inputs: inputs)
        let folder = destination.deletingLastPathComponent()
        guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
            FileManager.default.isWritableFile(atPath: folder.path)
        else { throw RecipeError.invalidDestination }
        let stamps = try Dictionary(
            uniqueKeysWithValues: Set(inputs).map { ($0, try FileStamp(of: $0, includingIdentity: true)) })
        let workspace = try context.stagingDirectory(for: destination)
        let sources = try clone(inputs, into: workspace)
        try checkSources(stamps)
        let runs = sources.flatMap { source in
            execution.recipe.variants.filter { $0.output.kind == FileKind(fileURL: source.original) }
                .map { VariantRun(source: source, variant: $0) }
        }
        var targets: [Int64?] = runs.map { $0.variant.targetBytes }
        var smallest = Int64.max
        for attempt in 0..<maximumAttempts {
            try Task.checkCancellation()
            let resultFolder = workspace.appending(path: "outputs-\(attempt)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: resultFolder, withIntermediateDirectories: false)
            let sizes = try await render(
                runs, targets: targets, into: resultFolder, execution: execution, context: context)
            let packaged = try package(execution.recipe, folder: resultFolder, workspace: workspace, attempt: attempt)
            let bytes = execution.recipe.packaging == .folder ? try sum(sizes) : try byteCount(packaged.url)
            smallest = min(smallest, bytes)
            if execution.recipe.totalBytes.map({ bytes <= $0 }) ?? true {
                try checkSources(stamps)
                try Task.checkCancellation()
                return .groupedDerived(destination: destination, sources: stamps, output: packaged)
            }
            guard let limit = execution.recipe.totalBytes, attempt + 1 < maximumAttempts else { break }
            targets = try allocatedTargets(runs, sizes: sizes, packagedBytes: bytes, limit: limit, previous: targets)
            try FileManager.default.removeItem(at: resultFolder)
            if execution.recipe.packaging == .zip { try FileManager.default.removeItem(at: packaged.url) }
        }
        throw EngineError.targetUnreachable(smallestBytes: smallest)
    }

    private static func clone(_ inputs: [URL], into workspace: URL) throws -> [Source] {
        try inputs.enumerated().map { index, original in
            try Task.checkCancellation()
            let directory = workspace.appending(path: "source-\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let copy = directory.appending(path: original.lastPathComponent)
            try FileManager.default.copyItem(at: original, to: copy)
            return Source(original: original, copy: copy)
        }
    }

    private static func checkSources(_ stamps: [URL: FileStamp]) throws {
        for (source, stamp) in stamps where !stamp.matches(source.path) {
            throw RecipeError.sourceChanged(source.lastPathComponent)
        }
    }

    private static func render(
        _ runs: [VariantRun], targets: [Int64?], into folder: URL,
        execution: RecipeExecution, context: ItemContext
    ) async throws -> [Int64] {
        var sizes: [Int64] = []
        for (index, run) in runs.enumerated() {
            try Task.checkCancellation()
            var variantSettings = execution.settings
            if run.variant.output == .pdfPagesJPEG { variantSettings.image.jpegQuality = run.variant.quality }
            let child = ItemContext(settings: variantSettings, staging: context.staging) { fraction in
                context.progress((Double(index) + fraction) / Double(runs.count))
            }
            defer {
                for warning in child.warnings where !context.warnings.contains(warning) { context.warn(warning) }
                child.removeStaging()
            }
            let result = try await produce(run, target: targets[index], context: child)
            let outputs = try stagedOutputs(result, source: run.source.copy, variant: run.variant)
            var total: Int64 = 0
            for output in outputs {
                try await verify(output, variant: run.variant)
                let proposed = name(output, run: run)
                let destination = try AvailableName.url(for: proposed, in: folder)
                try FileManager.default.moveItem(at: output.url, to: destination)
                total = try sum([total, recursiveBytes(destination)])
            }
            if let target = run.variant.targetBytes, total > target {
                throw EngineError.targetUnreachable(smallestBytes: total)
            }
            sizes.append(total)
        }
        guard !sizes.isEmpty else { throw RecipeError.noOutputs }
        return sizes
    }

    private static func produce(_ run: VariantRun, target: Int64?, context: ItemContext) async throws -> ItemResult {
        let variant = run.variant
        let source = run.source.copy
        if let format = variant.output.imageFormat {
            let preset = preset(variant, target: target, imageFormat: format.rawValue)
            return try await ImageCompressor.compress(
                source,
                ImageCompression(
                    goal: .platform(preset), allowsDownscale: true,
                    allowsFrameRateReduction: false, stripsGPS: false), context: context)
        }
        if variant.output.videoFormat != nil {
            return try await VideoCompressor.run(
                VideoCompression(goal: .platform(preset(variant, target: target))), url: source, context: context)
        }
        switch variant.output {
        case .videoThumbnail: return try await VideoStills.run(.middle, url: source, context: context)
        case .pdf:
            if variant.compressPDF { return try PDFEditing.compress(source, context: context) }
            return .skipped(.alreadyDone)
        case .pdfPagesPNG: return try PDFExport.images(of: source, format: .png, dpi: variant.pdfDPI, context: context)
        case .pdfPagesJPEG:
            return try PDFExport.images(of: source, format: .jpeg, dpi: variant.pdfDPI, context: context)
        case .pdfText: return try await PDFExport.text(of: source, context: context)
        default: throw RecipeError.invalidRecipe
        }
    }

    private static func preset(_ variant: OutputVariant, target: Int64?, imageFormat: String? = nil) -> PlatformPreset {
        var limits = MediaLimits()
        limits.formats = [imageFormat ?? variant.output.videoFormat ?? "mp4"]
        limits.maxWidth = variant.maximumEdge
        limits.maxHeight = variant.maximumEdge
        limits.quality = variant.quality
        limits.maxBytes = target
        limits.videoCodec = variant.output == .videoWebM ? "vp9" : variant.output == .videoMOV ? "hevc" : "h264"
        limits.audioCodec = variant.output == .videoWebM ? "opus" : "aac"
        return PlatformPreset(
            id: "recipe", name: LocalizedName(en: "Recipe", ja: "Recipe"),
            image: imageFormat == nil ? nil : limits, video: imageFormat == nil ? limits : nil)
    }

    private static func stagedOutputs(_ result: ItemResult, source: URL, variant: OutputVariant) throws -> [StagedFile]
    {
        switch result {
        case .replace(_, let output): return [output]
        case .derived(_, let outputs): return outputs
        case .skipped(.alreadyDone), .skipped(.outputNotSmaller):
            let copy = source.deletingLastPathComponent().appending(
                path: UUID().uuidString + "." + source.pathExtension)
            try FileManager.default.copyItem(at: source, to: copy)
            let check: OutputCheck =
                variant.output.kind == .pdf ? .pdf : variant.output.kind == .image ? .image : .media
            return [StagedFile(url: copy, name: source.lastPathComponent, check: check)]
        default: throw RecipeError.noOutputs
        }
    }

    private static func verify(_ output: StagedFile, variant: OutputVariant) async throws {
        try Task.checkCancellation()
        try await OutputVerifier.verify(output)
        if try output.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            let children = try FileManager.default.contentsOfDirectory(at: output.url, includingPropertiesForKeys: nil)
            for child in children {
                try await verify(StagedFile(url: child, name: child.lastPathComponent, check: .image), variant: variant)
            }
            return
        }
        let imageFormat: ImageFormat? =
            switch variant.output {
            case .videoThumbnail, .pdfPagesPNG: .png
            case .pdfPagesJPEG: .jpeg
            default: variant.output.imageFormat
            }
        if let imageFormat {
            let document = try await ImageDocument.load(output.url)
            guard document.format == imageFormat else { throw EngineError.encodeFailed("recipe image format mismatch") }
            if let edge = variant.maximumEdge {
                for index in 0..<document.frameCount {
                    let frame = try document.frame(at: index)
                    guard max(frame.image.width, frame.image.height) <= edge else {
                        throw EngineError.encodeFailed("recipe image dimensions exceeded")
                    }
                }
            }
        }
        if let format = variant.output.videoFormat {
            let media = try await MediaInput.open(output.url)
            let codec: MediaCodec = variant.output == .videoWebM ? .vp9 : variant.output == .videoMOV ? .hevc : .h264
            guard media.container.rawValue == format, media.video?.codec == codec else {
                throw EngineError.encodeFailed("recipe video format mismatch")
            }
            if let edge = variant.maximumEdge, max(media.displaySize.width, media.displaySize.height) > edge {
                throw EngineError.encodeFailed("recipe video dimensions exceeded")
            }
        }
    }

    private static func name(_ output: StagedFile, run: VariantRun) -> String {
        let base = run.source.original.deletingPathExtension().lastPathComponent + run.variant.suffix
        if case .folder = output.check { return base + "_pages" }
        return base + "." + (output.name as NSString).pathExtension
    }

    private static func package(_ recipe: Recipe, folder: URL, workspace: URL, attempt: Int) throws -> StagedFile {
        guard recipe.packaging == .zip else {
            return StagedFile(url: folder, name: recipe.name, check: .folder)
        }
        let archive = workspace.appending(path: "package-\(attempt).zip")
        let roots = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try ArchiveWriter.write(roots, to: archive, format: .zip, progress: { _ in }, skipping: { _ in false })
        try ArchiveListing.verify(archive)
        return StagedFile(url: archive, name: recipe.name + ".zip", check: .archive)
    }

    private static func allocatedTargets(
        _ runs: [VariantRun], sizes: [Int64], packagedBytes: Int64, limit: Int64, previous: [Int64?]
    ) throws -> [Int64?] {
        let fixed = try sum(zip(runs, sizes).filter { !$0.0.variant.output.supportsByteTarget }.map(\.1))
        let adjustable = try sum(zip(runs, sizes).filter { $0.0.variant.output.supportsByteTarget }.map(\.1))
        let overhead = max(0, packagedBytes - (try sum(sizes)))
        guard adjustable > 0, fixed < limit, overhead < limit - fixed else {
            throw EngineError.targetUnreachable(smallestBytes: packagedBytes)
        }
        let ratio = Double(limit - fixed - overhead) * retryShare / Double(adjustable)
        return runs.enumerated().map { index, run in
            guard run.variant.output.supportsByteTarget else { return nil }
            let allocation = max(1, Int64((Double(sizes[index]) * ratio).rounded(.down)))
            return min(previous[index] ?? allocation, allocation)
        }
    }

    private static func recursiveBytes(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw RecipeError.noOutputs }
        if values.isDirectory != true { return try byteCount(url) }
        return try sum(
            FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).map(recursiveBytes))
    }

    private static func byteCount(_ url: URL) throws -> Int64 {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw RecipeError.noOutputs }
        return Int64(size)
    }

    private static func sum(_ sizes: [Int64]) throws -> Int64 {
        try sizes.reduce(0) { total, bytes in
            let (result, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow else { throw RecipeError.noOutputs }
            return result
        }
    }
}
