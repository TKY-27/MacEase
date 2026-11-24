import AppKit
import ImageIO
import SwiftUI
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

    func testLoopCountsFollowEachFormat() async throws {
        let png = directory.appending(path: "loop.png")
        let frames = try (0..<3).map { try PreviewImageFixtures.solid(width: 8, height: 8, gray: CGFloat($0) / 2) }
        try PreviewImageFixtures.write(
            frames, to: png, type: .png,
            container: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 2]],
            frame: [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.02]])

        let twoGif = try await PreviewImageSource().open(
            PreviewImageFixtures.gif(frames: 3, loopCount: 2, in: directory, name: "two.gif"))
        let onceGif = try await PreviewImageSource().open(
            PreviewImageFixtures.gif(frames: 3, loopCount: nil, in: directory, name: "once.gif"))
        let foreverGif = try await PreviewImageSource().open(
            PreviewImageFixtures.gif(frames: 3, loopCount: 0, in: directory, name: "forever.gif"))
        let apng = try await PreviewImageSource().open(png)
        let finiteWebP = try await PreviewImageSource().open(
            PreviewImageFixtures.animatedWebP(loopCount: 2, delaysMs: [40, 80], in: directory, name: "two.webp"))
        let foreverWebP = try await PreviewImageSource().open(
            PreviewImageFixtures.animatedWebP(loopCount: 0, delaysMs: [50, 50], in: directory, name: "forever.webp"))

        XCTAssertEqual(twoGif.animation?.plays, 2)
        XCTAssertEqual(onceGif.animation?.plays, 1)
        XCTAssertNil(foreverGif.animation?.plays)
        XCTAssertEqual(apng.animation?.plays, 2)
        XCTAssertEqual(finiteWebP.animation?.plays, 2)
        XCTAssertEqual(finiteWebP.animation?.delays ?? [], [0.04, 0.08])
        XCTAssertNil(foreverWebP.animation?.plays)
        XCTAssertEqual(PreviewImageSource.plays([:]), 1)
    }

    func testHEICSReadsAnimationTimingThroughOpen() async throws {
        let supported = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        try XCTSkipUnless(supported.contains("public.heics"), "HEICS writer unavailable on this Mac")
        let url = directory.appending(path: "sequence.heics")
        let frames = try (0..<3).map { try PreviewImageFixtures.solid(width: 16, height: 16, gray: CGFloat($0) / 2) }
        try PreviewImageFixtures.write(
            frames, to: url, typeIdentifier: "public.heics",
            container: [kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSLoopCount: 0]],
            frame: [kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSUnclampedDelayTime: 0.04]])

        let opened = try await PreviewImageSource().open(url)
        let timing = try XCTUnwrap(opened.animation)
        XCTAssertEqual(timing.delays.count, 3)
        for delay in timing.delays { XCTAssertEqual(delay, 0.04, accuracy: 0.005) }
    }

    func testMultiPageTIFFICOAndICNSAreNotAnimated() async throws {
        let tiffURL = directory.appending(path: "pages.tiff")
        let widePage = try PreviewImageFixtures.solid(width: 4_500, height: 40, gray: 0.2)
        let secondPage = try PreviewImageFixtures.solid(width: 200, height: 40, gray: 0.8)
        try PreviewImageFixtures.write([widePage, secondPage], to: tiffURL, type: .tiff)

        let openedTIFF = try await PreviewImageSource().open(tiffURL)
        XCTAssertNil(openedTIFF.animation)
        XCTAssertEqual(openedTIFF.pixelSize, CGSize(width: 4_500, height: 40))
        XCTAssertTrue(openedTIFF.offersFullResolution)
        if ImageAnalyzer.isSupported {
            XCTAssertTrue(PreviewLiveText.isWorthAnalyzing(pixelSize: openedTIFF.pixelSize, animated: false))
        }

        let icoURL = directory.appending(path: "icon.ico")
        let iconFrames = [
            try PreviewImageFixtures.solid(width: 64, height: 64, gray: 0.3),
            try PreviewImageFixtures.solid(width: 32, height: 32, gray: 0.7),
        ]
        try PreviewImageFixtures.write(iconFrames, to: icoURL, typeIdentifier: "com.microsoft.ico")
        let openedICO = try await PreviewImageSource().open(icoURL)
        XCTAssertNil(openedICO.animation)
        XCTAssertEqual(openedICO.pixelSize, CGSize(width: 64, height: 64))

        let icnsURL = directory.appending(path: "icon.icns")
        let icnsFrames = [
            try PreviewImageFixtures.solid(width: 128, height: 128, gray: 0.4),
            try PreviewImageFixtures.solid(width: 32, height: 32, gray: 0.6),
        ]
        try PreviewImageFixtures.write(icnsFrames, to: icnsURL, typeIdentifier: "com.apple.icns")
        let openedICNS = try await PreviewImageSource().open(icnsURL)
        XCTAssertNil(openedICNS.animation)
    }

    func testGIFDelaysUnderTwentyMillisecondsPlayAtHundredMilliseconds() async throws {
        let zeroGIF = try PreviewImageFixtures.gif(frames: 2, loopCount: 0, delay: 0, in: directory, name: "zero.gif")
        let tenMsGIF = try PreviewImageFixtures.gif(
            frames: 2, loopCount: 0, delay: 0.01, in: directory, name: "ten.gif")
        let twentyMsGIF = try PreviewImageFixtures.gif(
            frames: 2, loopCount: 0, delay: 0.02, in: directory, name: "twenty.gif")
        let fiftyMsGIF = try PreviewImageFixtures.gif(
            frames: 2, loopCount: 0, delay: 0.05, in: directory, name: "fifty.gif")

        let openedZero = try await PreviewImageSource().open(zeroGIF)
        let openedTen = try await PreviewImageSource().open(tenMsGIF)
        let openedTwenty = try await PreviewImageSource().open(twentyMsGIF)
        let openedFifty = try await PreviewImageSource().open(fiftyMsGIF)

        XCTAssertEqual(openedZero.animation?.delays, [0.1, 0.1])
        XCTAssertEqual(openedTen.animation?.delays, [0.1, 0.1])
        XCTAssertEqual(openedTwenty.animation?.delays, [0.02, 0.02])
        XCTAssertEqual(openedFifty.animation?.delays, [0.05, 0.05])
        XCTAssertEqual(
            PreviewImageSource.clampedDelaySeconds(-0.05), PreviewImageSource.defaultFrameDelaySeconds)
    }

    func testHostileDelaysAndOverflowingDimensionsDoNotCrash() async throws {
        XCTAssertEqual(
            PreviewImageSource.clampedDelaySeconds(1e308), PreviewImageSource.maximumFrameDelaySeconds)
        XCTAssertEqual(
            PreviewImageSource.clampedDelaySeconds(.infinity), PreviewImageSource.defaultFrameDelaySeconds)
        XCTAssertEqual(
            PreviewImageSource.clampedDelaySeconds(.nan), PreviewImageSource.defaultFrameDelaySeconds)
        XCTAssertNil(PreviewImageSource.pixelCount(width: 4_000_000_000, height: 4_000_000_000))
        XCTAssertNil(
            PreviewImageSource.fullResolutionByteCount(width: 4_000_000_000, height: 4_000_000_000, bitsPerPixel: 32))
        XCTAssertNil(PreviewImageSource.byteCount(Int.max, 2))

        let hugePNGURL = directory.appending(path: "bomb.png")
        try PreviewImageFixtures.monochromePNG(width: 25_000, height: 25_000).write(to: hugePNGURL)
        do {
            _ = try await PreviewImageSource().open(hugePNGURL)
            XCTFail("Expected image exceeding maximumSourcePixelCount to be refused")
        } catch {
            XCTAssertNotNil(error)
        }

        let gifURL = try PreviewImageFixtures.gif(frames: 2, size: 16, loopCount: 1, in: directory, name: "huge.gif")
        let source = PreviewImageSource()
        let opened = try await source.open(gifURL)
        let animator = PreviewImageAnimator(
            source: source, first: opened.first, timing: PreviewImageTiming(delays: [1e308, 1e308], plays: 1))
        animator.play()
        await Task.yield()
        XCTAssertTrue(animator.isPlaying)
        animator.pause()
        XCTAssertFalse(animator.isPlaying)
    }

    func testHundredThousandFrameDeclarationRefusesAnimationAndCancelsPromptly() async throws {
        let url = try PreviewImageFixtures.manyFrameGIF(frameCount: 100_000, in: directory, name: "100k.gif")

        let opened = try await PreviewImageSource().open(url)
        XCTAssertNil(opened.animation)
        XCTAssertEqual(opened.first.width, 1)

        let start = ContinuousClock.now
        let source = PreviewImageSource(maximumFrameCount: 200_000)
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let task = Task.detached {
            startedContinuation.yield()
            startedContinuation.finish()
            return try await source.open(url)
        }
        for await _ in started { break }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancelled open to throw CancellationError")
        } catch is CancellationError {
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
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
        XCTAssertNil(PreviewImageTiming(delays: [], plays: 1).step(after: position))
    }

    func testAnimationStopsAfterItsPlaysAndReplaysFromTheStart() async throws {
        let model = PreviewImageModel()
        await model.load(
            try PreviewImageFixtures.gif(frames: 3, loopCount: 1, delay: 0.04, in: directory), reduceMotion: false)
        let animator = try XCTUnwrap(model.animator)
        XCTAssertTrue(animator.isPlaying)
        try await waitUntilObserved { !animator.isPlaying }
        XCTAssertEqual(animator.position, PreviewImageTiming.Position(index: 2, completedPlays: 0))

        animator.play()
        try await waitUntilObserved { animator.position.index == 0 }
        XCTAssertTrue(animator.isPlaying)
        animator.pause()
    }

    func testReduceMotionShowsTheFirstFrameUntilPlayIsPressed() async throws {
        let model = PreviewImageModel()
        await model.load(
            try PreviewImageFixtures.gif(frames: 4, loopCount: 0, delay: 0.03, in: directory), reduceMotion: true)
        let animator = try XCTUnwrap(model.animator)
        XCTAssertFalse(animator.isPlaying)
        XCTAssertEqual(animator.position.index, 0)

        animator.play()
        try await waitUntilObserved { animator.position.index > 0 }
        model.stop()
        XCTAssertFalse(animator.isPlaying)
    }

    func testAnimationPausesWhenOccludedAndResumesWhenVisible() async throws {
        let model = PreviewImageModel()
        await model.load(
            try PreviewImageFixtures.gif(frames: 4, loopCount: 0, delay: 0.03, in: directory), reduceMotion: false)
        let animator = try XCTUnwrap(model.animator)
        try await waitUntilObserved { animator.position.index > 0 }

        model.setWindowVisible(false)
        XCTAssertFalse(animator.isPlaying)
        let pausedPosition = animator.position
        await Task.yield()
        XCTAssertEqual(animator.position, pausedPosition)

        model.setWindowVisible(true)
        XCTAssertTrue(animator.isPlaying)
        try await waitUntilObserved { animator.position != pausedPosition }

        // User pause stays paused after occlusion changes.
        animator.pause()
        model.setWindowVisible(false)
        model.setWindowVisible(true)
        XCTAssertFalse(animator.isPlaying)
        model.stop()
    }

    private final class OcclusionTestWindow: NSWindow {
        var simulatedOcclusion: NSWindow.OcclusionState = .visible

        override var occlusionState: NSWindow.OcclusionState { simulatedOcclusion }
    }

    func testScrollViewObservesWindowOcclusionNotifications() async throws {
        let scroll = PreviewImageScroll(pixelSize: CGSize(width: 64, height: 64))
        var states: [Bool] = []
        scroll.occlusionChanged = { states.append($0) }
        let window = OcclusionTestWindow(
            contentRect: NSRect(x: -5_000, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.contentView = scroll
        try await waitUntilCondition { states == [true] }

        window.simulatedOcclusion = []
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertEqual(states, [true, false])

        window.simulatedOcclusion = .visible
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        XCTAssertEqual(states, [true, false, true])
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

    func testMixedFrameSizesRespectFrameCacheLimit() async throws {
        let url = try PreviewImageFixtures.gif(frames: 4, size: 16, loopCount: 0, in: directory, name: "mixed.gif")
        let smallFrameBytes = 16 * 16 * 4
        let cacheLimit = smallFrameBytes * 6
        let source = PreviewImageSource(frameCacheLimit: cacheLimit)
        _ = try await source.open(url)
        let initialBytes = await source.cachedBytes
        XCTAssertGreaterThan(initialBytes, 0)
        XCTAssertLessThanOrEqual(initialBytes, cacheLimit)

        let largeFrame = try PreviewImageFixtures.solid(width: 512, height: 512, gray: 0.5)
        await source.store(largeFrame, at: 1)
        let afterLarge = await source.cachedBytes
        XCTAssertLessThanOrEqual(afterLarge, cacheLimit)
        XCTAssertEqual(afterLarge, initialBytes)
    }

    func testLiveTextSkipsAnimatedTinyAndOversizedImages() throws {
        try XCTSkipUnless(ImageAnalyzer.isSupported, "Live Text is not supported on this Mac")
        XCTAssertTrue(PreviewLiveText.isWorthAnalyzing(pixelSize: CGSize(width: 2_880, height: 1_800), animated: false))
        XCTAssertFalse(PreviewLiveText.isWorthAnalyzing(pixelSize: CGSize(width: 2_880, height: 1_800), animated: true))
        XCTAssertFalse(PreviewLiveText.isWorthAnalyzing(pixelSize: CGSize(width: 16, height: 16), animated: false))
        XCTAssertFalse(
            PreviewLiveText.isWorthAnalyzing(pixelSize: CGSize(width: 12_000, height: 9_000), animated: false))
    }

    func testLiveTextFindsTextAndCancelsDuringAnalysis() async throws {
        try XCTSkipUnless(ImageAnalyzer.isSupported, "Live Text is not supported on this Mac")
        let url = directory.appending(path: "screenshot.png")
        try PreviewImageFixtures.write(
            [try PreviewImageFixtures.text("Invoice 2041 is overdue", width: 1_600, height: 400)], to: url, type: .png)

        let analysed = PreviewImageModel()
        await analysed.load(url, reduceMotion: false)
        try await waitUntilObserved(timeout: .seconds(20)) { analysed.liveText.analysis != nil }
        XCTAssertEqual(analysed.liveText.analysis?.hasResults(for: .text), true)

        let cancelled = PreviewImageModel()
        await cancelled.load(url, reduceMotion: false)
        try await waitUntilObserved(timeout: .seconds(5)) { cancelled.liveText.phase == .analyzing }
        cancelled.liveText.cancel()
        XCTAssertEqual(cancelled.liveText.phase, .idle)
        XCTAssertNil(cancelled.liveText.analysis)
    }

    func testLiveTextDoesNotKeepAnalysisOrMountOverlayWithoutText() async throws {
        try XCTSkipUnless(ImageAnalyzer.isSupported, "Live Text is not supported on this Mac")
        let url = directory.appending(path: "blank.png")
        try PreviewImageFixtures.write(
            [try PreviewImageFixtures.solid(width: 256, height: 256, gray: 0.5)], to: url, type: .png)

        let model = PreviewImageModel()
        await model.load(url, reduceMotion: false)
        try await waitUntilObserved(timeout: .seconds(20)) { model.liveText.phase == .finished }
        XCTAssertNil(model.liveText.analysis)
    }

    func testAnimatedImagesAreNeverAnalysed() async throws {
        let model = PreviewImageModel()
        await model.load(
            try PreviewImageFixtures.gif(frames: 2, size: 200, loopCount: 0, in: directory), reduceMotion: true)
        XCTAssertEqual(model.liveText.phase, .idle)
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

    func testCheckerboardTileIsBoundedAndCached() {
        let tinyScaleSquare = PreviewImageLayerView.checkerSquarePoints(forScale: 0.01)
        XCTAssertLessThanOrEqual(tinyScaleSquare, Int(PreviewImageLayerView.maximumCheckerSquarePoints))
        XCTAssertGreaterThanOrEqual(tinyScaleSquare, Int(PreviewImageLayerView.minimumCheckerSquarePoints))

        let first = PreviewImageLayerView.checkerboardColor(for: .aqua, squarePoints: tinyScaleSquare)
        let second = PreviewImageLayerView.checkerboardColor(for: .aqua, squarePoints: tinyScaleSquare)
        XCTAssertTrue(first === second)

        let layerView = PreviewImageLayerView(frame: NSRect(x: 0, y: 0, width: 20_000, height: 20_000))
        layerView.showsCheckerboard = true
        layerView.checkerScale = 0.01
        layerView.updateLayer()
        XCTAssertTrue(layerView.layer?.backgroundColor === first)
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
        XCTAssertNil(model.reducedSize)

        model.zoomChanged(PreviewZoom(preset: .fit, percent: 30))
        XCTAssertNil(model.detail)

        model.zoomChanged(PreviewZoom(preset: .actualSize, percent: 100))
        try await waitUntilObserved { model.detail != nil }
        XCTAssertEqual(model.detail?.width, 5_000)
        XCTAssertFalse(model.showsReduced)
        XCTAssertNil(model.reducedSize)
        model.stop()
    }

    func testOverLimitImageReportsReducedAndShownAt() async throws {
        let url = directory.appending(path: "over-limit.png")
        try PreviewImageFixtures.monochromePNG(width: 20_000, height: 20_000).write(to: url)
        let model = PreviewImageModel()
        await model.load(url, reduceMotion: false)
        let opened = try XCTUnwrap(model.opened)
        XCTAssertFalse(opened.offersFullResolution)
        XCTAssertEqual(opened.first.width, PreviewImageSource.maximumPreviewEdge)
        XCTAssertEqual(model.reducedSize, CGSize(width: opened.first.width, height: opened.first.height))

        model.zoomChanged(PreviewZoom(preset: .actualSize, percent: 100))
        XCTAssertTrue(model.showsReduced)
        model.stop()
    }

    func testFailedFullResolutionDecodeReportsReducedAndShownAt() async throws {
        let url = directory.appending(path: "vanishing.png")
        try PreviewImageFixtures.write(
            [try PreviewImageFixtures.solid(width: 5_000, height: 50, gray: 0.5)], to: url, type: .png)
        let model = PreviewImageModel()
        await model.load(url, reduceMotion: false)
        let opened = try XCTUnwrap(model.opened)
        XCTAssertTrue(opened.offersFullResolution)

        try FileManager.default.removeItem(at: url)
        model.zoomChanged(PreviewZoom(preset: .actualSize, percent: 100))
        try await waitUntilObserved { model.detailFailed }
        XCTAssertTrue(model.showsReduced)
        XCTAssertEqual(model.reducedSize, CGSize(width: opened.first.width, height: opened.first.height))
        model.stop()
    }

    func testRotatedEXIFOrientationsFiveThroughEightSwapDimensionsAndFullResolution() async throws {
        let raw = try PreviewImageFixtures.solid(width: 4_500, height: 80, gray: 0.4)
        for orientation in 5...8 {
            let url = directory.appending(path: "orient-\(orientation).jpg")
            try PreviewImageFixtures.write(
                [raw], to: url, type: .jpeg, frame: [kCGImagePropertyOrientation: orientation])
            let source = PreviewImageSource()
            let opened = try await source.open(url)
            XCTAssertEqual(opened.pixelSize, CGSize(width: 80, height: 4_500), "orientation \(orientation)")
            XCTAssertEqual(opened.first.height, PreviewImageSource.maximumPreviewEdge)
            XCTAssertLessThan(opened.first.width, opened.first.height)
            XCTAssertEqual(
                opened.metadata.rows.first { $0.field == .dimensions }?.value, "80 × 4500")
            XCTAssertTrue(opened.offersFullResolution)
            let full = try await source.fullResolution()
            XCTAssertEqual(full.width, 80)
            XCTAssertEqual(full.height, 4_500)
        }
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
        XCTAssertNil(model.reducedSize)
        model.stop()
    }

    func testInfoThroughOpenShowsOnlyKnownFieldsAndNeverCoordinates() async throws {
        let url = directory.appending(path: "camera.jpg")
        let photo = try PreviewImageFixtures.solid(width: 320, height: 240, gray: 0.4)
        try PreviewImageFixtures.write(
            [photo], to: url, type: .jpeg,
            frame: [
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS R5",
                ],
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifDateTimeOriginal: "2026:10:03 07:42:18",
                    kCGImagePropertyExifLensModel: "  ",
                ],
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 35.6586, kCGImagePropertyGPSLatitudeRef: "N",
                    kCGImagePropertyGPSLongitude: 139.7454, kCGImagePropertyGPSLongitudeRef: "E",
                ],
            ])

        let opened = try await PreviewImageSource().open(url)
        let metadata = opened.metadata
        XCTAssertEqual(metadata.rows.first { $0.field == .dimensions }?.value, "320 × 240")
        XCTAssertEqual(metadata.rows.first { $0.field == .camera }?.value, "Canon EOS R5")
        XCTAssertNil(metadata.rows.first { $0.field == .lens })
        XCTAssertNotNil(metadata.rows.first { $0.field == .captured })
        let location = try XCTUnwrap(metadata.rows.first { $0.field == .location }?.value)
        XCTAssertNil(location.rangeOfCharacter(from: .decimalDigits))
        for row in metadata.rows {
            XCTAssertFalse(row.value.contains("35.6") || row.value.contains("139"), "\(row.field) leaks coordinates")
        }
    }

    func testInfoThroughOpenListsProfileResolutionBitDepthAndHDR() async throws {
        let url = directory.appending(path: "p3.png")
        let image = try PreviewImageFixtures.solid(
            width: 200, height: 100, gray: 0.5, bitsPerComponent: 16, colorSpaceName: CGColorSpace.displayP3)
        try PreviewImageFixtures.write(
            [image], to: url, type: .png,
            frame: [
                kCGImagePropertyDPIWidth: 144.0, kCGImagePropertyDPIHeight: 144.0,
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17",
                ],
            ])

        let opened = try await PreviewImageSource().open(url)
        let metadata = opened.metadata
        XCTAssertEqual(metadata.rows.first { $0.field == .dimensions }?.value, "200 × 100")
        XCTAssertEqual(metadata.rows.first { $0.field == .colorProfile }?.value, "Display P3")
        XCTAssertNotNil(metadata.rows.first { $0.field == .resolution })
        XCTAssertNotNil(metadata.rows.first { $0.field == .bitDepth })

        let hdrDetails = PreviewImageInfo(properties: [:], pixelSize: CGSize(width: 10, height: 10), headroom: 4)
        XCTAssertEqual(hdrDetails.rows.map(\.field), [.dimensions, .dynamicRange])
        let sdrDetails = PreviewImageInfo(properties: [:], pixelSize: CGSize(width: 10, height: 10), headroom: 1)
        XCTAssertEqual(sdrDetails.rows.map(\.field), [.dimensions])
    }

    func testActualSizeAndFitStayTrueWhenTheDisplayScaleChanges() async throws {
        let window = ScaledWindow(
            contentRect: NSRect(x: -5_000, y: 0, width: 400, height: 400), styleMask: [.borderless],
            backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let scroll = PreviewImageScroll(pixelSize: CGSize(width: 2_000, height: 1_000))
        var reports: [PreviewZoom] = []
        scroll.zoomChanged = { reports.append($0) }
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
        scroll.setZoom(.actualSize, animated: false)
        XCTAssertEqual(scroll.magnification, 0.5, accuracy: 0.001)

        window.scale = 1
        scroll.viewDidChangeBackingProperties()
        XCTAssertEqual(scroll.zoom.preset, .actualSize)
        XCTAssertEqual(scroll.magnification, 1, accuracy: 0.001)
        try await waitUntilCondition { reports.last?.preset == .actualSize && reports.last?.percent == 100 }

        scroll.setZoom(.fit, animated: false)
        let fit = scroll.magnification
        window.scale = 2
        scroll.viewDidChangeBackingProperties()
        try await waitUntilCondition { reports.last.map { abs($0.percent - fit * 200) < 0.01 } == true }
        XCTAssertEqual(reports.last?.preset, .fit)
    }

    func testOverlappingAnimatedZoomsKeepTheTargetState() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: -5_000, y: 0, width: 400, height: 400), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let scroll = PreviewImageScroll(pixelSize: CGSize(width: 4_000, height: 2_000))
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
        var reports: [PreviewZoom] = []
        scroll.zoomChanged = { reports.append($0) }

        scroll.setZoom(.actualSize, animated: true)
        try await Task.sleep(for: .milliseconds(60))
        scroll.setZoom(.actualSize, centeredAt: NSPoint(x: 3_000, y: 1_000), animated: true)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(reports.contains { $0.preset == nil }, "intermediate zoom reported: \(reports)")
        XCTAssertEqual(reports.last?.preset, .actualSize)
        XCTAssertEqual(scroll.zoom.preset, .actualSize)
    }

    func testFitShowsTheWholeOfAVeryWideImage() {
        let scroll = PreviewImageScroll(pixelSize: CGSize(width: 60_000, height: 200))
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.zoom.preset, .fit)
        XCTAssertEqual(scroll.zoom.percent, 400.0 / 60_000 * 100, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(scroll.documentVisibleRect.width, 60_000 - 1)
    }

    func testInfoPopoverSurvivesTheBarCollapsing() async throws {
        let url = directory.appending(path: "photo.png")
        try PreviewImageFixtures.write(
            [try PreviewImageFixtures.solid(width: 800, height: 600, gray: 0.4)], to: url, type: .png)
        let model = PreviewImageModel()
        await model.load(url, reduceMotion: true)
        let opened = try XCTUnwrap(model.opened)
        let window = NSWindow(
            contentRect: NSRect(x: -5_000, y: 0, width: 420, height: 60), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: PreviewImageBar(
                model: model, opened: opened, zoomRequest: .constant(PreviewZoomRequest(preset: .fit, serial: 0)),
                showsInfo: .constant(true)
            ).frame(maxWidth: .infinity, alignment: .leading))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var popover: NSWindow?
        try await waitUntilCondition(timeout: .seconds(5)) {
            window.layoutIfNeeded()
            popover = NSApp.windows.first { $0.className.contains("Popover") && $0.isVisible }
            return popover != nil
        }

        window.setContentSize(NSSize(width: 120, height: 60))
        for _ in 0..<20 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let visible = NSApp.windows.filter { $0.className.contains("Popover") && $0.isVisible }
        XCTAssertEqual(visible.count, 1)
        XCTAssertTrue(visible.first === popover, "the same popover stays open")
        for open in visible { open.orderOut(nil) }
        model.stop()
    }

    func testLiveTextSelectionKeepsTheArrowsAndOffersCopy() async throws {
        try XCTSkipUnless(ImageAnalyzer.isSupported, "Live Text is not supported on this Mac")
        let url = directory.appending(path: "receipt.png")
        try PreviewImageFixtures.write(
            [try PreviewImageFixtures.text("Invoice 2041 is overdue", width: 1_600, height: 400)], to: url, type: .png)
        let model = PreviewImageModel()
        await model.load(url, reduceMotion: true)
        try await waitUntilCondition(timeout: .seconds(20)) { model.liveText.analysis != nil }
        let opened = try XCTUnwrap(model.opened)
        let window = NSWindow(
            contentRect: NSRect(x: -5_000, y: 0, width: 400, height: 300), styleMask: [.borderless],
            backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let scroll = PreviewImageScroll(pixelSize: opened.pixelSize)
        window.contentView = scroll
        scroll.content.image = opened.first
        let overlay = PreviewLiveTextOverlay(content: scroll.content)
        overlay.show(model.liveText.analysis)
        let copy = NSMenuItem(title: "", action: #selector(PreviewImageLayerView.copy(_:)), keyEquivalent: "")
        XCTAssertFalse(scroll.content.validateMenuItem(copy))

        let text = overlay.view.text
        overlay.view.selectedRanges = [text.startIndex..<text.index(text.startIndex, offsetBy: 7)]
        XCTAssertTrue(overlay.view.hasActiveTextSelection)
        XCTAssertTrue(window.makeFirstResponder(scroll.content))
        XCTAssertTrue(scroll.content.validateMenuItem(copy))
        XCTAssertFalse(
            PreviewPanelShortcut.nextFile.isAvailable(
                firstResponder: window.firstResponder, in: window, fullKeyboardAccess: false))

        overlay.view.resetSelection()
        XCTAssertTrue(
            PreviewPanelShortcut.nextFile.isAvailable(
                firstResponder: window.firstResponder, in: window, fullKeyboardAccess: false))
        model.stop()
    }

    private func waitUntilObserved(
        timeout: Duration = .seconds(5), _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return XCTFail("condition not met in time") }
            let changed = AsyncStream<Void> { continuation in
                withObservationTracking {
                    _ = condition()
                } onChange: {
                    continuation.yield()
                    continuation.finish()
                }
            }
            if condition() { return }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in changed { break }
                }
                group.addTask {
                    try? await Task.sleep(for: remaining)
                }
                await group.next()
                group.cancelAll()
            }
        }
    }

    private func waitUntilCondition(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("condition not met in time") }
            await Task.yield()
        }
    }
}

private final class ScaledWindow: NSWindow {
    var scale: CGFloat = 2

    override var backingScaleFactor: CGFloat { scale }
}
