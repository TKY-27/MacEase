import Engine
import SwiftUI

/// Playback controls centred under the viewer.
struct EditorTransportBar: View {
    @Bindable var model: MediaEditorModel

    var body: some View {
        HStack(spacing: 0) {
            TransportClock(position: model.position, duration: model.outputDuration)
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

    var body: some View {
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
            HStack(spacing: 14) {
                Button {
                    model.split()
                } label: {
                    Label("Split", systemImage: "scissors")
                }
                .help("Split at Playhead (⌘B)").disabled(!model.canSplit)
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
                TimelineZoomControls(zoom: $model.timelineZoom, maximumZoom: model.maximumTimelineZoom)
            }
            .labelStyle(.titleAndIcon)
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
                    case .duplicate: model.duplicateSelection()
                    case .left: model.moveSelection(-1)
                    case .right: model.moveSelection(1)
                    case .delete: model.deleteSelection()
                    }
                }, viewportChanged: { width in Task { @MainActor in model.timelineViewportWidth = width } }
            )
            .frame(height: MediaTimeline.height)
            .accessibilityLabel(Text("Timeline"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var segmentActions: some View {
        Group {
            Button("Set In Point at Playhead") { model.setTrimBoundaryAtPlayhead(start: true) }
            Button("Set Out Point at Playhead") { model.setTrimBoundaryAtPlayhead(start: false) }
            Divider()
            Button("Move Segment Left") { model.moveSelection(-1) }.disabled(model.values.selectedIndex == 0)
            Button("Move Segment Right") { model.moveSelection(1) }
                .disabled(model.values.selectedIndex == model.values.segments.count - 1)
        }
    }

    private var clips: [TimelineClip] {
        let numbered = model.values.segments.count > 1
        return model.values.segments.enumerated().map { index, segment in
            let range = model.timelineRange(for: segment)
            let name =
                model.values.sources.indices.contains(segment.sourceIndex)
                ? model.values.sources[segment.sourceIndex].url.lastPathComponent : model.url.lastPathComponent
            let fade = FadeRamp(
                duration: range.upperBound - range.lowerBound, fadeIn: segment.fadeIn, fadeOut: segment.fadeOut)
            return TimelineClip(
                id: segment.id, range: range,
                selection: model.values.selectedID == segment.id ? range : nil,
                label: numbered ? "\(index + 1)  \(name)" : name, frames: frames(for: segment),
                waveform: model.waveform(for: segment, in: range), fadeIn: fade.fadeIn, fadeOut: fade.fadeOut)
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
