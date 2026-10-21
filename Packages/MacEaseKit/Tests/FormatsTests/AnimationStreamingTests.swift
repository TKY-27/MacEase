import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import Formats

@Suite struct AnimationStreamingTests {
    private static let side = 8
    private static let frameCount = 40
    private static let framesPerSecond = 15.0

    @Test func gifClearsOpaquePixelsBeforeTransparentFrames() throws {
        let output = FileManager.default.temporaryDirectory.appending(path: "stream-\(UUID().uuidString).gif")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: output) } }
        let encoder = try GIFEncoder.Stream(
            width: Self.side, height: Self.side,
            options: GIFOptions(dithering: .none, paletteScope: .perFrame), to: output)
        let opaque = pixels(transparent: false)
        let transparent = pixels(transparent: true)
        for frame in [opaque, transparent, opaque] {
            try encoder.add(GIFFrame(pixels: frame, duration: 1 / Self.framesPerSecond))
        }
        try encoder.finish()
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 3)
        for (index, expected) in [opaque, transparent, opaque].enumerated() {
            let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
            #expect(try PixelBuffer(cgImage: image).rgba == expected.rgba)
        }
    }

    @Test(arguments: [false, true], [80.0, 100.0])
    func webPChunkBoundariesPreserveConstantAndTransparentFrames(_ changesAlpha: Bool, quality: Double) throws {
        let output = FileManager.default.temporaryDirectory.appending(path: "stream-\(UUID().uuidString).webp")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: output) } }
        let encoder = try WebPAnimationEncoder.Stream(
            width: Self.side, height: Self.side, quality: quality, loops: false, maximumEncodedBytes: 1_000_000)
        for index in 0..<Self.frameCount {
            let frame = pixels(transparent: changesAlpha && index % 2 == 1)
            try encoder.add(frame.makeCGImage(), duration: 1 / Self.framesPerSecond)
        }
        try encoder.finish(to: output)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        var elapsed = 0.0
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let timing = try #require(properties[kCGImagePropertyWebPDictionary] as? [CFString: Any])
            let delay = try #require(timing[kCGImagePropertyWebPUnclampedDelayTime] as? Double)
            let expectedIndex = Int((elapsed * Self.framesPerSecond).rounded())
            let expected = pixels(transparent: changesAlpha && expectedIndex % 2 == 1)
            let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
            let decoded = try PixelBuffer(cgImage: image)
            let colorTolerance = quality == 100 ? 0 : 16
            for base in stride(from: 0, to: expected.rgba.count, by: 4) {
                #expect(decoded.rgba[base + 3] == expected.rgba[base + 3])
                if expected.rgba[base + 3] > 0 {
                    for channel in 0..<3 {
                        #expect(
                            abs(Int(decoded.rgba[base + channel]) - Int(expected.rgba[base + channel]))
                                <= colorTolerance)
                    }
                }
            }
            elapsed += delay
        }
        #expect(abs(elapsed - Double(Self.frameCount) / Self.framesPerSecond) < 0.002)
    }

    @Test func webPRejectsCompressedOutputOverItsBudget() throws {
        let output = FileManager.default.temporaryDirectory.appending(path: "stream-\(UUID().uuidString).webp")
        TestTemporaryFolders.register(output)
        let encoder = try WebPAnimationEncoder.Stream(
            width: Self.side, height: Self.side, quality: 100, loops: false, maximumEncodedBytes: 1)
        try encoder.add(pixels(transparent: false).makeCGImage(), duration: 1 / Self.framesPerSecond)
        #expect(throws: WebPAnimationEncoder.Stream.Error.encodedSizeExceeded) {
            try encoder.finish(to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    private func pixels(transparent: Bool) -> PixelBuffer {
        let rgba = (0..<(Self.side * Self.side)).flatMap { pixel -> [UInt8] in
            transparent && pixel % Self.side < Self.side / 2 ? [0, 0, 0, 0] : [255, 0, 0, 255]
        }
        return PixelBuffer(width: Self.side, height: Self.side, rgba: rgba)
    }
}
