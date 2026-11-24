import AppKit
import CoreText
import Engine
import SwiftUI
import XCTest

@testable import MacEase

@MainActor
final class PreviewTextDecorationTests: XCTestCase {
    private static let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    struct Shown {
        let window: NSWindow
        let scroll: NSScrollView
        let textView: PreviewTextView
    }

    static func rendering(_ text: String, fileName: String, in directory: URL) throws -> PreviewTextRendering {
        let file = directory.appendingPathComponent(fileName)
        try Data(text.utf8).write(to: file)
        return try PreviewTextRendering.make(
            source: try PreviewTextSource.read(file), encoding: .automatic, rich: false, kind: .text, url: file,
            restricted: false)
    }

    static func show(
        _ rendering: PreviewTextRendering, width: CGFloat = 360, height: CGFloat = 200, wrap: Bool = true,
        appearance: NSAppearance.Name = .aqua
    ) -> Shown {
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: width, height: height), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.hasVerticalScroller = false
        let textView = PreviewTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wrap
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = wrap ? [.width] : []
        textView.textContainer?.widthTracksTextView = wrap
        textView.textContainer?.containerSize = NSSize(
            width: wrap ? width : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        scroll.documentView = textView
        window.contentView = scroll
        textView.show(rendering, font: font)
        window.orderBack(nil)
        settle(window)
        return Shown(window: window, scroll: scroll, textView: textView)
    }

