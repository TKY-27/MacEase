import Engine
import MenuCatalog
import SwiftUI
import os

/// Nothing runs until the user presses Run.
struct CustomAIPanel: View {
    let kind: FileKind
    @State var prompt: String
    /// `false` for steps the host cannot run.
    let isRunnable: (CustomStep) -> Bool
    let cancel: () -> Void
    let run: (_ prompt: String, [CustomStep]) -> Void

    @State private var steps: [CustomStep]?
    @State private var planRequest = 0
    @State private var isPlanning = false
    @State private var failure: String?

    private static let promptLines = 3...6

    var body: some View {
        PanelForm(
            actionTitle: steps == nil
                ? String(localized: "Plan", comment: "Custom AI panel action")
                : String(localized: "Run", comment: "Custom AI panel action"),
            canRun: canRun, width: PanelLayout.wideWidth, cancel: cancel
        ) {
            if let steps {
                run(prompt, steps)
            } else {
                planRequest += 1
            }
        } accessory: {
            if isPlanning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Planning"))
            }
        } content: {
            Section("Describe what to do") {
                TextField(
                    "Request", text: $prompt, prompt: Text("For example: WebP under 1 MB, long edge 1600"),
                    axis: .vertical
                )
                .labelsHidden()
                .lineLimit(Self.promptLines)
                .disabled(isPlanning)
                .onChange(of: prompt) { steps = nil }
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
            if let steps {
                Section("Plan") {
                    ForEach(steps.indices, id: \.self) { index in
                        LabeledContent {
                            if !isRunnable(steps[index]) {
                                Text("Not available in a plan")
                                    .foregroundStyle(.red)
                            }
                        } label: {
                            Text(
                                "\(index + 1). \(MenuStrings.operation(steps[index].operation)): \(MenuStrings.preset(steps[index].operation, steps[index].preset))"
                            )
                        }
                    }
                }
            }
        }
        .task(id: planRequest) {
            guard planRequest > 0 else { return }
            isPlanning = true
            defer { isPlanning = false }
            do {
                steps = try await AICustomPlanner.plan(prompt, kind: kind)
                failure = nil
            } catch is CancellationError {
                return
            } catch {
                Logger(category: "panels").error("Custom plan failed: \(error, privacy: .public)")
                failure = Self.describe(error)
            }
        }
    }

    private var canRun: Bool {
        guard !isPlanning, !prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return steps?.allSatisfy(isRunnable) ?? true
    }

    private static func describe(_ error: any Error) -> String {
        switch EngineError.wrapping(error, path: "") {
        case .invalidInput(.malformed(let reason)):
            String(localized: "The plan was rejected: \(reason)", comment: "Custom AI plan error")
        case .missingCapability(let capability):
            UserMessages.describe(.missingCapability(capability), file: "")
        default:
            String(localized: "No plan could be made. Try rephrasing the request.", comment: "Custom AI plan error")
        }
    }
}
