import AppKit
import Synchronization

// Vends fragments; text and shaping stay untouched.
final class PreviewTextDecorations: NSObject, NSTextLayoutManagerDelegate, Sendable {
    enum RowTint: Sendable { case added, removed }

    let marks: [PreviewInvisibleCharacter]
    private let rowTints: [Int: RowTint]
    // Container x range the text view covers.
    let rowSpan = Mutex<ClosedRange<CGFloat>>(0...0)

    init(marks: [PreviewInvisibleCharacter], rowTints: [Int: RowTint]) {
        self.marks = marks
        self.rowTints = rowTints
    }

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        guard let range = textElement.elementRange else {
            return NSTextLayoutFragment(textElement: textElement, range: nil)
        }
        let start = textLayoutManager.offset(from: textLayoutManager.documentRange.location, to: range.location)
        let end = start + textLayoutManager.offset(from: range.location, to: range.endLocation)
        let local = marks[marks.firstIndex(atOrAfter: start)..<marks.firstIndex(atOrAfter: end)].map {
            PreviewInvisibleCharacter(
                range: NSRange(location: $0.range.location - start, length: $0.range.length), scalar: $0.scalar)
        }
        return PreviewTextFragment(
            textElement: textElement, range: range, rowTint: rowTints[start], marks: local, decorations: self)
    }
}

final class PreviewTextFragment: NSTextLayoutFragment {
    // Risky characters are never capped.
    static let maximumQuietMarksPerLine = 100
    private static let markWidth: CGFloat = 2
    private static let markHeadWidth: CGFloat = 6
    private static let markHeadHeight: CGFloat = 3

    struct PlacedMark {
        // Zero width, at the caret position.
        let rect: CGRect
        let mark: PreviewInvisibleCharacter
        // Quiet marks cut after this one.
        var omittedAfter = 0
    }

    private let rowTint: PreviewTextDecorations.RowTint?
    // Ranges are relative to the paragraph.
    private let marks: [PreviewInvisibleCharacter]
    private let decorations: PreviewTextDecorations
    // Relayout replaces line objects, resetting this.
    private var caretCache: (lines: [NSTextLineFragment], positions: [ObjectIdentifier: [CGFloat?]]) = ([], [:])

    init(
        textElement: NSTextElement, range: NSTextRange, rowTint: PreviewTextDecorations.RowTint?,
        marks: [PreviewInvisibleCharacter], decorations: PreviewTextDecorations
    ) {
        self.rowTint = rowTint
        self.marks = marks
        self.decorations = decorations
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) { nil }

    override var renderingSurfaceBounds: CGRect {
        var surface = super.renderingSurfaceBounds
        if !marks.isEmpty { surface = surface.insetBy(dx: -Self.markHeadWidth, dy: 0) }
        guard rowTint != nil else { return surface }
        return surface.union(rowRect)
    }

    func placedMarks(within clip: CGRect) -> [PlacedMark] {
        var placed: [PlacedMark] = []
        let reach = clip.insetBy(dx: -Self.markHeadWidth, dy: 0)
        for line in textLineFragments {
            let bounds = line.typographicBounds
            guard bounds.maxY >= clip.minY, bounds.minY <= clip.maxY else { continue }
            let lineMarks = marks[
                marks.firstIndex(
                    atOrAfter: line.characterRange.location)..<marks.firstIndex(
                        atOrAfter: NSMaxRange(line.characterRange))]
            guard !lineMarks.isEmpty else { continue }
            var quietCount = 0
            var omitted = 0
            var lastQuiet: Int?
            for (mark, x) in zip(lineMarks, cachedCaretPositions(of: lineMarks, in: line)) {
                guard let x, x >= reach.minX, x <= reach.maxX else { continue }
                if !PreviewInvisibleScanner.altersReading(mark.scalar) {
                    guard quietCount < Self.maximumQuietMarksPerLine else {
                        omitted += 1
                        continue
                    }
                    quietCount += 1
                    lastQuiet = placed.count
                }
                placed.append(
                    PlacedMark(rect: CGRect(x: x, y: bounds.minY, width: 0, height: bounds.height), mark: mark))
            }
            if let lastQuiet, omitted > 0 { placed[lastQuiet].omittedAfter = omitted }
        }
        return placed
    }

    private func cachedCaretPositions(
        of lineMarks: ArraySlice<PreviewInvisibleCharacter>, in line: NSTextLineFragment
    ) -> [CGFloat?] {
        let lines = textLineFragments
        if !caretCache.lines.elementsEqual(lines, by: ===) { caretCache = (lines, [:]) }
        if let cached = caretCache.positions[ObjectIdentifier(line)] { return cached }
        let positions = caretPositions(of: lineMarks, in: line)
        caretCache.positions[ObjectIdentifier(line)] = positions
        return positions
    }

