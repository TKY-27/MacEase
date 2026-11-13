import Foundation
import ImageIO
import Testing

@testable import Engine

@Suite struct GalleryDownloadTests {
    @Test func analysisKeepsGallerySelectionExplicitAndRecordsItsPage() throws {
        let page = try #require(URL(string: "https://example.com/gallery/42"))
        let encoded = Data(
            #"[[2,{"title":"A gallery"}],[3,"https://example.com/a.png",{"extension":"png"}],[3,"https://example.com/b.jpg",{"extension":"jpg"}]]"#
                .utf8)
        let source = try GalleryDownloader.source(from: encoded, page: page)
        #expect(source.title == "A gallery")
        #expect(source.galleryCount == 2)
        #expect(source.isPlaylistEntry)
        #expect(source.webpageURL == page)
        #expect(source.thumbnailURL?.absoluteString == "https://example.com/a.png")
    }

    @Test(arguments: [
        #"[[-1,{"error":"HttpError"}]]"#,
        #"[[6,"https://example.com/child",{}]]"#,
        #"[[3,"file:///etc/passwd",{"extension":"jpg"}]]"#,
        #"[[3,"https://user:secret@example.com/a.jpg",{"extension":"jpg"}]]"#,
        #"[[3,"https://example.com/a.exe",{"extension":"exe"}]]"#,
        "[]",
    ])
    func analysisRefusesIncompleteOrUnsafeResults(_ encoded: String) throws {
        let page = try #require(URL(string: "https://example.com/gallery"))
        #expect(throws: EngineError.self) {
            _ = try GalleryDownloader.source(from: Data(encoded.utf8), page: page)
        }
    }

    @Test func verificationRejectsPartialFilesAndLinks() async throws {
        let root = try AudioSignals.temporaryFolder().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appending(path: "image.png")
        let context = try #require(
            CGContext(
                data: nil, width: 12, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let writer = try #require(CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        #expect(CGImageDestinationFinalize(writer))
        let verified = try await GalleryDownloader.verifyImages(in: root, expectedCount: 1)
        #expect(verified.map { $0.resolvingSymlinksInPath() } == [imageURL])
        await #expect(throws: EngineError.self) {
            _ = try await GalleryDownloader.verifyImages(in: root, expectedCount: 2)
        }
        let link = root.appending(path: "link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: imageURL)
        await #expect(throws: EngineError.self) {
            _ = try await GalleryDownloader.verifyImages(in: root, expectedCount: 2)
        }
        try FileManager.default.removeItem(at: link)
        try Data("incomplete image".utf8).write(to: imageURL)
        await #expect(throws: EngineError.self) {
            _ = try await GalleryDownloader.verifyImages(in: root, expectedCount: 1)
        }
    }
}
