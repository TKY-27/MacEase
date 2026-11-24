import Compression
import CoreText
import Foundation
import UniformTypeIdentifiers
import XCTest
import zlib

@testable import MacEase

final class PreviewFontFaceTests: XCTestCase {
    func testLoadsSystemTTFOTFAndFirstFaceOfTTC() throws {
        let ttf = URL(fileURLWithPath: "/System/Library/Fonts/Geneva.ttf")
        let ttfFace = try PreviewFontFace.load(ttf)
        XCTAssertEqual(ttfFace.displayName, "Geneva")
        XCTAssertEqual(ttfFace.faceCount, 1)
        for size in PreviewFontFace.specimenSizes {
            let font = ttfFace.font(size: size)
            XCTAssertEqual(CTFontGetSize(font), size, accuracy: 0.01)
            XCTAssertEqual(CTFontCopyDisplayName(font) as String, ttfFace.displayName)
        }

        let otf = URL(fileURLWithPath: "/System/Library/Fonts/LastResort.otf")
        let otfFace = try PreviewFontFace.load(otf)
        XCTAssertFalse(otfFace.displayName.isEmpty)
        XCTAssertEqual(otfFace.faceCount, 1)
        XCTAssertEqual(CTFontGetSize(otfFace.font(size: 28)), 28, accuracy: 0.01)

        let ttc = URL(fileURLWithPath: "/System/Library/Fonts/Menlo.ttc")
        let ttcFace = try PreviewFontFace.load(ttc)
        XCTAssertGreaterThan(ttcFace.faceCount, 1)
        XCTAssertEqual(ttcFace.displayName, "Menlo Regular")
        XCTAssertEqual(CTFontGetSize(ttcFace.font(size: 64)), 64, accuracy: 0.01)
    }

