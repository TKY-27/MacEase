import AVFoundation
import Engine
import SwiftUI

struct PlaybackSpeedField: View {
    @Binding var text: String

    var body: some View {
        LabeledContent("Playback speed") {
            HStack {
                TextField("Playback speed", text: $text)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Text("×").accessibilityHidden(true)
                Menu("Presets") {
                    ForEach(["0.5", "0.75", "1", "1.25", "1.5", "2", "4"], id: \.self) { value in
                        Button("\(value)×") { text = value }
                    }
                }
                .fixedSize()
            }
        }
    }

    static func speed(_ text: String) -> Double? {
        guard let speed = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            speed.isFinite, VideoEdit.speedRange.contains(speed)
        else { return nil }
        return speed
    }
}

struct SpeedPanel: View {
    let store: SettingsStore
    let cancel: () -> Void
    let run: (Double) -> Void
    @State private var speedText = "2"

    var body: some View {
        PanelForm(
            actionTitle: String(localized: "Change Speed"),
            canRun: PlaybackSpeedField.speed(speedText).map { $0 != 1 } ?? false, cancel: cancel
        ) {
            if let speed = PlaybackSpeedField.speed(speedText), speed != 1 { run(speed) }
        } content: {
            PlaybackSpeedField(text: $speedText)
            Text("Enter a speed from 0.5 to 4. The audio pitch stays the same.")
                .foregroundStyle(.secondary)
            if PlaybackSpeedField.speed(speedText) == nil {
                ProblemLabel(text: String(localized: "Enter a number from 0.5 to 4."))
            }
            OutputModeSummary(mode: store.settings.outputMode)
        }
    }
}

struct VideoEditPanel: View {
    let url: URL
    let store: SettingsStore
    let trimMode: TrimMode
    let cancel: () -> Void
    let run: (VideoEdit) -> Void
    @State private var preview: MediaPreview?
    @State private var failure: String?

    var body: some View {
        Group {
            if let preview {
                MediaLoader(url: url, isVideo: true, close: cancel) { media in
                    VideoEditForm(
                        preview: preview, media: media, store: store, mode: trimMode,
                        cancel: cancel, run: run)
                }
            } else if let failure {
                PanelFailure(message: failure, close: cancel)
            } else {
                ProgressView().padding().frame(width: PanelLayout.width)
            }
        }
        .task {
            do {
                preview = try await MediaPreview(videoAt: url)
            } catch {
                failure = UserMessages.describe(
                    EngineError.wrapping(error, path: url.path), file: url.lastPathComponent)
            }
        }
    }
}

private struct VideoEditForm: View {
    let preview: MediaPreview
    let media: LoadedMedia
    let store: SettingsStore
    @State var mode: TrimMode
    let cancel: () -> Void
    let run: (VideoEdit) -> Void
    @State private var startText = "0"
    @State private var endText = ""
    @State private var speedText = "1"
    @State private var lines = 0
    @FocusState private var startFocused: Bool
    @State private var playbackTask: Task<Void, Never>?

    private var edit: VideoEdit? {
        guard let start = Double(startText), let end = Double(endText), start.isFinite, end.isFinite,
            start >= 0, start < end, end <= preview.durationSeconds,
            let speed = PlaybackSpeedField.speed(speedText)
        else { return nil }
        return VideoEdit(
            start: start, end: end == preview.durationSeconds ? nil : end, speed: speed,
            resize: lines == 0 ? nil : .lines(lines), trimMode: mode)
    }

    private var changesSize: Bool {
        lines > 0 && lines < min(preview.displayWidth, preview.displayHeight)
    }

    private var changed: Bool {
        guard let edit else { return false }
        return edit.start > 0 || (edit.end ?? preview.durationSeconds) != preview.durationSeconds || edit.speed != 1
            || changesSize
    }

    var body: some View {
        PanelForm(
            actionTitle: String(localized: "Save Video"), canRun: changed,
            width: PanelLayout.wideWidth, cancel: cancel
        ) {
            if let edit, changed { run(edit) }
        } content: {
            Section {
                if case .player(let player, _) = media {
                    PlainPlayer(player: player).frame(height: MediaLayout.previewHeight)
                    Button("Preview Selection") { playSelection(player) }.disabled(edit == nil)
                } else if case .frames(_, let frames) = media {
                    FrameStrip(frames: frames, duration: preview.durationSeconds)
                }
                HStack {
                    TextField("Start (seconds)", text: $startText).focused($startFocused)
                    TextField("End (seconds)", text: $endText)
                }
                if edit?.speed == 1, !changesSize {
                    Picker("Cut", selection: $mode) {
                        ForEach(TrimMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
            Section {
                PlaybackSpeedField(text: $speedText)
                Picker("Resolution", selection: $lines) {
                    Text("Original resolution").tag(0)
                    ForEach([2160, 1080, 720, 480, 360], id: \.self) { value in
                        Text(verbatim: "\(value)p").tag(value)
                    }
                }
                if lines > 0, !changesSize {
                    Text("The source is already smaller. Its resolution will stay unchanged.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if let edit {
                    LabeledContent(durationLabel) {
                        Text(
                            ((edit.end ?? preview.durationSeconds) - edit.start) / edit.speed,
                            format: .number.precision(.fractionLength(3)))
                        Text("seconds")
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(durationLabel))
                    .accessibilityValue(
                        Text(
                            "\(((edit.end ?? preview.durationSeconds) - edit.start) / edit.speed, format: .number.precision(.fractionLength(3))) seconds"
                        ))
                    if usesKeyframeCut {
                        Text(
                            "Keyframe cuts may start earlier than the selected range. Choose Exact for an exact duration."
                        )
                        .foregroundStyle(.secondary)
                    }
                    LabeledContent("Output dimensions", value: dimensions)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Output dimensions"))
                        .accessibilityValue(dimensions)
                } else {
                    ProblemLabel(text: String(localized: "Enter a valid time range and a speed from 0.5 to 4."))
                }
                OutputModeSummary(mode: store.settings.outputMode)
            }
        }
        .onAppear {
            endText = String(preview.durationSeconds)
            startFocused = true
        }
        .onDisappear {
            playbackTask?.cancel()
            if case .player(let player, _) = media { player.pause() }
        }
    }

    private var usesKeyframeCut: Bool {
        mode == .keyframe && edit?.speed == 1 && !changesSize && (edit?.start ?? 0) > 0
    }

    private var durationLabel: String {
        usesKeyframeCut ? String(localized: "Selected duration") : String(localized: "Output duration")
    }

    private var dimensions: String {
        do {
            let size = try (edit?.resize ?? .percent(100)).dimensions(
                width: preview.displayWidth, height: preview.displayHeight)
            return "\(size.width) × \(size.height)"
        } catch {
            return String(localized: "Unavailable")
        }
    }

    private func playSelection(_ player: AVPlayer) {
        guard let edit else { return }
        player.pause()
        player.currentItem?.audioTimePitchAlgorithm = .spectral
        player.currentItem?.forwardPlaybackEndTime = CMTime(
            seconds: edit.end ?? preview.durationSeconds, preferredTimescale: 600)
        playbackTask?.cancel()
        playbackTask = Task {
            await player.seek(
                to: CMTime(seconds: edit.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled else { return }
            player.playImmediately(atRate: Float(edit.speed))
        }
    }
}

private struct OutputModeSummary: View {
    let mode: Engine.Settings.OutputMode

    var body: some View {
        LabeledContent("Saving") {
            Text(
                mode == .newFile
                    ? String(localized: "Save as new file") : String(localized: "Replace original (Trash and Undo)"))
        }
    }
}
