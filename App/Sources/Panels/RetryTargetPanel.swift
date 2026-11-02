import Engine
import SwiftUI

struct RetryTargetPanel: View {
    let request: OperationRequest
    let settings: Engine.Settings
    let bytes: Int64
    let cancel: () -> Void
    let run: (OperationOptions) -> Void
    @State private var submitted = false

    private var choice: TargetSizeChoice {
        let downscale: Bool?
        if case .image(.compress(let compression)) = request.options {
            downscale = compression.allowsDownscale
        } else {
            downscale = nil
        }
        return TargetSizeChoice(megabytes: Double(bytes) / 1_000_000, allowsDownscale: downscale)
    }

    private func updatedOptions(_ edited: OperationOptions) -> OperationOptions {
        switch (request.options, edited) {
        case (.image(.compress(var original)), .image(.compress(let changed))):
            original.goal = changed.goal
            original.allowsDownscale = changed.allowsDownscale
            return .image(.compress(original))
        case (.video(.compress(var original)), .video(.compress(let changed))):
            original.goal = changed.goal
            return .video(.compress(original))
        default: return edited
        }
    }

    var body: some View {
        TargetSizePanel(
            op: request.op, inputs: request.inputs, settings: settings,
            choice: choice, cancel: cancel
        ) { _, options in
            submitted = true
            run(updatedOptions(options))
        }
        .onDisappear { if !submitted { cancel() } }
    }
}
