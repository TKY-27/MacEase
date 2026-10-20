import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Formats

/// Strict LZW decoder checking code widths.
private func decodeLZW(_ bytes: [UInt8], minimumCodeSize: Int) throws -> [UInt8] {
    let clear = 1 << minimumCodeSize
    var table: [[UInt8]] = (0..<clear).map { [UInt8($0)] } + [[], []]
    var size = minimumCodeSize + 1
    var bitPosition = 0
    var previous: [UInt8]?
    var output: [UInt8] = []
    func read() throws -> Int {
        guard bitPosition + size <= bytes.count * 8 else { throw FormatError.corrupt("ran out of bits") }
        var code = 0
        for bit in 0..<size where bytes[(bitPosition + bit) / 8] >> ((bitPosition + bit) % 8) & 1 == 1 {
            code |= 1 << bit
        }
        bitPosition += size
        return code
    }
    while true {
        let code = try read()
        if code == clear {
            table = Array(table.prefix(clear + 2))
            size = minimumCodeSize + 1
            previous = nil
            continue
        }
        if code == clear + 1 { return output }
        let entry: [UInt8]
        if code < table.count {
            entry = table[code]
        } else if let previous, code == table.count {
            entry = previous + [previous[0]]
        } else {
            throw FormatError.corrupt("invalid code \(code)")
        }
        output += entry
        if let previous, table.count < 4096 {
            table.append(previous + [entry[0]])
            if table.count == 1 << size, size < 12 { size += 1 }
        }
        previous = entry
    }
}

@Suite struct LZWTests {
    @Test func strictDecoderAgreesAcrossLengthsAndWidths() throws {
        var random = FixtureRandom(seed: 5)
        for codeSize in [2, 4, 8] {
            for length in [1, 2, 3, 13, 255, 256, 1000, 5000, 20_000] {
                let symbols = (0..<length).map { _ in UInt8(random.next() % UInt64(1 << codeSize)) }
                var encoder = LZWEncoder(minimumCodeSize: codeSize)
                for symbol in symbols { encoder.append(symbol) }
                #expect(try decodeLZW(encoder.finish(), minimumCodeSize: codeSize) == symbols, "\(codeSize)/\(length)")
            }
        }
    }
}

@Suite struct ExactPaletteTests {
    private func nearColors() -> PixelBuffer {
        let colors: [[UInt8]] = [
            [100, 100, 100, 255], [101, 100, 100, 255], [200, 10, 10, 255], [201, 11, 10, 255],
        ]
        return PixelBuffer(width: 16, height: 16, rgba: (0..<256).flatMap { colors[$0 % 4] })
    }

    @Test func pngAndGIFKeepFewColorsExact() throws {
        let pixels = nearColors()
        let png = try PNGQuantizer.encode(pixels, colors: 16, dithering: .none)
        #expect(try Fixtures.decode(png).rgba == pixels.rgba)
        let gif = try GIFEncoder.encode(
            [GIFFrame(pixels: pixels, duration: 0)], options: GIFOptions(colors: 16, dithering: .none))
        #expect(try Fixtures.decode(gif).rgba == pixels.rgba)
    }

    @Test func svgLayersKeepExactColors() {
        let layers = SVGTracer.trace(nearColors(), colors: 4)
        #expect(Set(layers.map(\.color)).count == 4)
    }
}

@Suite struct TranslucencyTests {
    @Test func partialAlphaSurvivesQuantization() throws {
        var pixels = Fixtures.photo(width: 96, height: 64)
        for index in stride(from: 3, to: pixels.rgba.count, by: 4) {
            pixels.rgba[index] = UInt8(index / 4 % 96 * 255 / 95)
        }
        let decoded = try Fixtures.decode(try PNGQuantizer.encode(pixels, colors: 64, dithering: .none))
        for index in stride(from: 3, to: pixels.rgba.count, by: 4) where pixels.rgba[index] < 200 {
            #expect(decoded.rgba[index] < 240, "alpha \(pixels.rgba[index]) became \(decoded.rgba[index])")
        }
    }

