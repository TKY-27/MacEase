import CoreGraphics
import Formats
import Foundation
import MenuCatalog
import UniformTypeIdentifiers

public enum SVGTrace {
    private static let cancellationCheckMask = 4_095

    public static func prepare(_ source: URL, options: SVGTraceOptions, settings: Settings) async throws
        -> SVGTraceResult
    {
        guard source.isFileURL else { throw EngineError.invalidInput(.unsupportedFileType) }
        guard (1...SVGTracer.maximumColors).contains(options.colors) else {
            throw EngineError.invalidInput(.invalidNumericParameter)
        }
        try Task.checkCancellation()
        let sourceStamp = try FileStamp(of: source, includingIdentity: true)
        let document = try autoreleasepool { () throws -> ImageDocument in
            let fileBytes = try ConversionInput.read(source, limit: ImageMemoryLimits.encodedBytes)
            guard try isStaticPNG(fileBytes) else { throw EngineError.invalidInput(.unsupportedFileType) }
            return try ImageDocument.load(bytes: fileBytes, url: source)
        }
        guard sourceStamp.matches(source.path) else { throw EngineError.invalidInput(.malformed("source changed")) }
        var resolvedSettings = settings
        resolvedSettings.outputMode = .newFile
        resolvedSettings.image.svgMode = .trace
        guard document.contentType.conforms(to: .png), document.frameCount == 1, !document.isAnimated else {
            throw EngineError.imageSequenceUnsupported
        }
        let sourceImage = document.first
        let context = ItemContext(
            settings: resolvedSettings, staging: StagingArea(supportDirectory: source.deletingLastPathComponent())
        ) { _ in }
        let prepared = try ImageOutput.prepared(document, as: .svg, context: context, derived: true)
        let encoding = ImageOutput.defaultOptions(for: prepared, format: .svg, settings: resolvedSettings.image)
        let svg = try ImageEncoder.trace(prepared.first, options: options, encoding: encoding)
        guard Int64(svg.count) <= ImageMemoryLimits.encodedBytes else {
            throw EngineError.invalidInput(.tooLarge(limitBytes: ImageMemoryLimits.encodedBytes))
        }
        try Task.checkCancellation()
        guard sourceStamp.matches(source.path) else { throw EngineError.invalidInput(.malformed("source changed")) }
        return SVGTraceResult(
            source: source, sourceStamp: sourceStamp, settings: resolvedSettings,
            sourceImage: sourceImage, svg: svg,
            width: prepared.first.width, height: prepared.first.height, warnings: context.warnings)
    }

    private static func isStaticPNG(_ bytes: Data) throws -> Bool {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard bytes.count >= 20, bytes.prefix(signature.count).elementsEqual(signature) else { return false }
        var offset = signature.count
        var scanned = 0
        var hasImage = false
        while offset <= bytes.count - 12 {
            if scanned & cancellationCheckMask == 0 { try Task.checkCancellation() }
            let length = bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= bytes.count - offset - 12 else { return false }
            let name = bytes[(offset + 4)..<(offset + 8)]
            if name.elementsEqual([97, 99, 84, 76]) { return false }
            if name.elementsEqual([73, 68, 65, 84]) { hasImage = true }
            if name.elementsEqual([73, 69, 78, 68]) { return hasImage && length == 0 }
            offset += length + 12
            scanned += 1
        }
        return false
    }
}

public struct SVGTraceResult: Sendable {
    public let settings: Settings
    public let sourceImage: CGImage
    public let svg: Data
    public let width: Int
    public let height: Int
    public let warnings: [ItemWarning]

    private let source: URL
    private let sourceStamp: FileStamp

    init(
        source: URL, sourceStamp: FileStamp, settings: Settings,
        sourceImage: CGImage, svg: Data,
        width: Int, height: Int, warnings: [ItemWarning]
    ) {
        self.source = source
        self.sourceStamp = sourceStamp
        self.settings = settings
        self.sourceImage = sourceImage
        self.svg = svg
        self.width = width
        self.height = height
        self.warnings = warnings
    }

    public func batch(to destination: URL, operation: OperationID) -> Batch {
        let source = source
        let sourceStamp = sourceStamp
        let svg = svg
        let warnings = warnings
        let item = WorkItem(inputs: [source]) { context in
            guard destination.isFileURL, destination.pathExtension.lowercased() == "svg",
                AvailableName.checkedName(destination.lastPathComponent)
            else { throw EngineError.invalidInput(.malformed(destination.absoluteString)) }
            guard sourceStamp.matches(source.path) else { return .skipped(.changedSinceScan) }
            let staged = try context.stagingURL(for: destination, name: destination.lastPathComponent)
            try svg.write(to: staged)
            guard sourceStamp.matches(source.path) else { return .skipped(.changedSinceScan) }
            for warning in warnings { context.warn(warning) }
            return .exported(
                from: source, stamp: sourceStamp, to: destination,
                outputs: [StagedFile(url: staged, name: destination.lastPathComponent, check: .svg)])
        }
        return Batch(operation: operation, items: [item])
    }
}