    static func settle(_ window: NSWindow) {
        window.layoutIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    static func image(of shown: Shown) throws -> NSBitmapImageRep {
        settle(shown.window)
        let view = shown.scroll
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    // Point coordinates, top-left origin.
    static func pixel(_ bitmap: NSBitmapImageRep, at point: CGPoint) -> NSColor? {
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        return bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB)
    }

    static func isMarkColored(_ color: NSColor?) -> Bool {
        guard let color else { return false }
        return color.redComponent > 0.6 && color.redComponent - color.blueComponent > 0.4
            && color.greenComponent < color.redComponent
    }

    // Columns holding a mark-colored pixel.
    static func markColumns(in bitmap: NSBitmapImageRep) -> [Int] {
        (0..<bitmap.pixelsWide).filter { x in
            (0..<bitmap.pixelsHigh).contains { y in
                isMarkColored(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            }
        }
    }

    static func viewRect(of mark: CGRect, in fragment: NSTextLayoutFragment, textView: NSTextView) -> CGRect {
        mark.offsetBy(
            dx: fragment.layoutFragmentFrame.minX + textView.textContainerOrigin.x,
            dy: fragment.layoutFragmentFrame.minY + textView.textContainerOrigin.y)
    }

    static func fragments(of textView: NSTextView) throws -> [NSTextLayoutFragment] {
        let layout = try XCTUnwrap(textView.textLayoutManager)
        var found: [NSTextLayoutFragment] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) {
            found.append($0)
            return true
        }
        return found
    }

    func testZeroWidthMarksDrawAtTheirCaretAndChangeNoOtherPixel() throws {
        let directory = try PreviewFixtures.directory(self)
        let flagged = try Self.rendering("let user\u{200B}Name = 1\n", fileName: "a.swift", in: directory)
        let plain = try Self.rendering("let userName = 1\n", fileName: "b.swift", in: directory)
        XCTAssertEqual(flagged.invisibleCharacters.map(\.codePointLabel), ["U+200B"])

        let marked = Self.show(flagged)
        defer { marked.window.orderOut(nil) }
        let unmarked = Self.show(plain)
        defer { unmarked.window.orderOut(nil) }
        let fragment = try XCTUnwrap(Self.fragments(of: marked.textView).first as? PreviewTextFragment)
        let placed = fragment.markRects(within: .infinite)
        XCTAssertEqual(placed.map(\.mark.scalar), ["\u{200B}"])
        let mark = Self.viewRect(of: try XCTUnwrap(placed.first?.rect), in: fragment, textView: marked.textView)
        let caret = Self.font.advancement(forGlyph: Self.font.glyph(withName: "a")).width * 8
        let padding = try XCTUnwrap(marked.textView.textContainer).lineFragmentPadding
        XCTAssertEqual(
            mark.minX, marked.textView.textContainerOrigin.x + padding + caret, accuracy: 1, "mark sits after user")

        let markedImage = try Self.image(of: marked)
        let unmarkedImage = try Self.image(of: unmarked)
        XCTAssertTrue(Self.isMarkColored(Self.pixel(markedImage, at: CGPoint(x: mark.minX, y: mark.midY))))
        XCTAssertTrue(Self.markColumns(in: unmarkedImage).isEmpty)
        let scale = CGFloat(markedImage.pixelsWide) / markedImage.size.width
        let columns = Self.markColumns(in: markedImage)
        XCTAssertFalse(columns.isEmpty)
        // Antialiased edges blend into the text.
        let band = ((columns.min() ?? 0) - 2)...((columns.max() ?? 0) + 2)
        XCTAssertLessThan(CGFloat(band.count) / scale, 8, "one small mark")
        var changed = 0
        for x in 0..<markedImage.pixelsWide where !band.contains(x) {
            for y in 0..<markedImage.pixelsHigh
            where markedImage.colorAt(x: x, y: y) != unmarkedImage.colorAt(x: x, y: y) {
                changed += 1
            }
        }
        XCTAssertEqual(changed, 0, "text renders exactly as without the mark")
    }

    func testMarksStayVisibleOverTheSelectionAndInDarkMode() throws {
        let directory = try PreviewFixtures.directory(self)
        let rendering = try Self.rendering("abc\u{202E}def\n", fileName: "a.txt", in: directory)
        let shown = Self.show(rendering, appearance: .darkAqua)
        defer { shown.window.orderOut(nil) }
        shown.textView.setSelectedRange(NSRange(location: 0, length: 8))
        let fragment = try XCTUnwrap(Self.fragments(of: shown.textView).first as? PreviewTextFragment)
        let mark = Self.viewRect(
            of: try XCTUnwrap(fragment.markRects(within: .infinite).first?.rect), in: fragment,
            textView: shown.textView)
        let image = try Self.image(of: shown)
        XCTAssertTrue(Self.isMarkColored(Self.pixel(image, at: CGPoint(x: mark.minX, y: mark.midY))))
    }

    func testMarksDoNotChangeShapingOfHindiMarathiAndPersian() throws {
        let directory = try PreviewFixtures.directory(self)
        // Joining is transparent across U+034F.
        let samples = [
            "हिन्दी में क्‍ष और मराठी र‍्‍य लिखा है।\u{200B}\n",
            "من می‌خواهم این کتاب‌ها را بخوانم\u{2066}.\n",
            "من این کتا\u{034F}ب‌ها را می‌خوانم.\n",
            "मराठी में र‍्‍य और क\u{034F}्ष लिखा है।\n",
        ]
        for sample in samples {
            let flagged = try Self.rendering(sample, fileName: "sample.txt", in: directory)
            XCTAssertEqual(flagged.invisibleCharacters.count, 1, sample)
            let plain = PreviewTextRendering(
                text: flagged.text, tokens: [], lineStarts: flagged.lineStarts, html: false, decodedAs: nil,
                invisibleCharacters: [], altersReading: false, scannedPartially: false)
            let marked = Self.show(flagged)
            defer { marked.window.orderOut(nil) }
            let unmarked = Self.show(plain)
            defer { unmarked.window.orderOut(nil) }
            let markedLines = try Self.fragments(of: marked.textView).flatMap(\.textLineFragments)
            let plainLines = try Self.fragments(of: unmarked.textView).flatMap(\.textLineFragments)
            XCTAssertEqual(markedLines.count, plainLines.count, sample)
            for (markedLine, plainLine) in zip(markedLines, plainLines) {
                XCTAssertEqual(
                    markedLine.typographicBounds.width, plainLine.typographicBounds.width, accuracy: 0.01, sample)
                XCTAssertEqual(Self.glyphCount(markedLine), Self.glyphCount(plainLine), sample)
            }
            let fragment = try XCTUnwrap(Self.fragments(of: marked.textView).first as? PreviewTextFragment)
            XCTAssertEqual(fragment.markRects(within: .infinite).count, 1, sample)
        }
    }

    private static func glyphCount(_ line: NSTextLineFragment) -> Int {
        let shown = line.attributedString.attributedSubstring(from: line.characterRange)
        return CTLineGetGlyphCount(CTLineCreateWithAttributedString(shown))
    }

    func testCopyKeepsFlaggedCharactersAndStorageCarriesNoMarkAttributes() throws {
        let directory = try PreviewFixtures.directory(self)
        let text = "if (isAdmin\u{202E} \u{2066}// x\u{2069}\u{2066}) {\u{200B}\n"
        let shown = Self.show(try Self.rendering(text, fileName: "trojan.js", in: directory))
        defer { shown.window.orderOut(nil) }
        shown.textView.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(shown.textView.writeSelection(to: pasteboard, types: shown.textView.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), text)
        let storage = try XCTUnwrap(shown.textView.textStorage)
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, _, _ in
            XCTAssertNil(attributes[.backgroundColor])
            XCTAssertNil(attributes[.kern])
            XCTAssertNil(attributes[.underlineStyle])
            XCTAssertNil(attributes[.toolTip])
        }
    }

