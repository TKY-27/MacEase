import AppKit
import Engine
import SwiftUI

struct TimelineClip {
    let id: UUID
    let range: ClosedRange<Double>
    let selection: ClosedRange<Double>?
    let label: String
    var frames: [CGImage] = []
    var waveform: AudioWaveformSnapshot?
    var detailWaveform: AudioWaveformSnapshot?
    /// Timeline seconds, measured inside `selection ?? range`.
    var fadeIn = 0.0
    var fadeOut = 0.0
    /// A held picture without trim handles.
    var freeze = false
    var badges: [TimelineBadge] = []
    /// VoiceOver name; `nil` keeps the clip unexposed.
    var accessibilityName: String?
    var accessibilityStates: [String] = []
}

struct TimelineMusicBar {
    let range: ClosedRange<Double>
    let label: String
    /// Output seconds at the end.
    let fadeOut: Double
    let volume: Double
}

struct TimelineBadge {
    let symbol: String
    let title: String
}

/// One overlay, possibly shown in several places.
struct TimelineOverlayMark {
    let id: UUID
    let ranges: [ClosedRange<Double>]
    let label: String
    let fill: NSColor
    let text: NSColor
    let selected: Bool
}

struct TimelineActionState {
    var available = true
    var checked = false
    /// Shown when unavailable.
    var reason: String?
}

enum TimelineAction: Int, CaseIterable {
    case setIn, setOut, split, freeze, reverse, duplicate, left, right, delete

    var title: String {
        switch self {
        case .setIn: String(localized: "Set In Point at Playhead")
        case .setOut: String(localized: "Set Out Point at Playhead")
        case .split: String(localized: "Split at Playhead")
        case .freeze: String(localized: "Insert Freeze Frame at Playhead")
        case .reverse: String(localized: "Reverse Segment")
        case .duplicate: String(localized: "Duplicate Segment")
        case .left: String(localized: "Move Segment Left")
        case .right: String(localized: "Move Segment Right")
        case .delete: String(localized: "Delete Segment")
        }
    }
}

/// Editor clock text, such as `1:05.25`.
enum Timecode {
    static func string(_ seconds: Double, fractionDigits: Int = 2) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        let scale = pow(10, Double(fractionDigits))
        let units = Int((value * scale).rounded())
        let whole = units / Int(scale)
        let fraction = units % Int(scale)
        let clock =
            whole >= 3_600
            ? String(format: "%d:%02d:%02d", whole / 3_600, whole / 60 % 60, whole % 60)
            : String(format: "%d:%02d", whole / 60, whole % 60)
        guard fractionDigits > 0 else { return clock }
        return clock + "." + String(format: "%0\(fractionDigits)d", fraction)
    }
}

struct TimelineZoomControls: View {
    @Binding var zoom: Double
    let maximumZoom: Double

