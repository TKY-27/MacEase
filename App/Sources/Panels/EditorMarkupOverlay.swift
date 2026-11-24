import AppKit
import Engine
import SwiftUI

enum MarkupTool: CaseIterable {
    case select, redact, box, arrow, text

    var title: String {
        switch self {
        case .select: String(localized: "Select")
        case .redact: String(localized: "Redact")
        case .box: String(localized: "Box")
        case .arrow: String(localized: "Arrow")
        case .text: String(localized: "Text")
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .redact: "checkerboard.rectangle"
        case .box: "rectangle"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        }
    }
}

extension EditMark {
    var tool: MarkupTool {
        switch self {
        case .redaction: .redact
        case .box: .box
        case .arrow: .arrow
        case .text: .text
        }
    }

    var symbol: String {
        if case .redaction(_, let style) = self { return style.symbol }
        return tool.symbol
    }

    func translated(dx: Double, dy: Double) -> EditMark {
        func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(max(value, low), high) }
        switch self {
        case .redaction(var rect, let style):
            rect.x = clamp(rect.x + dx, 0, 1 - rect.width)
            rect.y = clamp(rect.y + dy, 0, 1 - rect.height)
            return .redaction(rect: rect, style: style)
        case .box(var rect, let color, let size):
            rect.x = clamp(rect.x + dx, 0, 1 - rect.width)
            rect.y = clamp(rect.y + dy, 0, 1 - rect.height)
            return .box(rect: rect, color: color, size: size)
        case .arrow(let from, let to, let color, let size):
            let x = clamp(dx, -min(from.x, to.x), 1 - max(from.x, to.x))
            let y = clamp(dy, -min(from.y, to.y), 1 - max(from.y, to.y))
            return .arrow(
                from: EditPoint(x: from.x + x, y: from.y + y), to: EditPoint(x: to.x + x, y: to.y + y), color: color,
                size: size)
        case .text(let text, let at, let color, let size):
            return .text(
                text, at: EditPoint(x: clamp(at.x + dx, 0, 1), y: clamp(at.y + dy, 0, 1)), color: color, size: size)
        }
    }

    /// Text steps through sizes instead of scaling.
    func scaled(by factor: Double) -> EditMark {
        func scaledRect(_ rect: EditCrop) -> EditCrop {
            let width = min(1, max(MediaEditorModel.minimumOverlaySide, rect.width * factor))
            let height = min(1, max(MediaEditorModel.minimumOverlaySide, rect.height * factor))
            let x = min(max(0, rect.x + (rect.width - width) / 2), 1 - width)
            let y = min(max(0, rect.y + (rect.height - height) / 2), 1 - height)
            return EditCrop(x: x, y: y, width: width, height: height)
        }
        switch self {
        case .redaction(let rect, let style): return .redaction(rect: scaledRect(rect), style: style)
        case .box(let rect, let color, let size): return .box(rect: scaledRect(rect), color: color, size: size)
        case .arrow(let from, let to, let color, let size):
            let center = EditPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            func scaled(_ point: EditPoint) -> EditPoint {
                EditPoint(
                    x: min(max(0, center.x + (point.x - center.x) * factor), 1),
                    y: min(max(0, center.y + (point.y - center.y) * factor), 1))
            }
            return .arrow(from: scaled(from), to: scaled(to), color: color, size: size)
        case .text(let text, let at, let color, let size):
            let sizes = MarkSize.allCases
            let index = sizes.firstIndex(of: size) ?? 0
            let next = min(max(0, index + (factor > 1 ? 1 : -1)), sizes.count - 1)
            return .text(text, at: at, color: color, size: sizes[next])
        }
    }
}

extension RedactionStyle {
    var title: String {
        switch self {
        case .mosaic: String(localized: "Mosaic")
        case .blur: String(localized: "Blur")
        case .solid: String(localized: "Solid")
        }
    }

    var symbol: String {
        switch self {
        case .mosaic: "checkerboard.rectangle"
        case .blur: "aqi.medium"
        case .solid: "rectangle.fill"
        }
    }
}

