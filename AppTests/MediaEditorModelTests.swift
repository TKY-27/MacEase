import AVFoundation
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import Engine
@testable import MacEase

@MainActor
final class MediaEditorModelTests: XCTestCase {
    func testNewFileSavePlansEditedNamesDespiteGlobalReplaceMode() async throws {
        var settings = Engine.Settings()
        settings.outputMode = .replace
        for model in [try await photoModel(settings: settings), try await videoModel(settings: settings)] {
            model.change { $0.photo.geometry.quarterTurns = 1 }
            let planned = try model.makeSave(replacingOriginal: false)
            XCTAssertEqual(planned.settings.outputMode, .newFile)
            XCTAssertEqual(model.settings.outputMode, .replace)
            XCTAssertFalse(model.forcesNewFile)
            XCTAssertNil(model.newFileReason)
            XCTAssertEqual(planned.batch.items.count, 1)
            let work = try XCTUnwrap(planned.batch.items.first)
            let naming = try XCTUnwrap(work.newFileNaming)
            XCTAssertEqual(
                naming.name(for: model.url, outputName: model.url.lastPathComponent),
                model.isVideo ? "clip-0_edited.mp4" : "photo_edited.png")
        }
    }

    func testReplaceSavePlansOriginalNamesDespiteGlobalNewFileMode() async throws {
        var settings = Engine.Settings()
        settings.outputMode = .newFile
        for model in [try await photoModel(settings: settings), try await videoModel(settings: settings)] {
            model.change { $0.photo.geometry.quarterTurns = 1 }
            let planned = try model.makeSave(replacingOriginal: true)
            XCTAssertEqual(planned.settings.outputMode, .replace)
            XCTAssertEqual(model.settings.outputMode, .newFile)
            XCTAssertFalse(model.forcesNewFile)
            XCTAssertNil(model.newFileReason)
            XCTAssertEqual(planned.batch.items.count, 1)
            XCTAssertNil(try XCTUnwrap(planned.batch.items.first).newFileNaming)
        }
    }

