import AppKit
import CoreText
import Engine
import SwiftUI
import XCTest

@testable import MacEase

@MainActor
final class PreviewFontFaceSwitchTests: XCTestCase {
    private static let menlo = URL(fileURLWithPath: "/System/Library/Fonts/Menlo.ttc")

    func testCollectionsListEveryFaceAndSwitchTheSampleWithItsDetails() throws {
        let collection = try PreviewFontFace.load(Self.menlo)
        XCTAssertEqual(collection.faceNames.count, collection.faceCount)
        XCTAssertEqual(collection.index, 0)
        XCTAssertEqual(collection.faceNames.first, collection.displayName)
        var postScriptNames: Set<String> = []
        var styles: Set<String> = []
        for index in collection.faceNames.indices {
            let face = collection.selecting(index)
            let font = face.font(size: 20)
            XCTAssertEqual(face.index, index)
            XCTAssertEqual(face.faceCount, collection.faceCount)
            XCTAssertEqual(face.displayName, collection.faceNames[index])
            XCTAssertEqual(CTFontCopyDisplayName(font) as String, face.displayName)
            XCTAssertEqual(face.glyphCount, CTFontGetGlyphCount(font))
            XCTAssertGreaterThan(face.glyphCount, 0)
            styles.insert(try XCTUnwrap(face.styleName))
            postScriptNames.insert(CTFontCopyPostScriptName(font) as String)
        }
        XCTAssertEqual(postScriptNames.count, collection.faceCount, "each face shows its own font")
        XCTAssertEqual(styles.count, collection.faceCount)

        let single = try PreviewFontFace.load(URL(fileURLWithPath: "/System/Library/Fonts/Geneva.ttf"))
        XCTAssertEqual(single.faceNames, ["Geneva"])
        XCTAssertGreaterThan(single.glyphCount, 0)
    }

    func testFaceButtonsStepThroughFacesAndANewFileStartsAtTheFirstFace() async throws {
        let directory = try PreviewFixtures.directory(self)
        let firstFile = directory.appendingPathComponent("first.ttc")
        let secondFile = directory.appendingPathComponent("second.ttc")
        // Two faces keep every step observable.
        let pair = URL(fileURLWithPath: "/System/Library/Fonts/MarkerFelt.ttc")
        try FileManager.default.copyItem(at: pair, to: firstFile)
        try FileManager.default.copyItem(at: pair, to: secondFile)
        XCTAssertEqual(try PreviewFontFace.load(firstFile).faceCount, 2)
        let suite = "PreviewFontFaceSwitchTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let state = FinderPreviewState()
        state.urls = [firstFile]
        state.kind = .font
        state.trust = PreviewTrust(level: .standard, resolvedPath: firstFile.path)
        state.generation = 1
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 420, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: FinderPreviewView(
                state: state, settings: SettingsStore(defaults: defaults),
                staging: StagingArea(supportDirectory: directory), close: {}, retry: {}, select: { _ in },
                resize: { _ in }))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let content = try XCTUnwrap(window.contentView)
        func steps() -> NSSegmentedControl? { PreviewFindTests.first(NSSegmentedControl.self, in: content) }
        func atFirstFace(_ control: NSSegmentedControl?) -> Bool {
            control.map { $0.segmentCount == 2 && !$0.isEnabled(forSegment: 0) && $0.isEnabled(forSegment: 1) }
                == true
        }

        let shown = try await PreviewFixtures.waitUntil { atFirstFace(steps()) }
        XCTAssertTrue(shown, "Previous is off on the first face")
        let firstControl = try XCTUnwrap(steps())
        click(segment: 1, of: try XCTUnwrap(steps()), in: window)
        let lastShown = try await PreviewFixtures.waitUntil {
            steps().map { $0.isEnabled(forSegment: 0) && !$0.isEnabled(forSegment: 1) } == true
        }
        XCTAssertTrue(lastShown, "Next steps to the last face")
        click(segment: 0, of: try XCTUnwrap(steps()), in: window)
        let steppedBack = try await PreviewFixtures.waitUntil { atFirstFace(steps()) }
        XCTAssertTrue(steppedBack, "Previous returns to the first face")
        click(segment: 1, of: try XCTUnwrap(steps()), in: window)
        let advancedAgain = try await PreviewFixtures.waitUntil { steps()?.isEnabled(forSegment: 0) == true }
        XCTAssertTrue(advancedAgain)

        state.urls = [secondFile]
        state.trust = PreviewTrust(level: .standard, resolvedPath: secondFile.path)
        state.generation += 1
        let reset = try await PreviewFixtures.waitUntil {
            let control = steps()
            return control !== firstControl && atFirstFace(control)
        }
        XCTAssertTrue(reset, "another file starts at its first face")
    }

    // SwiftUI momentary segments ignore selectedSegment.
    private func click(segment: Int, of control: NSSegmentedControl, in window: NSWindow) {
        let segmentWidth = control.bounds.width / CGFloat(control.segmentCount)
        let point = control.convert(
            NSPoint(x: segmentWidth * (CGFloat(segment) + 0.5), y: control.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else {
            return XCTFail("could not synthesize a click")
        }
        // Mouse tracking waits for the queued release.
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
    }
}
