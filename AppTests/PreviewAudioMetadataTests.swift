import AVFoundation
import AppKit
import XCTest

@testable import MacEase

@MainActor
final class PreviewAudioMetadataTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = try PreviewImageFixtures.directory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTitleArtistAndArtworkLoadFromTheUntrustedAsset() async throws {
        let cover = try PreviewImageFixtures.solid(width: 1_200, height: 1_200, gray: 0.4)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cover).representation(using: .png, properties: [:]))
        let url = try await PreviewImageFixtures.audio(
            in: directory,
            metadata: [
                PreviewImageFixtures.metadata(.iTunesMetadataSongName, "Harbour Lights" as NSString),
                PreviewImageFixtures.metadata(.iTunesMetadataArtist, "Mina Okada" as NSString),
                PreviewImageFixtures.metadata(.iTunesMetadataCoverArt, png as NSData),
            ])

        let metadata = await PreviewAudioMetadata.load(PreviewMediaAsset.make(url))
        XCTAssertEqual(metadata.title, "Harbour Lights")
        XCTAssertEqual(metadata.artist, "Mina Okada")
        let artwork = try XCTUnwrap(metadata.artwork)
        XCTAssertEqual(max(artwork.width, artwork.height), PreviewAudioMetadata.artworkPixelLimit)
    }

    func testFilesWithoutTagsFallBackToTheFileIcon() async throws {
        let url = try await PreviewImageFixtures.audio(in: directory)
        let metadata = await PreviewAudioMetadata.load(PreviewMediaAsset.make(url))
        XCTAssertNil(metadata.title)
        XCTAssertNil(metadata.artist)
        XCTAssertNil(metadata.artwork)
    }

    func testUndecodableArtworkIsDroppedButTextRemains() async throws {
        let url = try await PreviewImageFixtures.audio(
            in: directory,
            metadata: [
                PreviewImageFixtures.metadata(.iTunesMetadataSongName, "Static" as NSString),
                PreviewImageFixtures.metadata(.iTunesMetadataCoverArt, Data(repeating: 0x5A, count: 512) as NSData),
            ])
        let metadata = await PreviewAudioMetadata.load(PreviewMediaAsset.make(url))
        XCTAssertEqual(metadata.title, "Static")
        XCTAssertNil(metadata.artwork)
    }
}
