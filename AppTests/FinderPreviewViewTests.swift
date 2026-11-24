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

    func testSelectionShortcutLeavesTextFieldsTextViewsAndSelectionsAlone() async throws {
        let state = FinderPreviewState()
        state.urls = [first, second, URL(fileURLWithPath: "/tmp/third.md")]
        state.selectedIndex = 1
        var selected: [Int] = []
        let (window, host) = try await hostPanel(state) { selected.append($0) }
        defer { window.orderOut(nil) }
        let field = NSTextField(string: "search")
        field.frame = NSRect(x: 0, y: 0, width: 100, height: 22)
        let textView = NSTextView(frame: NSRect(x: 0, y: 30, width: 100, height: 40))
        textView.string = "selectable text"
        textView.isEditable = false
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        let selectionHolder = CopyableSelectionView(frame: NSRect(x: 0, y: 80, width: 40, height: 40))
        for view in [field, textView, selectionHolder] as [NSView] { host.addSubview(view) }
        let next = try arrow(right: true, modifiers: [.command, .option])

        for responder in [field, textView, selectionHolder] as [NSView] {
            XCTAssertTrue(window.makeFirstResponder(responder))
            XCTAssertFalse(window.performKeyEquivalent(with: next), "\(type(of: responder)) keeps the arrows")
        }
        XCTAssertEqual(selected, [])

        selectionHolder.hasSelection = false
        XCTAssertTrue(window.makeFirstResponder(selectionHolder))
        XCTAssertTrue(window.performKeyEquivalent(with: next))
        XCTAssertTrue(window.makeFirstResponder(host))
        XCTAssertTrue(window.performKeyEquivalent(with: next))
        XCTAssertEqual(selected, [2, 2])
    }

    func testSpaceStaysWithAFocusedControlUnderFullKeyboardAccess() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered,
            defer: false)
        let control = NSButton(title: "Info", target: nil, action: nil)
        XCTAssertFalse(
            PreviewPanelShortcut.playPause.isAvailable(firstResponder: control, in: window, fullKeyboardAccess: true))
        XCTAssertTrue(
            PreviewPanelShortcut.playPause.isAvailable(firstResponder: control, in: window, fullKeyboardAccess: false))
        XCTAssertTrue(
            PreviewPanelShortcut.playPause.isAvailable(firstResponder: window, in: window, fullKeyboardAccess: true))
        XCTAssertTrue(
            PreviewPanelShortcut.nextFile.isAvailable(firstResponder: control, in: window, fullKeyboardAccess: true))
        XCTAssertFalse(
            PreviewPanelShortcut.playPause.isAvailable(
                firstResponder: NSTextView(), in: window, fullKeyboardAccess: false))
    }

    func testLoadingIndicatorBelongsToTheGenerationThatWaited() {
        let state = FinderPreviewState()
        state.urls = [first, second]
        state.generation = 1
        state.trust = trust
        state.kind = .image
        state.revealLoadingIndicator(for: 1)
        XCTAssertFalse(state.showsLoadingIndicator, "a loaded file never shows the spinner")

        state.generation = 2
        state.selectedIndex = 1
        state.kind = nil
        state.trust = nil
        XCTAssertFalse(state.showsLoadingIndicator, "no spinner on the first frame of the next file")
        state.revealLoadingIndicator(for: 1)
        XCTAssertFalse(state.showsLoadingIndicator, "a stale delay cannot reveal it")
        state.revealLoadingIndicator(for: 2)
        XCTAssertTrue(state.showsLoadingIndicator)

        state.trust = trust
        state.kind = .text
        XCTAssertFalse(state.showsLoadingIndicator)
    }

    func testAnnouncementUsesTheRealKind() throws {
        let directory = try PreviewImageFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appending(path: "notes.md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let folderKind = try XCTUnwrap(
            try directory.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription)
        let spoken = try FinderPreviewView.spokenDescription(of: folder)
        XCTAssertTrue(spoken.hasPrefix("notes.md"))
        XCTAssertTrue(spoken.hasSuffix(folderKind), spoken)
    }

    private func hostPanel(
        _ state: FinderPreviewState, select: @escaping (Int) -> Void
    ) async throws -> (NSWindow, NSHostingView<some View>) {
        let settings = SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "Panel-\(UUID().uuidString)")))
        let staging = StagingArea(
            supportDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let window = NSWindow(
            contentRect: NSRect(x: -5_000, y: 0, width: 420, height: 400), styleMask: [.borderless], backing: .buffered,
            defer: false)
        var mounted = false
        let host = NSHostingView(
            rootView: FinderPreviewView(
                state: state, settings: settings, staging: staging, close: {}, retry: {}, select: select,
                resize: { _ in }
            ).onAppear { mounted = true })
        window.contentView = host
        window.orderFrontRegardless()
        try await waitUntil {
            window.layoutIfNeeded()
            return mounted && host.fittingSize.width > 0
        }
        window.displayIfNeeded()
        return (window, host)
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

private final class CopyableSelectionView: NSView, NSMenuItemValidation {
    var hasSelection = true

    override var acceptsFirstResponder: Bool { true }

    @objc func copy(_ sender: Any?) {}

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(copy(_:)) && hasSelection
    }
}
