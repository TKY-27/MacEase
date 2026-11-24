import AppKit
import PDFKit
import SwiftUI
import XCTest

@testable import MacEase

@MainActor
final class PreviewFindTests: XCTestCase {
    private func textView(showing text: String, in directory: URL) throws -> PreviewTextView {
        let file = directory.appendingPathComponent("notes.txt")
        try Data(text.utf8).write(to: file)
        let rendering = try PreviewTextRendering.make(
            source: try PreviewTextSource.read(file), encoding: .automatic, rich: false, kind: .text, url: file,
            restricted: false)
        let view = PreviewTextView(usingTextLayoutManager: true)
        view.show(rendering, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        return view
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    func testTextFindCountsMatchesWrapsBothWaysAndIgnoresCase() async throws {
        let view = try textView(showing: "alpha beta Alpha gamma ALPHA delta", in: try PreviewFixtures.directory(self))

        let first = await view.find("alpha", direction: .forward, restart: true)
        XCTAssertEqual(first, PreviewFindOutcome(found: true, current: 1, total: 3))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 5))
        let steps = [
            (PreviewFindDirection.forward, 2), (.forward, 3), (.forward, 1), (.backward, 3), (.backward, 2),
        ]
        for (direction, expected) in steps {
            let outcome = await view.find("alpha", direction: direction, restart: false)
            XCTAssertEqual(outcome.current, expected)
        }
        XCTAssertEqual(view.selectedRange(), NSRange(location: 11, length: 5))
        let missing = await view.find("omega", direction: .forward, restart: true)
        XCTAssertEqual(missing, .notFound)
    }

    func testFindModelSearchesAttachedViewerAndKeepsQueryUntilANewFileIsSelected() async throws {
        let view = try textView(showing: "one two one", in: try PreviewFixtures.directory(self))
        let find = PreviewFind()
        find.attach(view)
        find.query = "one"
        try await settle()
        XCTAssertNil(find.outcome, "a hidden bar does not search")

        find.present()
        try await settle()
        XCTAssertEqual(find.outcome, PreviewFindOutcome(found: true, current: 1, total: 2))
        find.next()
        try await settle()
        XCTAssertEqual(find.outcome?.current, 2)
        find.query = "three"
        try await settle()
        XCTAssertEqual(find.outcome, .notFound)

        find.dismiss()
        XCTAssertFalse(find.isPresented)
        XCTAssertNil(find.outcome)
        XCTAssertEqual(find.query, "three", "the query stays while the same file is selected")
        XCTAssertEqual(PreviewFind().query, "", "each newly selected file starts empty")
    }

    func testCommandFOpensFindWithoutClickingIntoTheTextAndEscapeClosesIt() async throws {
        let directory = try PreviewFixtures.directory(self)
        let file = directory.appendingPathComponent("notes.txt")
        try Data("searchable words".utf8).write(to: file)
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 320, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: PreviewTextViewer(
                url: file, kind: .text, trust: PreviewTrust(level: .standard, resolvedPath: file.path),
                settings: FinderPreviewSettings(), scriptConsent: .constant([])))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(window.firstResponder as? NSText)

        XCTAssertTrue(window.performKeyEquivalent(with: try key("f", modifiers: .command)))
        try await Task.sleep(for: .milliseconds(300))
        let field = try XCTUnwrap(window.contentView.flatMap(Self.searchField))
        XCTAssertTrue(window.firstResponder === field.currentEditor(), "the find field takes focus")

