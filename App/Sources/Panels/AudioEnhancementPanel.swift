import Engine
import Observation
import SwiftUI

@MainActor @Observable
final class AudioEnhancementModel {
    let source: URL
    var mode: AudioEnhancementMode
    private(set) var failure: String?
    private(set) var submitted = false
    private var closed = false
    private let run: (Batch) -> Void

    init(source: URL, mode: AudioEnhancementMode = .speech, run: @escaping (Batch) -> Void) {
        self.source = source
        self.mode = mode
        self.run = run
    }

    func enhance() {
        guard !closed, !submitted else { return }
        failure = nil
        do {
            let batch = try AudioEnhancement().makeBatch(source: source, mode: mode)
            submitted = true
            run(batch)
        } catch EngineError.unsupportedCodec(let requirement) {
            failure = requirement
        } catch {
            failure = UserMessages.describe(
                EngineError.wrapping(error, path: source.path), file: source.lastPathComponent)
        }
    }

    func close() { closed = true }
}

struct AudioEnhancementPanel: View {
    @Bindable var model: AudioEnhancementModel
    let close: () -> Void

    var body: some View {
        PanelForm(
            actionTitle: String(localized: "Export New Files"), canRun: !model.submitted,
            cancel: {
                model.close(); close()
            },
            run: {
                model.enhance()
                if model.submitted { close() }
            }
        ) {
            LabeledContent("Source", value: model.source.displayName)
            Picker("Output", selection: $model.mode) {
                Text("Clean Speech").tag(AudioEnhancementMode.speech)
                Text("Vocals and Instrumental").tag(AudioEnhancementMode.stems)
            }
            .disabled(model.submitted)
            if model.mode == .speech {
                Text("Reduces speech noise. Exports mono WAV at 16 kHz; stereo is mixed to mono. Maximum 10 minutes.")
            } else {
                Text("Exports vocals and instrumental as two stereo WAV files at 44.1 kHz. Maximum 5 minutes.")
            }
            Text("Processed on this Mac. Your original is kept. Tags are not copied.")
                .foregroundStyle(.secondary)
            if let failure = model.failure { ProblemLabel(text: failure) }
        }
        .onDisappear { model.close() }
    }
}