    func testVisibleMarksGetToolTipsNamingTheCharacter() async throws {
        let directory = try PreviewFixtures.directory(self)
        let lines = (0..<200).map { $0 == 150 ? "far\u{2066}away\n" : "line \($0)\n" }
        let text = "abc\u{200B}\u{200B}\u{2060}def\n" + lines.joined()
        let shown = Self.show(try Self.rendering(text, fileName: "a.txt", in: directory))
        defer { shown.window.orderOut(nil) }
        XCTAssertEqual(
            Array(shown.textView.markToolTips.labels.values), ["U+200B ZERO WIDTH SPACE ×2\nU+2060 WORD JOINER"])

        let far = (text as NSString).range(of: "far")
        shown.textView.scrollRangeToVisible(far)
        let scrolled = try await PreviewFixtures.waitUntil {
            Array(shown.textView.markToolTips.labels.values) == ["U+2066 LEFT-TO-RIGHT ISOLATE"]
        }
        XCTAssertTrue(scrolled, "tooltips follow the visible marks")
        XCTAssertEqual(
            PreviewTextView.toolTip(for: [
                PreviewInvisibleCharacter(range: NSRange(location: 0, length: 1), scalar: "\u{7}")
            ]),
            "U+0007 <control>")
    }

    func testDiffRowsAreTintedAcrossTheFullWidthExceptUnderTheSelection() throws {
        let directory = try PreviewFixtures.directory(self)
        let long = "+" + String(repeating: "wrapped ", count: 12)
        let text = "@@ -1,3 +1,3 @@\n context\n-old\n+\n\(long)\n"
        let shown = Self.show(try Self.rendering(text, fileName: "change.diff", in: directory))
        defer { shown.window.orderOut(nil) }
        let fragments = try Self.fragments(of: shown.textView)
        XCTAssertEqual(fragments.count, 5)
        XCTAssertGreaterThan(fragments[4].textLineFragments.count, 1, "the long added line wraps")
        let origin = shown.textView.textContainerOrigin
        let rightEdge = shown.textView.bounds.width - 2
        func row(_ index: Int, line: Int = 0) -> CGFloat {
            let fragment = fragments[index]
            return origin.y + fragment.layoutFragmentFrame.minY
                + fragment.textLineFragments[line].typographicBounds.midY
        }

        var image = try Self.image(of: shown)
        let background = try XCTUnwrap(Self.pixel(image, at: CGPoint(x: rightEdge, y: row(1))))
        let removed = try XCTUnwrap(Self.pixel(image, at: CGPoint(x: rightEdge, y: row(2))))
        let emptyAdded = try XCTUnwrap(Self.pixel(image, at: CGPoint(x: rightEdge, y: row(3))))
        let wrappedAdded = try XCTUnwrap(Self.pixel(image, at: CGPoint(x: rightEdge, y: row(4, line: 1))))
        XCTAssertGreaterThan(removed.redComponent - removed.greenComponent, 0.02, "removed row is red")
        XCTAssertGreaterThan(emptyAdded.greenComponent - emptyAdded.redComponent, 0.02, "empty added row is green")
        XCTAssertEqual(emptyAdded, wrappedAdded, "wrapped rows share the tint")
        XCTAssertNotEqual(background, emptyAdded)
        XCTAssertEqual(
            try XCTUnwrap(Self.pixel(image, at: CGPoint(x: 1, y: row(3)))), emptyAdded, "the tint starts at the edge")

        shown.textView.setSelectedRange((text as NSString).range(of: " context\n-old\n+\n"))
        image = try Self.image(of: shown)
        let insideSelection = shown.textView.bounds.width - 20
        let selectedContext = Self.pixel(image, at: CGPoint(x: insideSelection, y: row(1)))
        XCTAssertNotEqual(selectedContext, background)
        XCTAssertEqual(
            Self.pixel(image, at: CGPoint(x: insideSelection, y: row(3))), selectedContext,
            "selection looks the same on tinted rows")
    }

