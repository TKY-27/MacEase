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
}

enum TimelineAction: Int, CaseIterable {
    case setIn, setOut, split, duplicate, left, right, delete

    var title: String {
        switch self {
        case .setIn: String(localized: "Set In Point at Playhead")
        case .setOut: String(localized: "Set Out Point at Playhead")
        case .split: String(localized: "Split at Playhead")
        case .duplicate: String(localized: "Duplicate Segment")
        case .left: String(localized: "Move Segment Left")
        case .right: String(localized: "Move Segment Right")
        case .delete: String(localized: "Delete Segment")
        }
    }
}

struct TimelineZoomControls: View {
    @Binding var zoom: Double
    let maximumZoom: Double

    var body: some View {
        HStack(spacing: 6) {
            Button {
                zoom = max(1, zoom / 2)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }.help("Zoom Out (⌘−)")
            Slider(value: Binding(get: { log2(zoom) }, set: { zoom = pow(2, $0) }), in: 0...log2(maximumZoom)) {
                Text("Timeline Zoom")
            }.labelsHidden().frame(width: 100)
            Button {
                zoom = min(maximumZoom, zoom * 2)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }.help("Zoom In (⌘+)")
            Button("Fit") { zoom = 1 }.help("Fit Timeline (⇧Z)")
        }.buttonStyle(.borderless).fixedSize(horizontal: true, vertical: false)
    }
}

struct MediaTimeline: NSViewRepresentable {
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
    var viewportChanged: ((Double) -> Void)?

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
        scroll.configuration = self
        scroll.updateTimeline()
    }

    static func dismantleNSView(_ scroll: TimelineScrollView, coordinator: ()) {
        scroll.canvas?.leave()
        scroll.configuration = nil
    }
}

final class TimelineScrollView: NSScrollView {
    var configuration: MediaTimeline?
    var canvas: TimelineCanvas? { documentView as? TimelineCanvas }
    private var appliedZoom = 1.0
    private var previousViewportWidth = 0.0
    private var anchor: (fraction: Double, viewport: Double)?

    override func layout() {
        super.layout()
        updateTimeline()
    }

    func updateTimeline() {
        guard let configuration, let canvas else { return }
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
        canvas.frame = CGRect(x: 0, y: 0, width: viewportWidth * configuration.zoom, height: 92)
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
        canvas.needsDisplay = true
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
        guard event.modifierFlags.contains(.command) else { super.scrollWheel(with: event); return }
        magnify(by: exp(Double(event.scrollingDeltaY) * 0.025), event: event)
    }

    override func magnify(with event: NSEvent) {
        magnify(by: exp(Double(event.magnification)), event: event)
    }

    private func magnify(by factor: Double, event: NSEvent) {
        guard let configuration, let canvas else { return }
        let point = canvas.convert(event.locationInWindow, from: nil)
        anchor = (point.x / max(1, canvas.frame.width), point.x - contentView.bounds.minX)
        configuration.zoom = min(configuration.maximumZoom, max(1, configuration.zoom * factor))
    }
}

final class TimelineCanvas: NSView, NSDraggingSource {
    var configuration: MediaTimeline?
    private(set) var pointerInViewport: CGPoint?
    private var tracking: NSTrackingArea?
    private var hoverTime: Double?
    private var trimDrag: (origin: Double, boundary: Double, scale: Double, snaps: [Double])?
    private var mouseOrigin: CGPoint?
    private var draggedClip: UUID?
    private var menuClip: UUID?
    override var isFlipped: Bool { true }
    private static let rulerHeight = 24.0
    private static let clipHeight = 56.0
    private static let handleWidth = 9.0
    private static let snapDistance = 8.0

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

