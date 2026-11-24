import AVFoundation
import CoreImage
import ImageIO
import MediaToolbox
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

    func testSaveStaysOpenUntilSuccessAndKeepsFailureRetryable() async throws {
        let model = try await photoModel()
        model.change { $0.photo.geometry.quarterTurns = 1 }
        try await eventually { model.canSave }
        func finishing(with result: ItemOutcome?) -> (Batch, Engine.Settings) -> Task<BatchOutcome?, Never> {
            { batch, _ in
                XCTAssertEqual(model.savingBatchID, batch.id)
                XCTAssertFalse(model.canSave)
                let inputs = [[model.url]]
                return Task {
                    result.map {
                        BatchOutcome(
                            batchID: batch.id, operation: batch.operation, inputs: inputs, outcomes: [$0],
                            clipboardText: nil, reportText: nil, record: nil, historyFailed: false,
                            details: [ItemDetails()])
                    }
                }
            }
        }

        let failed = await model.save(replacingOriginal: false, run: finishing(with: .failed(.protectionDiskFull)))
        XCTAssertFalse(failed)
        XCTAssertNil(model.savingBatchID)
        XCTAssertEqual(
            model.saveFailure,
            UserMessages.describeResult(.protectionDiskFull, file: model.url.lastPathComponent))
        XCTAssertTrue(model.canSave)

        let cancelled = await model.save(replacingOriginal: false, run: finishing(with: .failed(.cancelled)))
        XCTAssertFalse(cancelled)
        XCTAssertNil(model.saveFailure)
        let interrupted = await model.save(replacingOriginal: false, run: finishing(with: nil))
        XCTAssertFalse(interrupted)

        let output = model.url.deletingLastPathComponent().appending(path: "photo_edited.png")
        let saved = await model.save(
            replacingOriginal: false, run: finishing(with: .succeeded(outputs: [output], warnings: [])))
        XCTAssertTrue(saved)
        XCTAssertNil(model.saveFailure)
        XCTAssertNil(model.savingBatchID)
    }

    func testPartialPhotoSaveRetriesOnlyUnsavedPhotosAfterFailureOrCancellation() async throws {
        for cancelled in [false, true] {
            let model = try await photoModel(additionalPhoto: true)
            let sources = model.photoURLs
            let savedStamp = try MediaSourceStamp(url: sources[0])
            model.change { $0.photo.geometry.quarterTurns = 1 }
            model.applyPhotoEdits(toAll: true)
            try await eventually { model.canSave }
            let engine = try JobEngine(supportDirectory: try workspace(), concurrency: 1)
            let completed = await model.save(replacingOriginal: true) { batch, settings in
                let remaining = WorkItem(inputs: [sources[1]]) { _ in
                    if cancelled { throw CancellationError() }
                    throw EngineError.protectionDiskFull
                }
                return Task {
                    let outcome = await engine.run(
                        Batch(operation: batch.operation, items: [batch.items[0], remaining]), settings: settings
                    ) { _ in }
                    self.addTeardownBlock { _ = try await engine.undo(outcome.batchID) }
                    if case .succeeded(let outputs, _) = outcome.outcomes[0] {
                        XCTAssertEqual(outputs, [sources[0]])
                    } else {
                        XCTFail("The first photo must commit before retry")
                    }
                    return outcome
                }
            }
            XCTAssertFalse(completed)
            XCTAssertThrowsError(try savedStamp.validate(sources[0]))
            try await eventually { model.canSave || model.failure != nil }
            XCTAssertNil(model.failure)
            XCTAssertEqual(model.saveFailure == nil, cancelled)
            XCTAssertEqual(model.photoURLs, [sources[1]])
            XCTAssertEqual(model.url, sources[1])
            XCTAssertNil(model.values.photoEdits[sources[0]])
            let retry = try model.makeSave(replacingOriginal: true)
            XCTAssertEqual(retry.batch.items.map(\.inputs), [[sources[1]]])
            model.undo()
            XCTAssertNil(model.values.photoEdits[sources[0]])
            model.redo()
            XCTAssertEqual(try model.makeSave(replacingOriginal: true).batch.items.map(\.inputs), [[sources[1]]])
            try await eventually { model.canSave || model.failure != nil }
            let saved = await model.save(replacingOriginal: true) { batch, settings in
                Task {
                    let outcome = await engine.run(batch, settings: settings) { _ in }
                    self.addTeardownBlock { _ = try await engine.undo(outcome.batchID) }
                    return outcome
                }
            }
            XCTAssertTrue(saved, model.saveFailure ?? "Retry did not finish")
        }
    }

    func testSavingBlocksKeyboardShortcutsAndModelEdits() async throws {
        let model = try await videoModel()
        model.change { $0.speed = 2 }
        try await eventually { model.canSave }
        model.seek(0.5)
        XCTAssertTrue(model.canSplit)
        let shortcutView = EditorKeyboardShortcuts.ShortcutView()
        shortcutView.model = model
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = shortcutView
        defer { shortcutView.stopMonitoring(); window.close() }
        let shortcuts: [(UInt16, String, NSEvent.ModifierFlags)] = [
            (51, "\u{7f}", []), (11, "b", .command), (34, "i", []), (31, "o", []),
            (46, "m", []), (49, " ", []), (24, "=", .command),
        ]
        let events = try shortcuts.map { code, characters, modifiers in
            try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        let snapshot = model.values
        model.play()
        XCTAssertTrue(model.playing)
        let saved = await model.save(replacingOriginal: false) { batch, _ in
            for event in events { NSApp.sendEvent(event) }
            XCTAssertFalse(model.original)
            XCTAssertFalse(model.playing)
            XCTAssertEqual(model.timelineZoom, 1)
            XCTAssertFalse(model.canSplit)
            model.deleteSelection()
            model.split()
            model.setVideoBoundary(0.25, start: true)
            model.setTrimBoundaryAtPlayhead(start: false)
            model.duplicateSelection()
            model.change { $0.speed = 4 }
            model.undo()
            model.redo()
            model.reset()
            XCTAssertEqual(model.values, snapshot)
            XCTAssertFalse(model.splitting)
            XCTAssertFalse(model.trimming)
            return Task {
                BatchOutcome(
                    batchID: batch.id, operation: batch.operation, inputs: batch.items.map(\.inputs),
                    outcomes: [.failed(.protectionDiskFull)], clipboardText: nil, reportText: nil,
                    record: nil, historyFailed: false, details: [ItemDetails()])
            }
        }
        XCTAssertFalse(saved)
        await model.finishBoundaryInput()
        XCTAssertEqual(model.values, snapshot)
        NSApp.sendEvent(events[4])
        XCTAssertTrue(model.original, "The monitor must resume after saving")
        model.deleteSelection()
        XCTAssertTrue(model.values.segments.isEmpty)
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
        let host = NSHostingView(
            rootView: MediaEditorView(
                model: model, close: {}, save: { _, _ in Task { nil } }, runFrame: { _, _ in Task { nil } },
                progress: { _ in nil }))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_280, height: 720), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await eventually { self.textFields(in: host).contains { $0.isEditable && $0.stringValue == "0:00.000" } }
        let field = try XCTUnwrap(textFields(in: host).first { $0.isEditable && $0.stringValue == "0:00.000" })
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
        try await eventually { field.stringValue == "0:00.125" }
        model.undo()
        XCTAssertEqual(model.values.start, 0)
        XCTAssertFalse(model.canUndo)
    }

    func testFastFrameSnappingAndBlurKeepDraftAndSingleUndo() async throws {
        let model = try await videoModel()
        model.setVideoBoundary(0, start: true)
        await model.finishBoundaryInput()
        let host = NSHostingView(
            rootView: MediaEditorView(
                model: model, close: {}, save: { _, _ in Task { nil } }, runFrame: { _, _ in Task { nil } },
                progress: { _ in nil }))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1_280, height: 720), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await eventually { self.textFields(in: host).contains { $0.isEditable && $0.stringValue == "0:00.000" } }
        let field = try XCTUnwrap(textFields(in: host).first { $0.isEditable && $0.stringValue == "0:00.000" })
        XCTAssertGreaterThan(field.frame.width, 50)
        XCTAssertTrue(window.makeFirstResponder(field))
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("0.1", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        await model.finishBoundaryInput()
        XCTAssertEqual(model.values.start, 2.0 / 24, accuracy: 0.000_001)
        XCTAssertEqual(editor.string, "0.1")
        editor.insertText("0.16", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertTrue(window.makeFirstResponder(nil))
        try await eventually { field.stringValue == "0:00.167" && !model.hasPendingBoundaryInput }
        XCTAssertEqual(model.values.start, 4.0 / 24, accuracy: 0.000_001)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(window.makeFirstResponder(nil))
        await model.finishBoundaryInput()
        XCTAssertEqual(model.values.start, 4.0 / 24, accuracy: 0.000_001)
        model.undo()
        XCTAssertEqual(model.values.start, 0)
        XCTAssertFalse(model.canUndo)
        try await eventually { field.stringValue == "0:00.000" }
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

    func testMarkupEditsAreSingleUndoStepsWithSelection() async throws {
        let model = try await photoModel()
        let rect = EditCrop(x: 0.1, y: 0.1, width: 0.3, height: 0.2)
        let id = try XCTUnwrap(model.addOverlay(.redaction(rect: rect, style: .mosaic)))
        XCTAssertEqual(model.values.selectedOverlayID, id)
        XCTAssertEqual(model.markupOverlays.map(\.id), [id])
        XCTAssertTrue(model.changesColor)

        model.beginInteraction()
        for x in [0.2, 0.3, 0.4] {
            model.updateOverlay(id, .redaction(rect: EditCrop(x: x, y: 0.1, width: 0.3, height: 0.2), style: .mosaic))
        }
        model.endInteraction()
        model.updateOverlay(id, .redaction(rect: EditCrop(x: 0.4, y: 0.1, width: 0.3, height: 0.2), style: .solid))
        model.deleteOverlay(id)
        XCTAssertTrue(model.markupOverlays.isEmpty)
        XCTAssertNil(model.values.selectedOverlayID)

        model.undo()
        XCTAssertEqual(
            model.selectedOverlay?.mark,
            .redaction(rect: EditCrop(x: 0.4, y: 0.1, width: 0.3, height: 0.2), style: .solid))
        model.undo()
        XCTAssertEqual(
            model.selectedOverlay?.mark,
            .redaction(rect: EditCrop(x: 0.4, y: 0.1, width: 0.3, height: 0.2), style: .mosaic))
        model.undo()
        XCTAssertEqual(model.selectedOverlay?.mark, .redaction(rect: rect, style: .mosaic), "one step per drag")
        model.undo()
        XCTAssertTrue(model.markupOverlays.isEmpty)
        XCTAssertFalse(model.canUndo)

        XCTAssertNil(model.addOverlay(.text("  ", at: EditPoint(x: 0.5, y: 0.5), color: .red, size: .small)))
        XCTAssertNil(model.addOverlay(.arrow(from: EditPoint(), to: EditPoint(x: 0.001), color: .red, size: .small)))
        XCTAssertTrue(model.markupOverlays.isEmpty, "invalid marks are never added")
        for index in 0..<EditOverlay.maximumCount {
            let x = Double(index % 10) / 10
            XCTAssertNotNil(
                model.addOverlay(
                    .box(rect: EditCrop(x: x, y: 0, width: 0.05, height: 0.05), color: .blue, size: .small)))
        }
        XCTAssertFalse(model.canAddOverlay)
        XCTAssertNil(model.addOverlay(.box(rect: rect, color: .blue, size: .small)))
    }

    func testMarkupCoordinatesFollowCropRotationFlipAndStraighten() async throws {
        let model = try await photoModel()
        model.change {
            $0.photo.geometry.quarterTurns = 1
            $0.photo.geometry.flipHorizontal = true
            $0.photo.geometry.straighten = 12
            $0.photo.geometry.crop = EditCrop(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
        }
        for point in [CGPoint(x: 0.3, y: 0.7), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.9, y: 0.15)] {
            let output = model.outputPoint(model.canvasPoint(point, clamped: false))
            XCTAssertEqual(output.x, point.x, accuracy: 1e-9)
            XCTAssertEqual(output.y, point.y, accuracy: 1e-9)
        }

        let dragged = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.25)
        let mark = try XCTUnwrap(model.newMark(.redact, outputRect: dragged))
        guard case .redaction(let rect, _) = mark else { return XCTFail("expected a redaction") }
        for corner in [
            CGPoint(x: dragged.minX, y: dragged.minY), CGPoint(x: dragged.maxX, y: dragged.minY),
            CGPoint(x: dragged.maxX, y: dragged.maxY), CGPoint(x: dragged.minX, y: dragged.maxY),
        ] {
            let canvas = model.canvasPoint(corner)
            XCTAssertTrue(
                canvas.x >= rect.x - 1e-9 && canvas.x <= rect.x + rect.width + 1e-9
                    && canvas.y >= rect.y - 1e-9 && canvas.y <= rect.y + rect.height + 1e-9,
                "a straightened redaction covers the whole dragged area")
        }

        let id = try XCTUnwrap(
            model.addOverlay(.text("Name", at: model.canvasPoint(CGPoint(x: 0.5, y: 0.5)), color: .white, size: .large))
        )
        model.nudgeOverlay(id, dx: MediaEditorModel.overlayNudge, dy: 0)
        guard case .text(_, let at, _, _) = model.selectedOverlay?.mark else { return XCTFail("expected text") }
        let moved = model.outputPoint(at)
        XCTAssertEqual(moved.x, 0.5 + MediaEditorModel.overlayNudge, accuracy: 1e-9, "nudges follow the screen")
        XCTAssertEqual(moved.y, 0.5, accuracy: 1e-9)
    }

    func testVideoOverlayRangeSnapsToPlayheadFramesAndAppearsWhereverItsFramesPlay() async throws {
        let model = try await videoModel()
        model.category = .markup
        model.seek(0.5)
        let id = try XCTUnwrap(
            model.addOverlay(.redaction(rect: EditCrop(x: 0, y: 0, width: 0.5, height: 1), style: .blur)))
        let added = try XCTUnwrap(model.selectedTimedOverlay)
        XCTAssertEqual(added.sourceIndex, 0)
        XCTAssertEqual(added.start, 0)
        XCTAssertEqual(added.end, model.values.sources[0].duration)

        model.seek(0.51)
        await model.setOverlayBoundaryAtPlayhead(start: true)
        model.seek(1.01)
        await model.setOverlayBoundaryAtPlayhead(start: false)
        let ranged = try XCTUnwrap(model.selectedTimedOverlay)
        XCTAssertEqual(ranged.start, 12.0 / 24, accuracy: 1e-6, "includes the frame at the playhead")
        XCTAssertEqual(ranged.end, 25.0 / 24, accuracy: 1e-6)
        let timeline = try XCTUnwrap(model.timeline)
        XCTAssertEqual(timeline.overlays(at: 0.5).map(\.id), [id])
        XCTAssertEqual(timeline.overlays(at: 1.03).map(\.id), [id])
        XCTAssertTrue(timeline.overlays(at: 0.45).isEmpty)
        XCTAssertTrue(timeline.overlays(at: 1.05).isEmpty)

        model.seek(1.5)
        await model.setOverlayBoundaryAtPlayhead(start: true)
        XCTAssertEqual(model.selectedTimedOverlay?.start ?? 0, 36.0 / 24, accuracy: 1e-6)
        XCTAssertEqual(model.selectedTimedOverlay?.end ?? 0, 2, accuracy: 1e-6, "a start after the end reopens it")
        model.undo()
        XCTAssertEqual(model.selectedTimedOverlay, ranged)

        let original = try XCTUnwrap(model.values.segments.first)
        model.change {
            var left = original
            left.end = 1
            var right = original
            right.id = UUID()
            right.start = 1
            $0.segments = [right, left]
        }
        let ranges = try XCTUnwrap(model.timeline).outputRanges(of: ranged)
        XCTAssertEqual(ranges.count, 2, "split and reordered frames appear in two places")
        XCTAssertEqual(ranges[0].lowerBound, 0, accuracy: 1e-6)
        XCTAssertEqual(ranges[0].upperBound, 1.0 / 24, accuracy: 1e-6)
        XCTAssertEqual(ranges[1].lowerBound, 1.5, accuracy: 1e-6)
        XCTAssertEqual(ranges[1].upperBound, 2, accuracy: 1e-6)

        model.selectOverlay(nil)
        model.seek(0.2)
        model.selectOverlay(id)
        XCTAssertEqual(model.position, 0, accuracy: 1e-6, "selecting a hidden overlay shows its first frame")
    }

    func testMarkupOnHDRPhotoExplainsTheSDRCopy() async throws {
        let model = try await photoModel(hdr: true)
        XCTAssertNil(model.newFileReason)
        model.addOverlay(.box(rect: EditCrop(x: 0.1, y: 0.1, width: 0.5, height: 0.5), color: .yellow, size: .medium))
        XCTAssertEqual(model.newFileReason, String(localized: "Markup on HDR media saves a new SDR file."))
        XCTAssertTrue(model.forcesNewFile)
        XCTAssertTrue(model.convertsToSDR)
    }

    func testSavedPhotoAndVideoCarryTheirRedactions() async throws {
        for model in [try await photoModel(), try await videoModel()] {
            model.addOverlay(.redaction(rect: EditCrop(x: 0, y: 0, width: 0.5, height: 1), style: .solid))
            try await eventually { model.canSave || model.failure != nil }
            XCTAssertNil(model.failure)
            let planned = try model.makeSave(replacingOriginal: false)
            let engine = try JobEngine(supportDirectory: try workspace(), concurrency: 1)
            let result = await engine.run(planned.batch, settings: planned.settings) { _ in }
            guard case .succeeded(let outputs, _) = result.outcomes.first, let output = outputs.first else {
                return XCTFail("save failed: \(result.outcomes)")
            }
            let image: CGImage
            if model.isVideo {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                image = try await generator.image(at: CMTime(value: 1, timescale: 1)).image
            } else {
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
                image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            }
            let left = try rgb(image, x: image.width / 4, y: image.height / 2)
            let right = try rgb(image, x: image.width * 3 / 4, y: image.height / 2)
            XCTAssertLessThan(left.max() ?? 1, 0.06, "\(model.isVideo ? "video" : "photo") redaction is saved")
            XCTAssertGreaterThan(right.max() ?? 0, 0.2, "outside the redaction stays visible")
        }
    }

    func testSaveFrameExportsTheEditedPlayheadFrameWhileEditingContinues() async throws {
        let model = try await videoModel()
        model.addOverlay(.redaction(rect: EditCrop(x: 0, y: 0, width: 0.5, height: 1), style: .solid))
        try await eventually { model.canSaveFrame }
        model.seek(1)
        let engine = try JobEngine(supportDirectory: try workspace(), concurrency: 1)
        let (gate, open) = AsyncStream<Void>.makeStream()
        let saving = Task {
            await model.saveFrame { batch, settings in
                Task {
                    for await _ in gate { break }
                    return await engine.run(batch, settings: settings) { _ in }
                }
            }
        }
        try await eventually { model.frameBatchID != nil }
        XCTAssertFalse(model.canSaveFrame)
        XCTAssertNil(model.savingBatchID)
        model.change { $0.photo.geometry.quarterTurns = 1 }
        XCTAssertEqual(model.values.photo.geometry.quarterTurns, 1, "editing continues during the frame export")
        open.yield()
        await saving.value
        XCTAssertNil(model.frameBatchID)
        guard case .saved(let output) = model.frameNote else {
            return XCTFail("frame not saved: \(String(describing: model.frameNote))")
        }
        XCTAssertEqual(output.deletingLastPathComponent(), model.url.deletingLastPathComponent())
        XCTAssertTrue(output.lastPathComponent.hasPrefix("clip-0_frame_0-01.000"), output.lastPathComponent)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(CGSize(width: image.width, height: image.height), model.sourceSize, "planned before rotating")
        XCTAssertLessThan(try rgb(image, x: image.width / 4, y: image.height / 2).max() ?? 1, 0.06)
        XCTAssertGreaterThan(try rgb(image, x: image.width * 3 / 4, y: image.height / 2).max() ?? 0, 0.2)
    }

    func testSaveFrameReportsAFailedExport() async throws {
        let model = try await videoModel()
        await model.saveFrame { batch, _ in
            let inputs = [[model.url]]
            return Task {
                BatchOutcome(
                    batchID: batch.id, operation: batch.operation, inputs: inputs,
                    outcomes: [.failed(.protectionDiskFull)], clipboardText: nil, reportText: nil, record: nil,
                    historyFailed: false, details: [ItemDetails()])
            }
        }
        XCTAssertEqual(
            model.frameNote, .failed(UserMessages.describeResult(.protectionDiskFull, file: "clip-0.mp4")))
        XCTAssertTrue(model.canSaveFrame, "a failed frame export can be retried")
        XCTAssertEqual(japanese("Saving Frame…"), "フレームを保存中…")
        XCTAssertEqual(japanese("Saved “%@”"), "“%@”を保存しました")
    }

    private func rgb(_ image: CGImage, x: Int, y: Int) throws -> [Double] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(
            CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return pixel.prefix(3).map { Double($0) / 255 }
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

    func testEditedPlaybackKeepsRenderingAudioAcrossReplays() async throws {
        let directory = try workspace()
        let source = try synthesizedVideoFixture(in: directory)
        let support = directory.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        let model = MediaEditorModel(
            urls: [source], isVideo: true, settings: Engine.Settings(),
            staging: StagingArea(supportDirectory: support))
        addTeardownBlock { await model.close() }
        model.load()
        try await eventually { model.canPlay || model.failure != nil }
        XCTAssertNil(model.failure)

        model.seek(1.5)
        try await eventually { model.canSplit }
        model.split()
        try await eventually { model.values.segments.count == 2 && !model.preparingPlayback && model.canPlay }
        model.seek(2.5)
        try await eventually { model.canSplit }
        model.split()
        try await eventually { model.values.segments.count == 3 && !model.preparingPlayback && model.canPlay }
        model.seek(4.0)
        try await eventually { model.canSplit }
        model.split()
        try await eventually { model.values.segments.count == 4 && !model.preparingPlayback && model.canPlay }
        model.selectSegment(model.values.segments[3].id)
        model.deleteSelection()
        try await eventually { model.values.segments.count == 3 && !model.preparingPlayback && model.canPlay }
        model.selectSegment(model.values.segments[1].id)
        model.deleteSelection()
        try await eventually { model.values.segments.count == 2 && !model.preparingPlayback && model.canPlay }

        model.zoomTimeline(by: 4)
        model.zoom = 2
        let player = try XCTUnwrap(model.player)
        let playerItem = try XCTUnwrap(player.currentItem)
        try await eventually { playerItem.status == .readyToPlay }
        let meter = PlaybackAudioMeter()
        try meter.install(on: playerItem)

        for (attempt, target) in [0.1, 2.0, 0.5, 2.0, 0.2].enumerated() {
            model.skim(target + 0.15)
            try await Task.sleep(for: .milliseconds(30))
            model.skim(nil)
            model.seek(target)
            try await Task.sleep(for: .milliseconds(60))
            meter.reset()
            model.play()
            try await eventually { player.rate == 1 && player.timeControlStatus == .playing }
            try await Task.sleep(for: .milliseconds(300))
            let peak = meter.peak()
            XCTAssertFalse(player.isMuted, "play \(attempt + 1) muted")
            XCTAssertEqual(player.volume, 1, "play \(attempt + 1) volume")
            XCTAssertNil(playerItem.error, "play \(attempt + 1) item error")
            XCTAssertEqual(playerItem.status, .readyToPlay, "play \(attempt + 1) item status")
            XCTAssertGreaterThan(peak, 0.01, "play \(attempt + 1) at \(target)s rendered silence")
            model.pause()
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    func testFreezeAndReversedPlaybackKeepRenderingAudioAcrossReplays() async throws {
        let directory = try workspace()
        let source = try synthesizedVideoFixture(in: directory)
        let support = directory.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        let staging = StagingArea(supportDirectory: support)
        let target = VideoSegment(start: 1.5, end: 2.5)
        var edit = VideoEdit()
        edit.segments = [
            VideoSegment(start: 0, end: 1),
            VideoSegment(start: 1.013, end: 1.046, volume: 0, freezeDuration: 0.5),
            target,
            VideoSegment(start: 3, end: 4),
        ]
        let reversed = try await VideoSegmentReverser.reverse(
            segmentID: target.id, in: edit, primaryURL: source, staging: staging)
        let sources = try XCTUnwrap(reversed.sources)
        addTeardownBlock {
            for clip in sources.dropFirst() {
                VideoSegmentReverser.cleanupStagedSource(clip.url, in: staging)
            }
        }
        let playback = try await VideoEditorPlayback.joined(
            urls: sources.map(\.url), edit: reversed, sourceSize: CGSize(width: 160, height: 120))
        let playerItem = AVPlayerItem(asset: playback.asset)
        playerItem.videoComposition = playback.videoComposition
        playerItem.audioMix = playback.audioMix
        let player = AVPlayer(playerItem: playerItem)
        addTeardownBlock { player.pause() }
        try await eventually { playerItem.status == .readyToPlay }
        let meter = PlaybackAudioMeter()
        try meter.install(on: playerItem)
        for target in [0.1, 1.6, 2.6, 1.7, 0.2, 2.7] {
            player.pause()
            await player.seek(
                to: CMTime(seconds: target, preferredTimescale: 60_000),
                toleranceBefore: .zero, toleranceAfter: .zero)
            meter.reset()
            player.play()
            try await eventually { player.rate == 1 && player.timeControlStatus == .playing }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertNil(playerItem.error)
            XCTAssertGreaterThan(meter.peak(), 0.01, "Replay at \(target)s rendered silence")
        }
    }

    func testCloseWaitsForSaveWithoutCancellingIt() async throws {
        let model = try await photoModel()
        model.change { $0.photo.geometry.quarterTurns = 1 }
        try await eventually { model.canSave }
        var release: CheckedContinuation<BatchOutcome?, Never>?
        var saveWasCancelled = false
        let saving = Task {
            await model.save(replacingOriginal: false) { _, _ in
                Task {
                    let outcome: BatchOutcome? = await withCheckedContinuation { release = $0 }
                    saveWasCancelled = Task.isCancelled
                    return outcome
                }
            }
        }
        try await eventually { release != nil }
        var closeFinished = false
        let closing = Task {
            await model.close()
            closeFinished = true
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(closeFinished)
        release?.resume(returning: nil)
        _ = await saving.value
        await closing.value
        XCTAssertTrue(closeFinished)
        XCTAssertFalse(saveWasCancelled)
    }

    func testReversedAndFrozenAudioHasExactTimelinePlacement() async throws {
        let directory = try workspace()
        let source = try synthesizedVideoFixture(in: directory)
        let support = directory.appending(path: "sync-support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        let staging = StagingArea(supportDirectory: support)
        let editor = try await VideoEditorSource.open(source, staging: staging)
        addTeardownBlock { await editor.close() }
        let reversedSegment = VideoSegment(start: 1.5, end: 2.5)
        var edit = VideoEdit()
        edit.segments = [
            VideoSegment(start: 0, end: 1),
            VideoSegment(start: 1.013, end: 1.046, volume: 0, freezeDuration: 0.5),
            reversedSegment,
            VideoSegment(start: 3, end: 4),
        ]
        let reversed = try await editor.reverse(segmentID: reversedSegment.id, in: edit)
        let playback = try await editor.playback(edit: reversed)
        let preview = try await renderedEditorAudio(asset: playback.asset, mix: playback.audioMix)
        let engine = try JobEngine(supportDirectory: directory.appending(path: "export-support"), concurrency: 1)
        let result = await engine.run(
            MediaEditing.video(url: source, edit: reversed, settings: Engine.Settings()), settings: Engine.Settings()
        ) { _ in }
        guard case .succeeded(let outputs, _) = result.outcomes.first, let output = outputs.first else {
            XCTFail("Audio placement export failed")
            return
        }
        let exported = try await renderedEditorAudio(asset: AVURLAsset(url: output), mix: nil)
        for (label, samples) in [("preview", preview), ("export", exported)] {
            XCTAssertEqual(Double(samples.count / 2) / 48_000, 3.5, accuracy: 0.03)
            for (start, end, audible) in [(0.8, 0.98, true), (1.02, 1.48, false), (1.52, 1.8, true), (2.45, 2.7, true)]
            {
                let first = Int(start * 48_000) * 2
                let last = min(samples.count, Int(end * 48_000) * 2)
                XCTAssertGreaterThan(last, first)
                let square = samples[first..<last].reduce(0.0) { $0 + Double($1 * $1) }
                let rms = sqrt(square / Double(last - first))
                if audible {
                    XCTAssertGreaterThan(rms, 0.02, "\(label) audio at \(start)...\(end)")
                } else {
                    XCTAssertLessThan(rms, 0.002, "\(label) audio at \(start)...\(end)")
                }
            }
        }
    }

    private func renderedEditorAudio(asset: AVAsset, mix: AVAudioMix?) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(tracks.isEmpty)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            ])
        output.audioMix = mix
        output.audioTimePitchAlgorithm = .timeDomain
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        while let sample = await output.nextSample() {
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = chunk.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return OSStatus(kCMBlockBufferBadLengthParameterErr) }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
            }
            XCTAssertEqual(status, noErr)
            samples += chunk
        }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        return samples
    }

    func testBackgroundMusicPlaybackStaysAudibleAcrossReplays() async throws {
        let directory = try workspace()
        let source = try synthesizedVideoFixture(in: directory)
        let silentSource = try synthesizedSilentVideoFixture(in: directory)
        let songURL = try audioFixture(in: directory)
        let support = directory.appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false)
        let staging = StagingArea(supportDirectory: support)
        var music = try BackgroundMusic.load(from: songURL)
        music.volume = 0.4

        var edit = VideoEdit()
        edit.segments = [
            VideoSegment(start: 0, end: 0.6),
            VideoSegment(start: 0.6, end: 0.634, volume: 0, freezeDuration: 0.8),
            VideoSegment(start: 0.6, end: 1.4),
        ]
        edit.music = music
        let editor = try await VideoEditorSource.open(source, staging: staging)
        addTeardownBlock { await editor.close() }
        let playback = try await editor.playback(edit: edit)
        let playerItem = AVPlayerItem(asset: playback.asset)
        playerItem.videoComposition = playback.videoComposition
        playerItem.audioMix = playback.audioMix
        let player = AVPlayer(playerItem: playerItem)
        addTeardownBlock { player.pause() }
        try await eventually { playerItem.status == .readyToPlay }
        let meter = PlaybackAudioMeter()
        try meter.install(on: playerItem)
        for target in [0.1, 0.75, 1.5, 0.8, 0.2] {
            player.pause()
            await player.seek(
                to: CMTime(seconds: target, preferredTimescale: 60_000),
                toleranceBefore: .zero, toleranceAfter: .zero)
            meter.reset()
            player.play()
            try await eventually { player.rate == 1 && player.timeControlStatus == .playing }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertNil(playerItem.error)
            XCTAssertGreaterThan(meter.peak(), 0.01, "Music replay at \(target)s rendered silence")
        }
        player.pause()

        var silentEdit = VideoEdit()
        silentEdit.segments = [VideoSegment(start: 0, end: 2.0)]
        silentEdit.music = music
        let silentEditor = try await VideoEditorSource.open(silentSource, staging: staging)
        addTeardownBlock { await silentEditor.close() }
        let silentPlayback = try await silentEditor.playback(edit: silentEdit)
        let silentItem = AVPlayerItem(asset: silentPlayback.asset)
        silentItem.videoComposition = silentPlayback.videoComposition
        silentItem.audioMix = silentPlayback.audioMix
        let silentPlayer = AVPlayer(playerItem: silentItem)
        addTeardownBlock { silentPlayer.pause() }
        try await eventually { silentItem.status == .readyToPlay }
        let silentMeter = PlaybackAudioMeter()
        try silentMeter.install(on: silentItem)
        for target in [0.1, 0.9, 0.3] {
            silentPlayer.pause()
            await silentPlayer.seek(
                to: CMTime(seconds: target, preferredTimescale: 60_000),
                toleranceBefore: .zero, toleranceAfter: .zero)
            silentMeter.reset()
            silentPlayer.play()
            try await eventually { silentPlayer.rate == 1 && silentPlayer.timeControlStatus == .playing }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertNil(silentItem.error)
            XCTAssertGreaterThan(silentMeter.peak(), 0.01, "Silent video music replay at \(target)s rendered silence")
        }
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

    private func synthesizedVideoFixture(in directory: URL) throws -> URL {
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let ffmpeg = resources.appending(path: "media-tools/bin/ffmpeg")
        let output = directory.appending(path: "tone-video.mp4")
        let encoding = Process()
        encoding.executableURL = ffmpeg
        encoding.arguments = [
            "-nostdin", "-y", "-v", "error",
            "-f", "lavfi", "-i", "color=c=blue:s=160x120:r=60000/1001:d=5",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=5",
            "-ac", "2", "-c:v", "h264_videotoolbox", "-b:v", "400k",
            "-c:a", "aac", "-b:a", "128k", output.path,
        ]
        encoding.standardInput = FileHandle.nullDevice
        encoding.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        encoding.standardError = stderr
        try encoding.run()
        encoding.waitUntilExit()
        let details = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(encoding.terminationStatus, 0, details)
        return output
    }

    private func synthesizedSilentVideoFixture(in directory: URL) throws -> URL {
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let ffmpeg = resources.appending(path: "media-tools/bin/ffmpeg")
        let output = directory.appending(path: "silent-video.mp4")
        let encoding = Process()
        encoding.executableURL = ffmpeg
        encoding.arguments = [
            "-nostdin", "-y", "-v", "error",
            "-f", "lavfi", "-i", "color=c=green:s=160x120:r=30:d=3",
            "-an", "-c:v", "h264_videotoolbox", "-b:v", "400k", output.path,
        ]
        encoding.standardInput = FileHandle.nullDevice
        encoding.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        encoding.standardError = stderr
        try encoding.run()
        encoding.waitUntilExit()
        let details = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(encoding.terminationStatus, 0, details)
        return output
    }

    private func japanese(_ key: String) -> String {
        let path = Bundle.main.path(forResource: "ja", ofType: "lproj")
        return path.flatMap(Bundle.init(path:))?.localizedString(forKey: key, value: "missing", table: nil) ?? "missing"
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Timed out waiting for the editor")
    }
}

