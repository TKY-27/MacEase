import AppKit

/// One drawn thing VoiceOver can reach.
enum TimelinePart: Hashable {
    case playhead
    case clip(UUID)
    case overlay(UUID, part: Int)
    case music
    case silence(Int)
}

struct TimelineOverlayKey: Hashable {
    let id: UUID
    let part: Int
}

/// Cached geometry; invalidated on configuration or resize.
final class TimelineLayout {
    let size: CGSize
    let overlayBars: [(mark: TimelineOverlayMark, part: Int, rect: CGRect)]
    private var clipIndices: [UUID: Int]?
    private var overlayIndices: [TimelineOverlayKey: Int]?

    init(size: CGSize, overlayBars: [(mark: TimelineOverlayMark, part: Int, rect: CGRect)]) {
        self.size = size
        self.overlayBars = overlayBars
    }

    func clipIndex(for id: UUID, in clips: [TimelineClip]) -> Int? {
        if clipIndices == nil {
            clipIndices = Dictionary(
                clips.enumerated().map { ($0.element.id, $0.offset) },
                uniquingKeysWith: { first, _ in first })
        }
        return clipIndices?[id]
    }

    func overlayBar(id: UUID, part: Int) -> (mark: TimelineOverlayMark, part: Int, rect: CGRect)? {
        if overlayIndices == nil {
            overlayIndices = Dictionary(
                overlayBars.enumerated().map {
                    (TimelineOverlayKey(id: $0.element.mark.id, part: $0.element.part), $0.offset)
                },
                uniquingKeysWith: { first, _ in first })
        }
        guard let index = overlayIndices?[TimelineOverlayKey(id: id, part: part)] else { return nil }
        return overlayBars[index]
    }
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

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { part == .playhead ? .slider : .layoutItem }
    override func accessibilityLabel() -> String? { onCanvas { [part] in $0.accessibilityLabel(of: part) } }
    override func accessibilityValue() -> Any? {
        let value: String? = onCanvas { [part] in $0.accessibilityValue(of: part) }
        return value
    }
    override func isAccessibilitySelected() -> Bool { onCanvas { [part] in $0.isPartSelected(part) } ?? false }
    override func isAccessibilityEnabled() -> Bool { onCanvas { $0.interactionEnabled } ?? false }

