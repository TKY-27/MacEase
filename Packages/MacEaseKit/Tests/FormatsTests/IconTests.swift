import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Formats

@Suite struct IconTests {
    private func pngs(for sizes: [Int]) throws -> [Int: Data] {
        Dictionary(
            uniqueKeysWithValues: try sizes.map { size in
                (size, try Fixtures.encode(Fixtures.logo(size: size), as: .png))
            }
        )
    }

    @Test func imageIOReadsEveryICOEntry() throws {
        let images = try pngs(for: ICOFile.standardSizes)
        let ico = try ICOFile.write(ICOFile.standardSizes.map { ($0, try #require(images[$0])) })
        let source = try #require(CGImageSourceCreateWithData(ico as CFData, nil))
        #expect(CGImageSourceGetCount(source) == ICOFile.standardSizes.count)
        let widths = (0..<CGImageSourceGetCount(source)).compactMap {
            CGImageSourceCreateImageAtIndex(source, $0, nil)?.width
        }
        #expect(widths.sorted() == ICOFile.standardSizes)
        #expect(try ICOFile.read(ico).map(\.width) == ICOFile.standardSizes)
    }

    @Test func imageIOAndNSImageReadEveryICNSSize() throws {
        let sizes = Set(ICNSFile.pngElements.map(\.size)).sorted()
        let icns = try ICNSFile.write(pngBySize: try pngs(for: sizes))
        let source = try #require(CGImageSourceCreateWithData(icns as CFData, nil))
        let widths = Set(
            (0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil)?.width })
        #expect(widths == Set(sizes))
        let image = try #require(NSImage(data: icns))
        let pixelWidths = Set(image.representations.map(\.pixelsWide))
        #expect(pixelWidths.isSuperset(of: Set(sizes)))
    }

    @Test func readsLegacyDIBEntries() throws {
        let size = 2
        var dib = [UInt8]()
        func le32(_ value: UInt32) -> [UInt8] {
            [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)]
        }
        dib += le32(40) + le32(UInt32(size)) + le32(UInt32(size * 2)) + [1, 0, 24, 0] + le32(0)
        dib += [UInt8](repeating: 0, count: 20)
        // Bottom row first: blue, green, red, white.
        dib += [255, 0, 0, 0, 255, 0, 0, 0]
        dib += [0, 0, 255, 255, 255, 255, 0, 0]
        // AND mask: hide the top-right pixel.
        dib += [0, 0, 0, 0, 0b0100_0000, 0, 0, 0]
        var ico = Data([0, 0, 1, 0, 1, 0, 2, 2, 0, 0, 1, 0, 24, 0])
        ico.append(contentsOf: le32(UInt32(dib.count)) + le32(22))
        ico.append(contentsOf: dib)
        let image = try #require(try ICOFile.read(ico).first)
        #expect(Array(image.rgba[0..<4]) == [255, 0, 0, 255])
        #expect(image.rgba[7] == 0)
        #expect(Array(image.rgba[8..<12]) == [0, 0, 255, 255])
    }

    @Test func readsICNSWrittenByImageIO() throws {
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.icns.identifier as CFString, 2, nil))
        for size in [128, 256] {
            CGImageDestinationAddImage(destination, try Fixtures.logo(size: size).makeCGImage(), nil)
        }
        #expect(CGImageDestinationFinalize(destination))
        let widths = try ICNSFile.read(data as Data).map(\.width)
        #expect(Set(widths).isSuperset(of: [128, 256]))
    }
}