    override func draw(_ dirtyRect: NSRect) {
        guard let configuration, configuration.duration > 0,
            let context = NSGraphicsContext.current?.cgContext
        else { return }
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        drawRuler(context, configuration: configuration)
        for clip in configuration.clips {
            let rect = rectangle(clip.range, duration: configuration.duration)
            guard rect.intersects(dirtyRect) else { continue }
            context.saveGState()
            context.clip(to: rect)
            NSColor.separatorColor.setFill()
            rect.fill()
            if let waveform = clip.waveform { drawWaveform(waveform, in: rect, context: context) }
            if let detail = clip.detailWaveform {
                let detailRect = rectangle(
                    detail.start...(detail.start + detail.duration), duration: configuration.duration)
                NSColor.controlBackgroundColor.setFill(); detailRect.fill()
                drawWaveform(detail, in: rect, context: context)
            }
            drawFrames(clip.frames, in: rect, context: context)
            if !clip.label.isEmpty {
                let label = NSAttributedString(
                    string: clip.label,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white,
                        .backgroundColor: NSColor.black.withAlphaComponent(0.65),
                    ])
                label.draw(at: CGPoint(x: rect.minX + 12, y: rect.maxY - 17))
            }
            context.restoreGState()
            NSColor.separatorColor.setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            if let selection = clip.selection {
                if selection != clip.range {
                    NSColor.controlBackgroundColor.withAlphaComponent(0.7).setFill()
                    rectangle(clip.range.lowerBound...selection.lowerBound, duration: configuration.duration).fill()
                    rectangle(selection.upperBound...clip.range.upperBound, duration: configuration.duration).fill()
                }
                drawSelection(selection, duration: configuration.duration)
            }
        }
        drawMarker(configuration.position, color: .white, configuration: configuration)
        if !configuration.playing, let hoverTime {
            drawMarker(hoverTime, color: .systemRed, configuration: configuration)
            let label = NSAttributedString(
                string: Self.timeLabel(hoverTime),
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor.systemRed,
                    .backgroundColor: NSColor.controlBackgroundColor,
                ])
            let x = min(visibleRect.maxX - label.size().width, max(visibleRect.minX, point(hoverTime, configuration)))
            label.draw(at: CGPoint(x: x, y: 0))
        }
    }

    private func drawRuler(_ context: CGContext, configuration: MediaTimeline) {
        let secondsPerPoint = configuration.duration / max(1, bounds.width)
        let approximate = secondsPerPoint * 90
        let power = pow(10, floor(log10(max(approximate, 0.001))))
        let step = [1.0, 2, 5, 10].map { $0 * power }.first { $0 >= approximate } ?? power * 10
        var time = floor(visibleRect.minX * secondsPerPoint / step) * step
        while time <= min(configuration.duration, visibleRect.maxX * secondsPerPoint) {
            let x = point(time, configuration)
            NSColor.secondaryLabelColor.setStroke()
            context.setStrokeColor(NSColor.secondaryLabelColor.cgColor)
            context.move(to: CGPoint(x: x, y: 18)); context.addLine(to: CGPoint(x: x, y: 23)); context.strokePath()
            NSAttributedString(
                string: Self.timeLabel(time),
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ).draw(at: CGPoint(x: x + 3, y: 2))
            time += step
        }
    }

    private func drawFrames(_ frames: [CGImage], in rect: CGRect, context: CGContext) {
        guard !frames.isEmpty else { return }
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

    private func drawWaveform(_ waveform: AudioWaveformSnapshot, in rect: CGRect, context: CGContext) {
        guard !waveform.peaks.isEmpty, let configuration, waveform.duration > 0 else { return }
        let firstTime = max(waveform.start, visibleRect.minX / bounds.width * configuration.duration)
        let lastTime = min(waveform.start + waveform.duration, visibleRect.maxX / bounds.width * configuration.duration)
        guard firstTime < lastTime else { return }
        let firstX = max(0, Int(point(firstTime, configuration)))
        let lastX = min(Int(bounds.width), Int(ceil(point(lastTime, configuration))))
        context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.8).cgColor)
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
            let amplitude = max(1, min(1, peak) * (rect.height / 2 - 5))
            context.move(to: CGPoint(x: Double(x) + 0.5, y: rect.midY - amplitude))
            context.addLine(to: CGPoint(x: Double(x) + 0.5, y: rect.midY + amplitude))
        }
        context.strokePath()
    }

    private func drawSelection(_ selection: ClosedRange<Double>, duration: Double) {
        let rect = rectangle(selection, duration: duration)
        NSColor.systemYellow.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5)); border.lineWidth = 3; border.stroke()
        for x in [rect.minX, rect.maxX - Self.handleWidth] {
            let handle = CGRect(x: x, y: rect.minY, width: Self.handleWidth, height: rect.height)
            NSColor.systemYellow.setFill(); handle.fill()
            NSColor.black.withAlphaComponent(0.6).setFill()
            CGRect(x: x + 4, y: rect.midY - 7, width: 1, height: 14).fill()
        }
    }

    private func drawMarker(_ seconds: Double, color: NSColor, configuration: MediaTimeline) {
        let x = point(seconds, configuration)
        let rect = CGRect(x: x - 0.75, y: 17, width: 1.5, height: Self.clipHeight + 9)
        NSColor.black.withAlphaComponent(0.65).setFill(); rect.insetBy(dx: -0.5, dy: 0).fill()
        color.setFill(); rect.fill()
    }

    private func rectangle(_ range: ClosedRange<Double>, duration: Double) -> CGRect {
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
        guard let configuration else { return }
        let location = convert(event.locationInWindow, from: nil)
        mouseOrigin = location
        leave()
        for clip in configuration.clips where location.y >= Self.rulerHeight {
            if let selection = clip.selection {
                let rect = rectangle(selection, duration: configuration.duration)
                for start in [true, false] {
                    let boundary = start ? rect.minX : rect.maxX
                    if abs(location.x - boundary) <= Self.handleWidth {
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
        } else if let draggedClip, let mouseOrigin, configuration.move != nil,
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
        if trimDrag != nil { configuration?.endTrim() }
        trimDrag = nil; mouseOrigin = nil; draggedClip = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation
    { .move }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        configuration?.move == nil ? [] : .move
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
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
        guard let configuration, configuration.action != nil else { return nil }
        let location = convert(event.locationInWindow, from: nil)
        guard
            let clip = configuration.clips.first(where: {
                rectangle($0.range, duration: configuration.duration).contains(location)
            })
        else { return nil }
        configuration.select(clip.id)
        menuClip = clip.id
        let menu = NSMenu()
        for action in TimelineAction.allCases {
            let entry = NSMenuItem(title: action.title, action: #selector(performTimelineAction(_:)), keyEquivalent: "")
            entry.tag = action.rawValue; entry.target = self
            menu.addItem(entry)
        }
        return menu
    }

    @objc private func performTimelineAction(_ sender: NSMenuItem) {
        guard let menuClip, let action = TimelineAction(rawValue: sender.tag) else { return }
        configuration?.action?(menuClip, action)
    }

    private static func timeLabel(_ seconds: Double) -> String {
        String(format: "%02d:%06.3f", Int(max(0, seconds)) / 60, max(0, seconds).truncatingRemainder(dividingBy: 60))
    }
}