    var body: some View {
        HStack(spacing: 8) {
            Button {
                zoom = max(1, zoom / 2)
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .help("Zoom Out (⌘−)")
            .disabled(zoom <= 1)
            Slider(value: Binding(get: { log2(zoom) }, set: { zoom = pow(2, $0) }), in: 0...log2(maximumZoom)) {
                Text("Timeline Zoom")
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 110)
            Button {
                zoom = min(maximumZoom, zoom * 2)
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .help("Zoom In (⌘+)")
            .disabled(zoom >= maximumZoom)
            Button("Fit") { zoom = 1 }
                .help("Fit Timeline (⇧Z)")
                .disabled(zoom == 1)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct MediaTimeline: NSViewRepresentable {
    static var height: CGFloat {
        let scroller =
            NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        return TimelineCanvas.contentHeight + 4 + scroller
    }

    static func maximumZoom(duration: Double, viewport: Double, interval: Double) -> Double {
        max(2, duration / max(0.000_001, interval) * 6 / max(1, viewport))
    }

    let duration: Double
    let position: Double
    let clips: [TimelineClip]
    let playing: Bool
    @Binding var zoom: Double
    let maximumZoom: Double
    let seek: (Double) -> Void
    let hover: (Double?) -> Void
    let select: (UUID) -> Void
    let beginTrim: (UUID, Bool) -> Void
    let trim: (Double) -> Void
    let endTrim: () -> Void
    var move: ((UUID, Int) -> Void)?
    var visibleRange: ((Range<Double>) -> Void)?
    var action: ((UUID, TimelineAction) -> Void)?
    var actionState: ((UUID, TimelineAction) -> TimelineActionState)?
    var viewportChanged: ((Double) -> Void)?
    var overlays: [TimelineOverlayMark] = []
    var showsOverlayLane = false
    var selectOverlay: ((UUID) -> Void)?
    /// Ranges a pending edit would remove.
    var hatched: [ClosedRange<Double>] = []
    var music: TimelineMusicBar?
    var selectMusic: (() -> Void)?
    /// Moves the playhead by frames.
    var step: ((Int) -> Void)?
    var accessibilityTitle = String(localized: "Timeline")

    var lanesHeight: Double {
        (showsOverlayLane ? TimelineCanvas.overlayLaneHeight : 0) + (music == nil ? 0 : TimelineCanvas.musicLaneHeight)
    }

    func makeNSView(context: Context) -> TimelineScrollView {
        let scroll = TimelineScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.documentView = TimelineCanvas()
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: TimelineScrollView, context: Context) {
        scroll.interactionEnabled = context.environment.isEnabled
        scroll.configuration = self
        scroll.updateTimeline()
    }

    static func dismantleNSView(_ scroll: TimelineScrollView, coordinator: ()) {
        scroll.canvas?.leave()
        scroll.configuration = nil
    }
}

final class TimelineScrollView: NSScrollView {
    var interactionEnabled = true
    var configuration: MediaTimeline?
    var canvas: TimelineCanvas? { documentView as? TimelineCanvas }
    private var appliedZoom = 1.0
    private var previousViewportWidth = 0.0
    private var anchor: (fraction: Double, viewport: Double)?
    private var revealedPosition: Double?

    override func layout() {
        super.layout()
        updateTimeline()
    }

    func updateTimeline() {
        guard let configuration, let canvas else { return }
        canvas.interactionEnabled = interactionEnabled
        let viewportWidth = max(1, contentSize.width)
        if viewportWidth != previousViewportWidth {
            previousViewportWidth = viewportWidth
            configuration.viewportChanged?(viewportWidth)
        }
        let oldWidth = max(1, canvas.frame.width)
        if appliedZoom != configuration.zoom, anchor == nil {
            if let pointer = canvas.pointerInViewport, (0...viewportWidth).contains(pointer.x) {
                anchor = ((contentView.bounds.minX + pointer.x) / oldWidth, pointer.x)
            }
            if anchor == nil {
                let seconds = configuration.position
                let fraction = min(1, max(0, seconds / max(configuration.duration, .leastNonzeroMagnitude)))
                let viewport = min(viewportWidth, max(0, oldWidth * fraction - contentView.bounds.minX))
                anchor = (fraction, viewport)
            }
        }
        appliedZoom = configuration.zoom
        canvas.frame = CGRect(
            x: 0, y: 0, width: viewportWidth * configuration.zoom,
            height: TimelineCanvas.contentHeight + configuration.lanesHeight)
        canvas.configuration = configuration
        if let anchor {
            contentView.scroll(
                to: CGPoint(
                    x: min(
                        max(0, canvas.frame.width * anchor.fraction - anchor.viewport),
                        max(0, canvas.frame.width - viewportWidth)), y: 0))
            reflectScrolledClipView(contentView)
            self.anchor = nil
        }
        horizontalScroller?.isEnabled = interactionEnabled && configuration.zoom > 1
        if configuration.position != revealedPosition {
            revealedPosition = configuration.position
            canvas.revealPlayhead()
        }
        canvas.needsDisplay = true
        window?.invalidateCursorRects(for: canvas)
        notifyVisibleRange()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        notifyVisibleRange()
    }

    private func notifyVisibleRange() {
        guard let configuration, let canvas, canvas.frame.width > 0, configuration.duration > 0 else { return }
        let bounds = contentView.bounds
        let start = max(0, bounds.minX / canvas.frame.width * configuration.duration)
        let end = min(configuration.duration, bounds.maxX / canvas.frame.width * configuration.duration)
        guard end > start else { return }
        configuration.visibleRange?(start..<end)
    }

    override func scrollWheel(with event: NSEvent) {
        guard interactionEnabled else { return }
        guard event.modifierFlags.contains(.command) else { super.scrollWheel(with: event); return }
        magnify(by: exp(Double(event.scrollingDeltaY) * 0.025), event: event)
    }

    override func magnify(with event: NSEvent) {
        magnify(by: exp(Double(event.magnification)), event: event)
    }

    private func magnify(by factor: Double, event: NSEvent) {
        guard interactionEnabled, let configuration, let canvas else { return }
        let point = canvas.convert(event.locationInWindow, from: nil)
        anchor = (point.x / max(1, canvas.frame.width), point.x - contentView.bounds.minX)
        configuration.zoom = min(configuration.maximumZoom, max(1, configuration.zoom * factor))
    }
}

final class TimelineCanvas: NSView, NSDraggingSource {
    static let rulerHeight = 24.0
    static let clipHeight = 64.0
    static let contentHeight = rulerHeight + clipHeight + 8
    private static let handleWidth = 12.0
    private static let handleHitSlop = 4.0
    private static let snapDistance = 8.0
    private static let clipRadius = 6.0
    private static let selectionLine = 3.0
    private static let playheadWidth = 2.0
    private static let rulerMinorTicks = 4
    private static let waveformLaneHeight = 18.0
    static let overlayLaneHeight = 30.0
    static let musicLaneHeight = 26.0
    private static let overlayRowLimit = 3
    private static let overlayRowGap = 2.0
    private static let overlayLabelMinimumWidth = 36.0
    private static let freezeDash: [CGFloat] = [4, 3]
    private static let minimumLabelWidth = 40.0
    private static let hatchSpacing = 7.0

    var interactionEnabled = true {
        didSet {
            guard oldValue, !interactionEnabled else { return }
            trimDrag = nil
            mouseOrigin = nil
            draggedClip = nil
            leave()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        interactionEnabled ? super.hitTest(point) : nil
    }

    var configuration: MediaTimeline? {
        didSet { announceAccessibilityChanges(from: oldValue) }
    }
    private var accessibilityElements: [TimelinePart: TimelineAccessibilityElement] = [:]
    private(set) var pointerInViewport: CGPoint?
    private var tracking: NSTrackingArea?
    private var hoverTime: Double?
    private var trimDrag: (origin: Double, boundary: Double, scale: Double, snaps: [Double])?
    private var mouseOrigin: CGPoint?
    private var draggedClip: UUID?
    private var menuClip: UUID?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) { return nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(
            rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil)
        self.tracking = tracking
        addTrackingArea(tracking)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .layoutArea }
    override func accessibilityLabel() -> String? { configuration?.accessibilityTitle }

    override func accessibilityChildren() -> [Any]? { currentAccessibilityElements() }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        let hit = MainActor.assumeIsolated {
            currentAccessibilityElements().first { NSPointInRect(point, $0.accessibilityFrame()) }
        }
        return hit ?? self
    }

    /// Reuses elements so VoiceOver keeps its place.
    private func currentAccessibilityElements() -> [TimelineAccessibilityElement] {
        let parts = configuration.map(accessibleParts) ?? []
        let elements = parts.map { part in
            accessibilityElements[part] ?? TimelineAccessibilityElement(part: part, canvas: self)
        }
        accessibilityElements = Dictionary(uniqueKeysWithValues: zip(parts, elements))
        return elements
    }

    /// Playback ticks only refresh the playhead.
    private func announceAccessibilityChanges(from previous: MediaTimeline?) {
        guard let configuration, !accessibilityElements.isEmpty else { return }
        if previous.map(accessibleParts) != accessibleParts(configuration) {
            NSAccessibility.post(element: self, notification: .layoutChanged)
        } else if !configuration.playing, previous?.position != configuration.position,
            let playhead = accessibilityElements[.playhead]
        {
            NSAccessibility.post(element: playhead, notification: .valueChanged)
        }
    }

    func revealPlayhead() {
        guard let configuration, trimDrag == nil else { return }
        scrollToVisible(playheadFrame(configuration))
    }

    override func resetCursorRects() {
        guard interactionEnabled, let configuration, configuration.duration > 0 else { return }
        for clip in configuration.clips where !clip.freeze {
            guard let selection = clip.selection else { continue }
            for handle in handleRects(rectangle(selection, duration: configuration.duration)) {
                addCursorRect(handle.insetBy(dx: -Self.handleHitSlop, dy: 0), cursor: .columnResize)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let configuration, configuration.duration > 0,
            let context = NSGraphicsContext.current?.cgContext
        else { return }
        NSColor.black.withAlphaComponent(0.18).setFill()
        dirtyRect.fill()
        drawRuler(context, configuration: configuration)
        for clip in configuration.clips {
            let rect = rectangle(clip.range, duration: configuration.duration)
            guard rect.intersects(dirtyRect) else { continue }
            let shape = NSBezierPath(roundedRect: rect, xRadius: Self.clipRadius, yRadius: Self.clipRadius)
            context.saveGState()
            shape.addClip()
            NSColor.quaternaryLabelColor.setFill()
            rect.fill()
            let lane = !clip.frames.isEmpty && clip.waveform != nil
            let frameRect = lane ? rect.divided(atDistance: Self.waveformLaneHeight, from: .maxYEdge).remainder : rect
            let waveRect = lane ? rect.divided(atDistance: Self.waveformLaneHeight, from: .maxYEdge).slice : rect
            if lane {
                NSColor.systemTeal.withAlphaComponent(0.22).setFill()
                waveRect.fill()
            }
            let waveColor = lane ? NSColor.systemTeal : NSColor.labelColor.withAlphaComponent(0.85)
            if let waveform = clip.waveform {
                drawWaveform(waveform, in: waveRect, color: waveColor, context: context)
            }
            if let detail = clip.detailWaveform {
                let detailRect = rectangle(
                    detail.start...(detail.start + detail.duration), duration: configuration.duration)
                NSColor.quaternaryLabelColor.setFill(); detailRect.intersection(waveRect).fill()
                drawWaveform(detail, in: waveRect, color: waveColor, context: context)
            }
            drawFrames(clip.frames, in: frameRect, tiled: clip.freeze, context: context)
            drawFades(clip, configuration: configuration)
            if let selection = clip.selection, selection != clip.range {
                NSColor.black.withAlphaComponent(0.55).setFill()
                rectangle(clip.range.lowerBound...selection.lowerBound, duration: configuration.duration).fill()
                rectangle(selection.upperBound...clip.range.upperBound, duration: configuration.duration).fill()
            }
            if clip.freeze {
                NSColor.systemCyan.withAlphaComponent(0.22).setFill()
                frameRect.fill()
            }
            let labelEnd = drawBadges(clip.badges, in: rect)
            if !clip.label.isEmpty { drawLabel(clip.label, in: rect, maxX: labelEnd) }
            context.restoreGState()
            NSColor.white.withAlphaComponent(clip.freeze ? 0.5 : 0.12).setStroke()
            let outline = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.clipRadius, yRadius: Self.clipRadius)
            if clip.freeze { outline.setLineDash(Self.freezeDash, count: Self.freezeDash.count, phase: 0) }
            outline.stroke()
            if let selection = clip.selection {
                drawSelection(selection, duration: configuration.duration, handles: !clip.freeze)
            }
        }
        drawHatching(configuration)
        if configuration.showsOverlayLane { drawOverlayLane(configuration) }
        if let music = configuration.music { drawMusicLane(music, configuration: configuration) }
        if !configuration.playing, let hoverTime { drawSkimmer(hoverTime, configuration: configuration) }
        drawPlayhead(configuration.position, configuration: configuration)
    }

    private func drawHatching(_ configuration: MediaTimeline) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for range in configuration.hatched {
            let visible = hatchRect(range, configuration: configuration)
            guard visible.intersects(visibleRect) else { continue }
            context.saveGState()
            context.clip(to: visible)
            NSColor.black.withAlphaComponent(0.45).setFill()
            visible.fill()
            context.setStrokeColor(NSColor.systemRed.cgColor)
            context.setLineWidth(2)
            var x = visible.minX - visible.height
            while x < visible.maxX {
                context.move(to: CGPoint(x: x, y: visible.maxY))
                context.addLine(to: CGPoint(x: x + visible.height, y: visible.minY))
                x += Self.hatchSpacing
            }
            context.strokePath()
            context.restoreGState()
            NSColor.systemRed.setFill()
            CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: 2).fill()
            CGRect(x: visible.minX, y: visible.maxY - 2, width: visible.width, height: 2).fill()
        }
    }

    func hatchRect(_ range: ClosedRange<Double>, configuration: MediaTimeline) -> CGRect {
        let rect = rectangle(range, duration: configuration.duration)
        return CGRect(x: rect.minX, y: rect.minY, width: max(1, rect.width), height: rect.height)
    }

    func musicBar(_ music: TimelineMusicBar, configuration: MediaTimeline) -> CGRect {
        let lane = musicLane(configuration)
        let span = rectangle(music.range, duration: configuration.duration)
        return CGRect(x: span.minX, y: lane.minY, width: max(2, span.width), height: lane.height)
    }

    private func musicLane(_ configuration: MediaTimeline) -> CGRect {
        CGRect(
            x: 0,
            y: Self.rulerHeight + Self.clipHeight + 6
                + (configuration.showsOverlayLane ? Self.overlayLaneHeight : 0),
            width: bounds.width, height: Self.musicLaneHeight - 4)
    }

    private func drawMusicLane(_ music: TimelineMusicBar, configuration: MediaTimeline) {
        let lane = musicLane(configuration)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: lane, xRadius: 4, yRadius: 4).fill()
        let bar = musicBar(music, configuration: configuration)
        let shape = NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4)
        NSColor.systemPurple.withAlphaComponent(0.6).setFill()
        shape.fill()
        let fadeWidth = music.fadeOut / configuration.duration * bounds.width
        if fadeWidth >= 1 {
            let ramp = NSBezierPath()
            ramp.move(to: CGPoint(x: bar.maxX - fadeWidth, y: bar.minY))
            ramp.line(to: CGPoint(x: bar.maxX, y: bar.maxY))
            ramp.line(to: CGPoint(x: bar.maxX, y: bar.minY))
            ramp.close()
            NSColor.black.withAlphaComponent(0.45).setFill()
            ramp.fill()
        }
        guard bar.width >= Self.overlayLabelMinimumWidth else { return }
        let label = NSAttributedString(
            string: "♪ " + music.label,
            attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white])
        let size = label.size()
        label.draw(
            with: CGRect(
                x: bar.minX + 6, y: bar.midY - size.height / 2, width: bar.width - 12 - fadeWidth,
                height: size.height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private var overlayLane: CGRect {
        CGRect(
            x: 0, y: Self.rulerHeight + Self.clipHeight + 6, width: bounds.width, height: Self.overlayLaneHeight - 4)
    }

    /// Packed rows; selected bars last, like drawing.
    func overlayBars(_ configuration: MediaTimeline) -> [(mark: TimelineOverlayMark, part: Int, rect: CGRect)] {
        var rows: [[ClosedRange<Double>]] = []
        var placed: [(TimelineOverlayMark, Int)] = []
        for mark in configuration.overlays where !mark.ranges.isEmpty {
            let free = rows.firstIndex { row in
                !row.contains { used in mark.ranges.contains { $0.overlaps(used) } }
            }
            let row = free ?? (rows.count < Self.overlayRowLimit ? rows.count : rows.count - 1)
            if row == rows.count { rows.append([]) }
            rows[row] += mark.ranges
            placed.append((mark, row))
        }
        let lane = overlayLane
        let count = Double(max(1, rows.count))
        let height = (lane.height - Self.overlayRowGap * (count - 1)) / count
        return placed.sorted { !$0.0.selected && $1.0.selected }.flatMap { mark, row in
            mark.ranges.enumerated().map { part, range in
                let rect = rectangle(range, duration: configuration.duration)
                return (
                    mark, part,
                    CGRect(
                        x: rect.minX, y: lane.minY + Double(row) * (height + Self.overlayRowGap),
                        width: max(2, rect.width), height: height)
                )
            }
        }
    }

    private func drawOverlayLane(_ configuration: MediaTimeline) {
        let lane = overlayLane
        NSColor.quaternaryLabelColor.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: lane, xRadius: 4, yRadius: 4).fill()
        for (mark, _, rect) in overlayBars(configuration) {
            let radius = min(3, rect.height / 2)
            let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            mark.fill.withAlphaComponent(0.9).setFill()
            shape.fill()
            if mark.selected {
                let frame = NSBezierPath(
                    roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: radius + 1, yRadius: radius + 1)
                frame.lineWidth = 2
                NSColor.systemYellow.setStroke()
                frame.stroke()
            }
            guard rect.width >= Self.overlayLabelMinimumWidth, rect.height >= 11 else { continue }
            let label = NSAttributedString(
                string: mark.label,
                attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: mark.text])
            let size = label.size()
            label.draw(
                with: CGRect(
                    x: rect.minX + 5, y: rect.midY - size.height / 2, width: rect.width - 10, height: size.height),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func drawLabel(_ text: String, in rect: CGRect, maxX: Double) {
        let label = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white])
        let size = label.size()
        let inset = Self.handleWidth + 4
        let pill = CGRect(
            x: rect.minX + inset, y: rect.minY + 4, width: min(size.width + 10, max(0, maxX - rect.minX - inset)),
            height: size.height + 2)
        guard pill.width > 12 else { return }
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        label.draw(
            with: pill.insetBy(dx: 5, dy: 1), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Narrow clips get icons; returns label room.
    private func drawBadges(_ badges: [TimelineBadge], in rect: CGRect) -> Double {
        let inset = Self.handleWidth + 4
        var trailing = rect.maxX - inset
        let wide = badges.map { badgeText($0, titled: true).size().width + 14 }.reduce(0, +)
        let titled = wide <= rect.width - inset * 2 - Self.minimumLabelWidth
        for badge in badges {
            let text = badgeText(badge, titled: titled)
            let size = text.size()
            let pill = CGRect(
                x: trailing - size.width - 10, y: rect.minY + 4, width: size.width + 10, height: size.height + 2)
            guard pill.minX >= rect.minX + inset else { break }
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            text.draw(with: pill.insetBy(dx: 5, dy: 1), options: [.usesLineFragmentOrigin])
            trailing = pill.minX - 4
        }
        return trailing
    }

    private func badgeText(_ badge: TimelineBadge, titled: Bool) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        if let symbol = NSImage(systemSymbolName: badge.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            attachment.bounds = CGRect(
                x: 0, y: font.descender / 2, width: symbol.size.width, height: symbol.size.height)
            text.append(NSAttributedString(attachment: attachment))
            if titled { text.append(NSAttributedString(string: " ")) }
        }
        if titled { text.append(NSAttributedString(string: badge.title)) }
        text.addAttributes(
            [.font: font, .foregroundColor: NSColor.black], range: NSRange(location: 0, length: text.length))
        return text
    }

    private func drawRuler(_ context: CGContext, configuration: MediaTimeline) {
        let secondsPerPoint = configuration.duration / max(1, bounds.width)
        let approximate = secondsPerPoint * 80
        let power = pow(10, floor(log10(max(approximate, 0.001))))
        let step = [1.0, 2, 5, 10].map { $0 * power }.first { $0 >= approximate } ?? power * 10
        let minor = step / Double(Self.rulerMinorTicks)
        let digits = step >= 1 ? 0 : step >= 0.1 ? 1 : step >= 0.01 ? 2 : 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let last = min(configuration.duration, visibleRect.maxX * secondsPerPoint)
        var index = Int(floor(visibleRect.minX * secondsPerPoint / minor))
        context.setLineWidth(1)
        while Double(index) * minor <= last {
            let time = Double(index) * minor
            let x = (point(time, configuration)).rounded() + 0.5
            let major = index % Self.rulerMinorTicks == 0
            context.setStrokeColor((major ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).cgColor)
            context.move(to: CGPoint(x: x, y: Self.rulerHeight - (major ? 8 : 4)))
            context.addLine(to: CGPoint(x: x, y: Self.rulerHeight - 1))
            context.strokePath()
            if major {
                NSAttributedString(string: Timecode.string(time, fractionDigits: digits), attributes: attributes)
                    .draw(at: CGPoint(x: x + 3, y: 2))
            }
            index += 1
        }
    }

    private func drawFrames(_ frames: [CGImage], in rect: CGRect, tiled: Bool, context: CGContext) {
        guard let still = frames.first else { return }
        let frames =
            tiled
            ? Array(
                repeating: still,
                count: max(
                    1, Int((rect.width * Double(still.height) / max(1, rect.height * Double(still.width))).rounded(.up))
                ))
            : frames
        let slot = max(1, rect.width / Double(frames.count))
        let first = max(0, Int((visibleRect.minX - rect.minX) / slot))
        let last = min(frames.count - 1, Int((visibleRect.maxX - rect.minX) / slot))
        guard first <= last else { return }
        for index in first...last {
            let image = frames[index]
            let cell = CGRect(x: rect.minX + Double(index) * slot, y: rect.minY, width: slot, height: rect.height)
            context.saveGState()
            context.clip(to: cell)
            let scale = max(cell.width / Double(image.width), cell.height / Double(image.height))
            let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
            context.translateBy(x: cell.midX, y: cell.midY)
            context.scaleBy(x: 1, y: -1)
            context.draw(
                image, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
            context.restoreGState()
        }
    }

    private func drawFades(_ clip: TimelineClip, configuration: MediaTimeline) {
        let span = rectangle(clip.selection ?? clip.range, duration: configuration.duration)
        let points = bounds.width / configuration.duration
        for (width, leading) in [(clip.fadeIn * points, true), (clip.fadeOut * points, false)] where width >= 1 {
            let ramp = NSBezierPath()
            let edge = leading ? span.minX : span.maxX
            let inner = leading ? span.minX + width : span.maxX - width
            ramp.move(to: CGPoint(x: edge, y: span.maxY))
            ramp.line(to: CGPoint(x: inner, y: span.minY))
            ramp.line(to: CGPoint(x: edge, y: span.minY))
            ramp.close()
            NSColor.black.withAlphaComponent(0.45).setFill()
            ramp.fill()
            let line = NSBezierPath()
            line.move(to: CGPoint(x: edge, y: span.maxY))
            line.line(to: CGPoint(x: inner, y: span.minY))
            line.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.85).setStroke()
            line.stroke()
        }
    }

    private func drawWaveform(
        _ waveform: AudioWaveformSnapshot, in rect: CGRect, color: NSColor, context: CGContext
    ) {
        guard !waveform.peaks.isEmpty, let configuration, waveform.duration > 0 else { return }
        let firstTime = max(waveform.start, visibleRect.minX / bounds.width * configuration.duration)
        let lastTime = min(waveform.start + waveform.duration, visibleRect.maxX / bounds.width * configuration.duration)
        guard firstTime < lastTime else { return }
        let firstX = max(0, Int(point(firstTime, configuration)))
        let lastX = min(Int(bounds.width), Int(ceil(point(lastTime, configuration))))
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1)
        for x in firstX..<lastX {
            let seconds = Double(x) / bounds.width * configuration.duration
            let next = Double(x + 1) / bounds.width * configuration.duration
            let lower = max(0, Int((seconds - waveform.start) / waveform.duration * Double(waveform.peaks.count)))
            let upper = min(
                waveform.peaks.count,
                max(
                    lower + 1,
                    Int(ceil((next - waveform.start) / waveform.duration * Double(waveform.peaks.count)))))
            guard lower < upper else { continue }
            let peak = Double(waveform.peaks[lower..<upper].max() ?? 0)
            let amplitude = max(0.5, min(1, peak) * (rect.height / 2 - min(6, rect.height * 0.1)))
            context.move(to: CGPoint(x: Double(x) + 0.5, y: rect.midY - amplitude))
            context.addLine(to: CGPoint(x: Double(x) + 0.5, y: rect.midY + amplitude))
        }
        context.strokePath()
    }

    private func handleRects(_ rect: CGRect) -> [CGRect] {
        let width = min(Self.handleWidth, rect.width / 2)
        return [
            CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
            CGRect(x: rect.maxX - width, y: rect.minY, width: width, height: rect.height),
        ]
    }

    private func drawSelection(_ selection: ClosedRange<Double>, duration: Double, handles: Bool) {
        let rect = rectangle(selection, duration: duration)
        let frame = NSBezierPath(
            roundedRect: rect.insetBy(dx: Self.selectionLine / 2, dy: Self.selectionLine / 2),
            xRadius: Self.clipRadius, yRadius: Self.clipRadius)
        frame.lineWidth = Self.selectionLine
        NSColor.systemYellow.setStroke()
        frame.stroke()
        guard handles else { return }
        for (index, handle) in handleRects(rect).enumerated() {
            let corners = NSBezierPath(roundedRect: handle, xRadius: Self.clipRadius, yRadius: Self.clipRadius)
            NSColor.systemYellow.setFill()
            corners.fill()
            let inner = max(0, handle.width - Self.clipRadius)
            CGRect(
                x: index == 0 ? handle.maxX - inner : handle.minX, y: handle.minY, width: inner, height: handle.height
            )
            .fill()
            let chevron = NSBezierPath()
            let direction = index == 0 ? 1.0 : -1.0
            chevron.move(to: CGPoint(x: handle.midX + 1.5 * direction, y: handle.midY - 5))
            chevron.line(to: CGPoint(x: handle.midX - 1.5 * direction, y: handle.midY))
            chevron.line(to: CGPoint(x: handle.midX + 1.5 * direction, y: handle.midY + 5))
            chevron.lineWidth = 2
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            NSColor.black.withAlphaComponent(0.7).setStroke()
            chevron.stroke()
        }
    }

    private static let knobHalfWidth = 6.0
    private static let knobTop = 3.0

    /// Knob and line together.
    func playheadFrame(_ configuration: MediaTimeline) -> CGRect {
        let x = min(
            max(point(configuration.position, configuration), Self.knobHalfWidth), bounds.width - Self.knobHalfWidth)
        let bottom = playheadLine(configuration.position, configuration: configuration).maxY
        return CGRect(
            x: x - Self.knobHalfWidth, y: Self.knobTop, width: Self.knobHalfWidth * 2, height: bottom - Self.knobTop)
    }

    private func playheadLine(_ seconds: Double, configuration: MediaTimeline) -> CGRect {
        CGRect(
            x: min(max(point(seconds, configuration) - Self.playheadWidth / 2, 0), bounds.width - Self.playheadWidth),
            y: Self.rulerHeight - 6, width: Self.playheadWidth,
            height: Self.clipHeight + 12 + max(0, configuration.lanesHeight - 4))
    }

    private func drawPlayhead(_ seconds: Double, configuration: MediaTimeline) {
        let knobHalfWidth = Self.knobHalfWidth
        let x = min(max(point(seconds, configuration), knobHalfWidth), bounds.width - knobHalfWidth)
        let line = playheadLine(seconds, configuration: configuration)
        NSColor.black.withAlphaComponent(0.5).setFill()
        line.insetBy(dx: -0.5, dy: 0).fill()
        NSColor.white.setFill()
        line.fill()
        let knob = NSBezierPath()
        knob.move(to: CGPoint(x: x - knobHalfWidth, y: Self.knobTop))
        knob.line(to: CGPoint(x: x + knobHalfWidth, y: Self.knobTop))
        knob.line(to: CGPoint(x: x + knobHalfWidth, y: Self.rulerHeight - 12))
        knob.line(to: CGPoint(x: x, y: Self.rulerHeight - 5))
        knob.line(to: CGPoint(x: x - knobHalfWidth, y: Self.rulerHeight - 12))
        knob.close()
        NSColor.white.setFill()
        knob.fill()
        NSColor.black.withAlphaComponent(0.35).setStroke()
        knob.lineWidth = 0.5
        knob.stroke()
    }

    private func drawSkimmer(_ seconds: Double, configuration: MediaTimeline) {
        let x = point(seconds, configuration)
        NSColor.systemPink.withAlphaComponent(0.9).setFill()
        CGRect(x: x - 0.5, y: Self.rulerHeight, width: 1, height: Self.clipHeight).fill()
        let label = NSAttributedString(
            string: Timecode.string(seconds),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
        let size = label.size()
        let pill = CGRect(
            x: min(visibleRect.maxX - size.width - 10, max(visibleRect.minX, x - size.width / 2 - 5)),
            y: Self.rulerHeight + Self.clipHeight - size.height - 6, width: size.width + 10, height: size.height + 2)
        NSColor.systemPink.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        label.draw(at: CGPoint(x: pill.minX + 5, y: pill.minY + 1))
    }

    func rectangle(_ range: ClosedRange<Double>, duration: Double) -> CGRect {
        CGRect(
            x: range.lowerBound / duration * bounds.width, y: Self.rulerHeight,
            width: (range.upperBound - range.lowerBound) / duration * bounds.width, height: Self.clipHeight)
    }

    private func point(_ seconds: Double, _ configuration: MediaTimeline) -> Double {
        seconds / configuration.duration * bounds.width
    }

    private func seconds(at x: Double) -> Double {
        guard let configuration else { return 0 }
        return min(configuration.duration, max(0, x / max(1, bounds.width) * configuration.duration))
    }

    override func mouseMoved(with event: NSEvent) {
        guard interactionEnabled else { return }
        guard let configuration, trimDrag == nil else { return }
        let location = convert(event.locationInWindow, from: nil)
        pointerInViewport = CGPoint(x: location.x - visibleRect.minX, y: location.y)
        hoverTime = seconds(at: location.x)
        configuration.hover(configuration.playing ? nil : hoverTime)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) { pointerInViewport = nil; leave() }

    func leave() {
        hoverTime = nil
        configuration?.hover(nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard interactionEnabled else { return }
        guard let configuration else { return }
        let location = convert(event.locationInWindow, from: nil)
        mouseOrigin = location
        leave()
        if configuration.music != nil, musicLane(configuration).contains(location) {
            configuration.selectMusic?()
            configuration.seek(seconds(at: location.x))
            return
        }
        if configuration.showsOverlayLane, overlayLane.contains(location) {
            if let bar = overlayBars(configuration).last(where: { $0.rect.insetBy(dx: -2, dy: 0).contains(location) }) {
                configuration.selectOverlay?(bar.mark.id)
            }
            configuration.seek(seconds(at: location.x))
            return
        }
        for clip in configuration.clips where location.y >= Self.rulerHeight && !clip.freeze {
            if let selection = clip.selection {
                let rect = rectangle(selection, duration: configuration.duration)
                for (start, handle) in zip([true, false], handleRects(rect))
                where handle.insetBy(dx: -Self.handleHitSlop, dy: 0).minX <= location.x
                    && location.x <= handle.insetBy(dx: -Self.handleHitSlop, dy: 0).maxX
                {
                    trimDrag = (
                        location.x, start ? selection.lowerBound : selection.upperBound,
                        configuration.duration / max(1, bounds.width),
                        configuration.clips.flatMap { [$0.range.lowerBound, $0.range.upperBound] }
                            + [configuration.position]
                    )
                    configuration.beginTrim(clip.id, start)
                    return
                }
            }
        }
        if location.y >= Self.rulerHeight,
            let clip = configuration.clips.first(where: {
                rectangle($0.range, duration: configuration.duration).contains(location)
            })
        {
            configuration.select(clip.id)
            draggedClip = clip.id
        }
        configuration.seek(seconds(at: location.x))
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactionEnabled else { return }
        guard let configuration else { return }
        let location = convert(event.locationInWindow, from: nil)
        if let drag = trimDrag {
            let candidate = drag.boundary + (location.x - drag.origin) * drag.scale
            let snapped =
                event.modifierFlags.contains(.option)
                ? candidate
                : drag.snaps.filter { abs($0 - candidate) / drag.scale <= Self.snapDistance }
                    .min { abs($0 - candidate) < abs($1 - candidate) } ?? candidate
            configuration.trim(snapped)
        } else if let draggedClip, let mouseOrigin, configuration.move != nil, configuration.clips.count > 1,
            hypot(location.x - mouseOrigin.x, location.y - mouseOrigin.y) >= 5
        {
            let pasteboard = NSPasteboardItem(); pasteboard.setString(draggedClip.uuidString, forType: .string)
            let dragging = NSDraggingItem(pasteboardWriter: pasteboard)
            dragging.setDraggingFrame(
                CGRect(x: location.x, y: location.y, width: 100, height: 32),
                contents: NSImage(systemSymbolName: "film", accessibilityDescription: nil))
            beginDraggingSession(with: [dragging], event: event, source: self)
            self.draggedClip = nil
        } else {
            configuration.seek(seconds(at: location.x))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard interactionEnabled else { return }
        if trimDrag != nil { configuration?.endTrim() }
        trimDrag = nil; mouseOrigin = nil; draggedClip = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation
    { .move }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard interactionEnabled else { return [] }
        return configuration?.move == nil ? [] : .move
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard interactionEnabled else { return false }
        guard let configuration, let move = configuration.move,
            let string = sender.draggingPasteboard.string(forType: .string), let id = UUID(uuidString: string),
            configuration.clips.contains(where: { $0.id == id })
        else { return false }
        let time = seconds(at: convert(sender.draggingLocation, from: nil).x)
        let index =
            configuration.clips.firstIndex(where: { $0.range.contains(time) })
            ?? max(0, configuration.clips.count - 1)
        move(id, index)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard interactionEnabled, let configuration, configuration.action != nil else { return nil }
        let location = convert(event.locationInWindow, from: nil)
        guard
            let clip = configuration.clips.first(where: {
                rectangle($0.range, duration: configuration.duration).contains(location)
            })
        else { return nil }
        configuration.select(clip.id)
        menuClip = clip.id
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in TimelineAction.allCases {
            let entry = NSMenuItem(title: action.title, action: #selector(performTimelineAction(_:)), keyEquivalent: "")
            entry.tag = action.rawValue; entry.target = self
            let state = configuration.actionState?(clip.id, action) ?? TimelineActionState()
            entry.isEnabled = state.available
            entry.state = state.checked ? .on : .off
            if !state.available { entry.toolTip = state.reason }
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func performTimelineAction(_ sender: NSMenuItem) {
        guard interactionEnabled, let menuClip, let action = TimelineAction(rawValue: sender.tag) else { return }
        configuration?.action?(menuClip, action)
    }
}