    func testCompressionRetryPrefillsEditableVideoRange() async throws {
        let model = try await videoModel(range: 0.5...1.5)
        XCTAssertEqual(model.values.start, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(model.values.end, 1.5, accuracy: 0.000_001)
        try await eventually { model.canSave || model.failure != nil }
        XCTAssertNil(model.failure)
        XCTAssertTrue(model.canSave)
        let planned = try model.makeSave(replacingOriginal: false)
        XCTAssertEqual(planned.batch.operation, .videoEdit)
        XCTAssertEqual(planned.settings.outputMode, .newFile)
        XCTAssertEqual(model.values.video.segments?.first?.start, 0.5)
        XCTAssertEqual(model.values.video.segments?.first?.end, 1.5)
    }

    func testMultipleVideoSourcesCannotReplaceOriginal() async throws {
        let model = try await videoModel(count: 2)
        XCTAssertTrue(model.forcesNewFile)
        XCTAssertThrowsError(try model.makeSave(replacingOriginal: true)) { error in
            XCTAssertEqual(
                error as? EngineError,
                .invalidInput(.malformed(String(localized: "Multiple videos require a new file."))))
        }
        let planned = try model.makeSave(replacingOriginal: false)
        XCTAssertEqual(planned.settings.outputMode, .newFile)
        XCTAssertEqual(planned.batch.items.count, 1)
        XCTAssertEqual(planned.batch.items.first?.inputs, model.values.sources.map(\.url))
    }

    func testSourceRequiringNewFileCannotReplaceOriginal() async throws {
        let model = try await photoModel(svg: true)
        XCTAssertTrue(model.requiresNewFile)
        model.change { $0.photo.geometry.quarterTurns = 1 }
        XCTAssertTrue(model.forcesNewFile)
        XCTAssertThrowsError(try model.makeSave(replacingOriginal: true)) { error in
            XCTAssertEqual(
                error as? EngineError,
                .invalidInput(.malformed(String(localized: "This source requires a new file."))))
        }
        let planned = try model.makeSave(replacingOriginal: false)
        XCTAssertEqual(planned.settings.outputMode, .newFile)
        XCTAssertNotNil(try XCTUnwrap(planned.batch.items.first).newFileNaming)
    }

    func testHDRColorEditsCannotReplaceOriginal() async throws {
        for model in [try await photoModel(hdr: true), try await videoModel()] {
            if model.isVideo { model.containsHDR = true }
            XCTAssertTrue(model.containsHDR)
            XCTAssertFalse(model.forcesNewFile)
            model.change {
                if model.isVideo {
                    $0.videoAdjustments[.exposure] = 0.5
                } else {
                    $0.photo.adjustments[.exposure] = 0.5
                }
            }
            XCTAssertTrue(model.forcesNewFile)
            XCTAssertTrue(model.convertsToSDR)
            XCTAssertThrowsError(try model.makeSave(replacingOriginal: true)) { error in
                XCTAssertEqual(
                    error as? EngineError,
                    .invalidInput(.malformed(String(localized: "HDR color edits require a new SDR file."))))
            }
            let planned = try model.makeSave(replacingOriginal: false)
            XCTAssertEqual(planned.settings.outputMode, .newFile)
            XCTAssertNotNil(try XCTUnwrap(planned.batch.items.first).newFileNaming)
        }
    }

    func testEditedHDRPhotoPreventsReplacementAfterSelectingSDRPhoto() async throws {
        let model = try await photoModel(hdr: true, additionalPhoto: true)
        XCTAssertTrue(model.containsHDR)
        model.change { $0.photo.adjustments[.exposure] = 0.5 }
        model.selectPhoto(model.photoURLs[1])
        try await eventually { !model.loadingPhoto }
        XCTAssertNil(model.failure)
        XCTAssertFalse(model.containsHDR)
        XCTAssertTrue(model.forcesNewFile)
        XCTAssertThrowsError(try model.makeSave(replacingOriginal: true)) { error in
            XCTAssertEqual(
                error as? EngineError,
                .invalidInput(.malformed(String(localized: "HDR color edits require a new SDR file."))))
        }
        let planned = try model.makeSave(replacingOriginal: false)
        XCTAssertEqual(planned.settings.outputMode, .newFile)
        XCTAssertEqual(planned.batch.items.count, 1)
        XCTAssertEqual(planned.batch.items.first?.inputs, [model.photoURLs[0]])
    }

    func testOnlyEditedPhotosDetermineForcedNewFilePolicy() async throws {
        let model = try await photoModel(svg: true, additionalPhoto: true)
        XCTAssertTrue(model.requiresNewFile)
        model.selectPhoto(model.photoURLs[1])
        try await eventually { !model.loadingPhoto }
        XCTAssertNil(model.failure)
        model.change { $0.photo.geometry.quarterTurns = 1 }
        model.selectPhoto(model.photoURLs[0])
        try await eventually { !model.loadingPhoto }
        XCTAssertNil(model.failure)
        XCTAssertTrue(model.requiresNewFile)
        XCTAssertFalse(model.forcesNewFile)
        let replacement = try model.makeSave(replacingOriginal: true)
        XCTAssertEqual(replacement.settings.outputMode, .replace)
        XCTAssertEqual(replacement.batch.items.count, 1)
        XCTAssertEqual(replacement.batch.items.first?.inputs, [model.photoURLs[1]])

        model.selectPhoto(model.photoURLs[1])
        try await eventually { !model.loadingPhoto }
        XCTAssertNil(model.failure)
        model.applyPhotoEdits(toAll: true)
        XCTAssertTrue(model.forcesNewFile)
        XCTAssertThrowsError(try model.makeSave(replacingOriginal: true)) { error in
            XCTAssertEqual(
                error as? EngineError,
                .invalidInput(.malformed(String(localized: "This source requires a new file."))))
        }
        let derived = try model.makeSave(replacingOriginal: false)
        XCTAssertEqual(derived.settings.outputMode, .newFile)
        XCTAssertEqual(derived.batch.items.count, 2)
    }

    func testChangeCanReadSourcePropertiesInsideMutation() async throws {
        let model = try await videoModel()
        let original = model.values.segments

        model.change {
            $0.start = model.sourceFrameDuration
            $0.end = model.sourceDuration - model.sourceFrameDuration
        }

        XCTAssertEqual(model.values.start, 1.0 / 24, accuracy: 0.000_001)
        XCTAssertEqual(model.values.end, 2 - 1.0 / 24, accuracy: 0.000_001)
        model.undo()
        XCTAssertEqual(model.values.segments, original)
    }

    func testVideoTrimKeepsScaleAndCreatesOneUndo() async throws {
        let model = try await videoModel()
        let original = try XCTUnwrap(model.values.segments.first)
        model.beginTimelineTrim(original.id, start: true)
        model.updateTimelineTrim(to: 0.43)
        try await eventually { model.values.start > 0 }
        XCTAssertEqual(model.timelineDuration, 2, accuracy: 0.000_001)
        XCTAssertEqual(model.timelineRange(for: model.values.segments[0]).lowerBound, 10.0 / 24, accuracy: 0.000_001)
        model.updateTimelineTrim(to: 0.63)
        await model.endTimelineTrim()

        XCTAssertEqual(model.values.start, 15.0 / 24, accuracy: 0.000_001)
        XCTAssertEqual(model.outputDuration, 2 - 15.0 / 24, accuracy: 0.000_001)
        model.undo()
        XCTAssertEqual(model.values.segments, [original])
        XCTAssertFalse(model.canUndo)
        model.redo()
        XCTAssertEqual(model.values.start, 15.0 / 24, accuracy: 0.000_001)
    }

    func testCrossingVideoHandlesKeepsOneActualFrame() async throws {
        let model = try await videoModel()
        let segment = try XCTUnwrap(model.values.segments.first)
        model.beginTimelineTrim(segment.id, start: true)
        model.updateTimelineTrim(to: 3)
        await model.endTimelineTrim()
        XCTAssertEqual(model.values.start, 47.0 / 24, accuracy: 0.000_001)
        XCTAssertEqual(model.values.end, 2, accuracy: 0.000_001)
        model.undo()
        model.beginTimelineTrim(segment.id, start: false)
        model.updateTimelineTrim(to: -1)
        await model.endTimelineTrim()
        XCTAssertEqual(model.values.start, 0)
        XCTAssertEqual(model.values.end, 1.0 / 24, accuracy: 0.000_001)
    }

    func testNumericVideoBoundaryUsesActualFrameTimestamps() async throws {
        let model = try await videoModel()
        model.beginInteraction()
        model.setVideoBoundary(0.63, start: true)
        await model.finishBoundaryInput()
        model.endInteraction()
        XCTAssertEqual(model.values.start, 15.0 / 24, accuracy: 0.000_001)
        model.undo()
        XCTAssertEqual(model.values.start, 0)
        XCTAssertFalse(model.canUndo)
    }

    func testFocusedNumericDraftSurvivesAsyncFrameSnappingUntilBlur() async throws {
        let model = try await videoModel()
        let host = NSHostingView(rootView: MediaEditorView(model: model, close: {}, save: { _, _ in }))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_280, height: 720), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await eventually { self.textFields(in: host).contains { $0.isEditable && $0.stringValue == "0.000" } }
        let field = try XCTUnwrap(textFields(in: host).first { $0.isEditable && $0.stringValue == "0.000" })
        XCTAssertTrue(window.makeFirstResponder(field))
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("0.1", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        await model.finishBoundaryInput()
        try await eventually { abs(model.values.start - 2.0 / 24) < 0.000_001 }
        XCTAssertEqual(editor.string, "0.1")
        editor.insertText("0.12", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        await model.finishBoundaryInput()
        try await eventually { abs(model.values.start - 3.0 / 24) < 0.000_001 }
        XCTAssertEqual(editor.string, "0.12")
        XCTAssertTrue(window.makeFirstResponder(nil))
        try await eventually { field.stringValue == "0.125" }
        model.undo()
        XCTAssertEqual(model.values.start, 0)
        XCTAssertFalse(model.canUndo)
    }

    func testNaturalVideoPlaybackEndRestoresPausedSkimming() async throws {
        let model = try await videoModel()
        model.seek(1.8)
        model.play()
        try await eventually { model.playing && model.player?.rate == 1 }
        try await eventually { !model.playing }
        XCTAssertEqual(model.position, 2, accuracy: 0.05)
        model.skim(0.5)
        XCTAssertEqual(model.hoverPosition, 0.5)
    }

    func testZoomAllowsFrameAndMillisecondPrecisionForLongMedia() {
        let viewport = 900.0
        let duration = 7_200.0
        let videoZoom = MediaTimeline.maximumZoom(duration: duration, viewport: viewport, interval: 1.0 / 24)
        let audioZoom = MediaTimeline.maximumZoom(duration: duration, viewport: viewport, interval: 0.001)
        XCTAssertEqual(viewport * videoZoom / duration / 24, 6, accuracy: 0.000_001)
        XCTAssertEqual(viewport * audioZoom / duration * 0.001, 6, accuracy: 0.000_001)
        XCTAssertGreaterThan(audioZoom, 128)
    }

    func testSpeedAndMultipleSourceOrderingRetainTimelineMapping() async throws {
        let model = try await videoModel(count: 2)
        let first = try XCTUnwrap(model.values.segments.first)
        let second = model.values.segments[1]
        model.selectSegment(first.id)
        model.change { $0.speed = 2 }
        XCTAssertEqual(model.outputDuration, 3, accuracy: 0.000_001)
        model.moveSegment(second.id, to: 0)
        let timeline = try XCTUnwrap(model.timeline)
        XCTAssertEqual(timeline.segment(at: 0.5).sourceIndex, 1)
        XCTAssertEqual(timeline.sourceTime(at: 0.5), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(timeline.segment(at: 2.5).sourceIndex, 0)
        XCTAssertEqual(timeline.sourceTime(at: 2.5), 1, accuracy: 0.000_001)
        model.duplicateSelection()
        XCTAssertEqual(model.values.segments.map(\.sourceIndex), [1, 1, 0])
        XCTAssertEqual(Set(model.values.segments.map(\.id)).count, 3)
        model.undo()
        XCTAssertEqual(model.values.segments.map(\.id), [second.id, first.id])
    }

    func testSkimmingDoesNotMoveCommittedPlayheadAndPlaybackWins() async throws {
        let model = try await videoModel()
        model.seek(0.5)
        model.skim(1.25)
        XCTAssertEqual(model.position, 0.5)
        XCTAssertEqual(model.hoverPosition, 1.25)
        XCTAssertEqual(model.player?.isMuted, true)
        model.skim(nil)
        XCTAssertNil(model.hoverPosition)
        XCTAssertEqual(model.position, 0.5)
        XCTAssertEqual(model.player?.isMuted, false)
        model.skim(1)
        model.play()
        try await eventually { model.playing && model.player?.rate == 1 }
        XCTAssertNil(model.hoverPosition)
        model.skim(1.5)
        XCTAssertNil(model.hoverPosition)
        XCTAssertEqual(model.player?.isMuted, false)
        model.pause()
    }

    func testTimelineHandleSnapsWithinEightPointsUnlessOptionIsHeld() throws {
        var zoom = 1.0
        var trims: [Double] = []
        let id = UUID()
        let canvas = TimelineCanvas(frame: CGRect(x: 0, y: 0, width: 900, height: 92))
        canvas.configuration = MediaTimeline(
            duration: 2, position: 1,
            clips: [TimelineClip(id: id, range: 0...2, selection: 0...2, label: "")], playing: false,
            zoom: Binding(get: { zoom }, set: { zoom = $0 }), maximumZoom: 100,
            seek: { _ in }, hover: { _ in }, select: { _ in }, beginTrim: { _, _ in },
            trim: { trims.append($0) }, endTrim: {})
        let down = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: CGPoint(x: 0, y: 50), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: down)
        for modifiers in [NSEvent.ModifierFlags(), .option] {
            let drag = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDragged, location: CGPoint(x: 456, y: 50), modifierFlags: modifiers, timestamp: 1,
                    windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            canvas.mouseDragged(with: drag)
        }
        XCTAssertEqual(trims.count, 2)
        XCTAssertEqual(trims[0], 1, accuracy: 1e-12)
        XCTAssertEqual(trims[1], 456.0 / 450, accuracy: 1e-12)
    }

    func testTimelineNonWheelZoomAnchorsPointerThenPlayheadAfterExit() throws {
        var zoom = 1.0
        let scroll = TimelineScrollView(frame: CGRect(x: 0, y: 0, width: 900, height: 106))
        scroll.documentView = TimelineCanvas()
        scroll.configuration = MediaTimeline(
            duration: 2, position: 1, clips: [], playing: false,
            zoom: Binding(get: { zoom }, set: { zoom = $0 }), maximumZoom: 100,
            seek: { _ in }, hover: { _ in }, select: { _ in }, beginTrim: { _, _ in },
            trim: { _ in }, endTrim: {})
        scroll.updateTimeline()
        let viewport = scroll.contentSize.width
        let canvas = try XCTUnwrap(scroll.canvas)
        let entered = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: CGPoint(x: viewport / 4, y: 50), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        canvas.mouseMoved(with: entered)
        zoom = 2
        scroll.updateTimeline()
        XCTAssertEqual(scroll.contentView.bounds.minX, viewport / 4, accuracy: 0.01)
        canvas.mouseExited(with: entered)
        zoom = 4
        scroll.updateTimeline()
        XCTAssertEqual(scroll.contentView.bounds.minX, viewport * 1.25, accuracy: 0.01)
    }

    func testAudioTrimRoundsSamplesAndGroupsDragUndo() async throws {
        let directory = try workspace()
        let url = try audioFixture(in: directory)
        let support = directory.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        let staging = StagingArea(supportDirectory: support)
        let model = AudioTrimModel(url: url, staging: staging, prefill: nil)
        addTeardownBlock { await model.close() }
        await model.load()
        XCTAssertTrue(model.ready, model.failure ?? "Audio did not load")
        XCTAssertEqual(model.sampleRate, 48_000)
        XCTAssertEqual(model.rounded(0.10002), 4_801.0 / 48_000, accuracy: 1e-12)
        model.beginTrim(model.clipID, start: true)
        model.trim(to: 0.20002)
        model.trim(to: 0.30002)
        model.endTrim()
        XCTAssertEqual(model.start, 14_401.0 / 48_000, accuracy: 1e-12)
        model.undo()
        XCTAssertEqual(model.start, 0)
        XCTAssertEqual(model.end, 2)
        XCTAssertFalse(model.canUndo)
        model.redo()
        XCTAssertEqual(model.start, 14_401.0 / 48_000, accuracy: 1e-12)
        model.beginTrim(model.clipID, start: false)
        model.trim(to: -1)
        model.endTrim()
        XCTAssertEqual(model.end - model.start, 1.0 / 48_000, accuracy: 1e-12)
        model.seek(0.10002)
        XCTAssertEqual(model.position, 4_801.0 / 48_000, accuracy: 1e-12)
        await model.close()
        XCTAssertFalse(model.canSave)
        XCTAssertFalse(model.playing)
        XCTAssertNil(model.waveform)
        XCTAssertNil(model.detailWaveform)
    }

    func testNaturalAudioPlaybackEndClearsPlayingWithoutAnotherClick() async throws {
        let directory = try workspace()
        let source = try audioFixture(in: directory)
        let model = AudioTrimModel(url: source, staging: StagingArea(supportDirectory: directory), prefill: nil)
        addTeardownBlock { await model.close() }
        await model.load()
        XCTAssertTrue(model.ready, model.failure ?? "Audio did not load")
        model.seek(1.8)
        model.play()
        XCTAssertTrue(model.playing)
        try await eventually { !model.playing }
        XCTAssertEqual(model.position, 2, accuracy: 0.05)
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }

    private func photoModel(
        hdr: Bool = false, svg: Bool = false, additionalPhoto: Bool = false,
        settings: Engine.Settings = Engine.Settings()
    ) async throws -> MediaEditorModel {
        let directory = try workspace()
        let sources = try (0..<(additionalPhoto ? 2 : 1)).map { index in
            let name = index == 0 ? "photo" : "photo-\(index)"
            let pathExtension = svg && index == 0 ? "svg" : hdr && index == 0 ? "jpg" : "png"
            let source = directory.appending(path: name + "." + pathExtension)
            let canvas = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 60))
            let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            if source.pathExtension == "svg" {
                try """
                <svg xmlns="http://www.w3.org/2000/svg" width="80" height="60">
                  <rect width="80" height="60" fill="red"/>
                </svg>
                """.write(to: source, atomically: true, encoding: .utf8)
            } else if source.pathExtension == "jpg" {
                let bright = CIImage(color: CIColor(red: 1.8, green: 0.5, blue: 0.5))
                    .cropped(to: canvas.extent).settingContentHeadroom(4)
                let encoded = try XCTUnwrap(
                    CIContext().jpegRepresentation(of: canvas, colorSpace: sRGB, options: [.hdrImage: bright]))
                try encoded.write(to: source)
            } else {
                let image = try XCTUnwrap(
                    CIContext().createCGImage(canvas, from: canvas.extent, format: .RGBA16, colorSpace: sRGB))
                let destination = try XCTUnwrap(
                    CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
            return source
        }
        let model = MediaEditorModel(
            urls: sources, isVideo: false, settings: settings, staging: StagingArea(supportDirectory: directory))
        addTeardownBlock { await model.close() }
        model.load()
        try await eventually { model.image != nil || model.failure != nil }
        XCTAssertNil(model.failure)
        XCTAssertTrue(model.ready)
        return model
    }

    private func videoModel(
        count: Int = 1, settings: Engine.Settings = Engine.Settings(), range: ClosedRange<Double>? = nil
    ) async throws
        -> MediaEditorModel
    {
        let directory = try workspace()
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ffmpeg-h264-aac", withExtension: "mp4"))
        let sources = try (0..<count).map { index in
            let source = directory.appending(path: "clip-\(index).mp4")
            try FileManager.default.copyItem(at: fixture, to: source)
            return source
        }
        let support = directory.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        let staging = StagingArea(supportDirectory: support)
        let model = MediaEditorModel(urls: sources, isVideo: true, settings: settings, staging: staging)
        addTeardownBlock { await model.close() }
        model.initialVideoRange = range
        model.load()
        try await eventually { model.canPlay || model.failure != nil }
        XCTAssertNil(model.failure)
        XCTAssertTrue(model.canPlay)
        return model
    }

    func testTimecodeFormatsClockTextAndParsesTypedBoundaries() {
        XCTAssertEqual(Timecode.string(65.257), "1:05.26")
        XCTAssertEqual(Timecode.string(16.704, fractionDigits: 3), "0:16.704")
        XCTAssertEqual(Timecode.string(3_725.5, fractionDigits: 3), "1:02:05.500")
        XCTAssertEqual(Timecode.string(-1), "0:00.00")
        XCTAssertEqual(TimecodeField.parse("1:05.250"), 65.25)
        XCTAssertEqual(TimecodeField.parse("1:02:05"), 3_725)
        XCTAssertEqual(TimecodeField.parse("12.5"), 12.5)
        XCTAssertEqual(TimecodeField.parse(" 90 "), 90)
        for invalid in ["", "1:75", "1:-2", "a:05", "1::05", "1:2:3:4", "-3"] {
            XCTAssertNil(TimecodeField.parse(invalid), invalid)
        }
        XCTAssertEqual(TimecodeField.parse("200000000000000000:0:0"), 7.2e20)
        let snapped = 0.5 + 10.0 / 44_100
        XCTAssertNil(TimecodeField.edited("0:00.500", from: snapped), "an untouched field never moves its boundary")
        XCTAssertFalse(TimecodeField.isInvalid("0:00.500", from: snapped))
        XCTAssertEqual(TimecodeField.edited("0:01", from: snapped), 1)
        XCTAssertTrue(TimecodeField.isInvalid("0:1x", from: snapped))
    }

    func testTypedAudioBoundaryCommitsSampleAlignedRange() async throws {
        let directory = try workspace()
        let support = directory.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        let model = AudioTrimModel(
            url: try audioFixture(in: directory), staging: StagingArea(supportDirectory: support), prefill: nil)
        addTeardownBlock { await model.close() }
        await model.load()
        XCTAssertTrue(model.ready, model.failure ?? "Audio did not load")
        let start = try XCTUnwrap(TimecodeField.parse("0:00.5"))
        model.changeRange(start: start, end: model.end)
        XCTAssertEqual(model.start, 0.5)
        XCTAssertTrue(model.canUndo)
        model.changeRange(start: model.end + 1, end: model.end)
        XCTAssertEqual(model.start, 0.5, "an inverted range is ignored")
    }

    func testLoopPlaybackRestartsFromTheBeginning() async throws {
        let model = try await videoModel()
        model.loops = true
        model.seek(1.8)
        model.play()
        try await eventually { model.playing && model.position < 1 }
        model.pause()
    }

    func testShuttleDoublesTheRateAndKStops() async throws {
        let model = try await videoModel()
        model.shuttle(1)
        XCTAssertTrue(model.playing)
        XCTAssertEqual(model.playbackRate, 1)
        model.shuttle(1)
        XCTAssertEqual(model.playbackRate, 2)
        model.shuttle(0)
        XCTAssertFalse(model.playing)
        XCTAssertEqual(model.playbackRate, 1)
        model.seek(1)
        model.shuttle(-1)
        if model.player?.currentItem?.canPlayReverse == true {
            XCTAssertEqual(model.playbackRate, -1)
        } else {
            try await eventually { model.position < 1 }
            XCTAssertFalse(model.playing)
        }
        model.pause()
    }

    func testFadesEditTheSelectedSegmentAndUndo() async throws {
        let model = try await videoModel()
        model.binding(\.fadeIn).wrappedValue = 1
        XCTAssertEqual(model.values.segments[0].fadeIn, 1)
        XCTAssertEqual(model.timeline?.fadeGain(at: 0.5), 0.5)
        model.undo()
        XCTAssertEqual(model.values.segments[0].fadeIn, 0)
    }

    func testWaveformSliceCoversTheSegmentInTimelineSeconds() async throws {
        let model = try await videoModel()
        let segment = try XCTUnwrap(model.values.segments.first)
        try await eventually { model.waveform(for: segment, in: 0...2) != nil }
        let whole = try XCTUnwrap(model.waveform(for: segment, in: 0...2))
        XCTAssertEqual(whole.start, 0)
        XCTAssertEqual(whole.duration, 2)
        XCTAssertTrue(whole.peaks.contains { $0 > 0.05 })
        var half = segment
        half.end = 1
        let slice = try XCTUnwrap(model.waveform(for: half, in: 3...4))
        XCTAssertEqual(slice.start, 3)
        XCTAssertEqual(Double(slice.peaks.count), Double(whole.peaks.count) / 2, accuracy: 2)
        var late = segment
        late.start = 1
        let tail = try XCTUnwrap(model.waveform(for: late, in: 0...1))
        XCTAssertEqual(tail.peaks, Array(whole.peaks.suffix(tail.peaks.count)))
        XCTAssertEqual(Double(tail.peaks.count), Double(whole.peaks.count) / 2, accuracy: 2)
    }

    func testAudioTrimFadesMustFitTheRange() async throws {
        let directory = try workspace()
        let support = directory.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        let model = AudioTrimModel(
            url: try audioFixture(in: directory), staging: StagingArea(supportDirectory: support), prefill: nil)
        addTeardownBlock { await model.close() }
        await model.load()
        XCTAssertTrue(model.canSave)
        model.fadeIn = 1.5
        model.fadeOut = 1
        XCTAssertFalse(model.canSave)
        XCTAssertFalse(model.fadesFit)
        model.fadeOut = 0.5
        XCTAssertTrue(model.canSave)
        let ramp = FadeRamp(duration: model.end - model.start, fadeIn: model.fadeIn, fadeOut: model.fadeOut)
        XCTAssertEqual(ramp.fadeIn, 1.5, "fitting fades are exported as chosen")
    }

    func testSplittingAFadedSegmentKeepsFadesAtTheOuterEdges() async throws {
        let model = try await videoModel()
        model.binding(\.fadeIn).wrappedValue = 0.5
        model.binding(\.fadeOut).wrappedValue = 0.5
        model.seek(1)
        try await eventually { model.canSplit }
        model.split()
        try await eventually { model.values.segments.count == 2 }
        XCTAssertEqual(model.values.segments.map(\.fadeIn), [0.5, 0])
        XCTAssertEqual(model.values.segments.map(\.fadeOut), [0, 0.5])
    }

    func testClipboardSuggestionDetectsLinksBeforeReadingThem() async throws {
        let name = NSPasteboard.Name("MacEaseTests-\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        addTeardownBlock { pasteboard.releaseGlobally() }
        let model = MediaDownloadModel(destination: try workspace())
        addTeardownBlock { await model.close() }
        pasteboard.clearContents()
        pasteboard.setString("not a link", forType: .string)
        await model.checkClipboard(name)
        XCTAssertFalse(model.clipboardHasURL)
        pasteboard.clearContents()
        pasteboard.setString("https://example.invalid/watch?v=1", forType: .string)
        await model.checkClipboard(name)
        XCTAssertTrue(model.clipboardHasURL)
        model.pasteClipboardURLs(name)
        XCTAssertEqual(model.urls, "https://example.invalid/watch?v=1")
        XCTAssertFalse(model.clipboardHasURL)
        model.cancelAnalysis()
    }

    private func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MacEaseAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func audioFixture(in directory: URL) throws -> URL {
        let sampleRate = 48_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData).pointee
        for frame in 0..<Int(buffer.frameLength) {
            channel[frame] = Float(sin(2 * .pi * 440 * Double(frame) / sampleRate) * 0.5)
        }
        let url = directory.appending(path: "tone.wav")
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        try writer.write(from: buffer)
        return url
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Timed out waiting for the editor")
    }
}
