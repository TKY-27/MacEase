import Engine
import SwiftUI

/// Playback controls centred under the viewer.
struct EditorTransportBar: View {
    @Bindable var model: MediaEditorModel
    let saveFrame: () -> Void

    var clockDisabled: Bool { model.editingLocked || model.values.segments.isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            TransportClock(position: model.position, duration: model.outputDuration, seek: model.seek)
                .disabled(clockDisabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 18) {
                Button {
                    model.stepFrame(-1)
                } label: {
                    Label("Previous Frame", systemImage: "backward.frame.fill")
                }
                .help("Previous Frame (←)")
                Button {
                    model.play()
                } label: {
                    Label(model.playing ? "Pause" : "Play", systemImage: model.playing ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 28, height: 28)
                }
                .help(model.playing ? "Pause (Space)" : "Play (Space)")
                Button {
                    model.stepFrame(1)
                } label: {
                    Label("Next Frame", systemImage: "forward.frame.fill")
                }
                .help("Next Frame (→)")
            }
            .disabled(!model.canPlay)
            HStack(spacing: 14) {
                Button(action: saveFrame) {
                    Label("Save Frame", systemImage: "camera")
                }
                .help(
                    model.saveFrameUnavailableReason
                        ?? String(localized: "Save Frame at Playhead as an Image (⇧⌘S)")
                )

                .disabled(!model.canSaveFrame)
                if model.playing, model.playbackRate != 1 {
                    Text(Self.rateText(model.playbackRate))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .accessibilityLabel(Text("Playback Rate"))
                        .accessibilityValue(Self.spokenRate(model.playbackRate))
                }
                Toggle(isOn: $model.loops) {
                    Label("Loop Playback", systemImage: "repeat")
                }
                .toggleStyle(.button)
                .help("Loop Playback")
                Button {
                    model.toggleMute()
                } label: {
                    Label("Mute Preview", systemImage: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .help(
                    model.previewMuteUnavailableReason
                        ?? (model.muted ? String(localized: "Unmute Preview") : String(localized: "Mute Preview"))
                )
                .disabled(!model.hasAudio || !model.canPlay)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.body)
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    static func rateText(_ rate: Float) -> String {
        (rate < 0 ? "◀︎ " : "") + abs(Double(rate)).formatted(.number.precision(.fractionLength(0...1))) + "×"
    }

    static func spokenRate(_ rate: Float) -> Text {
        let speed = abs(Double(rate)).formatted(.number.precision(.fractionLength(0...1)))
        return rate < 0 ? Text("Reverse \(speed)×") : Text("\(speed)×")
    }
}

struct TransportClock: View {
    let position: Double
    let duration: Double
    /// Makes the playhead time editable.
    var seek: ((Double) -> Void)?
    @State private var draft: String?
    @FocusState private var editing: Bool

    var body: some View {
        if seek != nil, let draft {
            TextField("Go to Time", text: Binding(get: { draft }, set: { self.draft = $0 }))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospacedDigit())
                .frame(width: Self.fieldWidth)
                .focused($editing)
                .onAppear { editing = true }
                .onSubmit { commit(draft) }
                .onExitCommand { self.draft = nil }
                .onChange(of: editing) { _, focused in if !focused { self.draft = nil } }
                .help("Type a time such as 1:05.25, then press Return")
        } else if seek != nil {
            Button {
                draft = Timecode.string(position, fractionDigits: Self.editingDigits)
            } label: {
                clock
            }
            .buttonStyle(.plain)
            .help("Click to Go to a Time")
            .accessibilityLabel(Text("Playhead"))
            .accessibilityValue(spokenTime)
            .accessibilityHint(Text("Type a time to move the playhead."))
        } else {
            clock
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Playhead"))
                .accessibilityValue(spokenTime)
        }
    }

    func commit(_ text: String) {
        guard let seek else { return }
        guard let seconds = TimecodeField.parse(text) else {
            NSSound.beep()
            return
        }
        seek(min(max(0, seconds), duration))
        draft = nil
    }

    private static let fieldWidth: CGFloat = 96
    private static let editingDigits = 3

    private var clock: some View {
        HStack(spacing: 4) {
            Text(Timecode.string(position)).foregroundStyle(.primary)
            Text(verbatim: "/").foregroundStyle(.tertiary)
            Text(Timecode.string(duration)).foregroundStyle(.secondary)
        }
        .font(.callout.monospacedDigit())
    }

    private var spokenTime: Text {
        Text("\(Timecode.spoken(position)) of \(Timecode.spoken(duration))")
    }
}

struct EditorTimeline: View {
    @Bindable var model: MediaEditorModel

    var body: some View {
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                actionBar.labelStyle(.titleAndIcon)
                actionBar.labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            MediaTimeline(
                duration: model.timelineDuration, position: model.position,
                clips: clips, playing: model.playing, trimming: model.trimming, playbackRate: model.playbackRate,
                revealRequest: model.playheadRevealRequest,
                zoom: $model.timelineZoom, maximumZoom: model.maximumTimelineZoom,
                seek: model.seek, hover: model.skim, select: model.selectSegment,
                beginTrim: model.beginTimelineTrim, trim: model.updateTimelineTrim,
                endTrim: { Task { await model.endTimelineTrim() } }, move: model.moveSegment,
                action: { id, action in
                    guard actionState(id, action).available else { return }
                    model.selectSegment(id)
                    switch action {
                    case .setIn: model.setTrimBoundaryAtPlayhead(start: true)
                    case .setOut: model.setTrimBoundaryAtPlayhead(start: false)
                    case .split: model.split()
                    case .freeze: model.insertFreezeFrame()
                    case .reverse: model.toggleReverse()
                    case .duplicate: model.duplicateSelection()
                    case .left: model.moveSelection(-1)
                    case .right: model.moveSelection(1)
                    case .delete: model.deleteSelection()
                    }
                },
                actionState: actionState,
                viewportChanged: { width in Task { @MainActor in model.timelineViewportWidth = width } },
                overlays: overlayMarks, showsOverlayLane: showsOverlayLane,
                selectOverlay: { id in
                    guard !model.editingLocked, model.markupOverlays.contains(where: { $0.id == id }) else { return }
                    model.category = .markup
                    model.selectOverlay(id)
                },
                hatched: model.silenceHatching, music: musicBar,
                selectMusic: model.selectMusic,
                step: model.stepFrame
            )
            .frame(
                height: MediaTimeline.height + (showsOverlayLane ? TimelineCanvas.overlayLaneHeight : 0)
                    + (musicBar == nil ? 0 : TimelineCanvas.musicLaneHeight)
            )
        }
        .disabled(model.editingLocked)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var actionBar: some View {
        HStack(spacing: 14) {
            Button {
                model.split()
            } label: {
                Label("Split", systemImage: "scissors")
            }
            .help(model.splitUnavailableReason ?? String(localized: "Split at Playhead (⌘B)"))
            .disabled(!model.canSplit)
            Button {
                model.insertFreezeFrame()
            } label: {
                Label("Freeze Frame", systemImage: "snowflake")
            }
            .help(
                model.freezeFrameUnavailableReason(for: nil)
                    ?? String(localized: "Insert a Freeze Frame at the Playhead (⌥F)")
            )
            .disabled(!model.canInsertFreezeFrame)
            Toggle(isOn: model.reversedBinding) {
                Label("Reverse", systemImage: "backward")
            }
            .toggleStyle(.button)
            .help(model.reverseUnavailableReason ?? String(localized: "Play the Selected Segment Backward"))
            .disabled(!model.canToggleReverse)
            Button {
                model.duplicateSelection()
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .help("Duplicate Segment").disabled(!model.hasSelection || model.trimming)
            Button(role: .destructive) {
                model.deleteSelection()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete Segment (⌫)").disabled(!model.hasSelection || model.trimming)
            Menu {
                segmentActions
            } label: {
                Label("Segment Actions", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More Segment Actions")
            .disabled(!model.hasSelection)
            Spacer(minLength: 8)
            Button {
                model.showsSilencePreview = true
            } label: {
                Label("Remove Silence…", systemImage: "waveform.path.badge.minus")
            }
            .help(model.silenceUnavailableReason ?? String(localized: "Cut pauses where the sound is quiet"))
            .disabled(model.values.segments.isEmpty || model.silenceUnavailableReason != nil)
            .popover(isPresented: $model.showsSilencePreview, arrowEdge: .top) {
                EditorSilencePopover(model: model)
            }
            Button {
                model.chooseMusic()
            } label: {
                Label(model.values.music == nil ? "Add Music…" : "Replace Music…", systemImage: "music.note")
            }
            .help("Play a song under the video")
            .disabled(model.musicTask != nil)
            Button {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = false
                panel.allowedContentTypes = [.movie, .video]
                if panel.runModal() == .OK { model.importVideos(panel.urls) }
            } label: {
                Label("Add Videos…", systemImage: "plus")
            }
            .help("Add videos to the end of the timeline")
            .disabled(model.importing)
            TimelineZoomControls(zoom: $model.timelineZoom, maximumZoom: model.maximumTimelineZoom)
        }
    }

    private var segmentActions: some View {
        Group {
            let trimReason = model.values.selectedID.flatMap(model.trimUnavailableReason(for:))
            Button("Set In Point at Playhead") { model.setTrimBoundaryAtPlayhead(start: true) }
                .disabled(trimReason != nil).help(trimReason ?? "")
            Button("Set Out Point at Playhead") { model.setTrimBoundaryAtPlayhead(start: false) }
                .disabled(trimReason != nil).help(trimReason ?? "")
            Button("Insert Freeze Frame at Playhead") { model.insertFreezeFrame() }
                .disabled(!model.canInsertFreezeFrame).help(model.freezeFrameUnavailableReason(for: nil) ?? "")
            Toggle("Reverse Segment", isOn: model.reversedBinding).disabled(!model.canToggleReverse)
                .help(model.reverseUnavailableReason ?? "")
            Divider()
            Button("Move Segment Left") { model.moveSelection(-1) }
                .disabled(model.trimming || model.values.selectedIndex == 0)
            Button("Move Segment Right") { model.moveSelection(1) }
                .disabled(model.trimming || model.values.selectedIndex == model.values.segments.count - 1)
        }
    }

    private func actionState(_ id: UUID, _ action: TimelineAction) -> TimelineActionState {
        guard let index = model.values.segments.firstIndex(where: { $0.id == id }) else {
            return TimelineActionState(available: false)
        }
        let segment = model.values.segments[index]
        switch action {
        case .setIn, .setOut:
            return TimelineActionState(available: !segment.isFreeze, reason: model.trimUnavailableReason(for: id))
        case .split:
            return TimelineActionState(
                available: model.canSplitSegment(id), reason: model.splitUnavailableReason(for: id))
        case .freeze:
            return TimelineActionState(
                available: model.canInsertFreezeFrame && model.timeline?.segment(at: model.position).id == id,
                reason: model.freezeFrameUnavailableReason(for: id))
        case .reverse:
            return TimelineActionState(
                available: model.canReverse(id), checked: segment.isReversed,
                reason: model.reverseUnavailableReason(for: segment))
        case .left: return TimelineActionState(available: !model.trimming && index > 0)
        case .right:
            return TimelineActionState(available: !model.trimming && index < model.values.segments.count - 1)
        case .duplicate, .delete: return TimelineActionState(available: !model.trimming)
        }
    }

    private var musicBar: TimelineMusicBar? {
        guard let music = model.values.music, model.outputDuration > 0 else { return nil }
        let duration = model.outputDuration
        return TimelineMusicBar(
            range: 0...music.playDuration(forOutputDuration: duration), label: music.url.lastPathComponent,
            fadeOut: music.fade(forOutputDuration: duration).fadeOut, volume: music.volume)
    }

    private var showsOverlayLane: Bool { model.category == .markup || !model.values.overlays.isEmpty }

    private var overlayMarks: [TimelineOverlayMark] {
        guard let timeline = model.timeline else { return [] }
        return model.values.overlays.map { timed in
            let color = timed.overlay.mark.color
            return TimelineOverlayMark(
                id: timed.id, ranges: timeline.outputRanges(of: timed), label: model.overlayName(timed.overlay),
                fill: color.flatMap { NSColor(cgColor: $0.cgColor) } ?? .systemIndigo,
                text: color.flatMap { NSColor(cgColor: $0.strokeColor) } ?? .white,
                selected: model.values.selectedOverlayID == timed.id)
        }
    }

    private var clips: [TimelineClip] {
        let count = model.values.segments.count
        let numbered = count > 1
        let joined = model.originalSources.count > 1
        return zip(model.values.segments, model.timelineRanges()).enumerated().map { index, pair in
            let (segment, range) = pair
            let name = model.sourceName(segment)
            let fade = FadeRamp(
                duration: range.upperBound - range.lowerBound, fadeIn: segment.fadeIn, fadeOut: segment.fadeOut)
            var badges: [TimelineBadge] = []
            if segment.isFreeze {
                badges.append(TimelineBadge(symbol: "snowflake", title: String(localized: "Freeze")))
            } else if segment.isReversed {
                badges.append(TimelineBadge(symbol: "backward.fill", title: String(localized: "Reversed")))
            }
            return TimelineClip(
                id: segment.id, range: range,
                selection: model.values.selectedID == segment.id ? range : nil,
                label: numbered ? "\(index + 1)  \(name)" : name, frames: frames(for: segment),
                waveform: model.waveform(for: segment, in: range), fadeIn: fade.fadeIn, fadeOut: fade.fadeOut,
                freeze: segment.isFreeze, badges: badges,
                accessibility: .segment(
                    index: index, count: count, sourceName: joined ? name : nil, freeze: segment.isFreeze,
                    reversed: segment.isReversed, speed: segment.speed))
        }
    }

    private func frames(for segment: VideoSegment) -> [CGImage] {
        let frames = model.thumbnails(for: segment)
        guard !frames.isEmpty, model.values.sources.indices.contains(segment.sourceIndex) else { return [] }
        let duration = model.values.sources[segment.sourceIndex].duration
        let count = frames.count
        let first = min(count - 1, Int(segment.start / duration * Double(count)))
        let last = max(first, min(count - 1, Int(segment.end / duration * Double(count))))
        return Array(frames[first...last])
    }
}
