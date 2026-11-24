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

    // Drains pending layout and display work.
    static func settle(_ window: NSWindow) {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            RunLoop.main.run(mode: .default, before: Date())
        } while (window.viewsNeedDisplay || window.contentView?.needsLayout == true) && Date() < deadline
    }

    static func image(of shown: Shown, scale: CGFloat? = nil) throws -> NSBitmapImageRep {
        settle(shown.window)
        let view = shown.scroll
        guard let scale else {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap
        }
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    // Point coordinates, top-left origin.
    static func pixel(_ bitmap: NSBitmapImageRep, at point: CGPoint) -> NSColor? {
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        return bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB)
    }

    private final class MarkSwatch: NSView {
        override func draw(_ dirtyRect: NSRect) {
            PreviewTextView.invisibleMarkColor.setFill()
            bounds.fill()
        }
    }

    // Read back through the same capture path.
    static func markColor(in window: NSWindow) throws -> NSColor {
        let content = try XCTUnwrap(window.contentView)
        let swatch = MarkSwatch(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        content.addSubview(swatch)
        defer { swatch.removeFromSuperview() }
        let bitmap = try XCTUnwrap(swatch.bitmapImageRepForCachingDisplay(in: swatch.bounds))
        swatch.cacheDisplay(in: swatch.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }

    static func isMarkColored(_ color: NSColor?, like mark: NSColor) -> Bool {
        guard let color = color?.usingColorSpace(.sRGB) else { return false }
        let tolerance = 0.12
        return abs(color.redComponent - mark.redComponent) < tolerance
            && abs(color.greenComponent - mark.greenComponent) < tolerance
            && abs(color.blueComponent - mark.blueComponent) < tolerance
    }

    // The bar shares pixels with glyphs.
    static func hasMarkPixel(_ bitmap: NSBitmapImageRep, around mark: CGRect, like color: NSColor) -> Bool {
        hasPixel(bitmap, around: mark) { isMarkColored($0, like: color) }
    }

    static func hasPixel(_ bitmap: NSBitmapImageRep, around mark: CGRect, where matches: (NSColor?) -> Bool) -> Bool {
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        let columns = Int((mark.minX - 1) * scale)...Int((mark.minX + 1) * scale)
        let rows = Int(mark.minY * scale)..<Int(mark.maxY * scale)
        return columns.contains { x in rows.contains { y in matches(bitmap.colorAt(x: x, y: y)) } }
    }

    // Columns holding a mark-colored pixel.
    static func markColumns(in bitmap: NSBitmapImageRep, like mark: NSColor) -> [Int] {
        (0..<bitmap.pixelsWide).filter { x in
            (0..<bitmap.pixelsHigh).contains { y in isMarkColored(bitmap.colorAt(x: x, y: y), like: mark) }
        }
    }

    // Container caret x of a monospaced column.
    static func columnX(_ column: Int, in textView: NSTextView) throws -> CGFloat {
        let padding = try XCTUnwrap(textView.textContainer).lineFragmentPadding
        return padding + font.advancement(forGlyph: font.glyph(withName: "a")).width * CGFloat(column)
    }

    static func placedMarks(in textView: NSTextView) throws -> [(line: Int, rect: CGRect, scalar: Unicode.Scalar)] {
        var found: [(line: Int, rect: CGRect, scalar: Unicode.Scalar)] = []
        var lineIndex = 0
        for fragment in try fragments(of: textView) {
            let lines = fragment.textLineFragments
            for placed in (fragment as? PreviewTextFragment)?.placedMarks(within: .infinite) ?? [] {
                let line = try XCTUnwrap(lines.firstIndex { $0.typographicBounds.minY == placed.rect.minY })
                let rect = placed.rect.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: 0)
                found.append((lineIndex + line, rect, placed.mark.scalar))
            }
            lineIndex += lines.count
        }
        return found
    }

    // Each visible mark has one tooltip.
    static func toolTipsMatchMarks(_ textView: PreviewTextView) throws -> Bool {
        let region = textView.preparedContentRect.union(textView.visibleRect)
        var points: [CGPoint] = []
        for fragment in try fragments(of: textView) {
            guard let fragment = fragment as? PreviewTextFragment else { continue }
            let frame = viewRect(of: fragment.layoutFragmentFrame, in: fragment, textView: textView)
                .offsetBy(dx: -fragment.layoutFragmentFrame.minX, dy: -fragment.layoutFragmentFrame.minY)
            let clip = region.offsetBy(dx: -frame.minX, dy: -frame.minY)
            points += fragment.placedMarks(within: clip).map {
                CGPoint(x: frame.minX + $0.rect.minX, y: frame.minY + $0.rect.midY)
            }
        }
        let areas = textView.markToolTips.entries.values.map(\.area)
        return !points.isEmpty && points.allSatisfy { point in areas.contains { $0.contains(point) } }
            && areas.allSatisfy { area in points.contains { area.contains($0) } }
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
        let placed = fragment.placedMarks(within: .infinite)
        XCTAssertEqual(placed.map(\.mark.scalar), ["\u{200B}"])
        let mark = Self.viewRect(of: try XCTUnwrap(placed.first?.rect), in: fragment, textView: marked.textView)
        XCTAssertEqual(
            mark.minX, marked.textView.textContainerOrigin.x + (try Self.columnX(8, in: marked.textView)),
            accuracy: 1, "mark sits after user")

        let markColor = try Self.markColor(in: marked.window)
        for scale: CGFloat in [1, 2] {
            let markedImage = try Self.image(of: marked, scale: scale)
            let unmarkedImage = try Self.image(of: unmarked, scale: scale)
            XCTAssertTrue(Self.hasMarkPixel(markedImage, around: mark, like: markColor), "scale \(scale)")
            XCTAssertTrue(Self.markColumns(in: unmarkedImage, like: markColor).isEmpty)
            let columns = Self.markColumns(in: markedImage, like: markColor)
            XCTAssertFalse(columns.isEmpty)
            // Antialiased edges blend into the text.
            let margin = Int(ceil(2 * scale))
            let band = ((columns.min() ?? 0) - margin)...((columns.max() ?? 0) + margin)
            XCTAssertLessThan(CGFloat(band.count) / scale, 12, "one small mark at scale \(scale)")
            var changed = 0
            for x in 0..<markedImage.pixelsWide where !band.contains(x) {
                for y in 0..<markedImage.pixelsHigh
                where markedImage.colorAt(x: x, y: y) != unmarkedImage.colorAt(x: x, y: y) {
                    changed += 1
                }
            }
            XCTAssertEqual(changed, 0, "text renders exactly as without the mark at scale \(scale)")
        }
    }

    func testMarksSitAtTheirCharacterAtLineEndsWrapsAndDirectionBoundaries() throws {
        let directory = try PreviewFixtures.directory(self)
        let cases: [(text: String, line: Int, column: Int)] = [
            ("\u{200B}abc\n", 0, 0),
            ("ab\u{200B}c\n", 0, 2),
            ("abc\u{200B}\n", 0, 3),
            ("abc\u{202E}\n", 0, 3),
            ("abc\u{200B}", 0, 3),
            ("\u{200B}\n", 0, 0),
            ("first\nabc\u{2066}\nthird\n", 1, 3),
            ("hello\u{200B}مرحبا\n", 0, 5),
            (String(repeating: "a", count: 30) + "\u{200B}" + String(repeating: "b", count: 30) + "\n", 0, 30),
        ]
        for (text, line, column) in cases {
            let shown = Self.show(try Self.rendering(text, fileName: "a.txt", in: directory))
            defer { shown.window.orderOut(nil) }
            let marks = try Self.placedMarks(in: shown.textView)
            XCTAssertEqual(marks.count, 1, text.debugDescription)
            XCTAssertEqual(marks.first?.line, line, text.debugDescription)
            XCTAssertEqual(
                marks.first?.rect.minX ?? -1, try Self.columnX(column, in: shown.textView), accuracy: 0.5,
                text.debugDescription)
        }
        let trailing = Self.show(try Self.rendering("abc\u{200B}\u{2060}\n", fileName: "a.txt", in: directory))
        defer { trailing.window.orderOut(nil) }
        let trailingX = try Self.columnX(3, in: trailing.textView)
        XCTAssertEqual(try Self.placedMarks(in: trailing.textView).map(\.rect.minX), [trailingX, trailingX])

        let rightToLeft = Self.show(try Self.rendering("مرحبا\u{200B}\n", fileName: "a.txt", in: directory))
        defer { rightToLeft.window.orderOut(nil) }
        let fragment = try XCTUnwrap(Self.fragments(of: rightToLeft.textView).first)
        let line = try XCTUnwrap(fragment.textLineFragments.first)
        let padding = try XCTUnwrap(rightToLeft.textView.textContainer).lineFragmentPadding
        XCTAssertGreaterThan(line.typographicBounds.minX, 100, "the line is right-aligned")
        XCTAssertEqual(
            try Self.placedMarks(in: rightToLeft.textView).first?.rect.minX ?? -1,
            line.typographicBounds.minX + padding, accuracy: 0.5, "after the last letter, on its left")
    }

    func testRiskyCharactersAreNeverCappedAndCutsAreAnnounced() throws {
        let directory = try PreviewFixtures.directory(self)
        let crowded = String(repeating: "\u{200B}", count: 1_000) + "if (x == \"user\u{202E}\")\n"
        let shown = Self.show(try Self.rendering(crowded, fileName: "a.js", in: directory))
        defer { shown.window.orderOut(nil) }
        let fragment = try XCTUnwrap(Self.fragments(of: shown.textView).first as? PreviewTextFragment)
        let placed = fragment.placedMarks(within: .infinite)
        XCTAssertTrue(placed.contains { $0.mark.scalar == "\u{202E}" })
        XCTAssertEqual(
            placed.filter { $0.mark.scalar == "\u{200B}" }.count, PreviewTextFragment.maximumQuietMarksPerLine)
        XCTAssertEqual(placed.map(\.omittedAfter).reduce(0, +), 1_000 - PreviewTextFragment.maximumQuietMarksPerLine)
        let labels = shown.textView.markToolTips.entries.values.map(\.label)
        XCTAssertTrue(labels.contains { $0.contains("U+202E RIGHT-TO-LEFT OVERRIDE") }, "\(labels)")
        let cut = String(
            localized:
                "\(1_000 - PreviewTextFragment.maximumQuietMarksPerLine) more hidden characters on this line aren't marked."
        )
        XCTAssertTrue(labels.contains { $0.contains(cut) }, "\(labels)")

        let long =
            String(repeating: "\u{200B}", count: 201) + String(repeating: "a", count: 19_800) + "\u{202E}\n"
        let unwrapped = Self.show(try Self.rendering(long, fileName: "b.js", in: directory), wrap: false)
        defer { unwrapped.window.orderOut(nil) }
        let longFragment = try XCTUnwrap(Self.fragments(of: unwrapped.textView).first as? PreviewTextFragment)
        let override = try XCTUnwrap(
            longFragment.placedMarks(within: .infinite).first { $0.mark.scalar == "\u{202E}" })
        XCTAssertEqual(
            override.rect.minX + longFragment.layoutFragmentFrame.minX,
            try Self.columnX(19_800, in: unwrapped.textView),
            accuracy: 1)
        let near = CGRect(x: override.rect.minX - 300, y: 0, width: 600, height: 100)
        XCTAssertEqual(longFragment.placedMarks(within: near).map(\.mark.scalar), ["\u{202E}"])
    }

    func testMarksStayVisibleOverTheSelectionAndInDarkMode() throws {
        let directory = try PreviewFixtures.directory(self)
        let rendering = try Self.rendering("abc\u{202E}def\nxyz\u{200B}w\n", fileName: "a.txt", in: directory)
        let shown = Self.show(rendering, appearance: .darkAqua)
        defer { shown.window.orderOut(nil) }
        shown.textView.setSelectedRange(NSRange(location: 0, length: 8))
        let fragments = try Self.fragments(of: shown.textView).compactMap { $0 as? PreviewTextFragment }
        XCTAssertEqual(fragments.count, 2)
        let marks = try fragments.map { fragment in
            Self.viewRect(
                of: try XCTUnwrap(fragment.placedMarks(within: .infinite).first?.rect), in: fragment,
                textView: shown.textView)
        }
        let image = try Self.image(of: shown)
        let color = try Self.markColor(in: shown.window)
        XCTAssertTrue(Self.hasMarkPixel(image, around: marks[1], like: color), "the dark mark colour is drawn")
        // Dark selection composites over the mark.
        let warmth = color.redComponent - color.blueComponent
        let warmOverSelection = Self.hasPixel(image, around: marks[0]) { pixel in
            guard let pixel = pixel?.usingColorSpace(.sRGB) else { return false }
            return pixel.redComponent - pixel.blueComponent > warmth / 2
        }
        XCTAssertTrue(warmOverSelection, "still orange over the selection")
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
            XCTAssertEqual(fragment.placedMarks(within: .infinite).count, 1, sample)
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
            shown.textView.markToolTips.entries.values.map(\.label),
            ["U+200B ZERO WIDTH SPACE ×2\nU+2060 WORD JOINER"])

        let far = (text as NSString).range(of: "far")
        shown.textView.scrollRangeToVisible(far)
        let scrolled = try await PreviewFixtures.waitUntil {
            shown.textView.markToolTips.entries.values.map(\.label) == ["U+2066 LEFT-TO-RIGHT ISOLATE"]
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
        XCTAssertEqual(PreviewTable.displayText("\u{FEFF}admin"), "\u{FFFD}admin", "a cell never starts a file")
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

    func testToolTipsExistOnOpenAndFollowResizeWrapFontAndNewText() async throws {
        let directory = try PreviewFixtures.directory(self)
        let first = directory.appendingPathComponent("first.txt")
        try Data((String(repeating: "word ", count: 30) + "hit\u{200B}here\nabc\u{202E}\n").utf8).write(to: first)
        let second = directory.appendingPathComponent("second.txt")
        try Data("x\u{2066}y\n".utf8).write(to: second)
        let (window, state, store) = try hostWithState(first, in: directory)
        defer { window.orderOut(nil) }
        let content = try XCTUnwrap(window.contentView)
        func textView() -> PreviewTextView? { PreviewFindTests.first(PreviewTextView.self, in: content) }
        func matched() async throws -> Bool {
            try await PreviewFixtures.waitUntil { try textView().map(Self.toolTipsMatchMarks) ?? false }
        }
        func areas() -> Set<String> {
            Set(textView()?.markToolTips.entries.values.map { "\($0.area)" } ?? [])
        }

        let opened = try await matched()
        XCTAssertTrue(opened, "tooltips exist before any scroll")
        var previous = areas()

        window.setContentSize(NSSize(width: 760, height: 400))
        let resized = try await PreviewFixtures.waitUntil {
            try areas() != previous && (textView().map(Self.toolTipsMatchMarks) ?? false)
        }
        XCTAssertTrue(resized)
        previous = areas()

        store.finderPreview.wrapLines = false
        let unwrapped = try await PreviewFixtures.waitUntil {
            try areas() != previous && (textView().map(Self.toolTipsMatchMarks) ?? false)
        }
        XCTAssertTrue(unwrapped)
        previous = areas()

        store.finderPreview.codeFontSize = 20
        let refont = try await PreviewFixtures.waitUntil {
            try areas() != previous && (textView().map(Self.toolTipsMatchMarks) ?? false)
        }
        XCTAssertTrue(refont)

        state.urls = [second]
        state.trust = PreviewTrust(level: .standard, resolvedPath: second.path)
        state.generation += 1
        let replaced = try await PreviewFixtures.waitUntil {
            textView()?.markToolTips.entries.values.map(\.label) == ["U+2066 LEFT-TO-RIGHT ISOLATE"]
        }
        XCTAssertTrue(replaced, "no tooltip outlives its text")
    }

    func testNoticeIsForSourceNotTableAndCountsTruncatedFilesAsLowerBound() async throws {
        let directory = try PreviewFixtures.directory(self)
        let table = directory.appendingPathComponent("trojan.csv")
        try Data("name,role\nalice,user\u{202E}admin\n".utf8).write(to: table)
        let notice = String(localized: "This file contains \(1) hidden or direction-changing characters.")
        try await PreviewFixtures.withAccessibilityEnabled {
            let window = try host(table, in: directory)
            defer { window.orderOut(nil) }
            let content = try XCTUnwrap(window.contentView)
            let tableShown = try await PreviewFixtures.waitUntil {
                PreviewFindTests.first(PreviewTableView.self, in: content) != nil
            }
            XCTAssertTrue(tableShown)
            XCTAssertFalse(PreviewFixtures.visibleTexts(in: content).contains(notice), "cells already replace it")
            let picker = try XCTUnwrap(PreviewFindTests.first(NSSegmentedControl.self, in: content))
            picker.selectedSegment = 1
            picker.sendAction(picker.action, to: picker.target)
            let sourceNotice = try await PreviewFixtures.waitUntil {
                PreviewFixtures.visibleTexts(in: content).contains(notice)
            }
            XCTAssertTrue(sourceNotice)
        }

        let large = directory.appendingPathComponent("large.txt")
        var bytes = Data("hi\u{202E}\n".utf8)
        bytes.append(Data(repeating: UInt8(ascii: "a"), count: Int(PreviewTextSource.maximumBytes)))
        try bytes.write(to: large)
        let source = try PreviewTextSource.read(large)
        XCTAssertTrue(source.truncated)
        let excerpt = try PreviewTextRendering.make(
            source: source, encoding: .automatic, rich: false, kind: .text, url: large, restricted: false)
        XCTAssertTrue(excerpt.altersReading)
        XCTAssertTrue(excerpt.scannedPartially, "an excerpt's count is a lower bound")
    }

    func testCleanFilesKeepPlainLayoutFragments() throws {
        let directory = try PreviewFixtures.directory(self)
        let clean = Self.show(try Self.rendering("let a = 1\n", fileName: "a.swift", in: directory))
        defer { clean.window.orderOut(nil) }
        XCTAssertNil(clean.textView.textLayoutManager?.delegate)
        XCTAssertFalse(try Self.fragments(of: clean.textView).contains { $0 is PreviewTextFragment })
        let marked = Self.show(try Self.rendering("let a\u{200B} = 1\n", fileName: "b.swift", in: directory))
        defer { marked.window.orderOut(nil) }
        XCTAssertNotNil(marked.textView.textLayoutManager?.delegate)
    }

    private func host(_ file: URL, in directory: URL) throws -> NSWindow {
        try hostWithState(file, in: directory).window
    }

    private func hostWithState(_ file: URL, in directory: URL) throws -> (
        window: NSWindow, state: FinderPreviewState, store: SettingsStore
    ) {
        let suite = "PreviewTextDecorationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let state = FinderPreviewState()
        state.urls = [file]
        state.kind = .text
        state.trust = PreviewTrust(level: .standard, resolvedPath: file.path)
        state.generation = 1
        let store = SettingsStore(defaults: defaults)
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 520, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: FinderPreviewView(
                state: state, settings: store, staging: StagingArea(supportDirectory: directory), close: {},
                retry: {}, select: { _ in }, resize: { _ in }))
        window.orderBack(nil)
        return (window, state, store)
    }
}
