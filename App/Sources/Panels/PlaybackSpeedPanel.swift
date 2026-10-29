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
