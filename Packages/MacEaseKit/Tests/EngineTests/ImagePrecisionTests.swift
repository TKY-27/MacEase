import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing

@testable import Engine

struct ImagePrecisionTests {
    enum Edit: CaseIterable {
        case resize, flip, trimBorders, background, square, icon, flatten
    }

    private static let width = 64
    private static let height = 48
    private static let channels = 4
    private static let componentBits = 16
    private static let red: UInt16 = 16_544
    private static let sampleTolerance = 16

    private static func sourceImage() throws -> CGImage {
        let rgba: [UInt16] = [red, 32_960, 49_504, UInt16.max]
        let samples = Array(repeating: rgba, count: width * height).flatMap { $0 }
        let payload = samples.withUnsafeBytes { Data($0) }
        let provider = try #require(CGDataProvider(data: payload as CFData))
        return try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: componentBits,
                bitsPerPixel: componentBits * channels,
                bytesPerRow: width * channels * MemoryLayout<UInt16>.size,
                space: ImageFixtures.sRGB,
                bitmapInfo: CGBitmapInfo.byteOrder16Little.union(
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private static func expectPrecision(_ image: CGImage) throws {
        #expect(image.bitsPerComponent == componentBits)
        let canvas = try #require(
            CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: componentBits,
                bytesPerRow: 0, space: ImageFixtures.sRGB,
                bitmapInfo: CGBitmapInfo.byteOrder16Little.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let samples = try #require(canvas.data).assumingMemoryBound(to: UInt16.self)
        let eightBitStep = Int(UInt16.max) / Int(UInt8.max)
        let center = (image.height / 2) * canvas.bytesPerRow / MemoryLayout<UInt16>.size + image.width / 2 * channels
        withExtendedLifetime(canvas) {
            #expect(abs(Int(samples[center]) - Int(red)) <= sampleTolerance)
            #expect(Int(samples[center]) % eightBitStep != 0)
            #expect(samples[center + channels - 1] == UInt16.max)
        }
    }

    @Test(arguments: [ImageFormat.png, .tiff])
    func sixteenBitPNGAndTIFFRotatedFifteenDegreesKeepPrecision(_ format: ImageFormat) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = folder.appending(path: "sixteen-bit.\(format.fileExtension)")
        try ImageFixtures.write([Self.sourceImage()], as: format.contentType, to: input)
        try Self.expectPrecision(ImageFixtures.image(input))
        let original = try Data(contentsOf: input)
        var settings = Settings()
        settings.outputMode = .replace
        let context = ItemContext(
            settings: settings, staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard
            case .replace(let source, let output) = try await ImageEdits.rotate(
                input, degrees: 15, fill: nil, context: context)
        else { Issue.record("Expected a staged rotation"); return }
        #expect(source == input)
        #expect(context.warnings.isEmpty)
        try await OutputVerifier.verify(output)
        try Self.expectPrecision(ImageFixtures.image(output.url))
        #expect(try Data(contentsOf: input) == original)
    }

    private static func applying(_ edit: Edit, to source: CGImage) throws -> CGImage {
        switch edit {
        case .resize:
            return try ImagePixels.scaled(source, width: width / 2, height: height / 2)
        case .flip:
            return try ImagePixels.flipped(source, .horizontal)
        case .trimBorders:
            return try ImagePixels.cropped(
                source, to: CGRect(x: 8, y: 8, width: width - 16, height: height - 16))
        case .background:
            let mask = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
            return try ImageBackground.composite(source, mask: mask, fill: .transparent)
        case .square:
            return try ImageEncoder.square(source)
        case .icon:
            return try ImagePixels.scaled(ImageEncoder.square(source), width: 32, height: 32)
        case .flatten:
            return try ImageEncoder.flattened(source, background: .white)
        }
    }

    @Test(arguments: [ImageFormat.png, .tiff], Edit.allCases)
    func ordinaryEditsKeepSixteenBitSamples(_ format: ImageFormat, _ edit: Edit) throws {
        let edited = try Self.applying(edit, to: Self.sourceImage())
        let encoded = try ImageEncoder.encode(
            [ImageFrame(image: edited, duration: 0)], as: format,
            options: EncodeOptions(quality: ImageEncoder.maximumQuality))
        let written = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
        try Self.expectPrecision(#require(CGImageSourceCreateImageAtIndex(written, 0, nil)))
    }

    @Test func sixteenBitDrawingRejectsOversizedCanvasBeforeAllocation() throws {
        let source = try Self.sourceImage()
        #expect(throws: EngineError.invalidInput(.frameMemoryExceeded)) {
            _ = try ImagePixels.padded(source, width: 12_500, height: 10_000, fill: nil)
        }
    }

    @Test(arguments: Edit.allCases)
    func floatingPointEditsKeepExtendedSamples(_ edit: Edit) throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let canvas = try #require(
            CGContext(
                data: nil, width: Self.width, height: Self.height, bitsPerComponent: Self.componentBits,
                bytesPerRow: 0, space: space,
                bitmapInfo: CGBitmapInfo.floatComponents.union(.byteOrder16Little).rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(try #require(CGColor(colorSpace: space, components: [1.5, 0.5, 0.25, 1])))
        canvas.fill(CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        let edited = try Self.applying(edit, to: #require(canvas.makeImage()))
        #expect(edited.bitsPerComponent == Self.componentBits)
        #expect(edited.bitmapInfo.contains(.floatComponents))
        let payload = try #require(edited.dataProvider?.data as Data?)
        let center =
            (edited.height / 2) * edited.bytesPerRow
            + (edited.width / 2) * Self.channels * MemoryLayout<Float16>.size
        #expect(payload.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: center, as: Float16.self) } == 1.5)
    }
}