    func testUnwrappedDiffTintFollowsTheViewWidth() throws {
        let directory = try PreviewFixtures.directory(self)
        let text = "@@ -1 +1 @@\n+added\n"
        let shown = Self.show(try Self.rendering(text, fileName: "change.patch", in: directory), wrap: false)
        defer { shown.window.orderOut(nil) }
        let wider: CGFloat = 640
        shown.window.setContentSize(NSSize(width: wider, height: 200))
        shown.scroll.frame = NSRect(x: 0, y: 0, width: wider, height: 200)
        shown.textView.setFrameSize(NSSize(width: wider, height: shown.textView.frame.height))
        let fragment = try XCTUnwrap(Self.fragments(of: shown.textView).last)
        let line = try XCTUnwrap(fragment.textLineFragments.first)
        let rowY =
            shown.textView.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.midY
        let image = try Self.image(of: shown)
        let edge = try XCTUnwrap(Self.pixel(image, at: CGPoint(x: wider - 2, y: rowY)))
        XCTAssertGreaterThan(edge.greenComponent - edge.redComponent, 0.02, "tint reaches the widened edge")
    }

    func testTableHidesTheSameCharactersTheSourceViewMarks() {
        XCTAssertEqual(PreviewTable.displayText("a\u{3164}b\u{180E}c"), "a\u{FFFD}b\u{FFFD}c")
        XCTAssertEqual(PreviewTable.displayText("id\u{200D}x"), "id\u{FFFD}x")
        let hebrew = "שלום \u{200F}עולם"
        XCTAssertEqual(PreviewTable.displayText(hebrew), hebrew, "marks in right-to-left text stay")
        let persian = "کتاب\u{200C}ها"
        XCTAssertEqual(PreviewTable.displayText(persian), persian)
    }

    func testNoticeCountsHiddenCharactersOnlyWhenTheyCanMisleadReaders() async throws {
        let directory = try PreviewFixtures.directory(self)
        let risky = directory.appendingPathComponent("trojan.swift")
        try Data("let a = 1\u{202E} // x\u{2066}\nlet b\u{200B} = 2\n".utf8).write(to: risky)
        let quiet = directory.appendingPathComponent("quiet.swift")
        try Data("let b\u{200B} = 2\n".utf8).write(to: quiet)
        let notice = String(localized: "This file contains \(3) hidden or direction-changing characters.")
        let quietNotice = String(localized: "This file contains \(1) hidden or direction-changing characters.")
        XCTAssertNotEqual(notice, "This file contains %lld hidden or direction-changing characters.")

        try await PreviewFixtures.withAccessibilityEnabled {
            let riskyWindow = try host(risky, in: directory)
            defer { riskyWindow.orderOut(nil) }
            let riskyContent = try XCTUnwrap(riskyWindow.contentView)
            let shown = try await PreviewFixtures.waitUntil {
                PreviewFixtures.visibleTexts(in: riskyContent).contains(notice)
            }
            XCTAssertTrue(shown, "\(PreviewFixtures.visibleTexts(in: riskyContent))")

            let quietWindow = try host(quiet, in: directory)
            defer { quietWindow.orderOut(nil) }
            let quietContent = try XCTUnwrap(quietWindow.contentView)
            let loaded = try await PreviewFixtures.waitUntil {
                PreviewFindTests.first(PreviewTextView.self, in: quietContent)?.string == "let b\u{200B} = 2\n"
            }
            XCTAssertTrue(loaded)
            XCTAssertFalse(PreviewFixtures.visibleTexts(in: quietContent).contains(quietNotice))
        }
    }

    private func host(_ file: URL, in directory: URL) throws -> NSWindow {
        let suite = "PreviewTextDecorationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let state = FinderPreviewState()
        state.urls = [file]
        state.kind = .text
        state.trust = PreviewTrust(level: .standard, resolvedPath: file.path)
        state.generation = 1
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 520, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: FinderPreviewView(
                state: state, settings: SettingsStore(defaults: defaults),
                staging: StagingArea(supportDirectory: directory), close: {}, retry: {}, select: { _ in },
                resize: { _ in }))
        window.orderBack(nil)
        return window
    }
}