    @Test func transparentAnimationRestoresBackground() throws {
        let frames = (0..<3).map { frame -> PixelBuffer in
            PixelBuffer(
                width: 8, height: 8,
                rgba: (0..<64).flatMap { pixel -> [UInt8] in pixel % 8 == frame ? [255, 0, 0, 255] : [0, 0, 0, 0] }
            )
        }
        let gif = try GIFEncoder.encode(
            frames.map { GIFFrame(pixels: $0, duration: 0.1) }, options: GIFOptions(dithering: .none))
        let source = try #require(CGImageSourceCreateWithData(gif as CFData, nil))
        let last = try PixelBuffer(cgImage: try #require(CGImageSourceCreateImageAtIndex(source, 2, nil)))
        #expect(last.rgba[2 * 4 + 3] == 255)
        #expect(last.rgba[0 * 4 + 3] == 0)
    }

    @Test func perFramePalettesAnimate() throws {
        let frames = Fixtures.gradientFrames(count: 6, width: 64, height: 36)
        let gif = try GIFEncoder.encode(
            frames.map { GIFFrame(pixels: $0, duration: 0.1) },
            options: GIFOptions(dithering: .none, paletteScope: .perFrame)
        )
        let source = try #require(CGImageSourceCreateWithData(gif as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 6)
        let decoded = try PixelBuffer(cgImage: try #require(CGImageSourceCreateImageAtIndex(source, 5, nil)))
        #expect(SSIM.compare(frames[5], decoded) > 0.95)
    }
}

@Suite struct ProfileTests {
    @Test func grayPixelsWithAnRGBProfileStayRGB() throws {
        var rgba: [UInt8] = []
        for pixel in 0..<1024 {
            let level = UInt8(pixel % 32 * 8)
            rgba += [level, level, level, 255]
        }
        let space = try #require(CGColorSpace(name: CGColorSpace.adobeRGB1998))
        let gray = PixelBuffer(width: 32, height: 32, rgba: rgba, colorSpace: space)
        let input = try Fixtures.encode(gray, as: .png)
        let output = try PNGOptimizer.optimize(input)
        let source = try #require(CGImageSourceCreateWithData(output as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.colorSpace?.model == CGColorSpaceModel.rgb)
        #expect(try PNGFile.chunks(in: output).contains { $0.type == "iCCP" })
    }
}

@Suite struct MalformedInputTests {
    @Test func icoReaderRejectsBrokenFiles() {
        let truncated = Data([0, 0, 1, 0, 5, 0])
        #expect(throws: FormatError.self) { try ICOFile.read(truncated) }
        var outOfRange = Data([0, 0, 1, 0, 1, 0, 16, 16, 0, 0, 1, 0, 32, 0])
        outOfRange.append(contentsOf: [0xFF, 0xFF, 0, 0, 0xFF, 0xFF, 0xFF, 0x7F])
        #expect(throws: FormatError.self) { try ICOFile.read(outOfRange) }
    }

    @Test func icoReaderRefusesHugeEmbeddedPNG() throws {
        var png = try Fixtures.encode(Fixtures.logo(size: 16), as: .png)
        // IHDR size fields start at 16.
        png.replaceSubrange(16..<24, with: [0, 0, 0xC3, 0x50, 0, 0, 0xC3, 0x50])
        let ico = try ICOFile.write([(16, png)])
        #expect(throws: FormatError.self) { try ICOFile.read(ico) }
    }

    @Test func icnsReaderRejectsOverrunningRLE() {
        var icns = Data("icns".utf8)
        icns.appendBigEndian(UInt32(8 + 8 + 2))
        icns.append(Data("is32".utf8))
        icns.appendBigEndian(UInt32(10))
        icns.append(contentsOf: [0x05, 0x01])
        #expect(throws: FormatError.self) { try ICNSFile.read(icns) }
    }

    @Test func pngChunkReaderRejectsOversizedLengths() {
        var png = Data(PNGFile.signature)
        png.appendBigEndian(UInt32.max)
        png.append(Data("IHDR".utf8))
        #expect(throws: FormatError.self) { try PNGFile.chunks(in: png) }
    }
}
