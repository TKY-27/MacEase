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
        let batchID: UUID
        let operation: OperationID
        let fileNames: [String]
        var progress = 0.0
        var completedItems = 0
        var currentItem: Int?

        var itemCount: Int { fileNames.count }
        var currentFileName: String? { currentItem.map { fileNames[$0] } }
    }

    struct CompletedBatch {
        let date: Date
        let operation: OperationID
        let summary: BatchSummary
    }

    private static let recentCount = 10

    private(set) var active: [ActiveBatch] = []
    private(set) var recent: [BatchRecord] = []
    private(set) var completed: [CompletedBatch] = []
    private var terminating = false
    private var undoTasks: [UUID: Task<Void, Never>] = [:]

    @ObservationIgnored let engine: JobEngine
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let notifier: BatchNotifier
    @ObservationIgnored private var tasks: [UUID: Task<BatchOutcome?, Never>] = [:]
    @ObservationIgnored var presentReport: ((String, OperationID) -> Void)?
    @ObservationIgnored var presentPanel: ((MenuEntry, [URL]) -> Void)?
    /// `false` when no panel can answer it.
    @ObservationIgnored var askAgain: ((OperationRequest, [URL], InvalidInput) -> Bool)?
    @ObservationIgnored var onStart: ((ActiveBatch) -> Void)?
    /// `true` when Activity keeps the result visible.
    @ObservationIgnored var showsFinished: ((ActiveBatch, BatchOutcome) -> Bool)?
    @ObservationIgnored private let logger = Logger(category: "jobs")

    init(engine: JobEngine, settings: SettingsStore, notifier: BatchNotifier) {
        self.engine = engine
        self.settings = settings
        self.notifier = notifier
    }

    var isBusy: Bool { !active.isEmpty }

    func start(entry: MenuEntry, inputs: [URL]) {
        guard !terminating else { return }
        let inputs = inputs.filter { input in
            let kind = FileKind(fileURL: input)
            return entry.kind == .any ? kind != .folder : kind == entry.kind
        }
        guard MenuLayout.isApplicable(entry, selection: inputs) else {
            logger.error("Selection no longer permits \(entry.op.rawValue, privacy: .public)")
            return
        }
        let preset = entry.isCustom ? nil : entry.preset
        // Finder selection order is unreliable.
        let ordersPages = [OperationID.imageToPDF, .pdfMerge].contains(entry.op) && inputs.count > 1
        let options = OperationPlanner.options(for: entry.op, preset: preset, settings: settings.planning)
        if !ordersPages, options == nil, preset != nil, preset != "choose-frame" {
            let alert = NSAlert()
            alert.messageText = MenuStrings.operationName(entry.op)
            alert.informativeText = String(
                localized: "Saved values are invalid. Review this operation in Settings.",
                comment: "Explains rejected saved parameters")
            alert.runModal()
            return
        }
        guard !ordersPages, let options else {
            var failures: [String] = []
            let inputs = inputs.filter { input in
                do {
                    try OperationPlanner.validateInput(input)
                    return true
                } catch {
                    failures.append(
                        UserMessages.describe(
                            EngineError.wrapping(error, path: input.path), file: input.lastPathComponent))
                    return false
                }
            }
            if !failures.isEmpty {
                notifier.notify(title: MenuStrings.operationName(entry.op), body: failures.joined(separator: "\n"))
            }
            guard !inputs.isEmpty else { return }
            if let presentPanel {
                presentPanel(entry, inputs)
            } else {
                logger.error("No panel for \(entry.op.rawValue, privacy: .public)")
            }
            return
        }
        run(OperationRequest(op: entry.op, options: options, inputs: inputs))
    }

    /// Await the task to chain batches.
    @discardableResult
    func run(_ request: OperationRequest) -> Task<BatchOutcome?, Never> {
        guard !terminating else { return Task { nil } }
        let snapshot = settings.planning
        let engine = engine
        let id = UUID()
        let task = Task { () -> BatchOutcome? in
            let batch = await Task.detached { OperationPlanner.batch(for: request, settings: snapshot) }.value
            guard !self.terminating, !Task.isCancelled, !batch.items.isEmpty else {
                self.forget(id)
                return nil
            }
            let started = ActiveBatch(
                id: id, batchID: batch.id, operation: request.op,
                fileNames: batch.items.map { $0.inputs.first?.lastPathComponent ?? "" })
            self.active.append(started)
            self.onStart?(started)
            let reporter = ProgressReporter(fraction: \.fraction, milestone: \.completedItems) {
                self.update(id, progress: $0)
            }
            let outcome = await engine.run(batch, settings: snapshot) { reporter.report($0) }
            self.finish(outcome, request: request, activeID: id)
            return outcome
        }
        tasks[id] = task
        return task
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    func canUndo(_ id: UUID) -> Bool {
        !terminating && !active.contains { $0.batchID == id } && undoTasks[id] == nil
    }

    func prepareForTermination() async throws {
        terminating = true
        for task in tasks.values { task.cancel() }
        let pendingUndos = Array(undoTasks.values)
        for task in pendingUndos { await task.value }
        do {
            try await engine.prepareForTermination()
        } catch {
            terminating = false
            throw error
        }
    }

    func undo(_ id: UUID) {
        guard !terminating, undoTasks[id] == nil else { return }
        undoTasks[id] = Task {
            defer { undoTasks[id] = nil }
            do {
                let outcomes = try await engine.undo(id)
                if !outcomes.isEmpty { notifyUndo(outcomes) }
            } catch UndoFailure.batchRunning {
                notifier.notify(
                    title: String(localized: "Undo", comment: "Notification title after undo"),
                    body: String(
                        localized: "This batch is still running. Try Undo after it finishes.",
                        comment: "Explains why running batches cannot undo"))
            } catch {
                let failure = error as NSError
                logger.error(
                    "Undo history write failed (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)): \(failure.localizedDescription, privacy: .private)"
                )
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
        Task {
            guard let record = await engine.history.records.first(where: { $0.id == id }) else { return }
            let urls = record.outputPaths.map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func showResult(_ batch: CompletedBatch) {
        presentReport?(batch.summary.details, batch.operation)
    }

    func refreshRecent() async {
        recent = Array(await engine.history.records.suffix(Self.recentCount).reversed())
    }

    private func update(_ id: UUID, progress: BatchProgress) {
        guard let index = active.firstIndex(where: { $0.id == id }) else { return }
        // Main-actor hops can reorder.
        guard progress.completedItems >= active[index].completedItems else { return }
        active[index].progress = max(active[index].progress, progress.fraction)
        active[index].completedItems = progress.completedItems
        active[index].currentItem = progress.currentItem
    }

    private func forget(_ id: UUID) {
        tasks[id] = nil
        active.removeAll { $0.id == id }
    }

    private func finish(_ outcome: BatchOutcome, request: OperationRequest, activeID: UUID) {
        let batch = active.first { $0.id == activeID }
        forget(activeID)
        guard !terminating else { return }
        completed.insert(
            CompletedBatch(
                date: Date(), operation: outcome.operation, summary: BatchSummary(outcome)),
            at: 0)
        completed = Array(completed.prefix(Self.recentCount))
        if let text = outcome.clipboardText {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        if let report = outcome.reportText { presentReport?(report, outcome.operation) }
        let questions = zip(outcome.inputs, outcome.outcomes).compactMap { inputs, result -> (URL, InvalidInput)? in
            guard case .failed(.invalidInput(let reason)) = result, Self.asksUser(reason), let url = inputs.first
            else { return nil }
            return (url, reason)
        }
        let asked = questions.first.map { askAgain?(request, questions.map(\.0), $0.1) ?? false } ?? false
        let shownInActivity = batch.map { showsFinished?($0, outcome) ?? false } ?? false
        if !shownInActivity, !asked || questions.count < outcome.outcomes.count { notifier.notify(outcome) }
        Task { await refreshRecent() }
    }

    private static func asksUser(_ reason: InvalidInput) -> Bool {
        switch reason {
        case .passwordRequired, .wrongPassword, .textEncodingUndetected, .tooLong: true
        default: false
        }
    }
}

/// Throttles progress hops to the main actor.
final class ProgressReporter<Update: Sendable>: Sendable {
    private static var minimumStep: Double { 0.01 }

    private let lastReported = Mutex((fraction: -1.0, milestone: -1))
    private let fraction: @Sendable (Update) -> Double
    /// A change always reports, however small.
    private let milestone: @Sendable (Update) -> Int
    private let deliver: @MainActor (Update) -> Void

    init(
        fraction: @escaping @Sendable (Update) -> Double, milestone: @escaping @Sendable (Update) -> Int,
        deliver: @escaping @MainActor (Update) -> Void
    ) {
        self.fraction = fraction
        self.milestone = milestone
        self.deliver = deliver
    }

    func report(_ update: Update) {
        let fraction = fraction(update)
        let milestone = milestone(update)
        let shouldSend = lastReported.withLock { last in
            guard fraction - last.fraction >= Self.minimumStep || fraction >= 1 || milestone != last.milestone
            else { return false }
            last = (fraction, milestone)
            return true
        }
        guard shouldSend else { return }
        Task { @MainActor in deliver(update) }
    }
}

extension ProgressReporter where Update == Double {
    convenience init(deliver: @escaping @MainActor (Double) -> Void) {
        self.init(fraction: { $0 }, milestone: { _ in 0 }, deliver: deliver)
    }
}