extension MediaEditorModel {
    nonisolated static let minimumOverlaySide = 0.01
    static let overlayNudge = 0.01
    static let overlayLargeNudge = 0.1
    static let overlayScaleStep = 1.1
    static let overlayTextField = "overlay-text"
    private static let defaultOverlayRect = CGRect(x: 0.35, y: 0.4, width: 0.3, height: 0.2)
    private static let defaultArrow = (from: CGPoint(x: 0.38, y: 0.62), to: CGPoint(x: 0.62, y: 0.38))

    var markupOverlays: [EditOverlay] { isVideo ? values.overlays.map(\.overlay) : values.photo.overlays }
    var selectedOverlay: EditOverlay? { markupOverlays.first { $0.id == values.selectedOverlayID } }
    var selectedTimedOverlay: TimedOverlay? { values.overlays.first { $0.id == values.selectedOverlayID } }
    var canAddOverlay: Bool {
        savingBatchID == nil && markupOverlays.count < EditOverlay.maximumCount && (!isVideo || timeline != nil)
    }

    /// Overlays drawn at the viewed frame.
    var visibleOverlayIDs: Set<UUID> {
        guard isVideo else { return Set(values.photo.overlays.map(\.id)) }
        guard let timeline else { return [] }
        return Set(timeline.overlays(at: hoverPosition ?? position).map(\.id))
    }

    func outputPoint(_ point: EditPoint) -> CGPoint {
        values.photo.geometry.outputPoint(point, canvas: sourceSize)
    }

    func canvasPoint(_ point: CGPoint, clamped: Bool = true) -> EditPoint {
        let mapped = values.photo.geometry.canvasPoint(point, canvas: sourceSize)
        guard clamped else { return mapped }
        return EditPoint(x: min(max(0, mapped.x), 1), y: min(max(0, mapped.y), 1))
    }