        XCTAssertTrue(window.performKeyEquivalent(with: try key("\u{1B}", keyCode: 53)))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(window.contentView.flatMap(Self.searchField))
        XCTAssertTrue(window.firstResponder is PreviewTextView, "focus returns to the text")
    }

    func testCommandFReachesTheFindBarWhileRenderedMarkdownHasFocus() async throws {
        let file = try PreviewFixtures.directory(self).appendingPathComponent("README.md")
        try Data("# Title\n\nSome words.".utf8).write(to: file)
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 320, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: PreviewTextViewer(
                url: file, kind: .markdown, trust: PreviewTrust(level: .standard, resolvedPath: file.path),
                settings: FinderPreviewSettings(), scriptConsent: .constant([])))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(800))
        let page = try XCTUnwrap(window.contentView.flatMap { Self.first(PreviewWKWebView.self, in: $0) })
        XCTAssertTrue(window.makeFirstResponder(page))

        XCTAssertTrue(window.performKeyEquivalent(with: try key("f", modifiers: .command)))
        try await Task.sleep(for: .milliseconds(300))
        let field = try XCTUnwrap(window.contentView.flatMap(Self.searchField))
        XCTAssertTrue(window.firstResponder === field.currentEditor())
    }

    func testPDFFindHighlightsEveryMatchAndWrapsAcrossPages() async throws {
        let url = try Self.pdf(
            pages: ["needle one", "nothing", "needle two NEEDLE"], in: try PreviewFixtures.directory(self))
        let view = PreviewPDFView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        view.document = try XCTUnwrap(PDFDocument(url: url))

        let first = await view.find("needle", direction: .forward, restart: true)
        XCTAssertEqual(first, PreviewFindOutcome(found: true, current: 1, total: 3))
        XCTAssertEqual(view.highlightedSelections?.count, 3)
        let last = await view.find("needle", direction: .backward, restart: false)
        XCTAssertEqual(last.current, 3)
        XCTAssertEqual(view.currentSelection?.pages.first.flatMap { view.document?.index(for: $0) }, 2)
        let wrapped = await view.find("needle", direction: .forward, restart: false)
        XCTAssertEqual(wrapped.current, 1)
        let missing = await view.find("haystack", direction: .forward, restart: true)
        XCTAssertEqual(missing, .notFound)
        view.endFind()
        XCTAssertNil(view.highlightedSelections)
    }

    func testPDFNavigatorReadsPagesJumpsAndOffersOutlineOnlyWhenPresent() throws {
        let directory = try PreviewFixtures.directory(self)
        let plain = try Self.pdf(pages: ["a", "b", "c", "d"], in: directory)
        let view = PreviewPDFView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let navigator = PreviewPDFNavigator()
        view.document = try XCTUnwrap(PDFDocument(url: plain))
        view.navigator = navigator
        navigator.attach(view)
        XCTAssertEqual(navigator.pageCount, 4)
        XCTAssertEqual(navigator.pageNumber, 1)
        XCTAssertTrue(navigator.outline.isEmpty)
        navigator.go(toPage: 3)
        XCTAssertEqual(navigator.pageNumber, 3, "the readout follows page changes")
        navigator.go(toPage: 99)
        XCTAssertEqual(navigator.pageNumber, 4)
        navigator.actualSize()
        XCTAssertFalse(navigator.fitsWidth)
        XCTAssertEqual(view.scaleFactor, 1)
        navigator.fitWidth()
        XCTAssertTrue(view.autoScales)

        let outlined = try XCTUnwrap(
            PDFDocument(
                url: try Self.pdf(
                    pages: ["a", "b", "c", "d"], outline: [("Intro", 0), ("Details", 2)], in: directory)))
        view.document = outlined
        navigator.attach(view)
        XCTAssertEqual(navigator.outline.map(\.title), ["Intro", "Details"])
        navigator.go(to: try XCTUnwrap(navigator.outline[1].destination))
        XCTAssertEqual(navigator.pageNumber, 3)
    }

    func testLockedPDFShowsPasswordFieldRejectsWrongPasswordAndOpensWithRightOne() async throws {
        let directory = try PreviewFixtures.directory(self)
        let open = try Self.pdf(pages: ["secret page"], in: directory)
        let locked = directory.appendingPathComponent("locked.pdf")
        let document = try XCTUnwrap(PDFDocument(url: open))
        XCTAssertTrue(
            document.write(to: locked, withOptions: [.userPasswordOption: "right", .ownerPasswordOption: "owner"]))
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 320, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: PreviewPDFViewer(url: locked))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(600))
        let content = try XCTUnwrap(window.contentView)
        XCTAssertNil(Self.first(PreviewPDFView.self, in: content))

        try submit("wrong", in: window)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(Self.first(PreviewPDFView.self, in: content), "a wrong password keeps the PDF locked")
        XCTAssertEqual(Self.first(NSSecureTextField.self, in: content)?.stringValue, "")

        try submit("right", in: window)
        try await Task.sleep(for: .milliseconds(300))
        let viewer = try XCTUnwrap(Self.first(PreviewPDFView.self, in: content))
        XCTAssertEqual(viewer.document?.isLocked, false)
    }

    private func submit(_ password: String, in window: NSWindow) throws {
        let field = try XCTUnwrap(window.contentView.flatMap { Self.first(NSSecureTextField.self, in: $0) })
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText(password, replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    private func key(_ characters: String, keyCode: UInt16 = 3, modifiers: NSEvent.ModifierFlags = []) throws
        -> NSEvent
    {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: keyCode))
    }

    private static func searchField(in view: NSView) -> NSSearchField? { first(NSSearchField.self, in: view) }

    static func first<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
        if let match = view as? View { return match }
        for child in view.subviews {
            if let match = first(type, in: child) { return match }
        }
        return nil
    }

    static func pdf(pages: [String], outline: [(title: String, page: Int)] = [], in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for text in pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)]))
            context.textPosition = CGPoint(x: 20, y: 300)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        if !outline.isEmpty {
            let children = outline.map { ["Title": $0.title, "Destination": $0.page + 1] as [String: Any] }
            CGPDFContextSetOutline(context, ["Children": children] as CFDictionary)
        }
        context.closePDF()
        return url
    }
}