    func testCoreTextLoadsWOFF1AndWOFF2WrappedFromSystemFonts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }

        let ttfBytes = try Data(contentsOf: URL(fileURLWithPath: "/System/Library/Fonts/Geneva.ttf"))
        let woffURL = directory.appendingPathComponent("geneva.woff")
        try Self.makeWOFF1(fromSFNT: ttfBytes).write(to: woffURL)
        let woffFace = try PreviewFontFace.load(woffURL)
        XCTAssertEqual(woffFace.displayName, "Geneva")
        XCTAssertEqual(woffFace.faceCount, 1)
        XCTAssertEqual(CTFontGetSize(woffFace.font(size: 20)), 20, accuracy: 0.01)

        let otfBytes = try Data(contentsOf: URL(fileURLWithPath: "/System/Library/Fonts/LastResort.otf"))
        let woff2URL = directory.appendingPathComponent("lastresort.woff2")
        try Self.makeWOFF2(fromCFFSFNT: otfBytes).write(to: woff2URL)
        let woff2Face = try PreviewFontFace.load(woff2URL)
        XCTAssertFalse(woff2Face.displayName.isEmpty)
        XCTAssertEqual(woff2Face.faceCount, 1)
        XCTAssertEqual(CTFontGetSize(woff2Face.font(size: 40)), 40, accuracy: 0.01)
    }

    func testUnreadableOrMissingFontReturnsTypedFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }

        let bogus = directory.appendingPathComponent("broken.ttf")
        try Data("not a font".utf8).write(to: bogus)
        XCTAssertThrowsError(try PreviewFontFace.load(bogus)) { error in
            XCTAssertEqual(error as? PreviewFontError, .unreadable)
        }

        let missing = directory.appendingPathComponent("missing.otf")
        XCTAssertThrowsError(try PreviewFontFace.load(missing)) { error in
            XCTAssertEqual(error as? PreviewFontError, .unreadable)
        }
    }

    func testFontBoundsRejectOversizedFilesExcessFacesAndCancellation() async throws {
        let directory = try PreviewFixtures.directory(self)
        let ttf = URL(fileURLWithPath: "/System/Library/Fonts/Geneva.ttf")
        let ttfSize = Int64(try XCTUnwrap(try ttf.resourceValues(forKeys: [.fileSizeKey]).fileSize))
        XCTAssertThrowsError(try PreviewFontFace.load(ttf, maximumFileBytes: ttfSize - 1)) { error in
            XCTAssertEqual(error as? PreviewFontError, .tooLarge)
        }

        // Huge TTC header fails before Core Text.
        let hugeCollection = directory.appendingPathComponent("huge.ttc")
        var header = Data("ttcf".utf8)
        Self.appendUInt32BE(&header, 0x0001_0000)
        Self.appendUInt32BE(&header, 100)
        try header.write(to: hugeCollection)
        XCTAssertThrowsError(try PreviewFontFace.load(hugeCollection)) { error in
            XCTAssertEqual(error as? PreviewFontError, .tooManyFaces)
        }

        let menlo = URL(fileURLWithPath: "/System/Library/Fonts/Menlo.ttc")
        XCTAssertThrowsError(try PreviewFontFace.load(menlo, maximumFaceCount: 1)) { error in
            XCTAssertEqual(error as? PreviewFontError, .tooManyFaces)
        }

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PreviewFontFace.load(ttf)
        }
        do {
            _ = try await cancelled.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCompressedFontBoundsRejectDeclaredAndDecompressedExpansionBombs() throws {
        let directory = try PreviewFixtures.directory(self)
        let limit: Int64 = 128 * 1024

        // WOFF1 claiming an oversized SFNT fails upfront.
        var woff1Claim = Data("wOFF".utf8)
        Self.appendUInt32BE(&woff1Claim, 0x0001_0000)
        Self.appendUInt32BE(&woff1Claim, 44)
        Self.appendUInt16BE(&woff1Claim, 0)
        Self.appendUInt16BE(&woff1Claim, 0)
        Self.appendUInt32BE(&woff1Claim, UInt32(limit + 1))
        Self.appendUInt16BE(&woff1Claim, 1)
        Self.appendUInt16BE(&woff1Claim, 0)
        for _ in 0..<5 { Self.appendUInt32BE(&woff1Claim, 0) }
        let woff1ClaimURL = directory.appendingPathComponent("claim.woff")
        try woff1Claim.write(to: woff1ClaimURL)
        XCTAssertThrowsError(try PreviewFontFace.load(woff1ClaimURL, maximumFileBytes: limit)) { error in
            XCTAssertEqual(error as? PreviewFontError, .tooLarge)
        }

        // WOFF1 zlib bomb with lying header fails.
        let bombPayload = Data(repeating: 0, count: Int(limit) + 4096)
        let zlibBomb = try Self.zlibCompress(bombPayload)
        XCTAssertLessThan(Int64(zlibBomb.count), limit)
        var woff1Bomb = Data("wOFF".utf8)
        Self.appendUInt32BE(&woff1Bomb, 0x0001_0000)
        Self.appendUInt32BE(&woff1Bomb, UInt32(44 + 20 + zlibBomb.count))
        Self.appendUInt16BE(&woff1Bomb, 1)
        Self.appendUInt16BE(&woff1Bomb, 0)
        Self.appendUInt32BE(&woff1Bomb, 4096)
        Self.appendUInt16BE(&woff1Bomb, 1)
        Self.appendUInt16BE(&woff1Bomb, 0)
        for _ in 0..<5 { Self.appendUInt32BE(&woff1Bomb, 0) }
        woff1Bomb.append(contentsOf: "head".utf8)
        Self.appendUInt32BE(&woff1Bomb, 64)
        Self.appendUInt32BE(&woff1Bomb, UInt32(zlibBomb.count))
        Self.appendUInt32BE(&woff1Bomb, 4096)
        Self.appendUInt32BE(&woff1Bomb, 0)
        woff1Bomb.append(zlibBomb)
        let woff1BombURL = directory.appendingPathComponent("bomb.woff")
        try woff1Bomb.write(to: woff1BombURL)
        XCTAssertThrowsError(try PreviewFontFace.load(woff1BombURL, maximumFileBytes: limit)) { error in
            XCTAssertEqual(error as? PreviewFontError, .tooLarge)
        }

        // WOFF2 claiming an oversized SFNT fails upfront.
        var woff2Claim = Data("wOF2".utf8)
        Self.appendUInt32BE(&woff2Claim, 0x4F54_544F)
        Self.appendUInt32BE(&woff2Claim, 48)
        Self.appendUInt16BE(&woff2Claim, 0)
        Self.appendUInt16BE(&woff2Claim, 0)
        Self.appendUInt32BE(&woff2Claim, UInt32(limit + 1))
        Self.appendUInt32BE(&woff2Claim, 0)
        Self.appendUInt16BE(&woff2Claim, 1)
        Self.appendUInt16BE(&woff2Claim, 0)
        for _ in 0..<5 { Self.appendUInt32BE(&woff2Claim, 0) }
        let woff2ClaimURL = directory.appendingPathComponent("claim.woff2")
        try woff2Claim.write(to: woff2ClaimURL)
        XCTAssertThrowsError(try PreviewFontFace.load(woff2ClaimURL, maximumFileBytes: limit)) { error in
            XCTAssertEqual(error as? PreviewFontError, .tooLarge)
        }

        // WOFF2 Brotli bomb with lying header fails.
        let brotliBomb = try Self.brotliCompress(bombPayload)
        XCTAssertLessThan(Int64(brotliBomb.count), limit)
        var tableDir = Data([63])
        tableDir.append(contentsOf: "head".utf8)
        Self.appendBase128(&tableDir, 64)
        var woff2Bomb = Data("wOF2".utf8)
        Self.appendUInt32BE(&woff2Bomb, 0x4F54_544F)
        Self.appendUInt32BE(&woff2Bomb, UInt32(48 + tableDir.count + brotliBomb.count))
        Self.appendUInt16BE(&woff2Bomb, 1)
        Self.appendUInt16BE(&woff2Bomb, 0)
        Self.appendUInt32BE(&woff2Bomb, 4096)
        Self.appendUInt32BE(&woff2Bomb, UInt32(brotliBomb.count))
        Self.appendUInt16BE(&woff2Bomb, 1)
        Self.appendUInt16BE(&woff2Bomb, 0)
        for _ in 0..<5 { Self.appendUInt32BE(&woff2Bomb, 0) }
        woff2Bomb.append(tableDir)
        woff2Bomb.append(brotliBomb)
        let woff2BombURL = directory.appendingPathComponent("bomb.woff2")
        try woff2Bomb.write(to: woff2BombURL)
        XCTAssertThrowsError(try PreviewFontFace.load(woff2BombURL, maximumFileBytes: limit)) { error in
            XCTAssertEqual(error as? PreviewFontError, .tooLarge)
        }
    }

    private static func zlibCompress(_ source: Data) throws -> Data {
        var capacity = uLongf(compressBound(uLong(source.count)))
        var output = Data(count: Int(capacity))
        let status: Int32 = output.withUnsafeMutableBytes { dst in
            source.withUnsafeBytes { src in
                guard let dstBase = dst.baseAddress?.assumingMemoryBound(to: Bytef.self),
                    let srcBase = src.baseAddress?.assumingMemoryBound(to: Bytef.self)
                else { return Z_MEM_ERROR }
                return compress2(dstBase, &capacity, srcBase, uLong(source.count), Z_BEST_COMPRESSION)
            }
        }
        guard status == Z_OK else { throw CocoaError(.coderInvalidValue) }
        output.count = Int(capacity)
        return output
    }

    func testWidenedExtensionMapAndTokenizerLanguageMapping() throws {
        let textCases: [(String, PreviewLanguage)] = [
            ("env", .ini), ("ini", .ini), ("cfg", .ini), ("conf", .ini), ("properties", .ini),
            ("srt", .plain), ("vtt", .plain), ("ass", .plain), ("lrc", .plain), ("diff", .diff), ("patch", .diff),
            ("tex", .latex), ("sty", .latex), ("cls", .latex), ("rst", .restructuredText),
            ("adoc", .asciiDoc), ("asciidoc", .asciiDoc),
            ("nfo", .plain), ("tsv", .plain), ("reg", .ini), ("inf", .ini),
            ("gitignore", .plain), ("gitattributes", .plain), ("gitmodules", .ini), ("editorconfig", .ini),
            ("jsonc", .json), ("json5", .json),
            ("xaml", .markup), ("csproj", .markup), ("vcxproj", .markup), ("fsproj", .markup), ("vbproj", .markup),
            ("props", .markup), ("targets", .markup), ("manifest", .markup), ("vue", .markup), ("svelte", .markup),
            ("astro", .markup),
            ("sass", .css), ("less", .css),
            ("mts", .javascript), ("cts", .javascript), ("ts", .javascript),
            ("pyi", .python),
            ("cxx", .cpp), ("hh", .cpp), ("hxx", .cpp), ("inl", .cpp), ("csx", .csharp), ("kt", .kotlin),
            ("kts", .kotlin),
            ("gradle", .groovy), ("groovy", .groovy), ("scala", .scala), ("dart", .dart),
            ("rb", .ruby), ("php", .php), ("go", .go), ("rs", .rust), ("fs", .fsharp), ("fsx", .fsharp),
            ("vb", .vb), ("vbs", .vb), ("lua", .lua), ("pl", .perl), ("pm", .perl), ("r", .r),
            ("jl", .julia), ("ex", .elixir), ("exs", .elixir), ("clj", .clojure), ("sql", .sql),
            ("ps1", .powershell), ("psm1", .powershell), ("psd1", .powershell), ("bat", .batch), ("cmd", .batch),
            ("dockerfile", .dockerfile), ("cmake", .cmake), ("mk", .makefile), ("mak", .makefile), ("make", .makefile),
            ("proto", .protobuf), ("graphql", .graphql), ("gql", .graphql), ("hcl", .hcl), ("tf", .hcl),
            ("tfvars", .hcl), ("sol", .solidity), ("sln", .plain),
        ]
        for (suffix, language) in textCases {
            XCTAssertEqual(PreviewKind.resolve(type: nil, extension: suffix), .text, suffix)
            XCTAssertEqual(PreviewLanguage.resolve(suffix), language, suffix)
        }

        XCTAssertEqual(PreviewKind.resolve(type: .mpeg2TransportStream, extension: "ts"), .text)
        XCTAssertEqual(PreviewKind.resolve(type: nil, extension: "xhtml"), .html)
        XCTAssertEqual(PreviewLanguage.resolve("xhtml"), .markup)
        XCTAssertEqual(PreviewKind.resolve(type: nil, extension: "mdx"), .markdown)
        XCTAssertEqual(PreviewLanguage.resolve("mdx"), .markdown)

        for video in ["mp4", "m4v", "webm", "mkv", "mov", "avi", "wmv", "flv", "ogv", "mpg", "mpeg", "m2ts", "3gp"] {
            XCTAssertEqual(PreviewKind.resolve(type: nil, extension: video), .media, video)
        }
        for audio in ["mp3", "wav", "flac", "ogg", "oga", "opus", "m4a", "aac", "wma", "aif", "aiff"] {
            XCTAssertEqual(PreviewKind.resolve(type: nil, extension: audio), .audio, audio)
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let dotfileExpectations: [(String, PreviewLanguage)] = [
            (".env", .ini), (".gitignore", .plain), (".gitattributes", .plain),
            (".gitmodules", .ini), (".editorconfig", .ini), (".dockerfile", .dockerfile),
        ]
        for (name, expected) in dotfileExpectations {
            let dotfile = directory.appendingPathComponent(name)
            try Data("KEY=VALUE\n".utf8).write(to: dotfile)
            XCTAssertEqual(try PreviewKind.inspect(dotfile), .text, name)
            XCTAssertEqual(
                PreviewLanguage.resolve(dotfile.pathExtension, fileName: dotfile.lastPathComponent),
                expected, name)
        }
    }

    private static func makeWOFF1(fromSFNT sfnt: Data) -> Data {
        let flavor = readUInt32BE(sfnt, at: 0)
        let numTables = Int(readUInt16BE(sfnt, at: 4))
        var totalSFNTSize = UInt32(12 + numTables * 16)
        var entries = Data()
        var payloads = Data()
        var currentOffset = UInt32(44 + numTables * 20)
        for index in 0..<numTables {
            let recordOffset = 12 + index * 16
            let tag = sfnt[recordOffset..<(recordOffset + 4)]
            let checksum = readUInt32BE(sfnt, at: recordOffset + 4)
            let offset = Int(readUInt32BE(sfnt, at: recordOffset + 8))
            let length = Int(readUInt32BE(sfnt, at: recordOffset + 12))
            let raw = Data(sfnt[offset..<(offset + length)])
            totalSFNTSize += UInt32((length + 3) & ~3)
            entries.append(tag)
            appendUInt32BE(&entries, currentOffset)
            appendUInt32BE(&entries, UInt32(raw.count))
            appendUInt32BE(&entries, UInt32(raw.count))
            appendUInt32BE(&entries, checksum)
            payloads.append(raw)
            let padding = (4 - (raw.count % 4)) % 4
            if padding > 0 { payloads.append(Data(repeating: 0, count: padding)) }
            currentOffset += UInt32(raw.count + padding)
        }
        var header = Data()
        appendUInt32BE(&header, 0x774F_4646)
        appendUInt32BE(&header, flavor)
        appendUInt32BE(&header, currentOffset)
        appendUInt16BE(&header, UInt16(numTables))
        appendUInt16BE(&header, 0)
        appendUInt32BE(&header, totalSFNTSize)
        appendUInt16BE(&header, 1)
        appendUInt16BE(&header, 0)
        for _ in 0..<5 { appendUInt32BE(&header, 0) }
        return header + entries + payloads
    }

    private static func makeWOFF2(fromCFFSFNT sfnt: Data) throws -> Data {
        let flavor = readUInt32BE(sfnt, at: 0)
        let numTables = Int(readUInt16BE(sfnt, at: 4))
        var totalSFNTSize = UInt32(12 + numTables * 16)
        var directory = Data()
        var stream = Data()
        for index in 0..<numTables {
            let recordOffset = 12 + index * 16
            let tag = sfnt[recordOffset..<(recordOffset + 4)]
            let offset = Int(readUInt32BE(sfnt, at: recordOffset + 8))
            let length = Int(readUInt32BE(sfnt, at: recordOffset + 12))
            totalSFNTSize += UInt32((length + 3) & ~3)
            // Flag 63 stores an untransformed explicit tag.
            directory.append(63)
            directory.append(tag)
            appendBase128(&directory, UInt32(length))
            stream.append(sfnt[offset..<(offset + length)])
        }
        let compressed = try brotliCompress(stream)
        let unpaddedLength = 48 + directory.count + compressed.count
        let trailingPadding = (4 - (unpaddedLength % 4)) % 4
        let totalLength = UInt32(unpaddedLength + trailingPadding)
        var header = Data()
        appendUInt32BE(&header, 0x774F_4632)
        appendUInt32BE(&header, flavor)
        appendUInt32BE(&header, totalLength)
        appendUInt16BE(&header, UInt16(numTables))
        appendUInt16BE(&header, 0)
        appendUInt32BE(&header, totalSFNTSize)
        appendUInt32BE(&header, UInt32(compressed.count))
        appendUInt16BE(&header, 1)
        appendUInt16BE(&header, 0)
        for _ in 0..<5 { appendUInt32BE(&header, 0) }
        return header + directory + compressed + Data(repeating: 0, count: trailingPadding)
    }

    private static func brotliCompress(_ source: Data) throws -> Data {
        let capacity = max(source.count + 1024, 4096)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination in
            source.withUnsafeBytes { input in
                guard let dst = destination.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    let src = input.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return 0 }
                return compression_encode_buffer(dst, capacity, src, source.count, nil, COMPRESSION_BROTLI)
            }
        }
        guard written > 0 else { throw CocoaError(.coderInvalidValue) }
        output.count = written
        return output
    }

    private static func appendBase128(_ buffer: inout Data, _ value: UInt32) {
        var chunks: [UInt8] = [UInt8(value & 0x7F)]
        var remaining = value >> 7
        while remaining > 0 {
            chunks.append(UInt8((remaining & 0x7F) | 0x80))
            remaining >>= 7
        }
        buffer.append(contentsOf: chunks.reversed())
    }

    private static func readUInt16BE(_ bytes: Data, at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readUInt32BE(_ bytes: Data, at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private static func appendUInt16BE(_ buffer: inout Data, _ value: UInt16) {
        buffer.append(contentsOf: [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    private static func appendUInt32BE(_ buffer: inout Data, _ value: UInt32) {
        buffer.append(contentsOf: [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }
}
