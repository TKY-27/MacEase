import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import Formats

private let displayP3 = CGColorSpace(name: CGColorSpace.displayP3) ?? PixelBuffer.sRGB

/// Display P3, left quarter transparent.
private func translucentP3Photo() -> PixelBuffer {
    let photo = Fixtures.photo(width: 160, height: 120)
    var rgba = photo.rgba
    for y in 0..<photo.height {
        for x in 0..<photo.width / 4 { rgba[(y * photo.width + x) * 4 + 3] = 0 }
    }
    return PixelBuffer(width: photo.width, height: photo.height, rgba: rgba, colorSpace: displayP3)
}

private struct Decoded {
    let image: CGImage
    let properties: [CFString: Any]
    let count: Int
    let source: CGImageSource
}

private func decode(_ data: Data) throws -> Decoded {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    return Decoded(image: image, properties: properties, count: CGImageSourceGetCount(source), source: source)
}

private func expectStill(_ data: Data, matches source: PixelBuffer, minimumSSIM: Double) throws {
    let decoded = try decode(data)
    #expect(decoded.image.width == source.width)
    #expect(decoded.image.height == source.height)
    #expect(decoded.properties[kCGImagePropertyHasAlpha] as? Bool == true)
    #expect(decoded.image.colorSpace?.name == CGColorSpace.displayP3)
    let pixels = try PixelBuffer(cgImage: decoded.image)
    #expect(pixels.rgba[3] < 8)
    #expect(pixels.rgba[(source.width - 1) * 4 + 3] > 247)
    #expect(SSIM.compare(source, pixels) >= minimumSSIM)
}

private func opaque(_ rgba: [UInt8]) -> [UInt8] {
    var copy = rgba
    for index in stride(from: 3, to: copy.count, by: 4) { copy[index] = 255 }
    return copy
}

@Suite struct CodecTests {
    @Test func webPKeepsSizeAlphaAndProfile() throws {
        let source = translucentP3Photo()
        let data = try WebPEncoder.encode(source, quality: 90)
        try expectStill(data, matches: source, minimumSSIM: 0.9)
        let lossless = try WebPEncoder.encode(source, quality: 100, lossless: true)
        let pixels = try PixelBuffer(cgImage: try decode(lossless).image)
        #expect(opaque(pixels.rgba)[4_000..<4_400] == opaque(source.rgba)[4_000..<4_400])
    }

    @Test func webPQualityControlsSize() throws {
        let source = Fixtures.photo()
        let small = try WebPEncoder.encode(source, quality: 30)
        let large = try WebPEncoder.encode(source, quality: 90)
        #expect(small.count < large.count)
    }

    @Test func animatedWebPKeepsFramesTimingAndLoop() throws {
        let durations = [0.1, 0.25, 0.5]
        let encoder = try WebPAnimationEncoder(width: 96, height: 64, quality: 80, loops: false)
        for (index, duration) in durations.enumerated() {
            let frame = Fixtures.photo(width: 96, height: 64, seed: UInt64(index + 1))
            if index == 1 {
                try encoder.add(try frame.makeCGImage(), duration: duration)
            } else {
                try encoder.add(frame, duration: duration)
            }
        }
        let decoded = try decode(try encoder.finish())
        #expect(decoded.count == durations.count)
        for (index, duration) in durations.enumerated() {
            let properties = CGImageSourceCopyPropertiesAtIndex(decoded.source, index, nil) as? [CFString: Any]
            let webP = properties?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
            let delay = webP?[kCGImagePropertyWebPUnclampedDelayTime] as? Double ?? 0
            #expect(abs(delay - duration) < 0.002)
        }
        let container = CGImageSourceCopyProperties(decoded.source, nil) as? [CFString: Any]
        let webP = container?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
        #expect(webP?[kCGImagePropertyWebPLoopCount] as? Int == 1)
        #expect(decoded.image.width == 96)
    }

    @Test func animatedWebPKeepsProfileAndAlpha() throws {
        let source = translucentP3Photo()
        let encoder = try WebPAnimationEncoder(width: source.width, height: source.height, quality: 90, loops: true)
        try encoder.add(source, duration: 0.1)
        var shifted = source
        for index in stride(from: 0, to: shifted.rgba.count, by: 4) { shifted.rgba[index] /= 2 }
        try encoder.add(shifted, duration: 0.1)
        let decoded = try decode(try encoder.finish())
        #expect(decoded.count == 2)
        #expect(decoded.image.colorSpace?.name == CGColorSpace.displayP3)
        #expect(try PixelBuffer(cgImage: decoded.image).rgba[3] < 8)
    }

    @Test func aVIFKeepsSizeAlphaAndProfile() throws {
        let source = translucentP3Photo()
        try expectStill(try AVIFEncoder.encode(source, quality: 80), matches: source, minimumSSIM: 0.9)
        let opaqueData = try AVIFEncoder.encode(Fixtures.photo(), quality: 60)
        #expect(try decode(opaqueData).properties[kCGImagePropertyHasAlpha] as? Bool != true)
    }

    @Test func jPEGXLKeepsSizeAlphaAndProfile() throws {
        let source = translucentP3Photo()
        try expectStill(try JXLEncoder.encode(source, quality: 90), matches: source, minimumSSIM: 0.9)
        let small = try JXLEncoder.encode(Fixtures.photo(), quality: 40)
        let large = try JXLEncoder.encode(Fixtures.photo(), quality: 90)
        #expect(small.count < large.count)
    }

    @Test func encodersEmbedXMP() throws {
        let xmp = Data(
            """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:CreatorTool="MacEaseTest"/>\
            </rdf:RDF></x:xmpmeta>
            """.utf8)
        let photo = Fixtures.photo(width: 64, height: 48)
        let outputs = [
            try WebPEncoder.encode(photo, quality: 80, xmp: xmp),
            try AVIFEncoder.encode(photo, quality: 80, xmp: xmp),
            try JXLEncoder.encode(photo, quality: 80, xmp: xmp),
        ]
        for data in outputs {
            let decoded = try decode(data)
            let metadata = try #require(CGImageSourceCopyMetadataAtIndex(decoded.source, 0, nil))
            let tool = CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:CreatorTool" as CFString)
            #expect(tool as String? == "MacEaseTest")
        }
    }
}
