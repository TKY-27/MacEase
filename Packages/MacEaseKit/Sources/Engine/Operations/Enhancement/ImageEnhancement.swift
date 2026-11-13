import CoreImage
import CoreML
import CoreVideo
import Formats
import Foundation

public struct ImageEnhancement: Sendable {
    public static let maximumInputPixels = 1_000_000
    public static let scale = 2
    private static let tileEdge = 64
    private static let halo = 8
    private static let coreEdge = tileEdge - 2 * halo
    private static let inputName = "pixel_values"
    private static let outputName = "reconstruction"

    private let modelURL: URL?

    public init(modelURL: URL? = nil) {
        self.modelURL = modelURL ?? Bundle.main.resourceURL?.appending(path: "upscaler/Swin2SR.mlmodelc")
    }

    public func makeBatch(source: URL) throws -> Batch {
        guard let modelURL, FileManager.default.fileExists(atPath: modelURL.path) else {
            throw EngineError.unsupportedCodec("Install the local image upscaler model")
        }
        return Batch(
            operation: .imageEnhance,
            items: [
                OperationPlanner.validated(source, kind: .image) { context in
                    try await Self.enhance(source, modelURL: modelURL, context: context)
                }
            ]
        )
    }

    private static func enhance(_ source: URL, modelURL: URL, context: ItemContext) async throws -> ItemResult {
        let document = try await ImageDocument.load(source)
        guard !document.isAnimated, !document.isMultiPage, document.frameCount == 1 else {
            throw EngineError.imageSequenceUnsupported
        }
        guard !document.containsHDR else { throw EngineError.imageHDRUnsupported }
        let image = document.first
        guard image.bitsPerComponent == 8, !image.bitmapInfo.contains(.floatComponents) else {
            throw EngineError.unsupportedCodec("Image upscaling requires 8-bit SDR input")
        }
        guard image.width <= maximumInputPixels / image.height else {
            throw EngineError.invalidInput(.frameMemoryExceeded)
        }
        guard try !ImageEncoder.hasTransparency(image) else { throw EngineError.imageTransparencyUnsupported }
        let original = CIImage(cgImage: image)
        let colorContext = CIContext(options: [.cacheIntermediates: false])
        guard
            let converted = colorContext.createCGImage(
                original, from: original.extent, format: .RGBA8, colorSpace: PixelBuffer.sRGB)
        else { throw EngineError.decodeFailed(source.lastPathComponent) }
        let pixels = try PixelBuffer(cgImage: converted)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        var input: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, tileEdge, tileEdge, kCVPixelFormatType_32BGRA, nil, &input)
        guard status == kCVReturnSuccess, let input else {
            throw EngineError.encodeFailed("Core ML input allocation")
        }
        let outputWidth = image.width * scale
        let outputHeight = image.height * scale
        var rgba = [UInt8](repeating: 255, count: outputWidth * outputHeight * 4)
        let columns = (image.width + coreEdge - 1) / coreEdge
        let rows = (image.height + coreEdge - 1) / coreEdge
        let total = columns * rows
        var completed = 0
        for row in 0..<rows {
            for column in 0..<columns {
                try Task.checkCancellation()
                try autoreleasepool {
                    let x = column * coreEdge
                    let y = row * coreEdge
                    try fill(input, from: pixels, x: x, y: y)
                    let features = try MLDictionaryFeatureProvider(dictionary: [
                        inputName: MLFeatureValue(pixelBuffer: input)
                    ])
                    let prediction = try model.prediction(from: features)
                    guard let tile = prediction.featureValue(for: outputName)?.imageBufferValue else {
                        throw EngineError.encodeFailed("Core ML output is missing")
                    }
                    try copy(
                        tile, into: &rgba, outputWidth: outputWidth, x: x, y: y,
                        width: min(coreEdge, image.width - x), height: min(coreEdge, image.height - y))
                }
                completed += 1
                context.progress(Double(completed) / Double(total))
            }
        }
        try Task.checkCancellation()
        let output = try PixelBuffer(width: outputWidth, height: outputHeight, rgba: rgba).makeCGImage()
        let name = source.deletingPathExtension().lastPathComponent + "-2x.png"
        let staged = try context.stagingURL(for: source, name: name)
        try ImageEncoder.png(output).write(to: staged)
        try Task.checkCancellation()
        return .derived(nextTo: source, outputs: [StagedFile(url: staged, name: name, check: .image)])
    }

    private static func fill(_ input: CVPixelBuffer, from pixels: PixelBuffer, x: Int, y: Int) throws {
        guard CVPixelBufferLockBaseAddress(input, []) == kCVReturnSuccess,
            let base = CVPixelBufferGetBaseAddress(input)
        else { throw EngineError.encodeFailed("Core ML input access") }
        defer { CVPixelBufferUnlockBaseAddress(input, []) }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(input)
        for tileY in 0..<tileEdge {
            let sourceY = min(max(y + tileY - halo, 0), pixels.height - 1)
            for tileX in 0..<tileEdge {
                let sourceX = min(max(x + tileX - halo, 0), pixels.width - 1)
                let source = (sourceY * pixels.width + sourceX) * 4
                let target = tileY * stride + tileX * 4
                bytes[target] = pixels.rgba[source + 2]
                bytes[target + 1] = pixels.rgba[source + 1]
                bytes[target + 2] = pixels.rgba[source]
                bytes[target + 3] = 255
            }
        }
    }

    private static func copy(
        _ tile: CVPixelBuffer, into rgba: inout [UInt8], outputWidth: Int,
        x: Int, y: Int, width: Int, height: Int
    ) throws {
        guard CVPixelBufferGetWidth(tile) == tileEdge * scale,
            CVPixelBufferGetHeight(tile) == tileEdge * scale,
            CVPixelBufferGetPixelFormatType(tile) == kCVPixelFormatType_32BGRA
        else { throw EngineError.encodeFailed("Core ML output format") }
        guard CVPixelBufferLockBaseAddress(tile, .readOnly) == kCVReturnSuccess,
            let base = CVPixelBufferGetBaseAddress(tile)
        else { throw EngineError.encodeFailed("Core ML output access") }
        defer { CVPixelBufferUnlockBaseAddress(tile, .readOnly) }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(tile)
        for outputY in 0..<(height * scale) {
            for outputX in 0..<(width * scale) {
                let source = (outputY + halo * scale) * stride + (outputX + halo * scale) * 4
                let target = ((y * scale + outputY) * outputWidth + x * scale + outputX) * 4
                rgba[target] = bytes[source + 2]
                rgba[target + 1] = bytes[source + 1]
                rgba[target + 2] = bytes[source]
            }
        }
    }
}
