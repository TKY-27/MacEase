import Foundation
import Testing

@testable import Formats

@Suite struct PNGStorageTests {
    @Test(arguments: [1, 17], [1, 70])
    func opaqueRowsKeepEncodedBytesAndSampleSelection(width: Int, height: Int) throws {
        let rgba = (0..<(width * height)).flatMap { pixel -> [UInt8] in
            [UInt8(pixel % 256), UInt8(pixel * 13 % 256), UInt8(pixel * 37 % 256), 255]
        }
        let rgb = stride(from: 0, to: rgba.count, by: 4).flatMap { Array(rgba[$0..<($0 + 3)]) }
        let packed = PNGRaster(width: width, height: height, colorType: .rgb, bitDepth: 8, samples: rgb)
        let shared = PNGRaster(
            width: width, height: height, colorType: .rgb, bitDepth: 8, samples: rgba, omitsOpaqueAlpha: true)
        let comment = PNGChunk(type: "tEXt", payload: Data("Comment\u{0}row storage".utf8))
        for strategy in PNGFilterStrategy.allCases {
            let expected = try PNGFile.encode(packed, ancillary: [comment], strategy: strategy, level: 6)
            let encoded = try PNGFile.encode(shared, ancillary: [comment], strategy: strategy, level: 6)
            #expect(encoded == expected)
            #expect(try Fixtures.decode(encoded).rgba == rgba)
            #expect(try PNGFile.chunks(in: encoded).contains(comment))
            let expectedSample = try PNGFile.encode(PNGOptimizer.sampled(packed), strategy: strategy, level: 6)
            let sampled = try PNGFile.encode(PNGOptimizer.sampled(shared), strategy: strategy, level: 6)
            #expect(sampled == expectedSample)
        }
    }

    @Test func rejectsIncompatibleOpaqueRowLayout() throws {
        let raster = PNGRaster(
            width: 1, height: 1, colorType: .gray, bitDepth: 8, samples: [1, 2, 3, 255], omitsOpaqueAlpha: true)
        #expect(throws: FormatError.self) {
            try PNGFile.encode(raster, strategy: .none, level: 6)
        }
    }
}
