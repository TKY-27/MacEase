import CDeflate
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import Formats

@Suite struct PNGOptimizerTests {
    private func inputs() throws -> [(String, Data)] {
        let photo = Fixtures.photo(width: 160, height: 120)
        var translucent = photo
        for index in stride(from: 3, to: translucent.rgba.count, by: 4) {
            translucent.rgba[index] = UInt8(index / 4 % 256)
        }
        let gray = PixelBuffer(
            width: 64, height: 64,
            rgba: (0..<(64 * 64)).flatMap { pixel -> [UInt8] in
                let value = UInt8(pixel % 64 * 4)
                return [value, value, value, 255]
            }
        )
        let fewColors = PixelBuffer(
            width: 50, height: 40,
            rgba: (0..<2000).flatMap { pixel -> [UInt8] in
                pixel % 7 < 3 ? [255, 0, 0, 255] : pixel % 7 < 5 ? [0, 0, 255, 128] : [0, 0, 0, 0]
            }
        )
        return try [("photo", photo), ("translucent", translucent), ("gray", gray), ("fewColors", fewColors)]
            .map { ($0.0, try Fixtures.encode($0.1, as: .png)) }
    }

    @Test func keepsPixelsIdenticalAndNeverGrows() throws {
        for (name, input) in try inputs() {
            let output = try PNGOptimizer.optimize(input)
            #expect(output.count <= input.count, "\(name) grew")
            #expect(try Fixtures.decode(output).rgba == Fixtures.decode(input).rgba, "\(name) changed pixels")
        }
    }

    @Test func shrinksImageIOOutput() throws {
        for (name, input) in try inputs() where name != "photo" {
            #expect(try PNGOptimizer.optimize(input).count < input.count, "\(name) did not shrink")
        }
    }

    @Test func optimizedOutputIsIdempotent() throws {
        let optimized = try PNGOptimizer.optimize(try inputs()[2].1)
        #expect(try PNGOptimizer.optimize(optimized) == optimized)
    }

    @Test func returnsInputBytesWhenNothingIsGained() throws {
        let original = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQAAAAA3bvkkAAAACklEQVR4nGNgAAAAAgABSK+kcQAAAABJRU5ErkJggg=="))
        #expect(try Fixtures.decode(original).rgba == [0, 0, 0, 255])
        #expect(try PNGOptimizer.optimize(original) == original)
    }

    @Test func outputCapacityAcceptsExactFitAndRejectsOneByteLess() throws {
        let pixels = PixelBuffer(
            width: 4, height: 1,
            rgba: [100, 100, 100, 255, 101, 101, 101, 255, 102, 102, 102, 255, 103, 103, 103, 255])
        let raster = PNGRaster(
            width: pixels.width, height: pixels.height, colorType: .rgba, bitDepth: 8, samples: pixels.rgba)
        let original = try PNGFile.encode(raster, strategy: .none, level: PNGFile.trialLevel)
        let compressed = try #require(PNGFile.chunks(in: original).first { $0.type == "IDAT" })
        let capacity = Int64(compressed.payload.count)
        let exactFit = try PNGFile.encode(
            raster, strategy: .none, level: PNGFile.trialLevel, maximumCompressedBytes: capacity)
        #expect(try Fixtures.decode(exactFit).rgba == pixels.rgba)
        #expect(exactFit == original)
        #expect(throws: PNGOutputError.sizeLimitExceeded) {
            try PNGFile.encode(
                raster, strategy: .none, level: PNGFile.trialLevel, maximumCompressedBytes: capacity - 1)
        }
    }

    @Test func zeroFilterFramesRowsExactlyAndKeepsCancellation() throws {
        func inflatedRows(_ raster: PNGRaster, strategy: PNGFilterStrategy) throws -> [UInt8] {
            let encoded = try PNGFile.encode(raster, strategy: strategy, level: PNGFile.trialLevel)
            let chunks = try PNGFile.chunks(in: encoded)
            let payload = try #require(chunks.first { $0.type == "IDAT" }).payload
            let decoder = try #require(libdeflate_alloc_decompressor())
            defer { libdeflate_free_decompressor(decoder) }
            var rows = [UInt8](repeating: 0, count: (raster.rowBytes + 1) * raster.height)
            let status = rows.withUnsafeMutableBytes { destination in
                payload.withUnsafeBytes { source in
                    libdeflate_zlib_decompress(
                        decoder, source.baseAddress, source.count, destination.baseAddress, destination.count, nil)
                }
            }
            #expect(status == LIBDEFLATE_SUCCESS)
            #expect(try Fixtures.decode(encoded).width == raster.width)
            return rows
        }
        let byteRows = PNGRaster(
            width: 4, height: 2, colorType: .gray, bitDepth: 8, samples: [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(try inflatedRows(byteRows, strategy: .none) == [0, 1, 2, 3, 4, 0, 5, 6, 7, 8])
        let packedRows = PNGRaster(
            width: 8, height: 2, colorType: .gray, bitDepth: 1, samples: [0xAA, 0x55])
        #expect(try inflatedRows(packedRows, strategy: .none) == [0, 0xAA, 0, 0x55])
        #expect(try inflatedRows(packedRows, strategy: .adaptive) == [0, 0xAA, 0, 0x55])
        var rows = 0
        #expect(throws: CancellationError.self) {
            try PNGFile.encode(byteRows, strategy: .none, level: PNGFile.trialLevel) {
                rows += 1
                return rows == 2
            }
        }
    }

    @Test func keepsAncillaryChunks() throws {
        let input = try inputs()[2].1
        var chunks = try PNGFile.chunks(in: input)
        let text = PNGChunk(type: "tEXt", payload: Data("Comment\u{0}kept".utf8))
        chunks.insert(text, at: 1)
        var rebuilt = Data(PNGFile.signature)
        for chunk in chunks { rebuilt.append(PNGFile.serialized(chunk)) }
        #expect(try PNGFile.chunks(in: PNGOptimizer.optimize(rebuilt)).contains(text))
    }
}

