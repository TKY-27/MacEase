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
        let interaction = model.beginInteraction()
        model.setVideoBoundary(0.63, start: true, in: interaction)
        await model.finishBoundaryInput()
        model.endInteraction(interaction)
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

    func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }

    func testMarkupEditsAreSingleUndoStepsWithSelection() async throws {
        let model = try await photoModel()
        let rect = EditCrop(x: 0.1, y: 0.1, width: 0.3, height: 0.2)
        let id = try XCTUnwrap(model.addOverlay(.redaction(rect: rect, style: .mosaic)))
        XCTAssertEqual(model.values.selectedOverlayID, id)
        XCTAssertEqual(model.markupOverlays.map(\.id), [id])
        XCTAssertTrue(model.changesColor)

        let interaction = model.beginInteraction()
        for x in [0.2, 0.3, 0.4] {
            model.updateOverlay(
                id, .redaction(rect: EditCrop(x: x, y: 0.1, width: 0.3, height: 0.2), style: .mosaic), in: interaction)
        }
        model.endInteraction(interaction)
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
        model.setOverlayBoundaryAtPlayhead(start: true)
        await model.overlayBoundaryTask?.value
        model.seek(1.01)
        model.setOverlayBoundaryAtPlayhead(start: false)
        await model.overlayBoundaryTask?.value
        let ranged = try XCTUnwrap(model.selectedTimedOverlay)
        XCTAssertEqual(ranged.start, 12.0 / 24, accuracy: 1e-6, "includes the frame at the playhead")
        XCTAssertEqual(ranged.end, 25.0 / 24, accuracy: 1e-6)
        let timeline = try XCTUnwrap(model.timeline)
        XCTAssertEqual(timeline.overlays(at: 0.5).map(\.id), [id])
        XCTAssertEqual(timeline.overlays(at: 1.03).map(\.id), [id])
        XCTAssertTrue(timeline.overlays(at: 0.45).isEmpty)
        XCTAssertTrue(timeline.overlays(at: 1.05).isEmpty)

        model.seek(1.5)
        model.setOverlayBoundaryAtPlayhead(start: true)
        await model.overlayBoundaryTask?.value
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

    func testSaveFrameWaitsForTimelineEditsAndIgnoresChangedMusic() async throws {
        let model = try await videoModel()
        model.setVideoBoundary(0.5, start: true)
        XCTAssertFalse(model.canSaveFrame)
        await model.finishBoundaryInput()
        XCTAssertTrue(model.canSaveFrame)
        let selected = try XCTUnwrap(model.selectedSegment)
        model.beginTimelineTrim(selected.id, start: true)
        XCTAssertFalse(model.canSaveFrame)
        await model.endTimelineTrim()
        model.seek(1)
        model.insertFreezeFrame()
        XCTAssertFalse(model.canSaveFrame)
        try await eventually { !model.splitting }
        let song = try audioFixture(in: try workspace())
        model.setMusic(song)
        try await eventually { model.musicTask == nil && !model.preparingPlayback }
        try Data(count: 4_096).write(to: song)
        model.report(EngineError.decodeFailed("music changed"))
        XCTAssertTrue(model.canSaveFrame)
        let engine = try JobEngine(supportDirectory: try workspace(), concurrency: 1)
        await model.saveFrame { batch, settings in Task { await engine.run(batch, settings: settings) { _ in } } }
        guard case .saved(let output) = model.frameNote else {
            return XCTFail("still rejected changed music: \(String(describing: model.frameNote))")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testCloseWaitsForThePlannedFrameExport() async throws {
        let model = try await videoModel()
        let engine = try JobEngine(supportDirectory: try workspace(), concurrency: 1)
        let (gate, release) = AsyncStream<Void>.makeStream()
        var output: URL?
        var cancelled = false
        let saving = Task {
            await model.saveFrame { batch, settings in
                Task {
                    for await _ in gate { break }
                    cancelled = Task.isCancelled
                    let outcome = await engine.run(batch, settings: settings) { _ in }
                    if case .succeeded(let outputs, _) = outcome.outcomes.first { output = outputs.first }
                    return outcome
                }
            }
        }
        try await eventually { model.frameBatchID != nil }
        var closed = false
        let closing = Task {
            await model.close(); closed = true
        }
        await Task.yield()
        XCTAssertFalse(closed)
        release.yield()
        release.finish()
        await saving.value
        await closing.value
        XCTAssertTrue(closed)
        XCTAssertFalse(cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(output).path))
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

    func testFreezeFrameSplitsAtThePlayheadAsOneUndoStepAndLocksTrimming() async throws {
        let model = try await videoModel()
        let before = model.outputDuration
        model.seek(1)
        XCTAssertTrue(model.canInsertFreezeFrame)
        model.insertFreezeFrame()
        try await eventually { model.values.segments.count == 3 }
        let segments = model.values.segments
        let freeze = segments[1]
        XCTAssertEqual(freeze.freezeDuration, MediaEditorModel.defaultFreezeSeconds)
        XCTAssertEqual(freeze.volume, 0)
        XCTAssertEqual(freeze.speed, 1)
        XCTAssertEqual(freeze.end - freeze.start, model.frameDuration, accuracy: 0.002, "holds one source frame")
        XCTAssertLessThanOrEqual(freeze.start, 1)
        XCTAssertGreaterThan(freeze.end, 1)
        XCTAssertEqual(segments[0].end, freeze.start)
        XCTAssertEqual(segments[2].start, freeze.start, "the clip continues from the held frame")
        XCTAssertEqual(model.values.selectedID, freeze.id)
        XCTAssertEqual(model.position, freeze.start, accuracy: 0.000_001)
        XCTAssertEqual(model.outputDuration, before + 2, accuracy: 0.000_001)
        XCTAssertEqual(
            model.timelineRange(for: freeze).upperBound - model.timelineRange(for: freeze).lowerBound, 2,
            accuracy: 0.000_001)

        XCTAssertFalse(model.canInsertFreezeFrame, "a freeze cannot be frozen again")
        XCTAssertFalse(model.canSplit)
        model.beginTimelineTrim(freeze.id, start: true)
        XCTAssertFalse(model.trimming, "freeze frames have no trim handles")
        model.setTrimBoundaryAtPlayhead(start: false)
        model.setVideoBoundary(0.5, start: true)
        await model.finishBoundaryInput()
        XCTAssertEqual(model.values.segments, segments)

        model.binding(\.freezeDuration).wrappedValue = 4.5
        XCTAssertEqual(model.values.segments[1].freezeDuration, 4.5)
        XCTAssertEqual(model.outputDuration, before + 4.5, accuracy: 0.000_001)
        model.undo()
        XCTAssertEqual(model.values.segments, segments)
        model.undo()
        XCTAssertEqual(model.values.segments.count, 1, "inserting is one Undo step")
        XCTAssertEqual(model.outputDuration, before, accuracy: 0.000_001)

        model.seek(0)
        model.insertFreezeFrame()
        try await eventually { model.values.segments.count == 2 }
        XCTAssertTrue(model.values.segments[0].isFreeze, "no empty piece before the first frame")
        XCTAssertEqual(model.values.segments[1].start, model.values.segments[0].start)
        XCTAssertEqual(japanese("Insert Freeze Frame at Playhead"), "再生ヘッドにフリーズフレームを挿入")
        XCTAssertEqual(
            japanese(
                "A freeze frame holds one picture without sound, so trimming, splitting, speed and volume don’t apply."),
            "フリーズフレームは1枚の画像を無音で表示するため、トリミング、分割、速度、音量は使えません。")
    }

    func testReverseLocksEditingDisclosesTheNewFileAndUndoesThroughStagedSources() async throws {
        let model = try await videoModel()
        let original = try XCTUnwrap(model.values.segments.first)
        XCTAssertTrue(model.canToggleReverse)
        model.toggleReverse()
        XCTAssertEqual(model.reverseProgress, 0)
        XCTAssertTrue(model.editingLocked)
        XCTAssertFalse(model.canSave)
        XCTAssertFalse(model.canToggleReverse)
        model.change { $0.photo.geometry.quarterTurns = 1 }
        XCTAssertEqual(model.values.photo.geometry.quarterTurns, 0, "edits wait for the reverse")
        try await eventually { model.reverseProgress == nil }
        XCTAssertNil(model.reverseFailure)
        let reversed = try XCTUnwrap(model.values.segments.first)
        XCTAssertTrue(reversed.isReversed)
        XCTAssertEqual(model.values.sources.count, 2)
        let staged = model.values.sources[1].url
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(model.outputDuration, original.end - original.start, accuracy: 0.05)
        XCTAssertEqual(model.sourceName(reversed), "clip-0.mp4")
        XCTAssertEqual(model.originalSources.map(\.url), [model.url])
        let notice = try XCTUnwrap(model.values.video.joinedExportNotice)
        XCTAssertEqual(model.newFileReason, notice)
        XCTAssertEqual(
            notice,
            "Joined and reversed edits save a new H.264 MP4 file. Transparency is flattened and HDR is converted to SDR."
        )
        XCTAssertTrue(model.forcesNewFile)
        XCTAssertThrowsError(try model.makeSave(replacingOriginal: true))
        try await eventually { model.canSave || model.failure != nil }
        XCTAssertNil(model.failure, "the staged source previews")

        model.undo()
        XCTAssertEqual(model.values.segments, [original], "reversing is one Undo step")
        XCTAssertFalse(model.forcesNewFile)
        model.redo()
        XCTAssertTrue(model.values.segments[0].isReversed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path), "Undo history keeps the staged file")

        model.toggleReverse()
        let restored = try XCTUnwrap(model.values.segments.first)
        XCTAssertFalse(restored.isReversed)
        XCTAssertEqual(restored.start, original.start, accuracy: model.frameDuration)
        XCTAssertEqual(restored.end, original.end, accuracy: model.frameDuration)
        XCTAssertEqual(model.values.sources.count, 1, "restoring drops the unused staged source")
        XCTAssertNil(model.newFileReason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        model.undo()
        XCTAssertTrue(model.values.segments[0].isReversed)
        try await eventually { model.canSave || model.failure != nil }
        XCTAssertNil(model.failure)

        await model.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "closing releases staged files")
    }

    func testCancellingAdoptionReleasesTheCompletedReverse() async throws {
        let model = try await videoModel()
        let previous = model.values.video
        let selected = try XCTUnwrap(model.selectedSegment)
        let session = try XCTUnwrap(model.source(for: selected))
        let reversed = try await session.reverse(segmentID: selected.id, in: previous)
        let sources = try XCTUnwrap(reversed.sources)
        let staged = try XCTUnwrap(sources.last).url
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        let adoption = Task {
            await Task.yield()
            try await model.completeReverse(reversed, replacing: previous, segmentID: selected.id)
        }
        adoption.cancel()
        do {
            try await adoption.value
            XCTFail("cancelled adoption succeeded")
        } catch is CancellationError {}
        XCTAssertEqual(model.values.video, previous)
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
        XCTAssertTrue(stagedDirectories(in: model.staging).isEmpty)

        let secondReversed = try await session.reverse(segmentID: selected.id, in: previous)
        let secondStaged = try XCTUnwrap(secondReversed.sources?.last).url
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondStaged.path))
        model.change { $0.speed = 2 }
        do {
            try await model.completeReverse(secondReversed, replacing: previous, segmentID: selected.id)
            XCTFail("stale adoption succeeded")
        } catch is CancellationError {}
        XCTAssertNil(model.videoSources[secondStaged])
        XCTAssertNil(model.videoDetails[secondStaged])
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondStaged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondStaged.deletingLastPathComponent().path))
        XCTAssertTrue(stagedDirectories(in: model.staging).isEmpty)
    }

    func testCancellingReverseLeavesTheEditUntouched() async throws {
        let directory = try workspace()
        let model = try await videoModel(fixture: try synthesizedVideoFixture(in: directory))
        let original = model.values
        model.toggleReverse()
        XCTAssertNotNil(model.reverseProgress)
        let started = try await waitForStagedDirectories(in: model.staging) { model.reverseProgress != nil }
        XCTAssertNotNil(model.reverseProgress, "reverse finished before cancellation")
        XCTAssertFalse(started.isEmpty, "reverse must begin staging before cancellation")
        model.cancelReverse()
        try await eventually { model.reverseProgress == nil }
        XCTAssertEqual(model.values, original)
        XCTAssertFalse(model.canUndo)
        XCTAssertNil(model.reverseFailure, "cancelling is not a failure")
        XCTAssertTrue(model.canToggleReverse)
        XCTAssertTrue(stagedDirectories(in: model.staging).isEmpty)
        for path in started { XCTAssertFalse(FileManager.default.fileExists(atPath: path)) }
    }

    func testJoinedReverseShowsItsFormatNoticeAndNamesTheFailingSource() async throws {
        let model = try await videoModel(count: 2)
        let second = model.values.segments[1]
        model.selectSegment(second.id)
        model.toggleReverse()
        try await eventually { model.reverseProgress == nil }
        XCTAssertNil(model.reverseFailure)
        XCTAssertEqual(model.newFileReason, model.values.video.joinedExportNotice)
        model.undo()
        let source = model.values.sources[second.sourceIndex].url
        try Data(count: 4_096).write(to: source)
        model.selectSegment(second.id)
        model.toggleReverse()
        try await eventually { model.reverseProgress == nil }
        XCTAssertTrue(try XCTUnwrap(model.reverseFailure).contains(source.lastPathComponent))
        XCTAssertFalse(try XCTUnwrap(model.reverseFailure).contains(model.initialURLs[0].lastPathComponent))
    }

    func testReverseExplainsFreezeAndLengthLimits() async throws {
        let directory = try workspace()
        let long = directory.appending(path: "long.mp4")
        let encoding = Process()
        encoding.executableURL = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "media-tools/bin/ffmpeg")
        encoding.arguments = [
            "-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", "color=c=gray:s=64x48:r=10:d=61",
            "-c:v", "h264_videotoolbox", long.path,
        ]
        try encoding.run()
        encoding.waitUntilExit()
        XCTAssertEqual(encoding.terminationStatus, 0)
        let model = try await videoModel(fixture: long)
        XCTAssertEqual(
            model.reverseUnavailableReason, "Reverse works on segments up to 1:00 long. Split this segment first.")
        XCTAssertFalse(model.canToggleReverse)
        model.toggleReverse()
        XCTAssertNil(model.reverseProgress)
        model.seek(30)
        model.insertFreezeFrame()
        try await eventually { model.selectedSegment?.isFreeze == true }
        XCTAssertEqual(model.reverseUnavailableReason, "A freeze frame can’t be reversed.")
        XCTAssertFalse(model.canToggleReverse)
        XCTAssertEqual(
            japanese("Reverse works on segments up to %@ long. Split this segment first."),
            "逆再生できるのは%@までのセグメントです。先にこのセグメントを分割してください。")
        XCTAssertEqual(japanese("A freeze frame can’t be reversed."), "フリーズフレームは逆再生できません。")
        XCTAssertEqual(
            japanese(
                "Joined and reversed edits save a new H.264 MP4 file. Transparency is flattened and HDR is converted to SDR."
            ),
            "結合・逆再生した動画はH.264のMP4形式で新規保存されます。透明部分は背景色で塗りつぶされ、HDRはSDRに変換されます。")
    }

    func testRemoveSilenceSummarizesHatchesAndCutsAsOneUndoStep() async throws {
        let directory = try workspace()
        let model = try await videoModel(fixture: try pausedSpeechFixture(in: directory))
        let original = model.values.segments
        XCTAssertNil(model.silenceUnavailableReason)
        XCTAssertNil(try model.silencePreview(SilenceRule()), "no summary before analysis")
        model.analyzeSilence()
        XCTAssertNotNil(model.silenceTask)
        try await eventually { model.silenceTask == nil }
        XCTAssertNil(model.silenceFailure)
        let preview = try XCTUnwrap(try model.silencePreview(SilenceRule()))
        XCTAssertEqual(preview.count, 3, "\(preview)")
        let removed = preview.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        XCTAssertEqual(removed, 0.76 + 0.76 + 0.88, accuracy: 0.1)
        XCTAssertEqual(preview[0].lowerBound, 1.12, accuracy: 0.05)
        XCTAssertEqual(preview[0].upperBound, 1.88, accuracy: 0.05)
        XCTAssertEqual(
            try XCTUnwrap(try model.silencePreview(SilenceRule(minimumDuration: 2))), [], "longer pauses only")
        model.showsSilencePreview = true
        XCTAssertEqual(model.silenceHatching, preview)
        model.analyzeSilence()
        XCTAssertNil(model.silenceTask, "levels are cached per source")

        model.removeSilence(SilenceRule())
        XCTAssertEqual(model.values.segments.count, 3)
        XCTAssertEqual(model.outputDuration, 6 - removed, accuracy: 0.05)
        XCTAssertTrue(model.values.segments.allSatisfy { $0.speed == 1 && $0.volume == 1 })
        model.undo()
        XCTAssertEqual(model.values.segments, original, "removing silence is one Undo step")

        model.change { $0.volume = 0 }
        XCTAssertEqual(model.silenceUnavailableReason, "There’s no audible sound to analyze in this video.")
        model.undo()
        model.change {
            $0.segments[0].start = 1.2; $0.segments[0].end = 1.8
        }
        XCTAssertEqual(
            model.describeSilence(EngineError.invalidInput(.emptyInput)),
            "Nothing would be left. Choose a lower threshold or a longer pause.")
        model.removeSilence(SilenceRule())
        XCTAssertEqual(model.silenceFailure, "Nothing would be left. Choose a lower threshold or a longer pause.")
        XCTAssertEqual(model.values.segments.count, 1)

        XCTAssertEqual(String(localized: "Removes \(1) pauses (\("0:01.0"))"), "Removes 1 pause (0:01.0)")
        XCTAssertEqual(String(localized: "Removes \(14) pauses (\("0:42.0"))"), "Removes 14 pauses (0:42.0)")
        XCTAssertEqual(japanese("Removes %lld pauses (%@)"), "%lldか所の間を削除（%@）")
        XCTAssertEqual(
            japanese("Nothing would be left. Choose a lower threshold or a longer pause."),
            "何も残らなくなります。無音とみなす音量を下げるか、対象にする間を長くしてください。")
        XCTAssertEqual(
            japanese("There’s no audible sound to analyze in this video."), "この動画には分析できる音がありません。")
    }

    func testSilenceAnalysisCanRetryCancellationAndFailure() async throws {
        let model = try await videoModel(fixture: try pausedSpeechFixture(in: try workspace()))
        model.analyzeSilence()
        model.cancelSilenceAnalysis()
        try await eventually { model.silenceTask == nil }
        XCTAssertTrue(model.canAnalyzeSilence)
        let displaced = model.url.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: model.url, to: displaced)
        model.analyzeSilence()
        XCTAssertNotNil(model.silenceFailure)
        XCTAssertTrue(model.canAnalyzeSilence)
        try FileManager.default.moveItem(at: displaced, to: model.url)
        model.analyzeSilence()
        try await eventually { model.silenceTask == nil }
        XCTAssertNil(model.silenceFailure)
        XCTAssertNotNil(try model.silencePreview(SilenceRule()))
        model.change {
            $0.segments[0].start = 1.2; $0.segments[0].end = 1.8
        }
        model.removeSilence(SilenceRule())
        XCTAssertNotNil(model.silenceFailure)
        model.undo()
        model.removeSilence(SilenceRule())
        XCTAssertNil(model.silenceFailure)
        XCTAssertEqual(model.values.segments.count, 3)
    }

    func testSilenceAnalysisRejectsChangedSourcesAndClearsOnClose() async throws {
        let model = try await videoModel(fixture: try pausedSpeechFixture(in: try workspace()))
        model.analyzeSilence()
        try await eventually { model.silenceTask == nil }
        XCTAssertNotNil(try model.silencePreview(SilenceRule()))
        let original = model.values
        try Data(count: 4_096).write(to: model.url)
        XCTAssertThrowsError(try model.silencePreview(SilenceRule()))
        model.removeSilence(SilenceRule())
        XCTAssertNotNil(model.silenceFailure)
        XCTAssertEqual(model.values, original)
        model.analyzeSilence()
        XCTAssertNotNil(model.silenceFailure)
        await model.close()
        XCTAssertTrue(model.silenceLevels.isEmpty)
    }

    func testRemoveSilenceExplainsVideosWithoutSound() async throws {
        let model = try await videoModel(fixture: try synthesizedSilentVideoFixture(in: try workspace()))
        XCTAssertEqual(model.silenceUnavailableReason, "There’s no audible sound to analyze in this video.")
        model.analyzeSilence()
        XCTAssertNil(model.silenceTask)
    }

    func testCancelledMusicPanelKeepsTheCurrentInspector() async throws {
        let model = try await videoModel()
        model.category = .markup
        let cancellation = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let panel = NSApp.modalWindow else { return }
                panel.orderOut(nil)
                NSApp.stopModal(withCode: .cancel)
            }
        }
        RunLoop.main.add(cancellation, forMode: .modalPanel)
        defer { cancellation.invalidate() }
        model.chooseMusic()
        XCTAssertEqual(model.category, .markup)
        XCTAssertNil(model.musicTask)
        XCTAssertNil(model.values.music)
    }

    func testMusicPermissionErrorsUseTheFullSourcePath() async throws {
        let model = try await videoModel()
        let song = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/missing-song.wav")
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        XCTAssertEqual(
            model.describeMusic(denied, url: song),
            UserMessages.describe(EngineError.wrapping(denied, path: song.path), file: song.lastPathComponent))
    }

    func testCloseCancelsMusicLoadingWithoutPublishingAnError() async throws {
        let model = try await videoModel()
        let missing = try workspace().appending(path: "missing.ogg")
        model.setMusic(missing)
        await model.close()
        XCTAssertNil(model.musicTask)
        XCTAssertNil(model.musicFailure)
        XCTAssertNil(model.values.music)
    }

    func testSilencePopoverShortcutsApplyOrDismissWithoutSavingTheEditor() async throws {
        let model = try await videoModel(fixture: try pausedSpeechFixture(in: try workspace()))
        model.analyzeSilence()
        try await eventually { model.silenceTask == nil }
        var saved = false
        var closed = false
        let shortcut = EditorKeyboardShortcuts.ShortcutView()
        shortcut.model = model
        shortcut.save = { saved = true }
        shortcut.close = { closed = true }
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = shortcut
        defer { shortcut.stopMonitoring(); window.close() }
        model.showsSilencePreview = true
        try sendEditorKey("\u{1b}", window: window)
        XCTAssertFalse(model.showsSilencePreview)
        XCTAssertFalse(closed)
        model.showsSilencePreview = true
        try sendEditorKey("\r", window: window)
        XCTAssertEqual(model.values.segments.count, 3)
        XCTAssertFalse(model.showsSilencePreview)
        XCTAssertFalse(saved)
    }

    func testBackgroundMusicAddsReplacesAndRemovesAsUndoSteps() async throws {
        let model = try await videoModel()
        let directory = try workspace()
        let song = try audioFixture(in: directory)
        XCTAssertTrue(MediaEditorModel.musicTypes.contains(.wav))
        XCTAssertTrue(MediaEditorModel.musicTypes.contains(.mp3))
        model.setMusic(song)
        try await eventually { model.musicTask == nil }
        XCTAssertNil(model.musicFailure)
        let music = try XCTUnwrap(model.values.music)
        XCTAssertEqual(music.url, song)
        XCTAssertEqual(music.volume, BackgroundMusic.defaultVolume)
        XCTAssertEqual(music.duration, 2, accuracy: 0.01)
        XCTAssertEqual(model.values.video.music, music)
        XCTAssertNotNil(model.musicRevealRequest)
        try await eventually { model.canSave || model.failure != nil }
        XCTAssertNil(model.failure)

        model.musicBinding(\.volume).wrappedValue = 0.8
        model.musicBinding(\.start).wrappedValue = 0.5
        XCTAssertEqual(model.values.music?.volume, 0.8)
        let replacement = directory.appending(path: "second.wav")
        try FileManager.default.copyItem(at: song, to: replacement)
        model.setMusic(replacement)
        try await eventually { model.musicTask == nil }
        XCTAssertEqual(model.values.music?.url, replacement)
        XCTAssertEqual(model.values.music?.volume, 0.8, "Replace keeps the mix")
        XCTAssertEqual(model.values.music?.start, 0.5)
        model.removeMusic()
        XCTAssertNil(model.values.music)
        model.undo()
        XCTAssertEqual(model.values.music?.url, replacement)
        model.undo()
        XCTAssertEqual(model.values.music?.url, song, "replacing is one Undo step")
        model.undo()
        model.undo()
        model.undo()
        XCTAssertNil(model.values.music, "adding is one Undo step")
    }

    func testBackgroundMusicExplainsUnsupportedAndChangedFiles() async throws {
        let model = try await videoModel()
        let directory = try workspace()
        let text = directory.appending(path: "notes.mp3")
        try Data("not audio".utf8).write(to: text)
        model.setMusic(text)
        try await eventually { model.musicTask == nil }
        XCTAssertNil(model.values.music)
        XCTAssertEqual(
            model.musicFailure,
            "“notes.mp3” can’t be used as music. Choose an MP3, AAC, WAV, AIFF, FLAC, Ogg or Opus file.")

        let song = try audioFixture(in: directory)
        model.setMusic(song)
        try await eventually { model.musicTask == nil }
        XCTAssertNil(model.musicFailure, "a new choice clears the old message")
        try await eventually { model.canSave || model.failure != nil }
        try Data(count: 4_096).write(to: song)
        XCTAssertTrue(model.musicChanged)
        XCTAssertThrowsError(try model.makeSave(replacingOriginal: false))
        model.musicBinding(\.volume).wrappedValue = 0.5
        try await eventually { model.failure != nil }
        XCTAssertEqual(model.failure, "The background music file changed while editing. Choose it again.")
        XCTAssertFalse(model.canSave)
        model.removeMusic()
        try await eventually { model.canPlay || model.failure != nil }
        XCTAssertNil(model.failure, "removing the changed song recovers")

        XCTAssertEqual(
            japanese("“%@” can’t be used as music. Choose an MP3, AAC, WAV, AIFF, FLAC, Ogg or Opus file."),
            "“%@”は音楽として使えません。MP3、AAC、WAV、AIFF、FLAC、Ogg、Opusのいずれかを選んでください。")
        XCTAssertEqual(
            japanese("The background music file changed while editing. Choose it again."),
            "編集中に音楽ファイルが変更されました。もう一度選んでください。")
    }

    func testUpAndDownJumpBetweenSegmentBoundaries() async throws {
        let model = try await videoModel()
        let segment = try XCTUnwrap(model.values.segments.first)
        model.change {
            var left = segment
            left.end = 0.5
            var right = segment
            right.id = UUID()
            right.start = 0.5
            right.speed = 2
            $0.segments = [left, right]
        }
        let end = model.outputDuration
        model.seek(0.2)
        model.jumpToSegmentBoundary(forward: true)
        XCTAssertEqual(model.position, 0.5, accuracy: 0.000_001)
        model.jumpToSegmentBoundary(forward: true)
        XCTAssertGreaterThan(model.position, end - 0.01, "the last boundary is the end")
        model.jumpToSegmentBoundary(forward: true)
        XCTAssertGreaterThan(model.position, end - 0.01)
        model.jumpToSegmentBoundary(forward: false)
        XCTAssertEqual(model.position, 0.5, accuracy: 0.000_001)
        model.jumpToSegmentBoundary(forward: false)
        XCTAssertEqual(model.position, 0)
        XCTAssertEqual(model.values.segments.count, 2, "jumping never edits")
    }

    func testApplyToAllSegmentsCopiesAdjustmentsOrStyleAsOneUndoStep() async throws {
        let model = try await videoModel()
        let segment = try XCTUnwrap(model.values.segments.first)
        model.change {
            var left = segment
            left.end = 0.5
            left.adjustments.style = .warm
            var right = segment
            right.id = UUID()
            right.start = 0.5
            $0.segments = [left, right]
            $0.selectedID = right.id
        }
        XCTAssertFalse(model.canApplyToAllSegments(styleOnly: false), "nothing differs yet")
        model.change { $0.videoAdjustments[.exposure] = 0.4 }
        model.change { $0.videoAdjustments.style = .dramatic }
        XCTAssertTrue(model.canApplyToAllSegments(styleOnly: false))
        model.applyToAllSegments(styleOnly: false)
        XCTAssertEqual(model.values.segments[0].adjustments[.exposure], 0.4)
        XCTAssertEqual(model.values.segments[0].adjustments.style, .warm, "Adjust keeps each segment's style")
        model.undo()
        XCTAssertEqual(model.values.segments[0].adjustments[.exposure], 0, "applying is one Undo step")
        model.applyToAllSegments(styleOnly: true)
        XCTAssertEqual(model.values.segments[0].adjustments.style, .dramatic)
        XCTAssertEqual(model.values.segments[0].adjustments[.exposure], 0, "Styles keep each segment's light")
        XCTAssertFalse(model.canApplyToAllSegments(styleOnly: true))

        model.change { $0.speed = 4 }
        try await eventually { model.canSave || model.failure != nil }
        XCTAssertNil(model.failure, "4x is a valid preset")
        XCTAssertEqual(japanese("Apply Style to All Segments"), "スタイルをすべてのセグメントに適用")
        XCTAssertEqual(japanese("Apply Adjustments to All Segments"), "調整をすべてのセグメントに適用")
    }

    func testPhotoZoomShortcutUsesShiftCommandPlusAndRespectsTextFocus() async throws {
        let model = try await photoModel()
        let shortcut = EditorKeyboardShortcuts.ShortcutView()
        shortcut.model = model
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 150, height: 24))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 100))
        container.addSubview(shortcut)
        container.addSubview(field)
        window.contentView = container
        defer { shortcut.stopMonitoring(); window.close() }
        try sendEditorKey("+", modifiers: [.command, .shift], window: window)
        XCTAssertEqual(model.zoom, 2)
        XCTAssertTrue(window.makeFirstResponder(field))
        try sendEditorKey("+", modifiers: [.command, .shift], window: window)
        try sendEditorKey("m", window: window)
        XCTAssertEqual(model.zoom, 2)
        XCTAssertFalse(model.original)
    }

    func testFreezeShortcutUsesItsCharacterAndFrameShortcutNeverStealsText() async throws {
        let model = try await videoModel()
        model.seek(0.5)
        var savedFrames = 0
        let host = NSHostingView(rootView: EditorTransportBar(model: model) { savedFrames += 1 })
        host.frame = CGRect(x: 0, y: 30, width: 800, height: 44)
        let shortcut = EditorKeyboardShortcuts.ShortcutView()
        shortcut.model = model
        shortcut.saveFrame = { savedFrames += 1 }
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 150, height: 24))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 100), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 100))
        container.addSubview(host)
        container.addSubview(shortcut)
        container.addSubview(field)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { shortcut.stopMonitoring(); window.close() }
        XCTAssertTrue(window.makeFirstResponder(field))
        try sendEditorKey("f", modifiers: .option, window: window)
        try sendEditorKey("s", modifiers: [.command, .shift], window: window)
        XCTAssertEqual(model.values.segments.count, 1)
        XCTAssertEqual(savedFrames, 0)
        window.makeFirstResponder(nil)
        try sendEditorKey("f", modifiers: .option, window: window)
        try await eventually { !model.splitting }
        XCTAssertEqual(model.values.segments.filter(\.isFreeze).count, 1)
        try sendEditorKey("s", modifiers: [.command, .shift], window: window)
        XCTAssertEqual(savedFrames, 1, "one registration saves one frame")
    }

    func testTransportClockCommitsTypedTimeAndLocksDuringReverse() async throws {
        let directory = try workspace()
        let model = try await videoModel(fixture: try synthesizedVideoFixture(in: directory))
        let bar = EditorTransportBar(model: model) {}
        let host = NSHostingView(rootView: bar)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 44), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        defer { window.close() }
        try await eventually {
            host.layoutSubtreeIfNeeded()
            return window.isVisible && host.bounds.size == CGSize(width: 800, height: 44)
        }
        XCTAssertFalse(bar.clockDisabled)
        try click(at: CGPoint(x: 40, y: 22), in: window)
        try await eventually {
            host.layoutSubtreeIfNeeded()
            return self.textFields(in: host).count == 1
        }
        let field = try XCTUnwrap(textFields(in: host).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("0:01", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let enter = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
        try await eventually {
            host.layoutSubtreeIfNeeded()
            return self.textFields(in: host).isEmpty
        }
        XCTAssertEqual(model.position, 1)

        let clock = TransportClock(position: model.position, duration: model.outputDuration, seek: model.seek)
        clock.commit("0:01")
        XCTAssertEqual(model.position, 1)
        clock.commit("0:59")
        XCTAssertLessThan(model.position, model.outputDuration)
        XCTAssertGreaterThan(model.position, model.outputDuration - model.frameDuration * 2)
        model.toggleReverse()
        XCTAssertTrue(model.editingLocked)
        XCTAssertTrue(bar.clockDisabled)
        XCTAssertFalse(model.canPlay)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let position = model.position
        try click(at: CGPoint(x: 40, y: 22), in: window)
        try click(at: CGPoint(x: 400, y: 22), in: window)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(textFields(in: host).isEmpty, "disabled clock must not open an editor")
        XCTAssertFalse(model.playing, "disabled play button must not start playback")
        clock.commit("0:00")
        XCTAssertEqual(model.position, position, "a clock commit cannot bypass the lock")
        model.cancelReverse()
        try await eventually { !model.editingLocked }
        model.change { $0.segments = [] }
        XCTAssertFalse(model.canPlay)
        XCTAssertTrue(bar.clockDisabled)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        try click(at: CGPoint(x: 40, y: 22), in: window)
        try click(at: CGPoint(x: 400, y: 22), in: window)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(textFields(in: host).isEmpty, "empty timeline clock must stay disabled")
        XCTAssertFalse(model.playing)
    }

    func testBoxHandleDragTracksFlippedRotatedAndStraightenedImages() async throws {
        for transform in ["flipped", "rotated", "straightened"] {
            let model = try await photoModel()
            model.category = .markup
            model.change {
                $0.photo.geometry.flipHorizontal = transform == "flipped"
                $0.photo.geometry.quarterTurns = transform == "rotated" ? 1 : 0
                $0.photo.geometry.straighten = transform == "straightened" ? 12 : 0
            }
            let rect = EditCrop(x: 0.25, y: 0.3, width: 0.4, height: 0.3)
            let id = try XCTUnwrap(model.addOverlay(.box(rect: rect, color: .red, size: .medium)))
            let host = NSHostingView(rootView: EditorMarkupOverlay(model: model))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            try await eventually {
                host.layoutSubtreeIfNeeded()
                return window.isVisible && host.bounds.size == CGSize(width: 400, height: 300)
            }
            XCTAssertEqual(host.bounds.width, 400)
            XCTAssertEqual(host.bounds.height, 300)
            XCTAssertTrue(window.isVisible)
            let before = boxOutputBounds(rect, model: model)
            let from = CGPoint(x: before.minX * 400, y: before.midY * 300)
            let to = CGPoint(x: from.x - 32, y: from.y)
            let overlay = EditorMarkupOverlay(model: model)
            guard
                case .handle(let hitID, let original, let resizeHandle, let location) = overlay.target(
                    at: from, size: host.bounds.size)
            else { window.close(); return XCTFail("handle missed the \(transform) box") }
            XCTAssertEqual(hitID, id)
            let resizedRect = model.resizeBox(
                original, horizontal: resizeHandle.x, vertical: resizeHandle.y,
                from: CGPoint(x: location.x / 400, y: location.y / 300),
                to: CGPoint(x: to.x / 400, y: to.y / 300))
            let interaction = model.beginInteraction()
            model.updateOverlay(hitID, .box(rect: resizedRect, color: .red, size: .medium), in: interaction)
            model.endInteraction(interaction)
            guard case .box(let resized, _, _) = model.selectedOverlay?.mark else {
                window.close()
                return XCTFail("handle missed the \(transform) box")
            }
            let after = boxOutputBounds(resized, model: model)
            XCTAssertEqual(model.markupOverlays.count, 1)
            XCTAssertEqual(model.values.selectedOverlayID, id)
            XCTAssertLessThan(after.minX, before.minX - 0.04, transform)
            XCTAssertGreaterThan(after.width, before.width, transform)
            if transform != "straightened" {
                XCTAssertEqual(after.maxX, before.maxX, accuracy: 0.001, transform)
                XCTAssertEqual(after.height, before.height, accuracy: 0.001, transform)
            }
            model.undo()
            XCTAssertEqual(model.selectedOverlay?.mark, .box(rect: rect, color: .red, size: .medium))
            window.close()
        }
    }

    func testPhotoZoomStaysWithinItsRange() async throws {
        let model = try await photoModel()
        model.setPhotoZoom(16)
        XCTAssertEqual(model.zoom, MediaEditorModel.photoZoomRange.upperBound)
        model.setPhotoZoom(0.2)
        XCTAssertEqual(model.zoom, 1)
        model.setPhotoZoom(.nan)
        XCTAssertEqual(model.zoom, 1)
        model.setPhotoZoom(2.5)
        XCTAssertEqual(model.zoom, 2.5)
    }

    func testDraggedArrowKeepsItsDirectionAndDraggedRedactionLandsUnderRotationAndFlip() async throws {
        let model = try await photoModel()
        model.change {
            $0.photo.geometry.quarterTurns = 1
            $0.photo.geometry.flipHorizontal = true
        }
        model.markColor = .yellow
        let arrow = try XCTUnwrap(
            model.newMark(.arrow, outputRect: CGRect(x: 0.8, y: 0.7, width: -0.6, height: -0.5)))
        guard case .arrow(let from, let to, _, _) = arrow else { return XCTFail("not an arrow") }
        let start = model.outputPoint(from)
        let end = model.outputPoint(to)
        XCTAssertEqual(start.x, 0.8, accuracy: 0.001, "drags from bottom-right")
        XCTAssertEqual(start.y, 0.7, accuracy: 0.001)
        XCTAssertEqual(end.x, 0.2, accuracy: 0.001, "toward top-left")
        XCTAssertEqual(end.y, 0.2, accuracy: 0.001)

        model.redactionStyle = .solid
        let drag = CGRect(x: 0.1, y: 0.6, width: 0.3, height: 0.25)
        let mark = try XCTUnwrap(model.newMark(.redact, outputRect: drag))
        XCTAssertNotNil(model.addOverlay(mark))
        try await eventually { model.canSave || model.failure != nil }
        let planned = try model.makeSave(replacingOriginal: false)
        let engine = try JobEngine(supportDirectory: try workspace(), concurrency: 1)
        let result = await engine.run(planned.batch, settings: planned.settings) { _ in }
        guard case .succeeded(let outputs, _) = result.outcomes.first, let output = outputs.first else {
            return XCTFail("save failed: \(result.outcomes)")
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        func pixel(_ x: Double, _ y: Double) throws -> [Double] {
            try rgb(image, x: Int(x * Double(image.width)), y: Int(y * Double(image.height)))
        }
        XCTAssertLessThan(try pixel(drag.midX, drag.midY).max() ?? 1, 0.06, "the dragged area is hidden")
        XCTAssertGreaterThan(try pixel(1 - drag.midX, drag.midY)[0], 0.5, "the mirrored area stays visible")
        XCTAssertGreaterThan(try pixel(drag.midX, 1 - drag.midY)[0], 0.5, "the flipped area stays visible")
    }

    func testUndoCancelsPendingBoundaryWithoutLateHistory() async throws {
        let model = try await videoModel()
        let original = model.values
        model.change { $0.speed = 2 }
        let startInteraction = model.beginInteraction()
        model.setVideoBoundary(0.5, start: true, in: startInteraction)
        model.endInteraction(startInteraction)
        model.undo()
        await model.finishBoundaryInput()
        XCTAssertEqual(model.values, original)
        XCTAssertFalse(model.canUndo)
        model.redo()
        XCTAssertEqual(model.values.speed, 2)
        model.endInteraction(startInteraction)
        model.undo()
        XCTAssertEqual(model.values, original, "blur cannot add a stale history entry")
    }

    func testConcurrentBoundaryCommitsKeepAValidRange() async throws {
        let model = try await videoModel()
        let startInteraction = model.beginInteraction()
        model.setVideoBoundary(1.5, start: true, in: startInteraction)
        let endInteraction = model.beginInteraction()
        model.setVideoBoundary(1, start: false, in: endInteraction)
        await model.finishBoundaryInput()
        model.endInteraction(endInteraction)
        XCTAssertEqual(model.values.start, 1.5, accuracy: model.sourceFrameDuration)
        XCTAssertGreaterThan(model.values.end, model.values.start)
        XCTAssertNotNil(model.timeline)
        model.undo()
        XCTAssertEqual(model.values.start, 1.5, accuracy: model.sourceFrameDuration)
        XCTAssertEqual(model.values.end, model.duration)
        model.undo()
        XCTAssertEqual(model.values.start, 0)
    }

    func testNumericFieldResumesItsHistoryAfterASliderInteraction() async throws {
        let model = try await videoModel()
        let host = NSHostingView(
            rootView: EditorNumberField(
                model: model, title: "Speed", id: "speed", keyPath: \.speed,
                range: VideoEdit.speedRange, precision: 2))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(textFields(in: host).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("2", replacementRange: editor.selectedRange())
        let slider = model.beginInteraction()
        model.change(in: slider) { $0.volume = 0.5 }
        model.endInteraction(slider)
        editor.selectAll(nil)
        editor.insertText("3", replacementRange: editor.selectedRange())
        editor.selectAll(nil)
        editor.insertText("4", replacementRange: editor.selectedRange())
        window.makeFirstResponder(nil)
        XCTAssertEqual(model.values.speed, 4)
        model.undo()
        XCTAssertEqual(model.values.speed, 2, "typing after the drag is one interaction")
        XCTAssertEqual(model.values.volume, 0.5)
        model.undo()
        XCTAssertEqual(model.values.volume, 1)
        model.undo()
        XCTAssertEqual(model.values.speed, 1)
    }

    func testReverseLocksAllEditEntryPointsAndSaving() async throws {
        let model = try await videoModel(count: 2)
        let original = model.values
        let selected = try XCTUnwrap(model.selectedSegment)
        model.toggleReverse()
        XCTAssertTrue(model.editingLocked)
        XCTAssertFalse(model.canPlay)
        model.selectSegment(model.values.segments[1].id)
        model.beginTimelineTrim(selected.id, start: true)
        model.updateTimelineTrim(to: 0.5)
        model.setVideoBoundary(0.5, start: true)
        model.setTrimBoundaryAtPlayhead(start: false)
        model.deleteSelection()
        model.duplicateSelection()
        model.moveSelection(1)
        model.moveSegment(selected.id, to: 1)
        model.reset()
        model.seek(1)
        model.skim(1)
        model.stepFrame(1)
        model.jumpToSegmentBoundary(forward: true)
        model.importVideos([model.url])
        model.addDefaultOverlay(.box)
        model.selectOverlay(UUID())
        model.setCropPercentage(50, keyPath: \.width)
        model.removeMusic()
        model.analyzeSilence()
        model.removeSilence(SilenceRule())
        model.undo()
        model.redo()
        model.change { $0.resolution = 480 }
        var ranSave = false
        let saved = await model.save(replacingOriginal: false) { _, _ in
            ranSave = true
            return Task { nil }
        }
        XCTAssertFalse(saved)
        XCTAssertFalse(ranSave)
        XCTAssertEqual(model.values, original)
        XCTAssertEqual(model.position, 0)
        XCTAssertNil(model.hoverPosition)
        XCTAssertFalse(model.trimming)
        XCTAssertFalse(model.importing)
        XCTAssertFalse(model.hasPendingBoundaryInput)
        XCTAssertNil(model.silenceTask)
        model.cancelReverse()
        try await eventually { !model.editingLocked }
    }

    func testEditorTimelineAccessibilityDescribesAndEditsJoinedSegments() async throws {
        let directory = try workspace()
        let model = try await videoModel(count: 2, fixture: try pausedSpeechFixture(in: directory))
        model.seek(1.5)
        model.insertFreezeFrame()
        try await eventually { model.values.segments.count == 4 && !model.splitting }
        model.selectSegment(model.values.segments[3].id)
        model.toggleReverse()
        try await eventually { model.reverseTask == nil }
        XCTAssertNil(model.reverseFailure)
        model.addDefaultOverlay(.box)
        model.setMusic(try audioFixture(in: directory))
        try await eventually { model.musicTask == nil }
        model.analyzeSilence()
        try await eventually { model.silenceTask == nil }
        model.showsSilencePreview = true
        let host = NSHostingView(rootView: EditorTimeline(model: model))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1200, height: 260), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let canvas = try XCTUnwrap(timelineView(in: host)?.canvas)
        func parts() throws -> [String: NSAccessibilityElement] {
            let children = try XCTUnwrap(canvas.accessibilityChildren() as? [NSAccessibilityElement])
            return Dictionary(uniqueKeysWithValues: children.map { ($0.accessibilityLabel() ?? "", $0) })
        }
        func value(_ label: String) throws -> String {
            try XCTUnwrap(try parts()[label]?.accessibilityValue() as? String, label)
        }
        let labels = try parts().keys
        for expected in [
            "Segment 1 of 4, clip-0.mp4", "Segment 2 of 4, clip-0.mp4", "Segment 3 of 4, clip-0.mp4",
            "Segment 4 of 4, clip-1.mp4", "Box 1", "Music, tone.wav", "Playhead",
        ] {
            XCTAssertTrue(labels.contains(expected), "\(expected) in \(labels.sorted())")
        }
        XCTAssertTrue(labels.contains { $0.hasPrefix("Pause to remove, 1 of ") }, "\(labels.sorted())")
        XCTAssertTrue(try value("Segment 2 of 4, clip-0.mp4").contains("Freeze Frame"))
        XCTAssertTrue(try value("Segment 4 of 4, clip-1.mp4").contains("Reversed"))
        XCTAssertTrue(try value("Segment 4 of 4, clip-1.mp4").contains("Selected"))
        XCTAssertFalse(try value("Segment 1 of 4, clip-0.mp4").contains("Selected"))
        XCTAssertTrue(try value("Music, tone.wav").contains("30%"))

        func perform(_ action: String, on label: String) async throws {
            let segment = try XCTUnwrap(try parts()[label], label)
            let custom = try XCTUnwrap(segment.accessibilityCustomActions()?.first { $0.name == action }, action)
            let before = model.values.segments
            XCTAssertTrue(custom.handler?() ?? false, action)
            try await eventually { model.values.segments != before && !model.splitting && model.reverseTask == nil }
            host.layoutSubtreeIfNeeded()
            model.undo()
            XCTAssertEqual(model.values.segments, before, "\(action) is exactly one Undo step")
            host.layoutSubtreeIfNeeded()
        }
        try await perform(TimelineAction.duplicate.title, on: "Segment 1 of 4, clip-0.mp4")
        try await perform(TimelineAction.delete.title, on: "Segment 3 of 4, clip-0.mp4")
        try await perform(TimelineAction.right.title, on: "Segment 1 of 4, clip-0.mp4")
        try await perform("Play Segment Forward", on: "Segment 4 of 4, clip-1.mp4")
        model.seek(4)
        host.layoutSubtreeIfNeeded()
        try await perform(TimelineAction.split.title, on: "Segment 3 of 4, clip-0.mp4")
        try await perform(TimelineAction.freeze.title, on: "Segment 3 of 4, clip-0.mp4")
        try await perform(TimelineAction.reverse.title, on: "Segment 3 of 4, clip-0.mp4")

        let playhead = try XCTUnwrap(try parts()["Playhead"])
        let start = model.position
        XCTAssertTrue(playhead.accessibilityPerformIncrement())
        try await eventually { model.position > start }
        XCTAssertEqual(model.position - start, model.frameDuration, accuracy: model.frameDuration / 2)

        let stale = try XCTUnwrap(
            try parts()["Segment 1 of 4, clip-0.mp4"]?.accessibilityCustomActions()?.first {
                $0.name == TimelineAction.duplicate.title
            })
        model.selectSegment(model.values.segments[2].id)
        model.toggleReverse()
        XCTAssertTrue(model.editingLocked)
        host.layoutSubtreeIfNeeded()
        let locked = model.values
        XCTAssertEqual(try parts()["Segment 1 of 4, clip-0.mp4"]?.accessibilityCustomActions()?.isEmpty, true)
        XCTAssertFalse(stale.handler?() ?? true)
        XCTAssertFalse(playhead.accessibilityPerformIncrement())
        XCTAssertFalse(try XCTUnwrap(try parts()["Box 1"]).accessibilityPerformPress())
        XCTAssertEqual(model.values, locked, "no accessibility action edits during a reverse")
        model.cancelReverse()
        try await eventually { !model.editingLocked }
    }

    func testReverseDisablesNativeTimelineInputThroughTheViewEnvironment() async throws {
        let model = try await videoModel()
        model.toggleReverse()
        let original = model.values
        let host = NSHostingView(rootView: EditorTimeline(model: model))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1200, height: 200), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(timelineView(in: host))
        let canvas = try XCTUnwrap(scroll.canvas)
        XCTAssertFalse(scroll.interactionEnabled)
        XCTAssertFalse(canvas.interactionEnabled)
        let down = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: CGPoint(x: 400, y: 50), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: down)
        canvas.mouseDragged(with: down)
        canvas.mouseUp(with: down)
        XCTAssertNil(canvas.menu(for: down))
        XCTAssertNil(canvas.hitTest(CGPoint(x: 400, y: 50)))
        let wheel = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: 80, wheel2: 0, wheel3: 0))
        wheel.flags = .maskCommand
        scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
        XCTAssertEqual(model.timelineZoom, 1)
        XCTAssertEqual(model.position, 0)
        XCTAssertEqual(model.values, original)
        model.cancelReverse()
        try await eventually { !model.editingLocked }
    }

    func testPreviewFailureEndsPreparingState() async throws {
        let model = try await videoModel()
        model.playerReady = false
        model.preparingPlayback = true
        XCTAssertTrue(model.preparingPreview)
        model.report(EngineError.decodeFailed("broken preview"))
        XCTAssertNotNil(model.failure)
        XCTAssertFalse(model.preparingPreview)
    }

    func testClosingCancelsOverlayBoundaryBeforeItCanEdit() async throws {
        let model = try await videoModel()
        model.addDefaultOverlay(.box)
        model.seek(1)
        let original = model.values
        model.setOverlayBoundaryAtPlayhead(start: true)
        await model.close()
        XCTAssertEqual(model.values, original)
        XCTAssertNil(model.overlayBoundaryTask)
        model.setOverlayBoundaryAtPlayhead(start: false)
        XCTAssertNil(model.overlayBoundaryTask)
    }

    func testFieldInteractionsBelongToTheirTokenAndStartAndEndSnapIndependently() async throws {
        let model = try await videoModel()
        let original = model.values.segments
        let startInteraction = model.beginInteraction()
        model.setVideoBoundary(0.5, start: true, in: startInteraction)
        let endInteraction = model.beginInteraction()
        model.endInteraction(startInteraction)
        model.setVideoBoundary(1.5, start: false, in: endInteraction)
        model.setVideoBoundary(1.4, start: false, in: endInteraction)
        await model.finishBoundaryInput()
        XCTAssertEqual(model.values.start, 0.5, accuracy: model.frameDuration, "End input keeps Start's value")
        XCTAssertEqual(model.values.end, 1.4, accuracy: model.frameDuration)
        model.setVideoBoundary(1.3, start: false, in: endInteraction)
        await model.finishBoundaryInput()
        model.endInteraction(endInteraction)
        XCTAssertFalse(model.canRedo)
        model.undo()
        XCTAssertEqual(model.values.start, 0.5, accuracy: model.frameDuration, "End is its own Undo step")
        XCTAssertEqual(model.values.end, original[0].end)
        model.undo()
        XCTAssertEqual(model.values.segments, original, "Start is a separate Undo step")

        let secondStart = model.beginInteraction()
        model.setVideoBoundary(0.5, start: true, in: secondStart)
        await model.finishBoundaryInput()
        let secondEnd = model.beginInteraction()
        model.setVideoBoundary(1.2, start: false, in: secondEnd)
        await model.finishBoundaryInput()
        model.endInteraction(secondEnd)
        model.undo()
        XCTAssertEqual(model.values.start, 0.5, accuracy: model.frameDuration, "each finished field is its own step")
        XCTAssertEqual(model.values.end, original[0].end)
        model.undo()
        XCTAssertEqual(model.values.segments, original)
    }

    func testMarkedTextDoesNotChangeANumberUntilCommitted() async throws {
        let model = try await videoModel()
        let host = NSHostingView(
            rootView: EditorNumberField(
                model: model, title: "Speed", id: "speed", keyPath: \.speed,
                range: VideoEdit.speedRange, precision: 2))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(textFields(in: host).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.setMarkedText(
            "2", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        XCTAssertTrue(editor.hasMarkedText())
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        XCTAssertEqual(model.values.speed, 1, "a composing digit is not applied")
        editor.insertText("2", replacementRange: editor.markedRange())
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(model.values.speed, 2, "the committed digit is applied")
        window.makeFirstResponder(nil)
    }

    func testOverlayLaneHitsTheSelectedBarDrawnOnTop() throws {
        var zoom = 1.0
        var selected: UUID?
        let ids = (0..<4).map { _ in UUID() }
        let canvas = TimelineCanvas(frame: CGRect(x: 0, y: 0, width: 900, height: 122))
        canvas.configuration = MediaTimeline(
            duration: 2, position: 1, clips: [TimelineClip(id: UUID(), range: 0...2, selection: nil, label: "")],
            playing: false, zoom: Binding(get: { zoom }, set: { zoom = $0 }), maximumZoom: 100,
            seek: { _ in }, hover: { _ in }, select: { _ in }, beginTrim: { _, _ in }, trim: { _ in }, endTrim: {},
            overlays: ids.enumerated().map { index, id in
                TimelineOverlayMark(
                    id: id, ranges: [0...2], label: "\(index)", fill: .systemRed, text: .white, selected: index == 2)
            },
            showsOverlayLane: true, selectOverlay: { selected = $0 })
        let lane = TimelineCanvas.rulerHeight + TimelineCanvas.clipHeight + 6
        for y in stride(from: lane + 1, to: lane + TimelineCanvas.overlayLaneHeight - 5, by: 2) {
            let down = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: CGPoint(x: 450, y: canvas.bounds.height - y), modifierFlags: [],
                    timestamp: 0,
                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            canvas.mouseDown(with: down)
            canvas.mouseUp(with: down)
            if selected == ids[2] { return }
            XCTAssertNotEqual(selected, ids[3], "the bar hidden behind the selected one was hit")
        }
        XCTFail("the selected bar drawn on top is never hit")
    }

    func testOverlayRangeLimitsUseTheOverlaySourceFrameRate() async throws {
        let directory = try workspace()
        let ffmpeg = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "media-tools/bin/ffmpeg")
        var clips: [URL] = []
        for rate in [24, 60] {
            let clip = directory.appending(path: "rate-\(rate).mp4")
            let encoding = Process()
            encoding.executableURL = ffmpeg
            encoding.arguments = [
                "-nostdin", "-y", "-v", "error", "-f", "lavfi", "-i", "color=c=gray:s=64x48:r=\(rate):d=1",
                "-c:v", "h264_videotoolbox", clip.path,
            ]
            try encoding.run()
            encoding.waitUntilExit()
            XCTAssertEqual(encoding.terminationStatus, 0)
            clips.append(clip)
        }
        let model = MediaEditorModel(
            urls: clips, isVideo: true, settings: Engine.Settings(),
            staging: StagingArea(supportDirectory: directory))
        addTeardownBlock { await model.close() }
        model.load()
        try await eventually { model.canPlay || model.failure != nil }
        XCTAssertEqual(model.frameDuration, 1.0 / 24, accuracy: 0.000_1)
        XCTAssertEqual(model.frameDuration(ofSource: 1), 1.0 / 60, accuracy: 0.000_1)
        XCTAssertEqual(model.frameDuration(ofSource: 0), 1.0 / 24, accuracy: 0.000_1)
        model.seek(1.2)
        model.addDefaultOverlay(.box)
        XCTAssertEqual(model.selectedTimedOverlay?.sourceIndex, 1)
        let host = NSHostingView(rootView: EditorMarkupInspector(model: model))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 900), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let end = try XCTUnwrap(textFields(in: host).first { $0.accessibilityLabel() == "End" })
        end.stringValue = "0:00.02"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: end)
        XCTAssertEqual(model.selectedTimedOverlay?.end, 0.02)
        XCTAssertFalse(model.invalidFields.contains("overlay-end"))

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

    func photoModel(
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

    func videoModel(
        count: Int = 1, settings: Engine.Settings = Engine.Settings(), range: ClosedRange<Double>? = nil,
        fixture: URL? = nil
    ) async throws
        -> MediaEditorModel
    {
        let directory = try workspace()
        let bundled = Bundle(for: Self.self).url(forResource: "ffmpeg-h264-aac", withExtension: "mp4")
        let fixture = try XCTUnwrap(fixture ?? bundled)
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
        var music = try await BackgroundMusic.load(from: songURL)
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

    func timelineView(in view: NSView) -> TimelineScrollView? {
        if let scroll = view as? TimelineScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.timelineView(in: $0) }.first
    }

    func sendEditorKey(
        _ characters: String, modifiers: NSEvent.ModifierFlags = [], window: NSWindow
    ) throws {
        let unrelatedPhysicalKey: UInt16 = 0
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: unrelatedPhysicalKey))
        NSApp.sendEvent(event)
    }

    private func boxOutputBounds(_ rect: EditCrop, model: MediaEditorModel) -> CGRect {
        let points = [
            EditPoint(x: rect.x, y: rect.y), EditPoint(x: rect.x + rect.width, y: rect.y),
            EditPoint(x: rect.x, y: rect.y + rect.height), EditPoint(x: rect.x + rect.width, y: rect.y + rect.height),
        ].map(model.outputPoint)
        return points.dropFirst().reduce(CGRect(origin: points[0], size: .zero)) { bounds, point in
            CGRect(
                x: min(bounds.minX, point.x), y: min(bounds.minY, point.y),
                width: max(bounds.maxX, point.x) - min(bounds.minX, point.x),
                height: max(bounds.maxY, point.y) - min(bounds.minY, point.y))
        }
    }

    func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MacEaseAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    func audioFixture(in directory: URL) throws -> URL {
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

    /// Alternating one-second tone and silence.
    func pausedSpeechFixture(in directory: URL) throws -> URL {
        let output = directory.appending(path: "paused.mp4")
        let encoding = Process()
        encoding.executableURL = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "media-tools/bin/ffmpeg")
        encoding.arguments = [
            "-nostdin", "-y", "-v", "error",
            "-f", "lavfi", "-i", "color=c=blue:s=160x120:r=30:d=6",
            "-f", "lavfi", "-i", "aevalsrc='0.4*sin(2*PI*440*t)*lt(mod(t\\,2)\\,1)':s=48000:d=6",
            "-ac", "2", "-c:v", "h264_videotoolbox", "-b:v", "400k", "-c:a", "aac", "-t", "6", output.path,
        ]
        try encoding.run()
        encoding.waitUntilExit()
        XCTAssertEqual(encoding.terminationStatus, 0)
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

    func testDiscreteEditsWhileNumericFieldKeepsFocusRecordFourUndoSteps() async throws {
        let model = try await videoModel()
        let host = NSHostingView(
            rootView: EditorNumberField(
                model: model, title: "Speed", id: "speed", keyPath: \.speed,
                range: VideoEdit.speedRange, precision: 2))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(textFields(in: host).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("2", replacementRange: editor.selectedRange())
        XCTAssertEqual(model.values.speed, 2)

        model.change { $0.volume = 0 }
        model.binding(\.fadeIn).wrappedValue = 1
        model.duplicateSelection()
        XCTAssertNotNil(field.currentEditor(), "Speed field keeps focus across discrete edits")
        XCTAssertEqual(model.values.segments.count, 2)

        model.undo()
        XCTAssertEqual(model.values.segments.count, 1)
        XCTAssertEqual(model.values.fadeIn, 1)
        XCTAssertEqual(model.values.volume, 0)
        XCTAssertEqual(model.values.speed, 2)
        model.undo()
        XCTAssertEqual(model.values.fadeIn, 0)
        XCTAssertEqual(model.values.volume, 0)
        XCTAssertEqual(model.values.speed, 2)
        model.undo()
        XCTAssertEqual(model.values.volume, 1)
        XCTAssertEqual(model.values.speed, 2)
        model.undo()
        XCTAssertEqual(model.values.speed, 1)
        XCTAssertFalse(model.canUndo)
    }

    func testPhotoSwitchWhileEditingExposureFieldSeparatesPhotoUndoSteps() async throws {
        let model = try await photoModel(additionalPhoto: true)
        let firstPhoto = model.photoURLs[0]
        let secondPhoto = model.photoURLs[1]
        struct ExposureHost: View {
            @Bindable var model: MediaEditorModel
            var body: some View {
                EditorNumberField(
                    model: model, title: "Exposure", id: MediaAdjustment.exposure.rawValue,
                    value: model.adjustments[.exposure], range: MediaAdjustment.exposure.range, precision: 2
                ) { amount, interaction in
                    model.setAdjustment(.exposure, to: amount, in: interaction)
                }
            }
        }
        let host = NSHostingView(rootView: ExposureHost(model: model))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(textFields(in: host).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("0.5", replacementRange: editor.selectedRange())
        XCTAssertEqual(model.values.photoEdits[firstPhoto]?.adjustments[.exposure] ?? 0, 0.5, accuracy: 0.001)

        model.selectPhoto(secondPhoto)
        XCTAssertNotNil(field.currentEditor(), "field stays focused across photo selection")
        editor.selectAll(nil)
        editor.insertText("0.8", replacementRange: editor.selectedRange())
        XCTAssertEqual(model.values.photoEdits[firstPhoto]?.adjustments[.exposure] ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(model.values.photoEdits[secondPhoto]?.adjustments[.exposure] ?? 0, 0.8, accuracy: 0.001)

        model.undo()
        XCTAssertEqual(model.values.photoEdits[secondPhoto]?.adjustments[.exposure] ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(model.values.photoEdits[firstPhoto]?.adjustments[.exposure] ?? 0, 0.5, accuracy: 0.001)
        model.undo()
        XCTAssertEqual(model.values.photoEdits[firstPhoto]?.adjustments[.exposure] ?? 0, 0, accuracy: 0.001)
        XCTAssertFalse(model.canUndo)
    }

    func testTypingStartThenImmediatelyEndRecordsTwoUndoSteps() async throws {
        let model = try await videoModel()
        struct BoundaryHost: View {
            @Bindable var model: MediaEditorModel
            var body: some View {
                HStack {
                    EditorNumberField(
                        model: model, title: "Start", id: "start", value: model.values.start,
                        range: 0...model.sourceDuration, precision: 3, timecode: true
                    ) { seconds, interaction in
                        model.setVideoBoundary(seconds, start: true, in: interaction)
                    }
                    EditorNumberField(
                        model: model, title: "End", id: "end", value: model.values.end,
                        range: 0...model.sourceDuration, precision: 3, timecode: true
                    ) { seconds, interaction in
                        model.setVideoBoundary(seconds, start: false, in: interaction)
                    }
                }
            }
        }
        let host = NSHostingView(rootView: BoundaryHost(model: model))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 40), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let fields = textFields(in: host)
        XCTAssertEqual(fields.count, 2)

        XCTAssertTrue(window.makeFirstResponder(fields[0]))
        let startEditor = try XCTUnwrap(fields[0].currentEditor() as? NSTextView)
        startEditor.selectAll(nil)
        startEditor.insertText("0.5", replacementRange: startEditor.selectedRange())

        XCTAssertTrue(window.makeFirstResponder(fields[1]))
        let endEditor = try XCTUnwrap(fields[1].currentEditor() as? NSTextView)
        endEditor.selectAll(nil)
        endEditor.insertText("1.5", replacementRange: endEditor.selectedRange())
        await model.finishBoundaryInput()
        window.makeFirstResponder(nil)

        XCTAssertEqual(model.values.start, 0.5, accuracy: model.sourceFrameDuration)
        XCTAssertEqual(model.values.end, 1.5, accuracy: model.sourceFrameDuration)
        model.undo()
        XCTAssertEqual(model.values.start, 0.5, accuracy: model.sourceFrameDuration)
        XCTAssertEqual(model.values.end, model.duration, accuracy: 0.000_001)
        model.undo()
        XCTAssertEqual(model.values.start, 0, accuracy: 0.000_001)
        XCTAssertFalse(model.canUndo)
    }

    func testSpeedFieldThenVolumeSliderDragThenSpeedFieldRecordsThreeUndoSteps() async throws {
        let model = try await videoModel()
        let host = NSHostingView(
            rootView: EditorNumberField(
                model: model, title: "Speed", id: "speed", keyPath: \.speed,
                range: VideoEdit.speedRange, precision: 2))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(textFields(in: host).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("2", replacementRange: editor.selectedRange())

        let slider = model.beginInteraction()
        for volume in [0.8, 0.6, 0.5] {
            model.change(in: slider) { $0.volume = volume }
        }
        model.endInteraction(slider)
        XCTAssertNotNil(field.currentEditor())

        editor.selectAll(nil)
        editor.insertText("3", replacementRange: editor.selectedRange())
        editor.selectAll(nil)
        editor.insertText("4", replacementRange: editor.selectedRange())
        window.makeFirstResponder(nil)

        XCTAssertEqual(model.values.speed, 4)
        XCTAssertEqual(model.values.volume, 0.5)
        model.undo()
        XCTAssertEqual(model.values.speed, 2)
        XCTAssertEqual(model.values.volume, 0.5)
        model.undo()
        XCTAssertEqual(model.values.volume, 1)
        XCTAssertEqual(model.values.speed, 2)
        model.undo()
        XCTAssertEqual(model.values.speed, 1)
        XCTAssertFalse(model.canUndo)
    }

    func testMarkupTextFieldTypingAfterToolbarUndoIsOneUndoStep() async throws {
        let model = try await photoModel()
        let initialMark = EditMark.text("Label", at: EditPoint(x: 0.5, y: 0.5), color: .red, size: .medium)
        let id = try XCTUnwrap(model.addOverlay(initialMark))
        struct TextHost: View {
            @Bindable var model: MediaEditorModel
            let id: UUID
            var body: some View {
                let text: String =
                    if case .text(let value, _, _, _) = model.selectedOverlay?.mark { value } else { "" }
                MarkupTextField(model: model, id: id, text: text)
            }
        }
        let host = NSHostingView(rootView: TextHost(model: model, id: id))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 240, height: 60), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await eventually { !self.textFields(in: host).isEmpty }
        let field = try XCTUnwrap(textFields(in: host).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        try await eventually { field.currentEditor() != nil }
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Hello", replacementRange: editor.selectedRange())
        XCTAssertEqual(
            model.selectedOverlay?.mark, .text("Hello", at: EditPoint(x: 0.5, y: 0.5), color: .red, size: .medium))

        model.undo()
        XCTAssertEqual(model.selectedOverlay?.mark, initialMark)
        XCTAssertNotNil(field.currentEditor(), "MarkupTextField keeps focus after toolbar Undo")

        editor.selectAll(nil)
        editor.insertText("a", replacementRange: editor.selectedRange())
        editor.insertText("b", replacementRange: editor.selectedRange())
        editor.insertText("c", replacementRange: editor.selectedRange())
        XCTAssertEqual(
            model.selectedOverlay?.mark, .text("abc", at: EditPoint(x: 0.5, y: 0.5), color: .red, size: .medium))

        model.undo()
        XCTAssertEqual(model.selectedOverlay?.mark, initialMark, "all three letters revert in one Undo step")
        model.undo()
        XCTAssertTrue(model.markupOverlays.isEmpty)
        XCTAssertFalse(model.canUndo)
    }

    func testSliderDragThroughManyValuesIsOneUndoStep() async throws {
        let model = try await videoModel()
        let slider = model.beginInteraction()
        for volume in [0.9, 0.7, 0.5, 0.3, 0.1] {
            model.change(in: slider) { $0.volume = volume }
        }
        model.endInteraction(slider)
        XCTAssertEqual(model.values.volume, 0.1)
        model.undo()
        XCTAssertEqual(model.values.volume, 1)
        XCTAssertFalse(model.canUndo)
    }

    func testUndoWhileBoundarySnapIsPendingRestoresOnlyPreviousAndNothingLandsAfterwards() async throws {
        let model = try await videoModel()
        let original = model.values
        model.change { $0.speed = 2 }
        let interaction = model.beginInteraction()
        model.setVideoBoundary(0.5, start: true, in: interaction)
        XCTAssertTrue(model.hasPendingBoundaryInput)
        model.undo()
        await model.finishBoundaryInput()
        XCTAssertEqual(model.values, original)
        XCTAssertEqual(model.values.start, 0)
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.hasPendingBoundaryInput)
    }

    func testEndAtOrBeforeLastFrameStartClampsToSourceDuration() async throws {
        let model = try await videoModel()
        let segment = try XCTUnwrap(model.values.segments.first)
        let lastFrame = 47.0 / 24

        let startToken = model.beginInteraction()
        model.setVideoBoundary(1.96, start: true, in: startToken)
        await model.finishBoundaryInput()
        model.endInteraction(startToken)
        XCTAssertEqual(model.values.start, lastFrame, accuracy: 0.000_001)

        let endToken = model.beginInteraction()
        model.setVideoBoundary(1.0, start: false, in: endToken)
        await model.finishBoundaryInput()
        model.endInteraction(endToken)
        XCTAssertEqual(model.values.start, lastFrame, accuracy: 0.000_001)
        XCTAssertEqual(model.values.end, model.duration, accuracy: 0.000_001)
        XCTAssertGreaterThan(model.values.end, model.values.start)
        XCTAssertNotNil(model.timeline)

        model.beginTimelineTrim(segment.id, start: false)
        model.updateTimelineTrim(to: 0.5)
        await model.endTimelineTrim()
        XCTAssertEqual(model.values.start, lastFrame, accuracy: 0.000_001)
        XCTAssertEqual(model.values.end, model.duration, accuracy: 0.000_001)
        XCTAssertGreaterThan(model.values.end, model.values.start)
        XCTAssertNotNil(model.timeline)
    }

    func testSilencePopoverDeduplicatesErrorsNamesFailingJoinedSourceAndHidesInertControls() async throws {
        let directory = try workspace()
        let first = directory.appending(path: "first-clip.mov")
        let second = directory.appending(path: "second-clip.mov")
        let template = try pausedSpeechFixture(in: directory)
        try FileManager.default.copyItem(at: template, to: first)
        try FileManager.default.copyItem(at: template, to: second)

        let model = MediaEditorModel(
            urls: [first, second], isVideo: true, settings: Engine.Settings(),
            staging: StagingArea(supportDirectory: directory.appending(path: "support")))
        addTeardownBlock { await model.close() }
        model.load()
        try await eventually { model.ready || model.failure != nil }
        XCTAssertNil(model.failure)

        let popover = EditorSilencePopover(model: model)
        let host = NSHostingView(rootView: popover)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 320), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await eventually { window.isVisible && model.hasSilenceAnalysis && model.silenceTask == nil }
        XCTAssertTrue(popover.showsControls)
        XCTAssertNil(popover.problemMessage(for: Result { try model.silencePreview(model.silenceRule) }))

        model.silenceLevels.removeAll()
        model.analyzeSilence()
        model.cancelSilenceAnalysis()
        try await eventually { model.silenceTask == nil }
        XCTAssertFalse(model.hasSilenceAnalysis)
        XCTAssertFalse(popover.showsControls)

        model.analyzeSilence()
        try await eventually { model.hasSilenceAnalysis && model.silenceTask == nil }
        XCTAssertTrue(popover.showsControls)

        try Data(count: 4_096).write(to: second)
        let previewWhileOpen = Result { try model.silencePreview(model.silenceRule) }
        let previewProblem = try XCTUnwrap(popover.problemMessage(for: previewWhileOpen))
        XCTAssertTrue(previewProblem.contains("second-clip.mov"), previewProblem)
        XCTAssertFalse(previewProblem.contains("first-clip.mov"), previewProblem)

        model.removeSilence(SilenceRule())
        let applyFailure = try XCTUnwrap(model.silenceFailure)
        XCTAssertTrue(applyFailure.contains("second-clip.mov"), applyFailure)
        XCTAssertFalse(applyFailure.contains("first-clip.mov"), applyFailure)
        XCTAssertEqual(popover.problemMessage(for: previewWhileOpen), applyFailure)

        model.analyzeSilence()
        let reopenFailure = try XCTUnwrap(model.silenceFailure)
        XCTAssertTrue(reopenFailure.contains("second-clip.mov"), reopenFailure)
        XCTAssertFalse(reopenFailure.contains("first-clip.mov"), reopenFailure)
        XCTAssertFalse(model.hasSilenceAnalysis)
        XCTAssertFalse(popover.showsControls)
        XCTAssertEqual(popover.problemMessage(for: nil), reopenFailure)
    }

    private func stagedDirectories(in staging: StagingArea) -> [String] {
        let registry = staging.supportDirectory.appending(path: "staging.json")
        guard let contents = try? Data(contentsOf: registry),
            let paths = try? JSONDecoder().decode([String].self, from: contents)
        else { return [] }
        return paths
    }

    private func waitForStagedDirectories(
        in staging: StagingArea, while running: () -> Bool
    ) async throws -> [String] {
        let deadline = ContinuousClock.now + .seconds(10)
        while running(), ContinuousClock.now < deadline {
            let staged = stagedDirectories(in: staging)
            if !staged.isEmpty { return staged }
            try await Task.sleep(for: .milliseconds(2))
        }
        return stagedDirectories(in: staging)
    }

    func click(at point: CGPoint, in window: NSWindow) throws {
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: kind, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }

    func japanese(_ key: String) -> String {
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
