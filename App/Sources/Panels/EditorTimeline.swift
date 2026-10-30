import Engine
import SwiftUI

struct EditorTimeline: View {
    @Bindable var model: MediaEditorModel
    @State private var trimStart: VideoSegment?

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
                Image(systemName: "minus.magnifyingglass").accessibilityHidden(true)
                Slider(value: $model.timelineZoom, in: 1...12) { Text("Timeline Zoom") }
                    .labelsHidden().frame(width: 100)
                Image(systemName: "plus.magnifyingglass").accessibilityHidden(true)
            }.buttonStyle(.borderless)
            GeometryReader { proxy in
                ScrollView(.horizontal) {
                    let width = max(1, proxy.size.width - 24) * model.timelineZoom
                    let duration = max(model.outputDuration, model.frameDuration)
                    VStack(spacing: 2) {
                        ruler(width: width, duration: duration)
                        ZStack(alignment: .topLeading) {
                            HStack(spacing: 0) {
                                ForEach(Array(model.values.segments.enumerated()), id: \.element.id) { index, segment in
                                    segmentView(segment, index: index, width: width, duration: duration)
                                }
                            }
                            Rectangle().fill(.primary).frame(width: 2, height: 58)
                                .offset(x: width * model.position / duration - 1)
                                .allowsHitTesting(false)
                        }.frame(width: width, height: 58, alignment: .leading)
                    }.padding(.horizontal, 12)
                }
            }.frame(height: 86)
        }
    }

    private var segmentActions: some View {
        Group {
            Button("Split at Playhead") { model.split() }.disabled(!model.canSplit)
            Button("Duplicate Segment") { model.duplicateSelection() }
            Button("Move Segment Left") { model.moveSelection(-1) }.disabled(model.values.selectedIndex == 0)
            Button("Move Segment Right") { model.moveSelection(1) }
                .disabled(model.values.selectedIndex == model.values.segments.count - 1)
            Divider()
            Button("Delete Segment", role: .destructive) { model.deleteSelection() }
        }
    }

    private func ruler(width: Double, duration: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
            ForEach(0..<6) { index in
                Text(duration * Double(index) / 5, format: .number.precision(.fractionLength(1)))
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    .offset(x: max(0, min(width - 35, width * Double(index) / 5)))
            }
        }
        .frame(width: width, height: 18)
        .gesture(DragGesture(minimumDistance: 0).onChanged { model.seek($0.location.x / width * duration) })
        .accessibilityLabel("Playhead")
        .accessibilityValue(Text(model.position, format: .number.precision(.fractionLength(3))))
        .accessibilityAdjustableAction { direction in model.stepFrame(direction == .increment ? 1 : -1) }
    }

    private func segmentView(_ segment: VideoSegment, index: Int, width: Double, duration: Double) -> some View {
        let segmentDuration = (segment.end - segment.start) / segment.speed
        let segmentWidth = width * segmentDuration / duration
        let selected = model.values.selectedID == segment.id
        return FrameStrip(frames: frames(for: segment), duration: segmentDuration)
            .frame(width: segmentWidth, height: 52)
            .background(.quaternary)
            .overlay(alignment: .bottomLeading) {
                Text("\(index + 1)").font(.caption2).monospacedDigit()
                    .padding(.horizontal, 5).padding(.vertical, 2).background(.regularMaterial)
                    .padding(4)
            }
            .overlay {
                Rectangle().strokeBorder(
                    selected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: selected ? 3 : 1)
            }
            .overlay(alignment: .leading) {
                if selected { trimHandle(segment, start: true, width: width, duration: duration) }
            }
            .overlay(alignment: .trailing) {
                if selected { trimHandle(segment, start: false, width: width, duration: duration) }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selectSegment(segment.id) }
            .draggable(segment.id.uuidString)
            .dropDestination(for: String.self) { identifiers, _ in
                guard let identifier = identifiers.first, let id = UUID(uuidString: identifier),
                    model.values.segments.contains(where: { $0.id == id })
                else { return false }
                model.moveSegment(id, to: index)
                return true
            }
            .contextMenu {
                Button("Select Segment") { model.selectSegment(segment.id) }
                Button("Split at Playhead") {
                    model.selectSegment(segment.id); model.split()
                }.disabled(!model.canSplitSegment(segment.id))
                Button("Duplicate Segment") {
                    model.selectSegment(segment.id); model.duplicateSelection()
                }
                Button("Move Segment Left") {
                    model.selectSegment(segment.id); model.moveSelection(-1)
                }.disabled(index == 0)
                Button("Move Segment Right") {
                    model.selectSegment(segment.id); model.moveSelection(1)
                }
                .disabled(index == model.values.segments.count - 1)
                Divider()
                Button("Delete Segment", role: .destructive) {
                    model.selectSegment(segment.id); model.deleteSelection()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Segment \(index + 1)"))
            .accessibilityValue(Text("\(segmentDuration, format: .number.precision(.fractionLength(2))) seconds"))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction { model.selectSegment(segment.id) }
    }

    private func frames(for segment: VideoSegment) -> [CGImage] {
        guard !model.thumbnails.isEmpty, model.duration > 0 else { return [] }
        let count = model.thumbnails.count
        let first = min(count - 1, Int(segment.start / model.duration * Double(count)))
        let last = max(first, min(count - 1, Int(segment.end / model.duration * Double(count))))
        return Array(model.thumbnails[first...last])
    }

    private func trimHandle(_ segment: VideoSegment, start: Bool, width: Double, duration: Double) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
            .frame(width: 8, height: 52)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { gesture in
                    if trimStart == nil { trimStart = segment; model.beginInteraction() }
                    guard let original = trimStart else { return }
                    let delta = gesture.translation.width / width * duration * original.speed
                    model.change {
                        guard let index = $0.segments.firstIndex(where: { $0.id == segment.id }) else { return }
                        if start {
                            $0.segments[index].start = min(
                                max(0, original.start + delta), original.end - model.frameDuration)
                        } else {
                            $0.segments[index].end = max(
                                min(model.duration, original.end + delta), original.start + model.frameDuration)
                        }
                    }
                }.onEnded { _ in
                    trimStart = nil; model.endInteraction()
                }
            )
            .help(start ? "Drag to trim the segment start" : "Drag to trim the segment end")
    }
}