@Suite struct PNGQuantizerTests {
    @Test func translucentGradientKeepsColorAndOpacityWithinTwoPercent() throws {
        let width = 600
        let height = 400
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt64 = 42
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let base = (y * width + x) * 4
                let noise = Int(seed >> 60)
                rgba[base] = UInt8(clamping: x * 220 / width + noise)
                rgba[base + 1] = UInt8(clamping: y * 220 / height + noise)
                rgba[base + 2] = UInt8(clamping: (x + y) * 200 / (width + height) + noise * 2)
                rgba[base + 3] = UInt8(x * 255 / width)
            }
        }
        let original = PixelBuffer(width: width, height: height, rgba: rgba)
        let output = try PNGQuantizer.encode(original, colors: 256, dithering: .ordered)
        let decoded = try Fixtures.decode(output)
        var colorError = 0.0
        var alphaError = 0.0
        for pixel in 0..<original.pixelCount {
            let base = pixel * 4
            let originalAlpha = Double(original.rgba[base + 3]) / 255
            let codedAlpha = Double(decoded.rgba[base + 3]) / 255
            alphaError += abs(originalAlpha - codedAlpha)
            for component in 0..<3 {
                let originalColor = Double(original.rgba[base + component]) / 255 * originalAlpha
                let codedColor = Double(decoded.rgba[base + component]) / 255 * codedAlpha
                colorError += abs(originalColor - codedColor)
            }
        }
        #expect(colorError / Double(original.pixelCount * 3) <= 0.02)
        #expect(alphaError / Double(original.pixelCount) <= 0.02)
    }

    @Test func meetsQualityAndSizeTargetsOnThePhotoFixture() throws {
        let photo = Fixtures.photo()
        let lossless = try PNGOptimizer.encodeLossless(photo, ancillary: [], allowsGray: true)
        let lossy = try PNGQuantizer.encode(photo, colors: 256, dithering: .none)
        let decoded = try Fixtures.decode(lossy)
        let ssim = SSIM.compare(photo, decoded)
        let ratio = Double(lossy.count) / Double(lossless.count)
        #expect(ssim >= 0.97, "SSIM \(ssim)")
        #expect(ratio <= 0.45, "size ratio \(ratio)")
        var chromaError = 0.0
        for pixel in 0..<photo.pixelCount {
            let base = pixel * 4
            let original = Oklab(red: photo.rgba[base], green: photo.rgba[base + 1], blue: photo.rgba[base + 2])
            let coded = Oklab(red: decoded.rgba[base], green: decoded.rgba[base + 1], blue: decoded.rgba[base + 2])
            chromaError += Double(hypot(original.a - coded.a, original.b - coded.b))
        }
        chromaError /= Double(photo.pixelCount)
        #expect(chromaError <= 0.02, "mean chroma error \(chromaError)")
    }

    @Test func cancellationStopsQuantizationBeforeWriting() throws {
        let pixels = Fixtures.photo(width: 320, height: 240)
        var probes = 0
        #expect(throws: CancellationError.self) {
            try PNGQuantizer.encode(pixels, colors: 256, dithering: .none) {
                probes += 1
                return probes > 10
            }
        }
        #expect(probes > 10)
    }

    @Test func cancellationStopsLosslessOptimizationBeforeWriting() throws {
        let encoded = try Fixtures.encode(Fixtures.photo(), as: .png)
        var probes = 0
        #expect(throws: CancellationError.self) {
            try PNGOptimizer.optimize(encoded) {
                probes += 1
                return probes > 10
            }
        }
        #expect(probes > 10)
    }

    @Test func exactMappingMatchesIndependentExhaustiveSearch() {
        let palette: [PaletteColor] = (0..<64).map { index -> PaletteColor in
            let red = UInt8(index * 37 % 256)
            let green = UInt8(index * 71 % 256)
            let blue = UInt8(index * 113 % 256)
            let alpha = UInt8(index * 53 % 256)
            return PaletteColor(red: red, green: green, blue: blue, alpha: alpha)
        }
        let quantizer = ColorQuantizer(includesAlpha: true)
        let centers = palette.map { quantizer.point($0) }
        var mapper = PaletteMapper(palette: palette, includesAlpha: true, dithering: .none)
        for index in 0..<4096 {
            let color = PaletteColor(
                red: UInt8(index % 256), green: UInt8(index / 256 * 17),
                blue: UInt8(index * 43 % 256), alpha: UInt8(index * 61 % 256))
            let point = quantizer.point(color)
            let expected = centers.indices.min { left, right in
                let lhs = centers[left] - point
                let rhs = centers[right] - point
                return (lhs * lhs).sum() < (rhs * rhs).sum()
            }
            #expect(mapper.index(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha) == expected)
        }
    }

    @Test(arguments: Dithering.allCases)
    func exactPalettesKeepEveryPixelRegardlessOfDithering(_ dithering: Dithering) throws {
        let pixels = PixelBuffer(
            width: 4, height: 1,
            rgba: [100, 100, 100, 255, 101, 101, 101, 255, 102, 102, 102, 255, 103, 103, 103, 255])
        let encoded = try PNGQuantizer.encode(pixels, colors: 4, dithering: dithering)
        #expect(try Fixtures.decode(encoded).rgba == pixels.rgba)
        #expect(try !PNGQuantizer.reducesColors(pixels, to: 4))
    }

    @Test func targetBudgetChangesCompressionEffortWithoutChangingPalettePixels() throws {
        let pixels = Fixtures.photo(width: 160, height: 120)
        let maximumEffort = try PNGQuantizer.encode(pixels, colors: 256, dithering: .none)
        let balanced = try PNGQuantizer.encode(
            pixels, colors: 256, dithering: .none, maximumBytes: 1_000_000)
        #expect(balanced.count <= 1_000_000)
        #expect(try Fixtures.decode(balanced).rgba == Fixtures.decode(maximumEffort).rgba)
        #expect(throws: PNGOutputError.sizeLimitExceeded) {
            try PNGQuantizer.encode(pixels, colors: 256, dithering: .none, maximumBytes: 1)
        }
    }

    @Test func keepsTranslucency() throws {
        var pixels = Fixtures.photo(width: 64, height: 64)
        for index in stride(from: 3, to: pixels.rgba.count, by: 4) {
            pixels.rgba[index] = index / 4 % 64 < 32 ? 0 : 255
        }
        let decoded = try Fixtures.decode(try PNGQuantizer.encode(pixels, colors: 64, dithering: .none))
        #expect(decoded.rgba[3] == 0)
        #expect(decoded.rgba[32 * 4 + 3] == 255)
    }
}

