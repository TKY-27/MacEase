import AppKit
import Engine
import MenuCatalog
import Observation
import Synchronization
import os

@MainActor
@Observable
final class JobCenter {
    struct ActiveBatch: Identifiable {
        let id: UUID
        let operation: OperationID
        let itemCount: Int
        var progress: Double
    }

    private static let recentCount = 10

    private(set) var active: [ActiveBatch] = []
    private(set) var recent: [BatchRecord] = []

    @ObservationIgnored let engine: JobEngine
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let notifier: BatchNotifier
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var presentReport: ((String, OperationID) -> Void)?
    @ObservationIgnored var presentPanel: ((MenuEntry, [URL]) -> Void)?
    @ObservationIgnored private let logger = Logger(category: "jobs")

    init(engine: JobEngine, settings: SettingsStore, notifier: BatchNotifier) {
        self.engine = engine
        self.settings = settings
        self.notifier = notifier
    }

    var isBusy: Bool { !active.isEmpty }

    func start(entry: MenuEntry, inputs: [URL]) {
        let preset = entry.isCustom ? nil : entry.preset
        guard let options = OperationPlanner.options(for: entry.op, preset: preset, settings: settings.planning) else {
            if let presentPanel {
                presentPanel(entry, inputs)
            } else {
                logger.error("No panel for \(entry.op.rawValue, privacy: .public)")
            }
            return
        }
        run(OperationRequest(op: entry.op, options: options, inputs: inputs))
    }

    func run(_ request: OperationRequest) {
        let snapshot = settings.planning
        let engine = engine
        let id = UUID()
        let task = Task {
            let batch = await Task.detached { OperationPlanner.batch(for: request, settings: snapshot) }.value
            guard !batch.items.isEmpty else {
                self.forget(id)
                return
            }
            self.active.append(ActiveBatch(id: id, operation: request.op, itemCount: batch.items.count, progress: 0))
            let reporter = ProgressReporter { fraction in self.update(id, progress: fraction) }
            let outcome = await engine.run(batch, settings: snapshot) { reporter.report($0) }
            self.finish(outcome, activeID: id)
        }
        tasks[id] = task
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    func undo(_ id: UUID) {
        Task {
            do {
                let outcomes = try await engine.history.undo(id)
                if !outcomes.isEmpty { notifyUndo(outcomes) }
            } catch {
                logger.error("Undo history write failed: \(error.localizedDescription, privacy: .public)")
            }
            await refreshRecent()
        }
    }

    private func notifyUndo(_ outcomes: [UndoOutcome]) {
        let restored = outcomes.filter { $0 == .restored }.count
        let problem = outcomes.lazy.compactMap { outcome -> String? in
            switch outcome {
            case .restored: nil
            case .skipped(let reason, let path):
                UserMessages.describe(reason, file: URL(fileURLWithPath: path).lastPathComponent)
            case .failed(let error, let path):
                UserMessages.describe(error, file: URL(fileURLWithPath: path).lastPathComponent)
            }
        }.first
        let summary = String(localized: "\(restored) of \(outcomes.count) restored", comment: "Undo notification body")
        notifier.notify(
            title: String(localized: "Undo", comment: "Notification title after undo"),
            body: [summary, problem].compactMap { $0 }.joined(separator: "\n")
        )
    }

    func showOutputs(of id: UUID) {
        guard let record = recent.first(where: { $0.id == id }) else { return }
        let urls = record.outputPaths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func refreshRecent() async {
        recent = Array(await engine.history.records.suffix(Self.recentCount).reversed())
    }

    private func update(_ id: UUID, progress: Double) {
        guard let index = active.firstIndex(where: { $0.id == id }) else { return }
        active[index].progress = max(active[index].progress, progress)
    }

    private func forget(_ id: UUID) {
        tasks[id] = nil
        active.removeAll { $0.id == id }
    }

    private func finish(_ outcome: BatchOutcome, activeID: UUID) {
        forget(activeID)
        if let text = outcome.clipboardText {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        if let report = outcome.reportText { presentReport?(report, outcome.operation) }
        notifier.notify(outcome)
        Task { await refreshRecent() }
    }
}

/// Throttles progress hops to the main actor.
private final class ProgressReporter: Sendable {
    private static let minimumStep = 0.01

    private let lastReported = Mutex(-1.0)
    private let deliver: @MainActor (Double) -> Void

    init(deliver: @escaping @MainActor (Double) -> Void) {
        self.deliver = deliver
    }

    func report(_ fraction: Double) {
        let shouldSend = lastReported.withLock { last in
            guard fraction - last >= Self.minimumStep || fraction >= 1 else { return false }
            last = fraction
            return true
        }
        guard shouldSend else { return }
        Task { @MainActor in deliver(fraction) }
    }
}
