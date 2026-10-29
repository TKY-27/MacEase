import Engine
import SwiftUI

struct EditorTimeline: View {
    @Bindable var model: MediaEditorModel
    @State private var dragRange: ClosedRange<Double>?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    model.stepFrame(-1)
                } label: {
                    Label("Previous Frame", systemImage: "backward.end")
                }
                .keyboardShortcut(.leftArrow, modifiers: []).disabled(model.player == nil)
                Button {
                    model.play()
                } label: {
                    Label(
                        model.playing ? "Pause" : "Play Selection",
                        systemImage: model.playing ? "pause.fill" : "play.fill")
                }
                .keyboardShortcut(.space, modifiers: []).disabled(model.player == nil || model.preparingPlayback)
                Button {
                    model.stepFrame(1)
                } label: {
                    Label("Next Frame", systemImage: "forward.end")
                }
                .keyboardShortcut(.rightArrow, modifiers: []).disabled(model.player == nil)
                Text(model.position, format: .number.precision(.fractionLength(3)))
                    .monospacedDigit().frame(width: 95, alignment: .leading)
                Spacer()
                Image(systemName: "minus.magnifyingglass").accessibilityHidden(true)
                Slider(value: $model.timelineZoom, in: 1...12) { Text("Timeline Zoom") }.labelsHidden().frame(
                    width: 120)
                Image(systemName: "plus.magnifyingglass").accessibilityHidden(true)
            }.labelStyle(.iconOnly).buttonStyle(.borderless)
            GeometryReader { proxy in
                ScrollView(.horizontal) {
                    let width = max(1, proxy.size.width - 24) * model.timelineZoom
                    let duration = max(model.duration, model.frameDuration)
                    let startX = width * model.values.start / duration
                    let endX = width * model.values.end / duration
                    ZStack(alignment: .topLeading) {
                        FrameStrip(frames: model.thumbnails, duration: duration).frame(width: width, height: 52)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0).onChanged {
                                    model.seek($0.location.x / width * duration)
                                })
                        Rectangle().fill(.black.opacity(0.45)).frame(width: max(0, startX), height: 52)
                            .allowsHitTesting(false)
                        Rectangle().fill(.black.opacity(0.45)).frame(width: max(0, width - endX), height: 52)
                            .offset(x: endX).allowsHitTesting(false)
                        Rectangle().strokeBorder(.yellow, lineWidth: 3).frame(width: max(1, endX - startX), height: 52)
                            .offset(x: startX).allowsHitTesting(false)
                        Rectangle().fill(.yellow.opacity(0.001)).frame(width: max(1, endX - startX), height: 14)
                            .contentShape(Rectangle()).offset(x: startX)
                            .gesture(rangeGesture(part: 0, width: width, duration: duration))
                            .help("Drag to move the selected range")
                        handle(start: true).offset(x: startX - 10)
                            .gesture(rangeGesture(part: -1, width: width, duration: duration))
                        handle(start: false).offset(x: endX - 10)
                            .gesture(rangeGesture(part: 1, width: width, duration: duration))
                        RoundedRectangle(cornerRadius: 1).fill(.white).frame(width: 3, height: 58)
                            .shadow(color: .black, radius: 1).offset(x: width * model.position / duration - 1.5, y: -3)
                            .allowsHitTesting(false)
                    }.frame(width: width, height: 58).padding(.horizontal, 12).padding(.top, 4)
                }
            }.frame(height: 72)
        }
    }

    private func handle(start: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(.yellow)
            .overlay {
                Image(systemName: start ? "chevron.left" : "chevron.right").font(.caption.bold()).foregroundStyle(
                    .black)
            }
            .frame(width: 20, height: 52)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(start ? "Selection Start" : "Selection End")
            .accessibilityValue(
                Text(start ? model.values.start : model.values.end, format: .number.precision(.fractionLength(3)))
            )
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? model.frameDuration : -model.frameDuration
                model.change {
                    if start {
                        $0.start = min(max(0, $0.start + delta), $0.end - model.frameDuration)
                    } else {
                        $0.end = max(min(model.duration, $0.end + delta), $0.start + model.frameDuration)
                    }
                }
            }
    }

    private func rangeGesture(part: Int, width: Double, duration: Double) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { gesture in
            if dragRange == nil {
                dragRange = model.values.start...max(model.values.start, model.values.end)
                model.beginInteraction()
            }
            guard let range = dragRange else { return }
            let delta = gesture.translation.width / width * duration
            let minimum = min(model.frameDuration, duration)
            model.change {
                if part < 0 {
                    $0.start = min(max(0, range.lowerBound + delta), $0.end - minimum)
                } else if part > 0 {
                    $0.end = max(min(duration, range.upperBound + delta), $0.start + minimum)
                } else {
                    let length = range.upperBound - range.lowerBound
                    $0.start = min(max(0, range.lowerBound + delta), duration - length)
                    $0.end = $0.start + length
                }
            }
            model.position = part > 0 ? max(0, model.values.end - minimum) : model.values.start
            model.refresh()
        }.onEnded { _ in
            dragRange = nil; model.endInteraction()
        }
    }
}