@Suite struct PNGChunkTests {
    @Test func parsesSlicesAndRetainsPayloadsIndependently() throws {
        let expected = [
            PNGChunk(type: "tEXt", payload: Data("Comment\u{0}kept".utf8)),
            PNGChunk(type: "IDAT", payload: Data((0..<1024).map { UInt8($0 % 256) })),
            PNGChunk(type: "IEND", payload: Data()),
        ]
        var original = Data(PNGFile.signature)
        for chunk in expected { original.append(PNGFile.serialized(chunk)) }
        let padding = Data(repeating: 0, count: 17)
        var envelope = padding + original
        var parsed = try PNGFile.chunks(in: envelope[padding.count...])
        #expect(parsed == expected)
        var rebuilt = Data(PNGFile.signature)
        for chunk in parsed { rebuilt.append(PNGFile.serialized(chunk)) }
        #expect(rebuilt == original)
        envelope.resetBytes(in: envelope.startIndex..<envelope.endIndex)
        #expect(parsed == expected)
        parsed[1].payload.append(0)
        #expect(parsed[1].payload.count == expected[1].payload.count + 1)
        #expect(rebuilt == original)
    }

    @Test func rejectsEveryTruncatedChunkPrefix() throws {
        var original = Data(PNGFile.signature)
        original.append(PNGFile.serialized(PNGChunk(type: "IDAT", payload: Data(repeating: 1, count: 32))))
        original.append(PNGFile.serialized(PNGChunk(type: "IEND", payload: Data())))
        for length in 0..<original.count {
            #expect(throws: FormatError.self) { try PNGFile.chunks(in: original.prefix(length)) }
        }
    }

    @Test func rejectsLengthsPastTheOriginalBytes() throws {
        var original = Data(PNGFile.signature)
        original.append(contentsOf: [255, 255, 255, 255])
        original.append(contentsOf: "IDAT".utf8)
        original.append(contentsOf: [0, 0, 0, 0])
        #expect(throws: FormatError.corrupt("truncated PNG chunk")) { try PNGFile.chunks(in: original) }
    }
}
