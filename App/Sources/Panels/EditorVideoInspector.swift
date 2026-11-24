import Engine
import SwiftUI

extension MediaEditorView {
    private var freezeControls: some View {
        Group {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Frame").foregroundStyle(.secondary)
                    Text(Timecode.string(model.values.start, fractionDigits: Self.timecodeDigits))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                GridRow {
                    Text("Freeze Duration").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        EditorNumberField(
                            model: model, title: String(localized: "Freeze Duration"), id: "freeze",
                            value: model.binding(\.freezeDuration), range: VideoSegment.freezeDurationRange,
                            precision: 1)
                        Text("sec").foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                }
            }
            Label(
                "A freeze frame holds one picture without sound, so trimming, splitting, speed and volume don’t apply.",
                systemImage: "snowflake"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    var videoControls: some View {
        let freeze = model.selectedSegment?.isFreeze == true
        return Group {
            if freeze {
                InspectorSection(String(localized: "Freeze Frame")) { freezeControls }
            } else {
                InspectorSection(String(localized: "Selected Segment")) { segmentRange }
            }
            InspectorSection(String(localized: "Speed")) {
                Picker(
                    "Playback speed",
                    selection: Binding(
                        get: { Self.speedPresets.contains(model.values.speed) ? model.values.speed : nil },
                        set: { speed in if let speed { model.change { $0.speed = speed } } })
                ) {
                    ForEach(Self.speedPresets, id: \.self) { speed in
                        Text(speed.formatted(.number.precision(.fractionLength(0...2))) + "×").tag(Optional(speed))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: 6) {
                    Text("Custom").foregroundStyle(.secondary)
                    Spacer()
                    EditorNumberField(
                        model: model, title: String(localized: "Custom speed"), id: "speed",
                        value: model.binding(\.speed), range: VideoEdit.speedRange, precision: 2
                    ).frame(width: 58)
                    Text(verbatim: "×").foregroundStyle(.secondary).accessibilityHidden(true)
                }
                Text("Pitch is preserved.").font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!model.hasSelection || freeze)
            InspectorSection(String(localized: "Direction")) {
                Toggle(
                    "Play Backward",
                    isOn: Binding(
                        get: { model.selectedSegment?.isReversed == true }, set: { _ in model.toggleReverse() })
                )
                .disabled(!model.canToggleReverse)
                Text(
                    model.reverseUnavailableReason
                        ?? String(
                            localized:
                                "Reversing prepares a backward copy, which takes about as long as the segment plays. Saving then makes a new H.264 MP4 file."
                        )
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!model.hasSelection)
            InspectorSection(String(localized: "Volume")) {
                HStack(spacing: 10) {
                    Button {
                        model.change { $0.volume = $0.volume == 0 ? 1 : 0 }
                    } label: {
                        Label(
                            model.values.volume == 0 ? "Unmute" : "Mute",
                            systemImage: model.values.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .frame(width: 22)
                    Slider(value: model.binding(\.volume), in: 0...1) {
                        Text("Volume")
                    } onEditingChanged: { active in
                        active ? model.beginInteraction() : model.endInteraction()
                    }
                    .labelsHidden()
                    Text("\(Int((model.values.volume * 100).rounded()))%")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
            .disabled(!model.selectedHasAudio || freeze)
            InspectorSection(String(localized: "Fade")) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Fade In").foregroundStyle(.secondary)
                        FadePicker(title: Text("Fade In"), value: model.binding(\.fadeIn))
                    }
                    GridRow {
                        Text("Fade Out").foregroundStyle(.secondary)
                        FadePicker(title: Text("Fade Out"), value: model.binding(\.fadeOut))
                    }
                }
                Text("Fades the picture to and from black and the sound to and from silence.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!model.hasSelection)
            EditorMusicSection(model: model).id(Self.musicSectionID)
            if model.originalSources.count > 1 {
                InspectorSection(String(localized: "Source Videos")) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.originalSources.enumerated()), id: \.offset) { index, source in
                            Text("\(index + 1). \(source.url.lastPathComponent)").font(.callout).lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Text(
                        "Joined videos use the first video's canvas and frame rate. Other sizes fit with black borders. HDR becomes SDR; transparency is flattened. Originals are kept. Metadata may be removed."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var segmentRange: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Start").foregroundStyle(.secondary)
                EditorNumberField(
                    model: model, title: String(localized: "Start"), id: "start",
                    value: model.videoBoundaryBinding(start: true),
                    range: 0...max(0, model.values.end - model.sourceFrameDuration),
                    precision: Self.timecodeDigits, timecode: true
                )
            }
            GridRow {
                Text("End").foregroundStyle(.secondary)
                EditorNumberField(
                    model: model, title: String(localized: "End"), id: "end",
                    value: model.videoBoundaryBinding(start: false),
                    range: min(
                        model.sourceDuration, model.values.start + model.sourceFrameDuration)...model
                        .sourceDuration,
                    precision: Self.timecodeDigits, timecode: true
                )
            }
            GridRow {
                Text("Length").foregroundStyle(.secondary)
                Text(
                    Timecode.string(
                        model.selectedSegment?.outputDuration ?? 0, fractionDigits: Self.timecodeDigits)
                )
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .disabled(!model.hasSelection)
    }

    static let musicSectionID = "music"
    private static let speedPresets: [Double] = [0.5, 1, 1.5, 2, 4]
    private static let timecodeDigits = 3
}
