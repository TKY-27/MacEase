import AppKit
import ImageIO
import UniformTypeIdentifiers
import VisionKit
import XCTest

@testable import MacEase

@MainActor
final class PreviewImageViewerTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = try PreviewImageFixtures.directory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLoopCountsFollowEachFormat() throws {
        let png = directory.appending(path: "loop.png")
        let frames = try (0..<3).map { try PreviewImageFixtures.solid(width: 8, height: 8, gray: CGFloat($0) / 2) }
        try PreviewImageFixtures.write(
            frames, to: png, type: .png,
            container: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 2]],
            frame: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.02]])

        XCTAssertEqual(try plays(PreviewImageFixtures.gif(frames: 3, loopCount: 2, in: directory, name: "two.gif")), 2)
        XCTAssertEqual(
            try plays(PreviewImageFixtures.gif(frames: 3, loopCount: nil, in: directory, name: "once.gif")), 1)
        XCTAssertNil(try plays(PreviewImageFixtures.gif(frames: 3, loopCount: 0, in: directory, name: "forever.gif")))
        XCTAssertEqual(try plays(png), 2)
        XCTAssertEqual(PreviewImageSource.plays([kCGImagePropertyWebPDictionary: [:] as [CFString: Any]]), 1)
        XCTAssertEqual(PreviewImageSource.plays([:]), 1)
    }

    func testTimingStopsOnTheLastFrameOfTheLastPlay() throws {
        let timing = PreviewImageTiming(delays: [0.1, 0.1, 0.1], plays: 2)
        var position = PreviewImageTiming.Position(index: 0, completedPlays: 0)
        var shown = [position.index]
        while let next = timing.step(after: position) {
            shown.append(next.index)
            position = next
        }
        XCTAssertEqual(shown, [0, 1, 2, 0, 1, 2])

        let endless = PreviewImageTiming(delays: [0.1, 0.1], plays: nil)
        var endlessPosition = PreviewImageTiming.Position(index: 0, completedPlays: 0)
        for _ in 0..<1_000 {
            endlessPosition = try XCTUnwrap(endless.step(after: endlessPosition))
        }
    }

    func testAnimationStopsAfterItsPlaysAndReplaysFromTheStart() async throws {
        let model = PreviewImageModel()
        await model.load(try PreviewImageFixtures.gif(frames: 3, loopCount: 1, in: directory), reduceMotion: false)
        let animator = try XCTUnwrap(model.animator)
        XCTAssertTrue(animator.isPlaying)
        try await waitUntil { !animator.isPlaying }
        XCTAssertEqual(animator.position, PreviewImageTiming.Position(index: 2, completedPlays: 0))

        animator.play()
        try await waitUntil { animator.position.index == 0 }
        XCTAssertTrue(animator.isPlaying)
        animator.pause()
    }

    func testReduceMotionShowsTheFirstFrameUntilPlayIsPressed() async throws {
        let model = PreviewImageModel()
        await model.load(try PreviewImageFixtures.gif(frames: 4, loopCount: 0, in: directory), reduceMotion: true)
        let animator = try XCTUnwrap(model.animator)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(animator.isPlaying)
        XCTAssertEqual(animator.position.index, 0)

        animator.play()
        try await waitUntil { animator.position.index > 0 }
        model.stop()
        XCTAssertFalse(animator.isPlaying)
    }

    func testFrameCacheStaysWithinItsBudget() async throws {
        let url = try PreviewImageFixtures.gif(frames: 40, size: 128, loopCount: 0, in: directory)
        let frameBytes = 128 * 128 * 4

        let small = PreviewImageSource(frameCacheLimit: frameBytes * 10)
        _ = try await small.open(url)
        for index in 0..<40 { _ = try await small.frame(index) }
        let smallCache = await small.cachedBytes
        XCTAssertEqual(smallCache, 0)

        let roomy = PreviewImageSource(frameCacheLimit: frameBytes * 40)
        _ = try await roomy.open(url)
        for _ in 0..<2 {
            for index in 0..<40 { _ = try await roomy.frame(index) }
        }
        let roomyCache = await roomy.cachedBytes
        XCTAssertLessThanOrEqual(roomyCache, frameBytes * 40)
        XCTAssertGreaterThan(roomyCache, frameBytes * 30)
    }

    func testLiveTextSkipsAnimatedTinyAndOversizedImages() throws {
        try XCTSkipUnless(ImageAnalyzer.isSupported, "Live Text is not supported on this Mac")
        XCTAssertTrue(PreviewLiveText.isWorthAnalyzing(pixelSize: CGSize(width: 2_880, height: 1_800), animated: false))
        XCTAssertFalse(PreviewLiveText.isWorthAnalyzing(pixelSize: CGSize(width: 2_880, height: 1_800), animated: true))
        XCTAssertFalse(PreviewLiveText.isWorthAnalyzing(pixelSize: CGSize(width: 16, height: 16), animated: false))
        XCTAssertFalse(
            PreviewLiveText.isWorthAnalyzing(pixelSize: CGSize(width: 12_000, height: 9_000), animated: false))
    }

    func testLiveTextFindsTextAndIsCancelledWhenTheSelectionMoves() async throws {
        try XCTSkipUnless(ImageAnalyzer.isSupported, "Live Text is not supported on this Mac")
        let url = directory.appending(path: "screenshot.png")
        try PreviewImageFixtures.write(
            [try PreviewImageFixtures.text("Invoice 2041 is overdue", width: 1_600, height: 400)], to: url, type: .png)

        let analysed = PreviewImageModel()
        await analysed.load(url, reduceMotion: false)
        try await waitUntil(timeout: .seconds(20)) { analysed.liveText.analysis != nil }
        XCTAssertEqual(analysed.liveText.analysis?.hasResults(for: .text), true)

        let cancelled = PreviewImageModel()
        await cancelled.load(url, reduceMotion: false)
        cancelled.liveText.cancel()
        try await Task.sleep(for: PreviewLiveText.settleDelay * 4)
        XCTAssertNil(cancelled.liveText.analysis)
    }

    func testAnimatedImagesAreNeverAnalysed() async throws {
        let model = PreviewImageModel()
        await model.load(
            try PreviewImageFixtures.gif(frames: 2, size: 200, loopCount: 0, in: directory), reduceMotion: true)
        try await Task.sleep(for: PreviewLiveText.settleDelay * 3)
        XCTAssertNil(model.liveText.analysis)
        model.stop()
    }

    func testZoomMovesBetweenFitActualSizeAndCustom() {
        let scroll = PreviewImageScroll(pixelSize: CGSize(width: 2_000, height: 1_000))
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        scroll.layoutSubtreeIfNeeded()
        let fit = min(scroll.contentSize.width / 2_000, scroll.contentSize.height / 1_000)
        XCTAssertEqual(scroll.zoom.preset, .fit)
        XCTAssertEqual(scroll.zoom.percent, fit * 100, accuracy: 0.01)

        let pointer = NSPoint(x: 1_500, y: 500)
        let pointerBefore = scroll.convert(pointer, from: scroll.content)
        scroll.toggleZoom(at: pointer, animated: false)
        XCTAssertEqual(scroll.zoom.preset, .actualSize)
        XCTAssertEqual(scroll.zoom.percent, 100, accuracy: 0.01)
        let pointerAfter = scroll.convert(pointer, from: scroll.content)
        XCTAssertEqual(pointerAfter.x, pointerBefore.x, accuracy: 1, "the pixel under the pointer stays put")

        scroll.magnification = 1.5
        XCTAssertNil(scroll.zoom.preset)
        XCTAssertEqual(scroll.zoom.percent, 150, accuracy: 0.5)

        scroll.toggleZoom(at: .zero, animated: false)
        XCTAssertEqual(scroll.zoom.preset, .fit)

        scroll.setZoom(.actualSize, animated: false)
        XCTAssertEqual(scroll.zoom.preset, .actualSize)
        scroll.frame.size = NSSize(width: 300, height: 300)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.zoom.preset, .actualSize, "resizing keeps a chosen zoom")
    }

    func testActualSizeOnALargeImageDecodesFullResolution() async throws {
        let url = directory.appending(path: "wide.png")
        try PreviewImageFixtures.write(
            [try PreviewImageFixtures.solid(width: 5_000, height: 50, gray: 0.5)], to: url, type: .png)
        let model = PreviewImageModel()
        await model.load(url, reduceMotion: false)
        let opened = try XCTUnwrap(model.opened)
        XCTAssertEqual(opened.first.width, PreviewImageSource.maximumPreviewEdge)
        XCTAssertTrue(opened.offersFullResolution)

        model.zoomChanged(PreviewZoom(preset: .fit, percent: 30))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(model.detail)

        model.zoomChanged(PreviewZoom(preset: .actualSize, percent: 100))
        try await waitUntil { model.detail != nil }
        XCTAssertEqual(model.detail?.width, 5_000)
        XCTAssertFalse(model.showsReduced)
        model.stop()
    }

    func testSmallImagesAreNeverReportedAsReduced() async throws {
        let url = directory.appending(path: "icon.png")
        try PreviewImageFixtures.write(
            [try PreviewImageFixtures.solid(width: 64, height: 64, gray: 0.2)], to: url, type: .png)
        let model = PreviewImageModel()
        await model.load(url, reduceMotion: false)
        model.zoomChanged(PreviewZoom(preset: nil, percent: 800))
        XCTAssertFalse(model.showsReduced)
        XCTAssertFalse(try XCTUnwrap(model.opened).offersFullResolution)
        model.stop()
    }

    func testInfoShowsOnlyKnownFieldsAndNeverCoordinates() throws {
        let info = PreviewImageInfo(
            properties: [
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS R5",
                ],
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifDateTimeOriginal: "2026:10:03 07:42:18", kCGImagePropertyExifLensModel: "  ",
                ],
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 35.6586, kCGImagePropertyGPSLongitude: 139.7454,
                ],
            ],
            pixelSize: CGSize(width: 8_192, height: 5_464), headroom: 0)

        XCTAssertEqual(info.rows.map(\.field), [.dimensions, .camera, .captured, .location])
        XCTAssertEqual(info.rows.first { $0.field == .camera }?.value, "Canon EOS R5")
        let location = try XCTUnwrap(info.rows.first { $0.field == .location }?.value)
        XCTAssertNil(location.rangeOfCharacter(from: .decimalDigits))
        for row in info.rows {
            XCTAssertFalse(row.value.contains("35.6") || row.value.contains("139"), "\(row.field) leaks coordinates")
        }
    }

    func testInfoListsHDRAndProfileDetailsWhenPresent() {
        let info = PreviewImageInfo(
            properties: [
                kCGImagePropertyDPIWidth: 144.0, kCGImagePropertyDPIHeight: 144.0, kCGImagePropertyDepth: 10,
                kCGImagePropertyProfileName: "Display P3",
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17",
                ],
            ],
            pixelSize: CGSize(width: 4_032, height: 3_024), headroom: 4)
        XCTAssertEqual(
            info.rows.map(\.field), [.dimensions, .resolution, .colorProfile, .bitDepth, .dynamicRange, .camera])
        XCTAssertEqual(info.rows.first { $0.field == .camera }?.value, "Apple iPhone 17")

        let standard = PreviewImageInfo(properties: [:], pixelSize: CGSize(width: 10, height: 10), headroom: 1)
        XCTAssertEqual(standard.rows.map(\.field), [.dimensions])
    }

    private func plays(_ url: URL) throws -> Int? {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return PreviewImageSource.plays(CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:])
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("condition not met in time") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