    override func accessibilityFrame() -> NSRect {
        onCanvas { [part] canvas in
            canvas.partFrame(of: part).map { NSAccessibility.screenRect(fromView: canvas, rect: $0) }
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
    func hasAccessibleContent(_ configuration: MediaTimeline) -> Bool {
        configuration.duration > 0 && !configuration.clips.isEmpty
    }

    /// Front to back, as hit-testing sees them.
    func accessibleParts(_ configuration: MediaTimeline) -> [TimelinePart] {
        guard hasAccessibleContent(configuration) else { return [] }
        var parts: [TimelinePart] = [.playhead]
        if configuration.showsOverlayLane {
            parts += currentLayout().overlayBars.reversed().map { .overlay($0.mark.id, part: $0.part) }
        }
        if let music = configuration.music, music.range.upperBound > music.range.lowerBound {
            parts.append(.music)
        }
        parts += configuration.hatched.indices.map(TimelinePart.silence)
        parts += configuration.clips.filter(\.isAccessible).map { .clip($0.id) }
        return parts
    }

    func partFrame(of part: TimelinePart) -> CGRect? {
        guard let configuration, hasAccessibleContent(configuration) else { return nil }
        switch part {
        case .playhead:
            return playheadFrame(configuration)
        case .clip(let id):
            guard let clip = accessibleClip(id, in: configuration) else { return nil }
            return rectangle(clip.range, duration: configuration.duration)
        case .overlay(let id, let index):
            guard configuration.showsOverlayLane else { return nil }
            return currentLayout().overlayBar(id: id, part: index)?.rect
        case .music:
            guard let music = configuration.music, music.range.upperBound > music.range.lowerBound else { return nil }
            return musicBar(music, configuration: configuration)
        case .silence(let index):
            guard configuration.hatched.indices.contains(index) else { return nil }
            return hatchRect(configuration.hatched[index], configuration: configuration)
        }
    }

    func isPartSelected(_ part: TimelinePart) -> Bool {
        guard let configuration, hasAccessibleContent(configuration) else { return false }
        switch part {
        case .clip(let id):
            return accessibleClip(id, in: configuration)?.selection != nil
        case .overlay(let id, let index):
            guard configuration.showsOverlayLane else { return false }
            return currentLayout().overlayBar(id: id, part: index)?.mark.selected ?? false
        case .playhead, .music, .silence:
            return false
        }
    }

    func accessibilityLabel(of part: TimelinePart) -> String? {
        guard let configuration, hasAccessibleContent(configuration) else { return nil }
        switch part {
        case .playhead:
            return String(localized: "Playhead")
        case .clip(let id):
            guard let accessibility = accessibleClip(id, in: configuration)?.accessibility else { return nil }
            return Self.clipLabel(accessibility)
        case .overlay(let id, let index):
            guard configuration.showsOverlayLane,
                let bar = currentLayout().overlayBar(id: id, part: index)
            else { return nil }
            let count = bar.mark.ranges.count
            return count > 1 ? String(localized: "\(bar.mark.label), part \(index + 1) of \(count)") : bar.mark.label
        case .music:
            guard let music = configuration.music, music.range.upperBound > music.range.lowerBound else { return nil }
            return String(localized: "Music, \(music.label)")
        case .silence(let index):
            guard configuration.hatched.indices.contains(index) else { return nil }
            return String(localized: "Pause to remove, \(index + 1) of \(configuration.hatched.count)")
        }
    }

    func accessibilityValue(of part: TimelinePart) -> String? {
        guard let configuration, hasAccessibleContent(configuration) else { return nil }
        switch part {
        case .playhead:
            return String(
                localized: "\(Timecode.spoken(configuration.position)) of \(Timecode.spoken(configuration.duration))")
        case .clip(let id):
            guard let clip = accessibleClip(id, in: configuration), let accessibility = clip.accessibility else {
                return nil
            }
            let selected = clip.selection != nil
            let states = Self.clipStates(accessibility) + (selected ? [String(localized: "Selected")] : [])
            return Self.spokenList([Timecode.spokenRange(clip.range)] + states)
        case .overlay(let id, let index):
            guard configuration.showsOverlayLane,
                let bar = currentLayout().overlayBar(id: id, part: index)
            else { return nil }
            let states = bar.mark.selected ? [String(localized: "Selected")] : []
            return Self.spokenList([Timecode.spokenRange(bar.mark.ranges[index])] + states)
        case .music:
            guard let music = configuration.music, music.range.upperBound > music.range.lowerBound else { return nil }
            let volume = String(localized: "Volume \(music.volume.formatted(.percent.precision(.fractionLength(0))))")
            return Self.spokenList([Timecode.spokenRange(music.range), volume])
        case .silence(let index):
            guard configuration.hatched.indices.contains(index) else { return nil }
            return Timecode.spokenRange(configuration.hatched[index])
        }
    }

    private func accessibleClip(_ id: UUID, in configuration: MediaTimeline) -> TimelineClip? {
        guard let index = currentLayout().clipIndex(for: id, in: configuration.clips) else { return nil }
        let clip = configuration.clips[index]
        return clip.isAccessible ? clip : nil
    }

    private static func clipLabel(_ accessibility: TimelineClipAccessibility) -> String {
        switch accessibility {
        case .text(let name, _):
            return name
        case .segment(let index, let count, let sourceName, _, _, _):
            if let sourceName { return String(localized: "Segment \(index + 1) of \(count), \(sourceName)") }
            return String(localized: "Segment \(index + 1) of \(count)")
        }
    }

    private static func clipStates(_ accessibility: TimelineClipAccessibility) -> [String] {
        switch accessibility {
        case .text(_, let states):
            return states
        case .segment(_, _, _, let freeze, let reversed, let speed):
            var states: [String] = []
            if freeze { states.append(String(localized: "Freeze Frame")) }
            if reversed { states.append(String(localized: "Reversed")) }
            if !freeze, speed != 1 {
                states.append(String(localized: "Speed \(speed.formatted(.number.precision(.fractionLength(0...2))))×"))
            }
            return states
        }
    }

    private static func spokenList(_ phrases: [String]) -> String {
        phrases.formatted(.list(type: .and, width: .narrow))
    }

    func press(_ part: TimelinePart) -> Bool {
        guard interactionEnabled, let configuration, hasAccessibleContent(configuration) else { return false }
        switch part {
        case .clip(let id):
            guard accessibleClip(id, in: configuration) != nil else { return false }
            configuration.select(id)
        case .overlay(let id, let partIndex):
            guard configuration.showsOverlayLane,
                currentLayout().overlayBar(id: id, part: partIndex) != nil,
                let selectOverlay = configuration.selectOverlay
            else { return false }
            selectOverlay(id)
        case .music:
            guard let music = configuration.music, music.range.upperBound > music.range.lowerBound,
                let selectMusic = configuration.selectMusic
            else { return false }
            selectMusic()
        case .playhead, .silence:
            return false
        }
        return true
    }

    func stepPlayhead(_ part: TimelinePart, by frames: Int) -> Bool {
        guard part == .playhead, interactionEnabled, let configuration,
            hasAccessibleContent(configuration), let step = configuration.step
        else { return false }
        step(frames)
        return true
    }

    /// Shared availability rule for menus and VoiceOver.
    func actionState(for id: UUID, action: TimelineAction) -> TimelineActionState {
        guard interactionEnabled, let configuration, configuration.action != nil,
            hasAccessibleContent(configuration),
            currentLayout().clipIndex(for: id, in: configuration.clips) != nil
        else { return TimelineActionState(available: false) }
        return configuration.actionState?(id, action) ?? TimelineActionState()
    }

    @discardableResult
    func performAction(_ action: TimelineAction, on id: UUID) -> Bool {
        guard actionState(for: id, action: action).available, let perform = configuration?.action else { return false }
        perform(id, action)
        return true
    }

    func availableActions(for part: TimelinePart) -> [(TimelineAction, String)] {
        guard case .clip(let id) = part, let configuration, accessibleClip(id, in: configuration) != nil else {
            return []
        }
        return TimelineAction.allCases.compactMap { action in
            let state = actionState(for: id, action: action)
            guard state.available else { return nil }
            let name =
                action == .reverse && state.checked ? String(localized: "Play Segment Forward") : action.title
            return (action, name)
        }
    }

    func perform(_ action: TimelineAction, on part: TimelinePart) -> Bool {
        guard case .clip(let id) = part, let configuration, accessibleClip(id, in: configuration) != nil else {
            return false
        }
        return performAction(action, on: id)
    }
}
