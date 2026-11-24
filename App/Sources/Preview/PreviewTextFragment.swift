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
    static let maximumDrawnMarks = 1_000
    // Locating a glyphless character scans its line.
    static let maximumScannedUnits = 4_000_000
    private static let markWidth: CGFloat = 2
    private static let markHeadWidth: CGFloat = 6
    private static let markHeadHeight: CGFloat = 3

    private let rowTint: PreviewTextDecorations.RowTint?
    // Ranges are relative to the paragraph.
    private let marks: [PreviewInvisibleCharacter]
    private let decorations: PreviewTextDecorations

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

    // Zero-width rects at each mark's caret position.
    func markRects(within clip: CGRect) -> [(rect: CGRect, mark: PreviewInvisibleCharacter)] {
        var placed: [(rect: CGRect, mark: PreviewInvisibleCharacter)] = []
        var budget = Self.maximumScannedUnits
        for line in textLineFragments {
            let bounds = line.typographicBounds
            guard bounds.maxY >= clip.minY, bounds.minY <= clip.maxY else { continue }
            let lineEnd = NSMaxRange(line.characterRange)
            let lookupCost = max(1, line.characterRange.length)
            var index = marks.firstIndex(atOrAfter: line.characterRange.location)
            while index < marks.endIndex, marks[index].range.location < lineEnd {
                guard placed.count < Self.maximumDrawnMarks, budget >= lookupCost else { return placed }
                budget -= lookupCost
                let x = bounds.minX + line.locationForCharacter(at: marks[index].range.location).x
                placed.append((CGRect(x: x, y: bounds.minY, width: 0, height: bounds.height), marks[index]))
                index += 1
            }
        }
        return placed
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let rowTint { fillRow(rowTint, at: point, in: context) }
        super.draw(at: point, in: context)
        guard !marks.isEmpty else { return }
        let clip = context.boundingBoxOfClipPath.offsetBy(dx: -point.x, dy: -point.y)
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(PreviewTextView.invisibleMarkColor.cgColor)
        for (rect, _) in markRects(within: clip) {
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
