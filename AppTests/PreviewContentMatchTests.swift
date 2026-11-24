import Engine
import XCTest

@testable import MacEase

final class PreviewContentMatchTests: XCTestCase {
    func testEmptyFilesAlwaysReportEmptyRegardlessOfKind() {
        let empty = DetectedContent(family: .empty, displayName: "Empty file")
        let kinds: [PreviewKind] = [
            .text, .html, .markdown, .json, .propertyList, .svg, .font, .image, .media, .audio, .pdf, .quickLook,
        ]
        for kind in kinds {
            XCTAssertEqual(PreviewContentMatch.evaluate(kind: kind, detected: empty), .empty)
        }
    }

    func testMatchingPairsReportMatches() {
        let matching: [(PreviewKind, DetectedContent)] = [
            (.text, DetectedContent(family: .text, displayName: "Text")),
            (.text, DetectedContent(family: .svg, displayName: "SVG")),
            (.html, DetectedContent(family: .text, displayName: "Text")),
            (.markdown, DetectedContent(family: .text, displayName: "Text")),
            (.json, DetectedContent(family: .text, displayName: "Text")),
            (.propertyList, DetectedContent(family: .text, displayName: "Text")),
            (.propertyList, DetectedContent(family: .binaryPropertyList, displayName: "Binary Property List")),
            (.svg, DetectedContent(family: .svg, displayName: "SVG")),
            (.image, DetectedContent(family: .image, displayName: "PNG")),
            (.media, DetectedContent(family: .video, displayName: "Matroska video")),
            (.audio, DetectedContent(family: .audio, displayName: "FLAC")),
            (.pdf, DetectedContent(family: .pdf, displayName: "PDF")),
            (.font, DetectedContent(family: .font, displayName: "TrueType font")),
            (.quickLook, DetectedContent(family: .executable, displayName: "Mach-O executable")),
        ]
        for (kind, detected) in matching {
            XCTAssertEqual(PreviewContentMatch.evaluate(kind: kind, detected: detected), .matches)
        }
    }

    func testBinaryContentWithTextExtensionIsRefusedWithDetectedName() {
        let png = DetectedContent(family: .image, displayName: "PNG")
        let machO = DetectedContent(family: .executable, displayName: "Mach-O executable")
        let pdf = DetectedContent(family: .pdf, displayName: "PDF")
        for kind in [PreviewKind.text, .html, .markdown, .json, .propertyList, .svg] {
            XCTAssertEqual(
                PreviewContentMatch.evaluate(kind: kind, detected: png),
                .binaryWithTextExtension(detectedName: "PNG"))
            XCTAssertEqual(
                PreviewContentMatch.evaluate(kind: kind, detected: machO),
                .binaryWithTextExtension(detectedName: "Mach-O executable"))
            XCTAssertEqual(
                PreviewContentMatch.evaluate(kind: kind, detected: pdf),
                .binaryWithTextExtension(detectedName: "PDF"))
        }
    }

    func testNonTextKindMismatchesCarryDetectedName() {
        let text = DetectedContent(family: .text, displayName: "Text")
        let pdf = DetectedContent(family: .pdf, displayName: "PDF")
        XCTAssertEqual(PreviewContentMatch.evaluate(kind: .image, detected: pdf), .mismatch(detectedName: "PDF"))
        XCTAssertEqual(PreviewContentMatch.evaluate(kind: .media, detected: text), .mismatch(detectedName: "Text"))
        XCTAssertEqual(PreviewContentMatch.evaluate(kind: .audio, detected: pdf), .mismatch(detectedName: "PDF"))
        XCTAssertEqual(PreviewContentMatch.evaluate(kind: .pdf, detected: text), .mismatch(detectedName: "Text"))
        XCTAssertEqual(PreviewContentMatch.evaluate(kind: .font, detected: text), .mismatch(detectedName: "Text"))
        XCTAssertEqual(PreviewContentMatch.evaluate(kind: .svg, detected: text), .mismatch(detectedName: "Text"))
    }

    func testDecodableTextFilesAreNeverRefused() throws {
        let directory = try PreviewFixtures.directory(self)
        let utf16LE: (String) -> [UInt8] = { $0.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } }
        let utf16BE: (String) -> [UInt8] = { $0.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] } }
        let utf32LE: (String) -> [UInt8] = { text in
            text.unicodeScalars.flatMap { scalar in
                let value = scalar.value
                return [
                    UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                    UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
                ]
            }
        }
        let samples: [(String, [UInt8], PreviewEncoding, String)] = [
            (
                "Signature.swift", Array("let signature = \"%PDF-1.7\"\n".utf8), .automatic,
                "let signature = \"%PDF-1.7\"\n"
            ),
            ("utf16.txt", [0x41, 0x00, 0x42, 0x00], .utf16LE, "AB"),
            ("cyrillic-le.txt", utf16LE("Привет, мир!"), .utf16LE, "Привет, мир!"),
            ("arabic-le.txt", utf16LE("مرحبا بالعالم"), .utf16LE, "مرحبا بالعالم"),
            ("emoji-le.txt", utf16LE("Hi 👋🌍"), .utf16LE, "Hi 👋🌍"),
            ("cyrillic-be.txt", utf16BE("Привет"), .utf16BE, "Привет"),
            ("utf32-bom.txt", [0xFF, 0xFE, 0x00, 0x00] + utf32LE("Привет 👋"), .automatic, "Привет 👋"),
            ("utf32-le.txt", utf32LE("مرحبا 👋"), .utf32LE, "مرحبا 👋"),
            ("shift-jis.txt", [0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA], .shiftJIS, "日本語"),
            ("euc-jp.txt", [UInt8](try XCTUnwrap("日本語".data(using: .japaneseEUC))), .eucJP, "日本語"),
            ("iso2022.txt", [UInt8](try XCTUnwrap("日本語".data(using: .iso2022JP))), .iso2022JP, "日本語"),
            ("latin1.txt", [UInt8](try XCTUnwrap("Café naïve".data(using: .isoLatin1))), .latin1, "Café naïve"),
        ]
        for (name, bytes, encoding, expected) in samples {
            let url = directory.appendingPathComponent(name)
            try Data(bytes).write(to: url)
            let kind = try PreviewKind.inspect(url)
            XCTAssertEqual(
                PreviewContentMatch.evaluate(kind: kind, detected: try ContentSniffer.identify(url)), .matches, name)
            let decoded = try PreviewTextSource.read(url).decoded(as: encoding)
            XCTAssertEqual(decoded, expected, name)
        }
        let image = directory.appendingPathComponent("notes.txt")
        try PreviewFixtures.png().write(to: image)
        XCTAssertEqual(
            PreviewContentMatch.evaluate(
                kind: try PreviewKind.inspect(image), detected: try ContentSniffer.identify(image)),
            .binaryWithTextExtension(detectedName: "PNG"))
    }
}
