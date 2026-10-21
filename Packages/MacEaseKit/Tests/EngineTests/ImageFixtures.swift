import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MenuCatalog
import Testing
import UniformTypeIdentifiers

@testable import Engine

/// Generated inputs and an operation runner.
enum ImageFixtures {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static func canvas(width: Int, height: Int, _ draw: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        return try #require(context.makeImage())
    }

    /// Gradients and grain that compress like photos.
    static func photo(width: Int = 640, height: Int = 480, seed: Int = 1) throws -> CGImage {
        var state = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15
        func random() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let base = (y * width + x) * 4
                let wave = 30 * sin(Double(x) * 0.05 + Double(seed)) * cos(Double(y) * 0.07)
                let grain = (random() - 0.5) * 24
                rgba[base] = UInt8(clamping: Int(60 + Double(x) / Double(width) * 150 + wave + grain))
                rgba[base + 1] = UInt8(clamping: Int(90 + Double(y) / Double(height) * 120 - wave + grain))
                rgba[base + 2] = UInt8(clamping: Int(200 - Double(x + y) / Double(width + height) * 140 + grain))
            }
        }
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        return try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// `nil` background is transparent.
    static func disc(size: Int = 200, background: CGColor? = CGColor(gray: 1, alpha: 1)) throws -> CGImage {
        try canvas(width: size, height: size) { context in
            if let background {
                context.setFillColor(background)
                context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            }
            context.setFillColor(CGColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1))
            let inset = Double(size) / 4
            context.fillEllipse(in: CGRect(x: inset, y: inset, width: Double(size) / 2, height: Double(size) / 2))
        }
    }

    static func text(_ string: String, width: Int = 900, height: Int = 200) throws -> CGImage {
        try canvas(width: width, height: height) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let font = CTFontCreateWithName("Helvetica" as CFString, 72, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            context.textPosition = CGPoint(x: 40, y: 70)
            CTLineDraw(line, context)
        }
    }

    @discardableResult
    static func write(
        _ images: [CGImage], as type: UTType, to url: URL, properties: [CFString: Any] = [:],
        frameProperties: [CFString: Any] = [:], quality: Double? = nil
    ) throws -> URL {
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil))
        CGImageDestinationSetProperties(destination, properties as CFDictionary)
        var perFrame = frameProperties
        if let quality { perFrame[kCGImageDestinationLossyCompressionQuality] = quality }
        for image in images { CGImageDestinationAddImage(destination, image, perFrame as CFDictionary) }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    static func source(_ url: URL) throws -> CGImageSource {
        try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    }

    static func image(_ url: URL, index: Int = 0) throws -> CGImage {
        try #require(CGImageSourceCreateImageAtIndex(try source(url), index, nil))
    }

    static func properties(_ url: URL, index: Int = 0) throws -> [CFString: Any] {
        CGImageSourceCopyPropertiesAtIndex(try source(url), index, nil) as? [CFString: Any] ?? [:]
    }

    /// Straight RGBA at (x, y), y down.
    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(
            CGContext(
                data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return bytes
    }

    static func rawBytes(_ url: URL) throws -> Data {
        try #require(try image(url).dataProvider?.data as Data?)
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    static let canEncodeHEIC: Bool = {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil),
            let image = try? disc(size: 16)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) && data.length > 0
    }()

    static func engine() throws -> JobEngine {
        let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseSupport-\(UUID().uuidString)")
        return try JobEngine(supportDirectory: support, concurrency: 2)
    }

    static func run(
        _ op: OperationID, preset: String?, inputs: [URL], settings: Settings = Settings()
    ) async throws -> BatchOutcome {
        let operation = try #require(ImagePlanner.operation(for: op, preset: preset, settings: settings))
        return try await run(op, operation, inputs: inputs, settings: settings)
    }

    static func run(
        _ op: OperationID, _ operation: ImageOperation, inputs: [URL], settings: Settings = Settings()
    ) async throws -> BatchOutcome {
        var settings = settings
        settings.outputMode = .replace
        let request = OperationRequest(op: op, options: .image(operation), inputs: inputs)
        let batch = OperationPlanner.batch(for: request, settings: settings)
        return try await engine().run(batch, settings: settings) { _ in }
    }

    /// The first item's first output.
    static func output(of outcome: BatchOutcome) throws -> URL {
        guard case .succeeded(let outputs, _) = try #require(outcome.outcomes.first), let url = outputs.first else {
            Issue.record("expected success, got \(outcome.outcomes)")
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    static func warnings(of outcome: BatchOutcome) -> [ItemWarning] {
        guard case .succeeded(_, let warnings) = outcome.outcomes.first else { return [] }
        return warnings
    }
}
