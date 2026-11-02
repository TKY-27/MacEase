import CoreGraphics
import Formats
import Foundation
import ImageIO
import Testing

@testable import Engine

@Suite struct OpaquePNGPreparationTests {
    private static let width = 3
    private static let height = 2
    private static let rowBytes = 16
    private static let rgba: [UInt8] = [
        0, 19, 254, 255, 22, 33, 44, 255, 250, 127, 1, 255,
        99, 100, 101, 255, 17, 255, 5, 255, 0, 0, 0, 255,
    ]

    private static func image(
        alpha: CGImageAlphaInfo = .premultipliedLast, space: CGColorSpace = PixelBuffer.sRGB,
        order: CGBitmapInfo = .byteOrder32Big, opacity: UInt8 = 255
    ) throws -> CGImage {
        var rows = Data(count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let source = (y * width + x) * 4
                let target = y * rowBytes + x * 4
                let colors = (0..<3).map { UInt8(Int(rgba[source + $0]) * Int(opacity) / 255) }
                var components = alpha == .premultipliedFirst ? [opacity] + colors : colors + [opacity]
                if order == .byteOrder32Little { components.reverse() }
                for channel in 0..<4 { rows[target + channel] = components[channel] }
            }
        }
        let provider = try #require(CGDataProvider(data: rows as CFData))
        return try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                space: space, bitmapInfo: order.union(CGBitmapInfo(rawValue: alpha.rawValue)), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @Test(arguments: [CGImageAlphaInfo.premultipliedFirst, .premultipliedLast])
    func opaquePaddedRowsKeepOriginalBytesAndProfile(alpha: CGImageAlphaInfo) throws {
        for profile in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
            let space = try #require(CGColorSpace(name: profile))
            let original = try Self.image(alpha: alpha, space: space)
            #expect(!PixelBuffer.canReadExactly(original))
            let pixels = try #require(try PixelBuffer(opaquePremultiplied: original))
            #expect(pixels.rgba == Self.rgba)
            #expect((pixels.colorSpace.copyICCData() as Data?) == (space.copyICCData() as Data?))
            #expect(original.bitsPerComponent == 8)
            let frames = [ImageFrame(image: original, duration: 0)]
            var options = EncodeOptions(quality: 100)
            options.optimizesPNG = true
            options.maximumPNGBytes = 1_000_000
            let oldRoundtrip = try ImageEncoder.encode(frames, as: .png, options: options)
            let reference = try #require(CGImageSourceCreateWithData(oldRoundtrip as CFData, nil))
            let decoded = try #require(CGImageSourceCreateImageAtIndex(reference, 0, nil))
            #expect(try PixelBuffer(cgImage: decoded).rgba == pixels.rgba)
            #expect(decoded.bitsPerComponent == original.bitsPerComponent)
            #expect((decoded.colorSpace?.copyICCData() as Data?) == (pixels.colorSpace.copyICCData() as Data?))
        }
    }

    @Test func scaledTargetPreparationMatchesImageIORoundtripAndMetadata() throws {
        let original = try ImageFixtures.photo(width: 192, height: 128)
        let scaled = try ImagePixels.scaled(original, width: 144, height: 96)
        #expect(scaled.alphaInfo == .premultipliedLast)
        #expect(!PixelBuffer.canReadExactly(scaled))
        let metadata = CGImageMetadataCreateMutable()
        #expect(
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment,
                "Opaque scaled PNG" as CFString))
        var options = EncodeOptions(quality: 100)
        options.optimizesPNG = true
        options.maximumPNGBytes = 1_000_000
        options.metadata = metadata
        let frames = [ImageFrame(image: scaled, duration: 0)]
        let reference = try ImageEncoder.encode(frames, as: .png, options: options)
        let prepared = try #require(try ImageEncoder.preparePNGTargetPixels(frames, options: options, retaining: []))
        let direct = try ImageEncoder.encode(frames, as: .png, options: options, preparedPNGPixels: prepared)
        let oldSource = try #require(CGImageSourceCreateWithData(reference as CFData, nil))
        let directSource = try #require(CGImageSourceCreateWithData(direct as CFData, nil))
        let oldImage = try #require(CGImageSourceCreateImageAtIndex(oldSource, 0, nil))
        let directImage = try #require(CGImageSourceCreateImageAtIndex(directSource, 0, nil))
        #expect(try prepared.rgba == PixelBuffer(cgImage: oldImage).rgba)
        #expect(try PixelBuffer(cgImage: directImage).rgba == prepared.rgba)
        #expect(directImage.width == 144 && directImage.height == 96)
        #expect(directImage.bitsPerComponent == oldImage.bitsPerComponent)
        #expect((directImage.colorSpace?.copyICCData() as Data?) == (oldImage.colorSpace?.copyICCData() as Data?))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(directSource, 0, nil) as? [CFString: Any])
        let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifUserComment] as? String == "Opaque scaled PNG")
    }

    @Test func partialAlphaAndLittleEndianStayOnTheExistingPath() throws {
        for opacity: UInt8 in [0, 128, 254] {
            let image = try Self.image(opacity: opacity)
            #expect(try PixelBuffer(opaquePremultiplied: image) == nil)
            #expect(
                try ImageEncoder.preparePNGTargetPixels(
                    [ImageFrame(image: image, duration: 0)], options: EncodeOptions(quality: 100), retaining: []) == nil
            )
        }
        #expect(try PixelBuffer(opaquePremultiplied: Self.image(order: .byteOrder32Little)) == nil)
    }

    @Test func decodeTablesAndSixteenBitPixelsAreNeverReadAsExactEightBit() throws {
        let provider = try #require(CGDataProvider(data: Data(Self.rgba) as CFData))
        let decode: [CGFloat] = [1, 0, 0, 1, 0, 1]
        try decode.withUnsafeBufferPointer { table in
            let image = try #require(
                CGImage(
                    width: Self.width, height: Self.height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: Self.width * 4, space: PixelBuffer.sRGB,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: table.baseAddress, shouldInterpolate: false, intent: .defaultIntent))
            #expect(try PixelBuffer(opaquePremultiplied: image) == nil)
        }
        let samples: [UInt16] = [20_001, 30_001, 40_001, .max]
        let payload = samples.withUnsafeBytes { Data($0) }
        let highProvider = try #require(CGDataProvider(data: payload as CFData))
        let highPrecision = try #require(
            CGImage(
                width: 1, height: 1, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: 8,
                space: PixelBuffer.sRGB,
                bitmapInfo: CGBitmapInfo.byteOrder16Little.union(
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
                provider: highProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        #expect(try PixelBuffer(opaquePremultiplied: highPrecision) == nil)
        #expect(
            try ImageEncoder.preparePNGTargetPixels(
                [ImageFrame(image: highPrecision, duration: 0)], options: EncodeOptions(quality: 100), retaining: [])
                == nil)
    }

    @Test(arguments: [2, 4])
    func opacityScanAndCopyBothObserveCancellation(cancelAt: Int) throws {
        let image = try Self.image()
        var probes = 0
        #expect(throws: CancellationError.self) {
            _ = try PixelBuffer(opaquePremultiplied: image) {
                probes += 1
                return probes >= cancelAt
            }
        }
    }
}