private final class PlaybackAudioMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var maximumPeak: Float = 0

    func reset() {
        lock.lock()
        maximumPeak = 0
        lock.unlock()
    }

    func peak() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return maximumPeak
    }

    private func record(_ value: Float) {
        lock.lock()
        if value > maximumPeak { maximumPeak = value }
        lock.unlock()
    }

    @MainActor
    func install(on playerItem: AVPlayerItem) throws {
        let currentMix = try XCTUnwrap(playerItem.audioMix)
        let mutableMix = try XCTUnwrap(currentMix.mutableCopy() as? AVMutableAudioMix)
        mutableMix.inputParameters = try mutableMix.inputParameters.map { parameter in
            let editable = try XCTUnwrap(parameter.mutableCopy() as? AVMutableAudioMixInputParameters)
            editable.audioTapProcessor = try makeTap()
            return editable
        }
        playerItem.audioMix = try XCTUnwrap(mutableMix.copy() as? AVAudioMix)
    }

    private func makeTap() throws -> MTAudioProcessingTap {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<PlaybackAudioMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { _, _, _ in },
            unprepare: { _ in },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                guard status == noErr else { return }
                let meter = Unmanaged<PlaybackAudioMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                var maxAbs: Float = 0
                for buffer in UnsafeMutableAudioBufferListPointer(bufferListInOut) {
                    guard let pointer = buffer.mData else { continue }
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let samples = pointer.assumingMemoryBound(to: Float.self)
                    for index in 0..<count {
                        let sample = abs(samples[index])
                        if sample > maxAbs { maxAbs = sample }
                    }
                }
                meter.record(maxAbs)
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(tap)

    }
}
