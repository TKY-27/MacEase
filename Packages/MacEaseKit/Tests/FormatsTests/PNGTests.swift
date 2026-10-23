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
