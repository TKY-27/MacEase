import AppKit
import Engine
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
        let directory = try PreviewFixtures.directory(self)
        let view = try textView(showing: "one two one", in: directory)
        let find = PreviewFind()
        find.attach(view)
        find.query = "one"
        await Task.yield()
        XCTAssertNil(find.outcome, "a hidden bar does not search")

        find.present()
        let firstMatched = try await PreviewFixtures.waitUntil {
            find.outcome == PreviewFindOutcome(found: true, current: 1, total: 2)
        }
        XCTAssertTrue(firstMatched)
        find.next()
        let secondMatched = try await PreviewFixtures.waitUntil { find.outcome?.current == 2 }
        XCTAssertTrue(secondMatched)
        find.query = "three"
        let notFound = try await PreviewFixtures.waitUntil { find.outcome == .notFound }
        XCTAssertTrue(notFound)

        find.dismiss()
        XCTAssertFalse(find.isPresented)
        XCTAssertNil(find.outcome)
        XCTAssertEqual(find.query, "three", "the query stays while the same file is selected")

        // Real selection change resets Find state.
        let firstFile = directory.appendingPathComponent("first.txt")
        let secondFile = directory.appendingPathComponent("second.txt")
        try Data("alpha one".utf8).write(to: firstFile)
        try Data("beta two".utf8).write(to: secondFile)
        let suite = "PreviewFindTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let state = FinderPreviewState()
        state.urls = [firstFile]
        state.kind = .text
        state.trust = PreviewTrust(level: .standard, resolvedPath: firstFile.path)
        state.generation = 1
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 320, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: FinderPreviewView(
                state: state, settings: store, staging: StagingArea(supportDirectory: directory), close: {}, retry: {},
                select: { _ in }, resize: { _ in }))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let loadedFirst = try await PreviewFixtures.waitUntil {
            window.contentView.flatMap { Self.first(PreviewTextView.self, in: $0) } != nil
        }
        XCTAssertTrue(loadedFirst)
        XCTAssertTrue(window.performKeyEquivalent(with: try key("f", modifiers: .command)))
        let fieldShown = try await PreviewFixtures.waitUntil {
            window.contentView.flatMap(Self.searchField)?.currentEditor() != nil
        }
        XCTAssertTrue(fieldShown)
        let firstField = try XCTUnwrap(window.contentView.flatMap(Self.searchField))
        let editor = try XCTUnwrap(firstField.currentEditor() as? NSTextView)
        editor.insertText("alpha", replacementRange: editor.selectedRange())
        let entered = try await PreviewFixtures.waitUntil { firstField.stringValue == "alpha" }
        XCTAssertTrue(entered)

        state.urls = [secondFile]
        state.kind = .text
        state.trust = PreviewTrust(level: .standard, resolvedPath: secondFile.path)
        state.generation += 1
        let barClosed = try await PreviewFixtures.waitUntil { window.contentView.flatMap(Self.searchField) == nil }
        XCTAssertTrue(barClosed, "selecting another file closes Find")
        let loadedSecond = try await PreviewFixtures.waitUntil {
            window.contentView.flatMap { Self.first(PreviewTextView.self, in: $0) }?.string == "beta two"
        }
        XCTAssertTrue(loadedSecond)
        XCTAssertTrue(window.performKeyEquivalent(with: try key("f", modifiers: .command)))
        let secondFieldShown = try await PreviewFixtures.waitUntil {
            window.contentView.flatMap(Self.searchField) != nil
        }
        XCTAssertTrue(secondFieldShown)
        XCTAssertEqual(window.contentView.flatMap(Self.searchField)?.stringValue, "")
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
        let loaded = try await PreviewFixtures.waitUntil {
            window.contentView.flatMap { Self.first(PreviewTextView.self, in: $0) } != nil
        }
        XCTAssertTrue(loaded)
        XCTAssertNil(window.firstResponder as? NSText)

        XCTAssertTrue(window.performKeyEquivalent(with: try key("f", modifiers: .command)))
        let focusedField = try await PreviewFixtures.waitUntil {
            guard let field = window.contentView.flatMap(Self.searchField) else { return false }
            return window.firstResponder === field.currentEditor()
        }
        XCTAssertTrue(focusedField, "the find field takes focus")

        XCTAssertTrue(window.performKeyEquivalent(with: try key("\u{1B}", keyCode: 53)))
        let closed = try await PreviewFixtures.waitUntil {
            window.contentView.flatMap(Self.searchField) == nil && window.firstResponder is PreviewTextView
        }
        XCTAssertTrue(closed, "focus returns to the text")
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
        let loaded = try await PreviewFixtures.waitUntil {
            window.contentView.flatMap { Self.first(PreviewWKWebView.self, in: $0) } != nil
        }
        XCTAssertTrue(loaded)
        let page = try XCTUnwrap(window.contentView.flatMap { Self.first(PreviewWKWebView.self, in: $0) })
        XCTAssertTrue(window.makeFirstResponder(page))

        XCTAssertTrue(window.performKeyEquivalent(with: try key("f", modifiers: .command)))
        let focused = try await PreviewFixtures.waitUntil {
            guard let field = window.contentView.flatMap(Self.searchField) else { return false }
            return window.firstResponder === field.currentEditor()
        }
        XCTAssertTrue(focused)
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
        try await PreviewFixtures.withAccessibilityEnabled {
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
            let content = try XCTUnwrap(window.contentView)
            let promptReady = try await PreviewFixtures.waitUntil {
                Self.first(NSSecureTextField.self, in: content) != nil
            }
            XCTAssertTrue(promptReady)
            XCTAssertNil(Self.first(PreviewPDFView.self, in: content))

            try await submit("wrong", in: window)
            let errorVisible = try await PreviewFixtures.waitUntil(timeout: .seconds(1)) {
                PreviewFixtures.visibleTexts(in: content).contains("The password is incorrect.")
            }
            XCTAssertTrue(
                errorVisible,
                "wrong password must keep the error message visible: \(PreviewFixtures.visibleTexts(in: content))")
            // Confirm SwiftUI onChange does not clear it.
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(
                PreviewFixtures.visibleTexts(in: content).contains("The password is incorrect."),
                "error disappeared after password reset: \(PreviewFixtures.visibleTexts(in: content))")
            XCTAssertNil(Self.first(PreviewPDFView.self, in: content), "a wrong password keeps the PDF locked")
            XCTAssertEqual(Self.first(NSSecureTextField.self, in: content)?.stringValue, "")

            try await submit("right", in: window)
            let unlocked = try await PreviewFixtures.waitUntil { Self.first(PreviewPDFView.self, in: content) != nil }
            XCTAssertTrue(unlocked)
            let viewer = try XCTUnwrap(Self.first(PreviewPDFView.self, in: content))
            XCTAssertEqual(viewer.document?.isLocked, false)
        }
    }

    func testPDFViewNavigatorAssignmentPreservesOtherNotificationObservers() throws {
        let notificationName = Notification.Name("MacEasePreviewPDFObserverPreservedTest")
        let view = PreviewPDFView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        PreviewPDFView.customNotificationCount = 0
        NotificationCenter.default.addObserver(
            view, selector: #selector(PreviewPDFView.observedCustomForTest), name: notificationName, object: nil)
        defer { NotificationCenter.default.removeObserver(view, name: notificationName, object: nil) }

        let navigator = PreviewPDFNavigator()
        view.navigator = navigator
        NotificationCenter.default.post(name: notificationName, object: nil)
        XCTAssertEqual(PreviewPDFView.customNotificationCount, 1)
    }

    func testPDFPageFieldResetsInvalidEntriesAndOmitsGroupingCommaAtOneThousandPages() async throws {
        let directory = try PreviewFixtures.directory(self)
        let shortPDF = try Self.pdf(pages: ["one", "two", "three", "four"], in: directory)
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 420, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: PreviewPDFViewer(url: shortPDF))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let content = try XCTUnwrap(window.contentView)
        let ready = try await PreviewFixtures.waitUntil {
            Self.first(PreviewPDFView.self, in: content) != nil
                && Self.editableField(in: content) != nil
        }
        XCTAssertTrue(ready)

        for (entered, expected) in [("0", "1"), ("-5", "1"), ("99", "4"), ("99", "4"), ("abc", "4")] {
            let field = try XCTUnwrap(Self.editableField(in: content))
            try submitText(entered, in: field, window: window)
            let reset = try await PreviewFixtures.waitUntil(timeout: .seconds(1)) { field.stringValue == expected }
            XCTAssertTrue(reset, "expected \(expected) after entering \(entered), got \(field.stringValue)")
        }

        let longPDF = try Self.pdf(pages: Array(repeating: "", count: 1005), in: directory)
        window.contentView = NSHostingView(rootView: PreviewPDFViewer(url: longPDF))
        let longContent = try XCTUnwrap(window.contentView)
        let longReady = try await PreviewFixtures.waitUntil {
            Self.first(PreviewPDFView.self, in: longContent) != nil
                && Self.editableField(in: longContent) != nil
        }
        XCTAssertTrue(longReady)
        let longField = try XCTUnwrap(Self.editableField(in: longContent))
        try submitText("1000", in: longField, window: window)
        let atThousand = try await PreviewFixtures.waitUntil(timeout: .seconds(1)) { longField.stringValue == "1000" }
        XCTAssertTrue(atThousand, "got \(longField.stringValue)")
    }

    func testPDFRapidFindQueriesCompleteWithoutLeakingAndKeepLatestResult() async throws {
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 20)
        let pages = (0..<600).map { $0.isMultiple(of: 2) ? "alpha \($0) \(filler)" : "omega \($0) \(filler)" }
        let url = try Self.pdf(pages: pages, in: try PreviewFixtures.directory(self))
        let view = PreviewPDFView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let recordedDocument = try XCTUnwrap(FindRecordingPDFDocument(url: url))
        view.document = recordedDocument

        let first = Task { await view.find("alpha", direction: .forward, restart: true) }
        await Task.yield()
        let second = Task { await view.find("beta", direction: .forward, restart: true) }
        second.cancel()
        let third = Task { await view.find("omega", direction: .forward, restart: true) }
        first.cancel()

        var outcomes: [PreviewFindOutcome]?
        let watcher = Task { @MainActor in
            outcomes = [await first.value, await second.value, await third.value]
        }
        let finished = try await PreviewFixtures.waitUntil(timeout: .seconds(5)) { outcomes != nil }
        watcher.cancel()
        XCTAssertTrue(finished, "rapid PDF queries leaked a continuation")
        let settled = try XCTUnwrap(outcomes)
        XCTAssertEqual(settled[0], .notFound)
        XCTAssertEqual(settled[1], .notFound)
        XCTAssertEqual(settled[2], PreviewFindOutcome(found: true, current: 1, total: 300))
        XCTAssertEqual(view.highlightedSelections?.count, 300)
        XCTAssertFalse(recordedDocument.startedQueries.contains("beta"), "\(recordedDocument.startedQueries)")
    }

    func testPDFNavigatorIgnoresGoToPageOnZeroPageDocument() {
        let view = PreviewPDFView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let emptyDocument = IndexRecordingPDFDocument()
        view.document = emptyDocument
        let navigator = PreviewPDFNavigator()
        view.navigator = navigator
        navigator.attach(view)
        XCTAssertEqual(navigator.pageCount, 0)
        navigator.go(toPage: 1)
        navigator.go(toPage: 0)
        XCTAssertEqual(navigator.pageNumber, 0)
        XCTAssertFalse(emptyDocument.requestedIndices.contains { $0 < 0 }, "\(emptyDocument.requestedIndices)")
    }

    func testDamagedPDFShowsFailureMessage() async throws {
        try await PreviewFixtures.withAccessibilityEnabled {
            let directory = try PreviewFixtures.directory(self)
            let damaged = directory.appendingPathComponent("damaged.pdf")
            try Data("not a valid pdf".utf8).write(to: damaged)
            let window = NSWindow(
                contentRect: NSRect(x: -2000, y: -2000, width: 320, height: 400), styleMask: [.titled],
                backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: PreviewPDFViewer(url: damaged))
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            let content = try XCTUnwrap(window.contentView)
            let failed = try await PreviewFixtures.waitUntil {
                PreviewFixtures.visibleTexts(in: content).contains("This preview could not be displayed.")
            }
            XCTAssertTrue(failed, "\(PreviewFixtures.visibleTexts(in: content))")
            XCTAssertNil(Self.first(PreviewPDFView.self, in: content))
        }
    }

    func testPDFSearchCancelsCleanlyOnClose() async throws {
        let pages = (0..<200).map { "searchable text \($0)" }
        let url = try Self.pdf(pages: pages, in: try PreviewFixtures.directory(self))
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 320, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: PreviewPDFViewer(url: url))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let loaded = try await PreviewFixtures.waitUntil {
            window.contentView.flatMap { Self.first(PreviewPDFView.self, in: $0) } != nil
        }
        XCTAssertTrue(loaded)
        let pdfView = try XCTUnwrap(window.contentView.flatMap { Self.first(PreviewPDFView.self, in: $0) })
        let searchTask = Task { await pdfView.find("searchable", direction: .forward, restart: true) }
        await Task.yield()
        window.contentView = NSView()
        searchTask.cancel()
        let outcome = await searchTask.value
        XCTAssertEqual(outcome, .notFound)
        XCTAssertNil(pdfView.document)
    }

    private func submit(_ password: String, in window: NSWindow) async throws {
        let field = try XCTUnwrap(window.contentView.flatMap { Self.first(NSSecureTextField.self, in: $0) })
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(password, replacementRange: editor.selectedRange())
        // Let SwiftUI observe the non-empty password first.
        _ = try await PreviewFixtures.waitUntil(timeout: .milliseconds(200)) { field.stringValue == password }
        try await Task.sleep(for: .milliseconds(50))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    private func submitText(_ text: String, in field: NSTextField, window: NSWindow) throws {
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
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

    private static func editableField(in view: NSView) -> NSTextField? {
        all(NSTextField.self, in: view).first { $0.isEditable && !($0 is NSSearchField) && !($0 is NSSecureTextField) }
    }

    static func first<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
        if let match = view as? View { return match }
        for child in view.subviews {
            if let match = first(type, in: child) { return match }
        }
        return nil
    }

    static func all<View: NSView>(_ type: View.Type, in view: NSView) -> [View] {
        var matches: [View] = []
        if let match = view as? View { matches.append(match) }
        for child in view.subviews { matches.append(contentsOf: all(type, in: child)) }
        return matches
    }

    static func pdf(pages: [String], outline: [(title: String, page: Int)] = [], in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for text in pages {
            context.beginPDFPage(nil)
            if !text.isEmpty {
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)]))
                context.textPosition = CGPoint(x: 20, y: 300)
                CTLineDraw(line, context)
            }
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

private extension PreviewPDFView {
    static var customNotificationCount = 0

    @objc func observedCustomForTest() { Self.customNotificationCount += 1 }
}

private final class IndexRecordingPDFDocument: PDFDocument {
    var requestedIndices: [Int] = []

    override func page(at index: Int) -> PDFPage? {
        requestedIndices.append(index)
        return super.page(at: index)
    }
}

private final class FindRecordingPDFDocument: PDFDocument {
    var startedQueries: [String] = []

    override func beginFindString(_ string: String, withOptions options: NSString.CompareOptions = []) {
        startedQueries.append(string)
        super.beginFindString(string, withOptions: options)
    }
}
