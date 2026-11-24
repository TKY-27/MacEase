import AppKit

/// One drawn thing VoiceOver can reach.
enum TimelinePart: Hashable {
    case playhead
    case clip(UUID)
    case overlay(UUID, part: Int)
    case music
    case silence(Int)
}

extension Timecode {
    /// Units VoiceOver reads naturally.
    static func spoken(_ seconds: Double) -> String {
        Duration.seconds(max(0, seconds.isFinite ? seconds : 0))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, fractionalPart: .show(length: 2)))
    }

    static func spokenRange(_ range: ClosedRange<Double>) -> String {
        let length = spoken(range.upperBound - range.lowerBound)
        return String(localized: "\(spoken(range.lowerBound)) to \(spoken(range.upperBound)), \(length) long")
    }
}

/// Reads attributes from the canvas lazily.
// Unchecked: AppKit queries it on main.
final class TimelineAccessibilityElement: NSAccessibilityElement, @unchecked Sendable {
    let part: TimelinePart
    private weak var canvas: TimelineCanvas?

    init(part: TimelinePart, canvas: TimelineCanvas) {
        self.part = part
        self.canvas = canvas
        super.init()
        setAccessibilityParent(canvas)
    }

    private func onCanvas<Result: Sendable>(_ body: @MainActor (TimelineCanvas) -> Result?) -> Result? {
        let canvas = canvas
        return MainActor.assumeIsolated { canvas.flatMap(body) }
    }

    private var details: TimelineCanvas.PartDetails? { onCanvas { [part] in $0.details(of: part) } }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { part == .playhead ? .slider : .layoutItem }
    override func accessibilityLabel() -> String? { details?.label }
    override func accessibilityValue() -> Any? { details?.value }
    override func isAccessibilitySelected() -> Bool { details?.selected ?? false }
    override func isAccessibilityEnabled() -> Bool { onCanvas { $0.interactionEnabled } ?? false }

    override func accessibilityFrame() -> NSRect {
        onCanvas { [part] canvas in
            canvas.details(of: part).map { NSAccessibility.screenRect(fromView: canvas, rect: $0.frame) }
        } ?? .zero
    }

    override func accessibilityPerformPress() -> Bool { onCanvas { [part] in $0.press(part) } ?? false }
    override func accessibilityPerformIncrement() -> Bool {
        onCanvas { [part] in $0.stepPlayhead(part, by: 1) } ?? false
    }
    override func accessibilityPerformDecrement() -> Bool {
        onCanvas { [part] in $0.stepPlayhead(part, by: -1) } ?? false
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let available = onCanvas { [part] in $0.availableActions(for: part) } ?? []
        let canvas = canvas
        let part = part
        return available.map { action, name in
            NSAccessibilityCustomAction(name: name) { [weak canvas] in
                MainActor.assumeIsolated { canvas?.perform(action, on: part) ?? false }
            }
        }
    }
}

extension TimelineCanvas {
    struct PartDetails {
        let label: String
        let value: String
        let frame: CGRect
        var selected = false
    }

    /// Front to back, as hit-testing sees them.
    func accessibleParts(_ configuration: MediaTimeline) -> [TimelinePart] {
        guard configuration.duration > 0 else { return [] }
        var parts: [TimelinePart] = [.playhead]
        if configuration.showsOverlayLane {
            parts += overlayBars(configuration).reversed().map { .overlay($0.mark.id, part: $0.part) }
        }
        if configuration.music != nil { parts.append(.music) }
        parts += configuration.hatched.indices.map(TimelinePart.silence)
        parts += configuration.clips.filter { $0.accessibilityName != nil }.map { .clip($0.id) }
        return parts
    }

    func details(of part: TimelinePart) -> PartDetails? {
        guard let configuration, configuration.duration > 0 else { return nil }
        switch part {
        case .playhead:
            let time = String(
                localized: "\(Timecode.spoken(configuration.position)) of \(Timecode.spoken(configuration.duration))")
            return PartDetails(
                label: String(localized: "Playhead"), value: time, frame: playheadFrame(configuration))
        case .clip(let id):
            guard let clip = configuration.clips.first(where: { $0.id == id }), let name = clip.accessibilityName
            else { return nil }
            let selected = clip.selection != nil
            let states = clip.accessibilityStates + (selected ? [String(localized: "Selected")] : [])
            return PartDetails(
                label: name, value: Self.spokenList([Timecode.spokenRange(clip.range)] + states),
                frame: rectangle(clip.range, duration: configuration.duration), selected: selected)
        case .overlay(let id, let index):
            guard let bar = overlayBars(configuration).first(where: { $0.mark.id == id && $0.part == index })
            else { return nil }
            let count = bar.mark.ranges.count
            let label =
                count > 1 ? String(localized: "\(bar.mark.label), part \(index + 1) of \(count)") : bar.mark.label
            let states = bar.mark.selected ? [String(localized: "Selected")] : []
            return PartDetails(
                label: label, value: Self.spokenList([Timecode.spokenRange(bar.mark.ranges[index])] + states),
                frame: bar.rect, selected: bar.mark.selected)
        case .music:
            guard let music = configuration.music else { return nil }
            let volume = String(localized: "Volume \(music.volume.formatted(.percent.precision(.fractionLength(0))))")
            return PartDetails(
                label: String(localized: "Music, \(music.label)"),
                value: Self.spokenList([Timecode.spokenRange(music.range), volume]),
                frame: musicBar(music, configuration: configuration))
        case .silence(let index):
            guard configuration.hatched.indices.contains(index) else { return nil }
            let range = configuration.hatched[index]
            return PartDetails(
                label: String(localized: "Pause to remove, \(index + 1) of \(configuration.hatched.count)"),
                value: Timecode.spokenRange(range), frame: hatchRect(range, configuration: configuration))
        }
    }

    private static func spokenList(_ phrases: [String]) -> String {
        phrases.formatted(.list(type: .and, width: .narrow))
    }

    func press(_ part: TimelinePart) -> Bool {
        guard interactionEnabled, let configuration else { return false }
        switch part {
        case .clip(let id): configuration.select(id)
        case .overlay(let id, _):
            guard let selectOverlay = configuration.selectOverlay else { return false }
            selectOverlay(id)
        case .music:
            guard let selectMusic = configuration.selectMusic else { return false }
            selectMusic()
        case .playhead, .silence: return false
        }
        return true
    }

    func stepPlayhead(_ part: TimelinePart, by frames: Int) -> Bool {
        guard part == .playhead, interactionEnabled, let step = configuration?.step else { return false }
        step(frames)
        return true
    }

    func availableActions(for part: TimelinePart) -> [(TimelineAction, String)] {
        guard interactionEnabled, case .clip(let id) = part, let configuration, configuration.action != nil
        else { return [] }
        return TimelineAction.allCases.compactMap { action in
            let state = configuration.actionState?(id, action) ?? TimelineActionState()
            guard state.available else { return nil }
            let name =
                action == .reverse && state.checked ? String(localized: "Play Segment Forward") : action.title
            return (action, name)
        }
    }

    func perform(_ action: TimelineAction, on part: TimelinePart) -> Bool {
        guard interactionEnabled, case .clip(let id) = part, let perform = configuration?.action else { return false }
        perform(id, action)
        return true
    }
}