    /// Covers the dragged area when straightened.
    func canvasRect(fromOutput rect: CGRect) -> EditCrop? {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
        ].map { canvasPoint($0) }
        let left = corners.map(\.x).min() ?? 0
        let top = corners.map(\.y).min() ?? 0
        let width = (corners.map(\.x).max() ?? 0) - left
        let height = (corners.map(\.y).max() ?? 0) - top
        guard width >= Self.minimumOverlaySide, height >= Self.minimumOverlaySide else { return nil }
        return EditCrop(x: left, y: top, width: width, height: height)
    }

    func newMark(_ tool: MarkupTool, outputRect rect: CGRect) -> EditMark? {
        switch tool {
        case .select: return nil
        case .redact: return canvasRect(fromOutput: rect).map { .redaction(rect: $0, style: redactionStyle) }
        case .box: return canvasRect(fromOutput: rect).map { .box(rect: $0, color: markColor, size: markSize) }
        case .arrow:
            let mark = EditMark.arrow(
                from: canvasPoint(CGPoint(x: rect.minX, y: rect.minY)),
                to: canvasPoint(CGPoint(x: rect.maxX, y: rect.maxY)), color: markColor, size: markSize)
            return (try? mark.validate()) == nil ? nil : mark
        case .text:
            return .text(
                String(localized: "Text"), at: canvasPoint(CGPoint(x: rect.midX, y: rect.midY)), color: markColor,
                size: markSize)
        }
    }

    /// The pointer-free way to create markup.
    func addDefaultOverlay(_ tool: MarkupTool) {
        let rect =
            tool == .arrow
            ? CGRect(
                x: Self.defaultArrow.from.x, y: Self.defaultArrow.from.y,
                width: Self.defaultArrow.to.x - Self.defaultArrow.from.x,
                height: Self.defaultArrow.to.y - Self.defaultArrow.from.y)
            : Self.defaultOverlayRect
        guard let mark = newMark(tool, outputRect: rect), let id = addOverlay(mark) else { return }
        if tool == .text { overlayTextFocusRequest = id }
    }

    @discardableResult
    func addOverlay(_ mark: EditMark) -> UUID? {
        guard canAddOverlay, (try? mark.validate()) != nil else { return nil }
        let overlay = EditOverlay(mark: mark)
        if isVideo {
            guard let timeline else { return nil }
            let sourceIndex = timeline.segment(at: position).sourceIndex
            guard values.sources.indices.contains(sourceIndex) else { return nil }
            let duration = values.sources[sourceIndex].duration
            change {
                $0.overlays.append(TimedOverlay(overlay: overlay, sourceIndex: sourceIndex, start: 0, end: duration))
                $0.selectedOverlayID = overlay.id
            }
        } else {
            change {
                $0.photo.overlays.append(overlay)
                $0.selectedOverlayID = overlay.id
            }
        }
        return overlay.id
    }

    func updateOverlay(_ id: UUID, _ mark: EditMark) {
        guard (try? mark.validate()) != nil else { return }
        change { values in
            if let index = values.overlays.firstIndex(where: { $0.id == id }) {
                values.overlays[index].overlay.mark = mark
            }
            if let index = values.photo.overlays.firstIndex(where: { $0.id == id }) {
                values.photo.overlays[index].mark = mark
            }
        }
    }

    func deleteOverlay(_ id: UUID) {
        change { values in
            values.overlays.removeAll { $0.id == id }
            values.photo.overlays.removeAll { $0.id == id }
            if values.selectedOverlayID == id { values.selectedOverlayID = nil }
        }
    }

    /// Seeks to hidden overlays.
    func selectOverlay(_ id: UUID?) {
        guard savingBatchID == nil else { return }
        endInteraction()
        values.selectedOverlayID = id
        guard let id, let timed = values.overlays.first(where: { $0.id == id }), !visibleOverlayIDs.contains(id),
            let first = timeline?.outputRanges(of: timed).first
        else { return }
        seek(first.lowerBound)
    }

    /// Nudges in screen directions.
    func nudgeOverlay(_ id: UUID, dx: Double, dy: Double) {
        guard let overlay = markupOverlays.first(where: { $0.id == id }) else { return }
        let origin = canvasPoint(CGPoint(x: 0.5, y: 0.5), clamped: false)
        let moved = canvasPoint(CGPoint(x: 0.5 + dx, y: 0.5 + dy), clamped: false)
        updateOverlay(id, overlay.mark.translated(dx: moved.x - origin.x, dy: moved.y - origin.y))
    }

    func scaleOverlay(_ id: UUID, by factor: Double) {
        guard let overlay = markupOverlays.first(where: { $0.id == id }) else { return }
        updateOverlay(id, overlay.mark.scaled(by: factor))
    }

    var canSetOverlayBoundary: Bool {
        guard savingBatchID == nil, let timed = selectedTimedOverlay, let timeline else { return false }
        return timeline.segment(at: position).sourceIndex == timed.sourceIndex
    }

    /// Includes the frame at the playhead.
    func setOverlayBoundaryAtPlayhead(start: Bool) async {
        guard canSetOverlayBoundary, let timed = selectedTimedOverlay, let timeline else { return }
        let segment = timeline.segment(at: position)
        guard let actor = source(for: segment) else { return }
        let seconds = timeline.sourceTime(at: position)
        let duration = values.sources[timed.sourceIndex].duration
        do {
            let next = try await actor.adjacentFrameTime(to: seconds, forward: true)
            let frameEnd = next > seconds ? next : duration
            let frameStart = try await actor.adjacentFrameTime(to: frameEnd, forward: false)
            guard !Task.isCancelled, let index = values.overlays.firstIndex(where: { $0.id == timed.id }) else {
                return
            }
            change { values in
                if start {
                    values.overlays[index].start = frameStart
                    if values.overlays[index].end <= frameStart { values.overlays[index].end = duration }
                } else {
                    values.overlays[index].end = frameEnd
                    if values.overlays[index].start >= frameEnd { values.overlays[index].start = 0 }
                }
            }
        } catch is CancellationError { return } catch { report(error) }
    }

    func setOverlayRange(_ id: UUID, start: Double, end: Double) {
        guard start.isFinite, end.isFinite, start < end,
            let index = values.overlays.firstIndex(where: { $0.id == id })
        else { return }
        change {
            $0.overlays[index].start = start
            $0.overlays[index].end = end
        }
    }

    func overlayName(_ overlay: EditOverlay) -> String {
        let number =
            markupOverlays.prefix { $0.id != overlay.id }.filter { $0.mark.tool == overlay.mark.tool }.count + 1
        switch overlay.mark {
        case .redaction(_, .mosaic): return String(localized: "Mosaic region \(number)")
        case .redaction(_, .blur): return String(localized: "Blur region \(number)")
        case .redaction(_, .solid): return String(localized: "Solid region \(number)")
        case .box: return String(localized: "Box \(number)")
        case .arrow: return String(localized: "Arrow \(number)")
        case .text: return String(localized: "Text \(number)")
        }
    }

    func overlayDescription(_ overlay: EditOverlay) -> String {
        func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0))) }
        switch overlay.mark {
        case .redaction(let rect, _), .box(let rect, _, _):
            return String(
                localized:
                    "Left \(percent(rect.x)), top \(percent(rect.y)), width \(percent(rect.width)), height \(percent(rect.height))"
            )
        case .arrow(let from, let to, _, _):
            return String(
                localized: "From \(percent(from.x)), \(percent(from.y)) to \(percent(to.x)), \(percent(to.y))")
        case .text(let text, let at, _, _):
            return String(localized: "“\(text)” at \(percent(at.x)), \(percent(at.y))")
        }
    }
}

