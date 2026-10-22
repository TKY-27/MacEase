import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Formats

@Suite struct IconTests {
    @Test func rejectsExcessiveICNSChunkMetadata() throws {
        let entryCount = 100_000
        let headerBytes = 8
        let firstCharacter = UInt8(ascii: "!")
        let alphabetSize = Int(UInt8(ascii: "~") - firstCharacter) + 1
        var icon = Data("icns".utf8)
        icon.appendBigEndian(UInt32(headerBytes + entryCount * headerBytes))
        for index in 0..<entryCount {
            var ordinal = index
            var signature = [UInt8](repeating: firstCharacter, count: 4)
            for position in signature.indices.reversed() {
                signature[position] += UInt8(ordinal % alphabetSize)
                ordinal /= alphabetSize
            }
            icon.append(contentsOf: signature)
            icon.appendBigEndian(UInt32(headerBytes))
        }
        #expect(throws: FormatError.frameMemoryExceeded) { try ICNSFile.readLargest(icon) }
    }

    @Test func encodedSizeLimitPrecedesIconParsing() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "MacEase-icon-\(UUID().uuidString)")
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: url) } }
        try Data().write(to: url)
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: UInt64(ImageMemoryLimits.encodedBytes) + 1)
        try writer.close()
        let encoded = try Data(contentsOf: url, options: .alwaysMapped)
        let expected = FormatError.inputTooLarge(limitBytes: Int64(ImageMemoryLimits.encodedBytes))
        #expect(throws: expected) { try ICOFile.read(encoded) }
        #expect(throws: expected) { try ICOFile.readLargest(encoded) }
        #expect(throws: expected) { try ICOFile.validateStructure(encoded) }
        #expect(throws: expected) { try ICNSFile.read(encoded) }
        #expect(throws: expected) { try ICNSFile.readLargest(encoded) }
    }

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
        #expect(try ICOFile.readLargest(ico).width == 256)
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
        #expect(try ICNSFile.readLargest(icns).width == 1024)
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

    @Test func rejectsSharedICOEntryBeforeDIBDecode() throws {
        let count = 4_096
        let directorySize = 6
        let entrySize = 16
        let dibHeaderSize = 40
        let edge = 512
        let bitsPerPixel = 32
        let pixelBytes = edge * edge * bitsPerPixel / 8
        let maskBytes = ((edge + 31) / 32) * 4 * edge
        let directoryEnd = directorySize + count * entrySize
        let dibLength = dibHeaderSize + pixelBytes + maskBytes
        var icon = Data([0, 0, 1, 0])
        icon.appendLittleEndian(UInt16(count))
        for _ in 0..<count {
            icon.append(contentsOf: [0, 0, 0, 0])
            icon.appendLittleEndian(UInt16(1))
            icon.appendLittleEndian(UInt16(bitsPerPixel))
            icon.appendLittleEndian(UInt32(dibLength))
            icon.appendLittleEndian(UInt32(directoryEnd))
        }
        icon.appendLittleEndian(UInt32(dibHeaderSize))
        icon.appendLittleEndian(UInt32(edge))
        icon.appendLittleEndian(UInt32(edge * 2))
        icon.appendLittleEndian(UInt16(1))
        icon.appendLittleEndian(UInt16(bitsPerPixel))
        icon.appendLittleEndian(UInt32(0))
        icon.appendLittleEndian(UInt32(pixelBytes))
        icon.append(contentsOf: [UInt8](repeating: 0, count: dibHeaderSize - 24))
        icon.append(contentsOf: [UInt8](repeating: 0, count: pixelBytes + maskBytes))
        #expect(throws: FormatError.corrupt("overlapping ICO entries")) { try ICOFile.read(icon) }
        #expect(throws: FormatError.corrupt("overlapping ICO entries")) { try ICOFile.readLargest(icon) }
    }

    @Test func rejectsCumulativeICOFramesBeforeDIBDecode() throws {
        let count = 96
        let directoryEnd = 6 + count * 16
        var icon = Data([0, 0, 1, 0])
        icon.appendLittleEndian(UInt16(count))
        for index in 0..<count {
            icon.append(contentsOf: [0, 0, 0, 0])
            icon.appendLittleEndian(UInt16(1))
            icon.appendLittleEndian(UInt16(32))
            icon.appendLittleEndian(UInt32(40))
            icon.appendLittleEndian(UInt32(directoryEnd + index * 40))
        }
        for _ in 0..<count {
            icon.appendLittleEndian(UInt32(40))
            icon.appendLittleEndian(UInt32(512))
            icon.appendLittleEndian(UInt32(1_024))
            icon.append(contentsOf: [UInt8](repeating: 0, count: 28))
        }
        #expect(throws: FormatError.frameMemoryExceeded) { try ICOFile.read(icon) }
    }
}
