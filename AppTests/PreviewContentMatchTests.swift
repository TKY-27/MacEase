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
        for kind in [PreviewKind.text, .html, .markdown, .json, .propertyList] {
            XCTAssertEqual(
                PreviewContentMatch.evaluate(kind: kind, detected: png),
                .binaryWithTextExtension(detectedName: "PNG"))
            XCTAssertEqual(
                PreviewContentMatch.evaluate(kind: kind, detected: machO),
                .binaryWithTextExtension(detectedName: "Mach-O executable"))
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
        XCTAssertEqual(PreviewContentMatch.evaluate(kind: .svg, detected: pdf), .mismatch(detectedName: "PDF"))
    }
}