/// Edits markup directly on the preview.
struct EditorMarkupOverlay: View {
    @Bindable var model: MediaEditorModel
    @State private var drag: MarkupDrag?
    @State private var hover: CGPoint?
    private static let createThreshold = 3.0
    private static let handleRadius = 4.5
    private static let handleHitRadius = 10.0
    private static let lineHitDistance = 8.0
    private static let dash: [CGFloat] = [4, 3]

    private struct Handle: Equatable {
        let x: Int
        let y: Int
        static let all = [-1, 0, 1].flatMap { x in [-1, 0, 1].map { Handle(x: x, y: $0) } }.filter {
            $0.x != 0 || $0.y != 0
        }
    }

    private enum Target {
        case handle(UUID, EditCrop, Handle, CGPoint)
        case endpoint(UUID, EditMark, from: Bool)
        case body(UUID, EditMark)
        case empty
    }

    private enum MarkupDrag {
        case pending(CGPoint)
        case creating(UUID, CGPoint)
        case moving(UUID, EditMark, EditPoint)
        case resizing(UUID, EditCrop, Handle)
        case endpoint(UUID, EditMark, from: Bool)
        case ignored
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let visible = model.visibleOverlayIDs
            let candidates = shownOverlays
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .gesture(gesture(size: size))
                    .onContinuousHover { phase in
                        if case .active(let point) = phase { hover = point } else { hover = nil }
                    }
                    .pointerStyle(pointerStyle(size: size))
                    .accessibilityHidden(true)
                Canvas { context, _ in
                    for overlay in candidates {
                        draw(overlay, hidden: !visible.contains(overlay.id), in: &context, size: size)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                ForEach(candidates, id: \.id) { overlay in
                    accessibilityElement(overlay, size: size)
                }
            }
        }
    }

    private var shownOverlays: [EditOverlay] {
        let visible = model.visibleOverlayIDs
        return model.markupOverlays.filter { visible.contains($0.id) || $0.id == model.values.selectedOverlayID }
    }

    private func viewPoint(_ point: EditPoint, _ size: CGSize) -> CGPoint {
        let output = model.outputPoint(point)
        return CGPoint(x: output.x * size.width, y: output.y * size.height)
    }

