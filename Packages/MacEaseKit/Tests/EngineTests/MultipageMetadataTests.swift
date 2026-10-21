import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Engine

@Suite struct MultipageMetadataTests {
    private static let descriptions = ["page-one", "page-two"]
    private static let comment = "Remove this comment"

    private func tiff(in folder: URL, commentPages: Set<Int>) throws -> URL {
        let input = folder.appending(path: "pages.tiff")
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                input as CFURL, UTType.tiff.identifier as CFString, Self.descriptions.count, nil))
        for (index, description) in Self.descriptions.enumerated() {
            var properties: [CFString: Any] = [
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: description]
            ]
            if commentPages.contains(index) {
                properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifUserComment: Self.comment]
            }
            CGImageDestinationAddImage(
                destination, try ImageFixtures.photo(width: 32, height: 16, seed: index), properties as CFDictionary)
        }
        try #require(CGImageDestinationFinalize(destination))
        for (index, description) in Self.descriptions.enumerated() {
            let properties = try ImageFixtures.properties(input, index: index)
            let tiff = try #require(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
            #expect(tiff[kCGImagePropertyTIFFImageDescription] as? String == description)
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            #expect(
                exif?[kCGImagePropertyExifUserComment] as? String == (commentPages.contains(index) ? Self.comment : nil)
            )
        }
        return input
    }

    @Test(arguments: [0, 1])
    func strippingCommentsKeepsEachPagesDescription(commentPage: Int) async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try tiff(in: folder, commentPages: [commentPage])
        let original = try Data(contentsOf: input)
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard case .replace(_, let output) = try await ImageMetadata.strip(input, fields: [.comments], context: context)
        else {
            Issue.record("Expected comments on any page to produce a staged TIFF")
            return
        }
        #expect(CGImageSourceGetCount(try ImageFixtures.source(output.url)) == Self.descriptions.count)
        for (index, description) in Self.descriptions.enumerated() {
            let properties = try ImageFixtures.properties(output.url, index: index)
            let tiff = try #require(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
            #expect(tiff[kCGImagePropertyTIFFImageDescription] as? String == description)
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            #expect(exif?[kCGImagePropertyExifUserComment] == nil)
            let before = try ImageFixtures.image(input, index: index)
            let after = try ImageFixtures.image(output.url, index: index)
            #expect(try #require(before.dataProvider?.data as Data?) == #require(after.dataProvider?.data as Data?))
        }
        #expect(try Data(contentsOf: input) == original)
    }

    @Test func skipsOnlyWhenEveryPageHasNothingToRemove() async throws {
        let folder = try AudioSignals.temporaryFolder()
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let input = try tiff(in: folder, commentPages: [])
        let context = ItemContext(
            settings: Settings(), staging: StagingArea(supportDirectory: folder), progress: { _ in })
        defer { context.removeStaging() }
        guard
            case .skipped(.nothingToRemove) = try await ImageMetadata.strip(
                input, fields: [.comments], context: context)
        else {
            Issue.record("Expected no removable comments across all pages")
            return
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [input.lastPathComponent])
    }
}
