import Engine
import Observation
import SwiftUI

@MainActor @Observable
final class AudioEnhancementModel {
    let source: URL
    var mode: AudioEnhancementMode
    private(set) var failure: String?
    private(set) var submitted = false
    private(set) var checking = false
    var streamConsent: StreamConsentRequest?
    private var closed = false
    private let run: (Batch) -> Void

    init(source: URL, mode: AudioEnhancementMode = .speech, run: @escaping (Batch) -> Void) {
        self.source = source
        self.mode = mode
        self.run = run
    }

    func enhance() {
        guard !closed, !submitted, !checking else { return }
        failure = nil
        checking = true
        let source = source
        Task {
            defer { checking = false }
            do {
                let omission = try await Task.detached { try AudioEnhancement.streamOmission(for: source) }.value
                guard let omission else { return submit(omission: nil) }
                streamConsent = StreamConsentRequest(purpose: .proceed, files: [.init(url: source, omission: omission)])
            } catch {
                report(error)
            }
        }
    }

    func continueWithoutStreams(_ request: StreamConsentRequest) {
        streamConsent = nil
        submit(omission: request.files.first { $0.url == source }?.omission)
    }

    private func submit(omission: StreamOmission?) {
        guard !closed, !submitted else { return }
        do {
            let batch = try AudioEnhancement().makeBatch(source: source, mode: mode, omission: omission)
            submitted = true
            run(batch)
        } catch EngineError.unsupportedCodec(let requirement) {
            failure = requirement
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        failure = UserMessages.describe(EngineError.wrapping(error, path: source.path), file: source.lastPathComponent)
    }

    func close() { closed = true }
}

struct AudioEnhancementPanel: View {
    @Bindable var model: AudioEnhancementModel
    let close: () -> Void

    var body: some View {
        PanelForm(
            actionTitle: String(localized: "Export New Files"), canRun: !model.submitted && !model.checking,
            cancel: {
                model.close(); close()
            },
            run: model.enhance
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
        .onChange(of: model.submitted) { _, submitted in if submitted { close() } }
        .streamConsentAlert($model.streamConsent, accept: model.continueWithoutStreams) { _ in }
        .onDisappear { model.close() }
    }
}