    private func normalized(_ point: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: point.x / max(1, size.width), y: point.y / max(1, size.height))
    }

    private func corners(_ rect: EditCrop) -> [EditPoint] {
        [
            EditPoint(x: rect.x, y: rect.y), EditPoint(x: rect.x + rect.width, y: rect.y),
            EditPoint(x: rect.x + rect.width, y: rect.y + rect.height), EditPoint(x: rect.x, y: rect.y + rect.height),
        ]
    }

    private func handlePoint(_ handle: Handle, _ rect: EditCrop) -> EditPoint {
        EditPoint(
            x: rect.x + Double(handle.x + 1) / 2 * rect.width, y: rect.y + Double(handle.y + 1) / 2 * rect.height)
    }

    private func textFrame(_ text: String, at point: EditPoint, size markSize: MarkSize, _ size: CGSize) -> CGRect {
        let font = NSFont.systemFont(ofSize: min(size.width, size.height) * markSize.fontFraction, weight: .heavy)
        let measured = NSAttributedString(
            string: text.trimmingCharacters(in: .whitespacesAndNewlines), attributes: [.font: font]
        ).size()
        let center = viewPoint(point, size)
        return CGRect(
            x: center.x - measured.width / 2, y: center.y - measured.height / 2, width: measured.width,
            height: measured.height
        ).insetBy(dx: -4, dy: -2)
    }

    private func outline(_ mark: EditMark, _ size: CGSize) -> Path {
        switch mark {
        case .redaction(let rect, _), .box(let rect, _, _):
            return Path { path in
                path.addLines(corners(rect).map { viewPoint($0, size) }); path.closeSubpath()
            }
        case .arrow(let from, let to, _, _):
            return Path { path in
                path.move(to: viewPoint(from, size))
                path.addLine(to: viewPoint(to, size))
            }
        case .text(let text, let at, _, let markSize):
            return Path(textFrame(text, at: at, size: markSize, size))
        }
    }

    private func draw(_ overlay: EditOverlay, hidden: Bool, in context: inout GraphicsContext, size: CGSize) {
        let selected = overlay.id == model.values.selectedOverlayID
        let path = outline(overlay.mark, size)
        let dash = selected && !hidden ? [] : Self.dash
        let outlined =
            switch overlay.mark {
            case .redaction: true
            case .box, .text: selected || hidden
            case .arrow: hidden
            }
        if outlined {
            // Dark halo keeps lines visible.
            context.stroke(
                path, with: .color(.black.opacity(selected ? 0.55 : 0.35)),
                style: StrokeStyle(lineWidth: selected ? 3 : 2, dash: dash))
            context.stroke(
                path, with: .color(.white.opacity(selected ? 1 : 0.75)),
                style: StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: dash))
        }
        guard selected else { return }
        let points: [CGPoint]
        switch overlay.mark {
        case .redaction(let rect, _), .box(let rect, _, _):
            points = Handle.all.map { viewPoint(handlePoint($0, rect), size) }
        case .arrow(let from, let to, _, _): points = [viewPoint(from, size), viewPoint(to, size)]
        case .text: points = []
        }
        for point in points {
            let dot = Path(
                ellipseIn: CGRect(
                    x: point.x - Self.handleRadius, y: point.y - Self.handleRadius, width: Self.handleRadius * 2,
                    height: Self.handleRadius * 2))
            context.fill(dot, with: .color(.white))
            context.stroke(dot, with: .color(.black.opacity(0.6)), lineWidth: 1)
        }
    }

    private func hits(_ mark: EditMark, _ point: CGPoint, _ size: CGSize) -> Bool {
        switch mark {
        case .redaction, .box, .text: return outline(mark, size).contains(point)
        case .arrow(let from, let to, _, let markSize):
            let start = viewPoint(from, size)
            let end = viewPoint(to, size)
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = max(0.001, dx * dx + dy * dy)
            let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / length))
            let distance = hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
            return distance <= max(Self.lineHitDistance, min(size.width, size.height) * markSize.strokeFraction)
        }
    }

    private func target(at point: CGPoint, size: CGSize) -> Target {
        if let selected = model.selectedOverlay {
            switch selected.mark {
            case .redaction(let rect, _), .box(let rect, _, _):
                for handle in Handle.all {
                    let location = viewPoint(handlePoint(handle, rect), size)
                    if hypot(location.x - point.x, location.y - point.y) <= Self.handleHitRadius {
                        return .handle(selected.id, rect, handle, location)
                    }
                }
            case .arrow(let from, let to, _, _):
                for (isFrom, end) in [(false, to), (true, from)] {
                    let location = viewPoint(end, size)
                    if hypot(location.x - point.x, location.y - point.y) <= Self.handleHitRadius {
                        return .endpoint(selected.id, selected.mark, from: isFrom)
                    }
                }
            case .text: break
            }
            if hits(selected.mark, point, size) { return .body(selected.id, selected.mark) }
        }
        if let overlay = shownOverlays.last(where: { hits($0.mark, point, size) }) {
            return .body(overlay.id, overlay.mark)
        }
        return .empty
    }

    private func pointerStyle(size: CGSize) -> PointerStyle {
        if case .moving = drag { return .grabActive }
        guard let hover else { return .default }
        switch target(at: hover, size: size) {
        case .handle(_, let rect, _, let location):
            let center = viewPoint(EditPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2), size)
            return .frameResize(position: Self.resizePosition(location, around: center))
        case .endpoint: return .rectSelection
        case .body: return .grabIdle
        case .empty:
            switch model.markupTool {
            case .select: return .default
            case .text: return .horizontalText
            case .redact, .box, .arrow: return .rectSelection
            }
        }
    }

    private static func resizePosition(_ point: CGPoint, around center: CGPoint) -> FrameResizePosition {
        let tolerance = 1.0
        let horizontal = point.x < center.x - tolerance ? -1 : point.x > center.x + tolerance ? 1 : 0
        let vertical = point.y < center.y - tolerance ? -1 : point.y > center.y + tolerance ? 1 : 0
        switch (horizontal, vertical) {
        case (-1, -1): return .topLeading
        case (1, -1): return .topTrailing
        case (-1, 1): return .bottomLeading
        case (1, 1): return .bottomTrailing
        case (-1, _): return .leading
        case (1, _): return .trailing
        case (_, -1): return .top
        default: return .bottom
        }
    }

    private func gesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil { drag = begin(at: value.startLocation, size: size) }
                update(to: value.location, size: size)
            }
            .onEnded { value in
                finish(at: value.location, size: size)
            }
    }

    private func begin(at point: CGPoint, size: CGSize) -> MarkupDrag {
        switch target(at: point, size: size) {
        case .handle(let id, let rect, let handle, _):
            model.beginInteraction()
            return .resizing(id, rect, handle)
        case .endpoint(let id, let mark, let from):
            model.beginInteraction()
            return .endpoint(id, mark, from: from)
        case .body(let id, let mark):
            if model.values.selectedOverlayID != id { model.selectOverlay(id) }
            model.beginInteraction()
            return .moving(id, mark, model.canvasPoint(normalized(point, size), clamped: false))
        case .empty:
            if model.markupTool == .select {
                model.selectOverlay(nil)
                return .ignored
            }
            return .pending(point)
        }
    }

    private func outputRect(from start: CGPoint, to end: CGPoint, size: CGSize) -> CGRect {
        let a = normalized(start, size)
        let b = normalized(end, size)
        return model.markupTool == .arrow
            ? CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
            : CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func update(to point: CGPoint, size: CGSize) {
        switch drag {
        case .pending(let start):
            guard model.markupTool != .text, hypot(point.x - start.x, point.y - start.y) >= Self.createThreshold,
                let mark = model.newMark(model.markupTool, outputRect: outputRect(from: start, to: point, size: size))
            else { return }
            model.beginInteraction()
            if let id = model.addOverlay(mark) {
                drag = .creating(id, start)
            } else {
                model.endInteraction()
                drag = .ignored
            }
        case .creating(let id, let start):
            if let mark = model.newMark(model.markupTool, outputRect: outputRect(from: start, to: point, size: size)) {
                model.updateOverlay(id, mark)
            }
        case .moving(let id, let mark, let origin):
            let current = model.canvasPoint(normalized(point, size), clamped: false)
            model.updateOverlay(id, mark.translated(dx: current.x - origin.x, dy: current.y - origin.y))
        case .resizing(let id, let rect, let handle):
            guard let overlay = model.markupOverlays.first(where: { $0.id == id }) else { return }
            let resized = Self.resized(rect, handle: handle, to: model.canvasPoint(normalized(point, size)))
            switch overlay.mark {
            case .redaction(_, let style): model.updateOverlay(id, .redaction(rect: resized, style: style))
            case .box(_, let color, let markSize):
                model.updateOverlay(id, .box(rect: resized, color: color, size: markSize))
            case .arrow, .text: break
            }
        case .endpoint(let id, let mark, let from):
            guard case .arrow(let start, let end, let color, let markSize) = mark else { return }
            let moved = model.canvasPoint(normalized(point, size))
            model.updateOverlay(
                id, .arrow(from: from ? moved : start, to: from ? end : moved, color: color, size: markSize))
        case .ignored, .none: break
        }
    }

    private static func resized(_ rect: EditCrop, handle: Handle, to point: EditPoint) -> EditCrop {
        let minimum = MediaEditorModel.minimumOverlaySide
        var left = rect.x
        var right = rect.x + rect.width
        var top = rect.y
        var bottom = rect.y + rect.height
        if handle.x < 0 { left = min(point.x, right - minimum) }
        if handle.x > 0 { right = max(point.x, left + minimum) }
        if handle.y < 0 { top = min(point.y, bottom - minimum) }
        if handle.y > 0 { bottom = max(point.y, top + minimum) }
        left = max(0, left)
        top = max(0, top)
        return EditCrop(x: left, y: top, width: min(1, right) - left, height: min(1, bottom) - top)
    }

    private func finish(at point: CGPoint, size: CGSize) {
        switch drag {
        case .pending(let start):
            if model.markupTool == .text,
                let mark = model.newMark(.text, outputRect: CGRect(origin: normalized(start, size), size: .zero)),
                let id = model.addOverlay(mark)
            {
                model.overlayTextFocusRequest = id
            } else {
                model.selectOverlay(nil)
            }
        case .creating, .moving, .resizing, .endpoint: model.endInteraction()
        case .ignored, .none: break
        }
        drag = nil
    }

    private func accessibilityElement(_ overlay: EditOverlay, size: CGSize) -> some View {
        let frame = outline(overlay.mark, size).boundingRect.insetBy(dx: -4, dy: -4)
        let id = overlay.id
        let step = MediaEditorModel.overlayNudge
        return Color.clear
            .frame(width: max(1, frame.width), height: max(1, frame.height))
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(Text(model.overlayName(overlay)))
            .accessibilityValue(Text(model.overlayDescription(overlay)))
            .accessibilityAddTraits(id == model.values.selectedOverlayID ? [.isSelected] : [])
            .accessibilityAction { model.selectOverlay(id) }
            .accessibilityAction(named: Text("Move Left")) { model.nudgeOverlay(id, dx: -step, dy: 0) }
            .accessibilityAction(named: Text("Move Right")) { model.nudgeOverlay(id, dx: step, dy: 0) }
            .accessibilityAction(named: Text("Move Up")) { model.nudgeOverlay(id, dx: 0, dy: -step) }
            .accessibilityAction(named: Text("Move Down")) { model.nudgeOverlay(id, dx: 0, dy: step) }
            .accessibilityAction(named: Text("Make Larger")) {
                model.scaleOverlay(id, by: MediaEditorModel.overlayScaleStep)
            }
            .accessibilityAction(named: Text("Make Smaller")) {
                model.scaleOverlay(id, by: 1 / MediaEditorModel.overlayScaleStep)
            }
            .accessibilityAction(named: Text("Delete")) { model.deleteOverlay(id) }
    }
}
