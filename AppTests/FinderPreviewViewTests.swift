import AppKit
import Engine
import SwiftUI
import XCTest

@testable import MacEase

@MainActor
final class FinderPreviewViewTests: XCTestCase {
    private let first = URL(fileURLWithPath: "/tmp/first.png")
    private let second = URL(fileURLWithPath: "/tmp/second.txt")
    private let trust = PreviewTrust(level: .standard, resolvedPath: "/tmp/first.png")

    func testPreviousContentStaysUntilTheNextFileIsReady() {
        let state = FinderPreviewState()
        state.urls = [first, second]
        state.generation = 1
        state.trust = trust
        state.kind = .image
        XCTAssertEqual(state.shown?.url, first)
        XCTAssertFalse(state.isLoading)

        state.generation = 2
        state.selectedIndex = 1
        state.kind = nil
        state.trust = nil
        XCTAssertTrue(state.isLoading)
        XCTAssertEqual(state.shown?.url, first)
        XCTAssertEqual(state.shown?.generation, 1)

        state.trust = trust
        XCTAssertEqual(state.shown?.url, first, "trust alone is not enough to show the next file")
        state.kind = .text
        XCTAssertEqual(state.shown?.url, second)
        XCTAssertEqual(state.shown?.kind, .text)
        XCTAssertEqual(state.shown?.generation, 2)
    }

    func testClearingOrFailingDropsThePreviousContent() {
        let state = FinderPreviewState()
        state.urls = [first]
        state.trust = trust
        state.kind = .image
        state.fileFailure = "This file could not be read."
        XCTAssertNil(state.shown)
        XCTAssertFalse(state.isLoading)

        state.fileFailure = nil
        state.kind = .image
        XCTAssertEqual(state.shown?.url, first)
        state.urls = []
        XCTAssertNil(state.shown)
    }

    func testCommandOptionArrowsStepThroughTheSelection() async throws {
        let state = FinderPreviewState()
        state.urls = [first, second, URL(fileURLWithPath: "/tmp/third.md")]
        state.selectedIndex = 1
        var selected: [Int] = []
        let settings = SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "Shortcut-\(UUID().uuidString)")))
        let staging = StagingArea(
            supportDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let window = NSWindow(
            contentRect: NSRect(x: -5_000, y: 0, width: 420, height: 400), styleMask: [.borderless], backing: .buffered,
            defer: false)
        var mounted = false
        let host = NSHostingView(
            rootView: FinderPreviewView(
                state: state, settings: settings, staging: staging, close: {}, retry: {},
                select: { selected.append($0) },
                resize: { _ in }
            ).onAppear { mounted = true })
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await waitUntil {
            window.layoutIfNeeded()
            return mounted && host.fittingSize.width > 0
        }
        window.displayIfNeeded()

        XCTAssertFalse(window.performKeyEquivalent(with: try arrow(right: true, modifiers: .option)))
        XCTAssertEqual(selected, [], "Option-Arrow stays with text navigation")
        XCTAssertTrue(window.performKeyEquivalent(with: try arrow(right: true, modifiers: [.command, .option])))
        XCTAssertTrue(window.performKeyEquivalent(with: try arrow(right: false, modifiers: [.command, .option])))
        XCTAssertEqual(selected, [2, 0])
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("condition not met in time")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func arrow(right: Bool, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        let scalar = try XCTUnwrap(UnicodeScalar(right ? NSRightArrowFunctionKey : NSLeftArrowFunctionKey))
        let key = String(Character(scalar))
        return try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers.union([.function, .numericPad]),
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: right ? 124 : 123))
    }
}
