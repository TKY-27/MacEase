import AVFoundation
import AppKit
import SwiftUI
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

    func testArtworkExceedingByteLimitIsRefused() throws {
        let validImage = try PreviewImageFixtures.solid(width: 16, height: 16, gray: 0.5)
        var oversized = try XCTUnwrap(
            NSBitmapImageRep(cgImage: validImage).representation(using: .png, properties: [:]))
        XCTAssertNotNil(PreviewAudioMetadata.decodeArtwork(oversized))
        oversized.append(Data(count: PreviewAudioMetadata.artworkByteLimit))
        XCTAssertGreaterThan(oversized.count, PreviewAudioMetadata.artworkByteLimit)
        XCTAssertNil(PreviewAudioMetadata.decodeArtwork(oversized))
    }

    func testArtworkExceedingSourcePixelLimitIsRefusedWhileTextRemains() async throws {
        let bombPNG = PreviewImageFixtures.monochromePNG(width: 10_000, height: 10_000)
        XCTAssertLessThan(bombPNG.count, PreviewAudioMetadata.artworkByteLimit)
        XCTAssertNil(PreviewAudioMetadata.decodeArtwork(bombPNG))

        let url = try await PreviewImageFixtures.audio(
            in: directory, name: "bomb-cover.m4a",
            metadata: [
                PreviewImageFixtures.metadata(.iTunesMetadataSongName, "Oversized Cover" as NSString),
                PreviewImageFixtures.metadata(.iTunesMetadataArtist, "Test Artist" as NSString),
                PreviewImageFixtures.metadata(.iTunesMetadataCoverArt, bombPNG as NSData),
            ])
        let metadata = await PreviewAudioMetadata.load(PreviewMediaAsset.make(url))
        XCTAssertEqual(metadata.title, "Oversized Cover")
        XCTAssertEqual(metadata.artist, "Test Artist")
        XCTAssertNil(metadata.artwork)
    }

    func testCancelledMetadataLoadReturnsEmptyWithoutDecoding() async throws {
        let cover = try PreviewImageFixtures.solid(width: 256, height: 256, gray: 0.5)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cover).representation(using: .png, properties: [:]))
        let url = try await PreviewImageFixtures.audio(
            in: directory, name: "cancelled.m4a",
            metadata: [
                PreviewImageFixtures.metadata(.iTunesMetadataSongName, "Ignored" as NSString),
                PreviewImageFixtures.metadata(.iTunesMetadataCoverArt, png as NSData),
            ])
        let asset = PreviewMediaAsset.make(url)
        let loadTask = Task { @MainActor in
            await PreviewAudioMetadata.load(asset)
        }
        loadTask.cancel()
        let metadata = await loadTask.value
        XCTAssertNil(metadata.title)
        XCTAssertNil(metadata.artist)
        XCTAssertNil(metadata.artwork)

        let detailsTask = Task { @MainActor in
            try await PreviewAudioControls.loadDetails(asset: asset)
        }
        detailsTask.cancel()
        do {
            _ = try await detailsTask.value
            XCTFail("Expected cancelled loadDetails to throw CancellationError")
        } catch is CancellationError {
        }
    }

    func testAudioControlsLoadFileIconOnceDuringPlayback() async throws {
        let url = try await PreviewImageFixtures.audio(in: directory, name: "icon-once.m4a", seconds: 0.5)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: PreviewMediaAsset.make(url)))
        player.isMuted = true
        var iconLoads = 0
        let stubIcon = NSImage(size: NSSize(width: 32, height: 32))
        let window = NSWindow(
            contentRect: NSRect(x: -5_000, y: 0, width: 420, height: 400), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.contentView = NSHostingView(
            rootView: PreviewAudioControls(
                player: player, url: url,
                loadFileIcon: { _ in
                    iconLoads += 1
                    return stubIcon
                }))
        window.orderFrontRegardless()
        defer {
            player.pause()
            window.orderOut(nil)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while iconLoads == 0, ContinuousClock.now < deadline {
            window.layoutIfNeeded()
            await Task.yield()
        }
        XCTAssertEqual(iconLoads, 1)

        player.play()
        let playbackDeadline = ContinuousClock.now + .seconds(5)
        while player.currentTime().seconds < 0.25, ContinuousClock.now < playbackDeadline {
            await Task.yield()
        }
        player.pause()
        XCTAssertEqual(iconLoads, 1)
    }

    func testAudioDurationFormattingClampsHostileValues() {
        XCTAssertEqual(PreviewAudioControls.clampedDurationSeconds(.nan), 0)
        XCTAssertEqual(PreviewAudioControls.clampedDurationSeconds(.infinity), 0)
        XCTAssertEqual(PreviewAudioControls.clampedDurationSeconds(-10), 0)
        XCTAssertEqual(
            PreviewAudioControls.clampedDurationSeconds(1e308), PreviewAudioControls.maximumDisplayDurationSeconds)
        XCTAssertFalse(PreviewAudioControls.format(1e308).isEmpty)
        XCTAssertFalse(PreviewAudioControls.format(-5).isEmpty)
    }
}