    // One caret pass per line.
    private func caretPositions(
        of lineMarks: ArraySlice<PreviewInvisibleCharacter>, in line: NSTextLineFragment
    ) -> [CGFloat?] {
        let start = rangeInElement.location
        guard let layout = textLayoutManager,
            let lineStart = layout.location(start, offsetBy: line.characterRange.location)
        else { return [] }
        var leading: [Int: CGFloat] = [:]
        var trailing: [(offset: Int, x: CGFloat)] = []
        layout.enumerateCaretOffsetsInLineFragment(at: lineStart) { x, location, isLeading, _ in
            let offset = layout.offset(from: start, to: location)
            if !isLeading {
                trailing.append((offset, x))
            } else if leading[offset] == nil {
                leading[offset] = x
            }
        }
        trailing.sort { $0.offset < $1.offset }
        let originX = layoutFragmentFrame.minX
        var cursor = 0
        return lineMarks.map { mark in
            let offset = mark.range.location
            if let x = leading[offset] { return x - originX }
            // Clusters report edges at their last character.
            while cursor < trailing.count, trailing[cursor].offset < offset { cursor += 1 }
            return cursor < trailing.count ? trailing[cursor].x - originX : nil
        }
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let rowTint { fillRow(rowTint, at: point, in: context) }
        super.draw(at: point, in: context)
        guard !marks.isEmpty else { return }
        let clip = context.boundingBoxOfClipPath.offsetBy(dx: -point.x, dy: -point.y)
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(PreviewTextView.invisibleMarkColor.cgColor)
        var previous: CGRect?
        for placed in placedMarks(within: clip) where placed.rect != previous {
            previous = placed.rect
            let rect = placed.rect
            let x = point.x + rect.minX
            let top = point.y + rect.minY
            context.fill(CGRect(x: x - Self.markWidth / 2, y: top, width: Self.markWidth, height: rect.height))
            context.move(to: CGPoint(x: x - Self.markHeadWidth / 2, y: top))
            context.addLine(to: CGPoint(x: x + Self.markHeadWidth / 2, y: top))
            context.addLine(to: CGPoint(x: x, y: top + Self.markHeadHeight))
            context.closePath()
            context.fillPath()
        }
    }

    // Skips the trailing empty line.
    private var rowRect: CGRect {
        let span = decorations.rowSpan.withLock { $0 }
        let frame = layoutFragmentFrame
        let height = textLineFragments.last { $0.characterRange.length > 0 }?.typographicBounds.maxY ?? frame.height
        return CGRect(x: span.lowerBound - frame.minX, y: 0, width: span.upperBound - span.lowerBound, height: height)
    }

    // Selection keeps its own colour, as before.
    private func fillRow(_ tint: PreviewTextDecorations.RowTint, at point: CGPoint, in context: CGContext) {
        let row = rowRect
        let path = CGMutablePath()
        path.addRect(row.offsetBy(dx: point.x, dy: point.y))
        for selected in selectionRects() {
            let local = selected.offsetBy(dx: -layoutFragmentFrame.minX, dy: -layoutFragmentFrame.minY)
            path.addRect(local.intersection(row).offsetBy(dx: point.x, dy: point.y))
        }
        context.saveGState()
        defer { context.restoreGState() }
        let color = tint == .added ? PreviewTextView.diffAddedBackground : PreviewTextView.diffRemovedBackground
        context.setFillColor(color.cgColor)
        context.addPath(path)
        context.fillPath(using: .evenOdd)
    }

    private func selectionRects() -> [CGRect] {
        guard let layout = textLayoutManager else { return [] }
        var rects: [CGRect] = []
        for selected in layout.textSelections.flatMap(\.textRanges) {
            guard let overlap = selected.intersection(rangeInElement), !overlap.isEmpty else { continue }
            layout.enumerateTextSegments(in: overlap, type: .selection, options: []) { _, frame, _, _ in
                rects.append(frame)
                return true
            }
        }
        return rects
    }
}

extension RandomAccessCollection where Element == PreviewInvisibleCharacter, Index == Int {
    // Marks are sorted by location.
    fileprivate func firstIndex(atOrAfter offset: Int) -> Int {
        var lower = startIndex
        var upper = endIndex
        while lower < upper {
            let middle = (lower + upper) / 2
            if self[middle].range.location < offset { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
}
