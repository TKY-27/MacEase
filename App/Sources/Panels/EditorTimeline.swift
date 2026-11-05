import Engine
import SwiftUI

struct EditorTimeline: View {
    @Bindable var model: MediaEditorModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                HStack(spacing: 12) {
                    Button {
                        model.stepFrame(-1)
                    } label: {
                        Label("Previous Frame", systemImage: "backward.end")
                    }
                    Button {
                        model.play()
                    } label: {
                        Label(model.playing ? "Pause" : "Play", systemImage: model.playing ? "pause.fill" : "play.fill")
                    }
                    Button {
                        model.stepFrame(1)
                    } label: {
                        Label("Next Frame", systemImage: "forward.end")
                    }
                    Button {
                        model.toggleMute()
                    } label: {
                        Label("Mute Preview", systemImage: model.muted ? "speaker.slash" : "speaker.wave.2")
                    }.disabled(!model.hasAudio)
                }
                .labelStyle(.iconOnly).disabled(!model.canPlay)
                Text(model.position, format: .number.precision(.fractionLength(3)))
                    .monospacedDigit().frame(width: 80, alignment: .leading)
                Divider().frame(height: 18)
                Button {
                    model.split()
                } label: {
                    Label("Split", systemImage: "scissors")
                }
                .help("Split at playhead (⌘B)").disabled(!model.canSplit)
                Button {
                    model.deleteSelection()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete selected segment (Delete)").disabled(!model.hasSelection)
                Menu {
                    segmentActions
                } label: {
                    Label("Segment Actions", systemImage: "ellipsis.circle")
                }
                .labelStyle(.iconOnly).disabled(!model.hasSelection)
                Spacer(minLength: 8)
                TimelineZoomControls(zoom: $model.timelineZoom, maximumZoom: model.maximumTimelineZoom)
            }.buttonStyle(.borderless)
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
            ).frame(height: 106)

        }
    }

    private var segmentActions: some View {
        Group {
            Button("Set In Point at Playhead") { model.setTrimBoundaryAtPlayhead(start: true) }
            Button("Set Out Point at Playhead") { model.setTrimBoundaryAtPlayhead(start: false) }
            Divider()
            Button("Split at Playhead") { model.split() }.disabled(!model.canSplit)
            Button("Duplicate Segment") { model.duplicateSelection() }
            Button("Move Segment Left") { model.moveSelection(-1) }.disabled(model.values.selectedIndex == 0)
            Button("Move Segment Right") { model.moveSelection(1) }
                .disabled(model.values.selectedIndex == model.values.segments.count - 1)
            Divider()
            Button("Delete Segment", role: .destructive) { model.deleteSelection() }
        }
    }

    private var clips: [TimelineClip] {
        model.values.segments.enumerated().map { index, segment in
            let range = model.timelineRange(for: segment)
            let name =
                model.values.sources.indices.contains(segment.sourceIndex)
                ? model.values.sources[segment.sourceIndex].url.lastPathComponent : model.url.lastPathComponent
            return TimelineClip(
                id: segment.id, range: range,
                selection: model.values.selectedID == segment.id ? range : nil,
                label: "\(index + 1) · \(name)", frames: frames(for: segment))
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
