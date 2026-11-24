import Engine
import SwiftUI

/// Playback controls centred under the viewer.
struct EditorTransportBar: View {
    @Bindable var model: MediaEditorModel
    let saveFrame: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            TransportClock(position: model.position, duration: model.outputDuration, seek: model.seek)
                .disabled(model.editingLocked || model.values.segments.isEmpty)
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
                .help("Save Frame at Playhead as an Image (⇧⌘S)")

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
                .help(model.muted ? "Unmute Preview" : "Mute Preview")
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
        } else {
            clock
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Playhead"))
        .accessibilityValue(Text("\(Timecode.string(position)) of \(Timecode.string(duration))"))
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
                duration: max(model.timelineDuration, model.frameDuration), position: model.position,
                clips: clips, playing: model.playing, zoom: $model.timelineZoom, maximumZoom: model.maximumTimelineZoom,
                seek: model.seek, hover: model.skim, select: model.selectSegment,
                beginTrim: model.beginTimelineTrim, trim: model.updateTimelineTrim,
                endTrim: { Task { await model.endTimelineTrim() } }, move: model.moveSegment,
                action: { id, action in
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
                actionAvailable: available,
                viewportChanged: { width in Task { @MainActor in model.timelineViewportWidth = width } },
                overlays: overlayMarks, showsOverlayLane: showsOverlayLane,
                selectOverlay: { id in
                    model.category = .markup
                    model.selectOverlay(id)
                },
                hatched: model.silenceHatching, music: musicBar,
                selectMusic: {
                    model.category = .video
                    model.musicRevealRequest = UUID()
                }
            )
            .frame(
                height: MediaTimeline.height + (showsOverlayLane ? TimelineCanvas.overlayLaneHeight : 0)
                    + (musicBar == nil ? 0 : TimelineCanvas.musicLaneHeight)
            )
            .accessibilityLabel(Text("Timeline"))
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
            .help("Split at Playhead (⌘B)").disabled(!model.canSplit)
            Button {
                model.insertFreezeFrame()
            } label: {
                Label("Freeze Frame", systemImage: "snowflake")
            }
            .help("Insert a Freeze Frame at the Playhead (⌥F)").disabled(!model.canInsertFreezeFrame)
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
            .help("Duplicate Segment").disabled(!model.hasSelection)
            Button(role: .destructive) {
                model.deleteSelection()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete Segment (⌫)").disabled(!model.hasSelection)
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
            .disabled(model.values.segments.isEmpty)
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
            Button("Set In Point at Playhead") { model.setTrimBoundaryAtPlayhead(start: true) }
                .disabled(model.selectedSegment?.isFreeze == true)
            Button("Set Out Point at Playhead") { model.setTrimBoundaryAtPlayhead(start: false) }
                .disabled(model.selectedSegment?.isFreeze == true)
            Button("Insert Freeze Frame at Playhead") { model.insertFreezeFrame() }

                .disabled(!model.canInsertFreezeFrame)
            Toggle("Reverse Segment", isOn: model.reversedBinding).disabled(!model.canToggleReverse)
            Divider()
            Button("Move Segment Left") { model.moveSelection(-1) }.disabled(model.values.selectedIndex == 0)
            Button("Move Segment Right") { model.moveSelection(1) }
                .disabled(model.values.selectedIndex == model.values.segments.count - 1)
        }
    }

    private func available(_ id: UUID, _ action: TimelineAction) -> Bool {
        guard let index = model.values.segments.firstIndex(where: { $0.id == id }) else { return false }
        let segment = model.values.segments[index]
        switch action {
        case .setIn, .setOut: return !segment.isFreeze
        case .split: return model.canSplitSegment(id)
        case .freeze: return model.canInsertFreezeFrame && model.timeline?.segment(at: model.position).id == id
        case .reverse: return model.values.selectedID == id && model.canToggleReverse
        case .left: return index > 0
        case .right: return index < model.values.segments.count - 1
        case .duplicate, .delete: return true
        }
    }

    private var musicBar: TimelineMusicBar? {
        guard let music = model.values.music else { return nil }
        let duration = model.outputDuration
        return TimelineMusicBar(
            range: 0...music.playDuration(forOutputDuration: duration), label: music.url.lastPathComponent,
            fadeOut: music.fade(forOutputDuration: duration).fadeOut)
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
        let numbered = model.values.segments.count > 1
        return model.values.segments.enumerated().map { index, segment in
            let range = model.timelineRange(for: segment)
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
                freeze: segment.isFreeze, badges: badges)
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
