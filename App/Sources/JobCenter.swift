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
        var isScan = false
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
        let hasFailures: Bool
    }

    private struct RunningJob {
        let cancel: @MainActor () -> Void
        let waitForCompletion: @MainActor () async -> Void
    }

    private static let recentCount = 10
    private static let terminationCleanupTimeout: TimeInterval = 5

    private(set) var active: [ActiveBatch] = []
    private(set) var recent: [BatchRecord] = []
    private(set) var hatchSessions: [HatchExtractionSession] = []
    private(set) var completed: [CompletedBatch] = []
    private var terminating = false
    private var undoTasks: [UUID: Task<Void, Never>] = [:]

    @ObservationIgnored let engine: JobEngine
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let notifier: BatchNotifier
    @ObservationIgnored private var runningJobs: [UUID: RunningJob] = [:]
    @ObservationIgnored var presentReport: ((String, OperationID) -> Void)?
    @ObservationIgnored var presentPanel: ((MenuEntry, [URL]) -> Void)?
    /// `false` when no panel can answer it.
    @ObservationIgnored var askAgain: ((OperationRequest, [URL], InvalidInput) -> Bool)?
    @ObservationIgnored var presentFailure: ((OperationID, String) -> Void)?
    @ObservationIgnored var onStart: ((ActiveBatch) -> Void)?
    @ObservationIgnored var onScanEnd: ((UUID) -> Void)?
    /// `true` when Activity keeps the result visible.
    @ObservationIgnored var showsFinished: ((ActiveBatch, BatchOutcome) -> Bool)?
    @ObservationIgnored private let logger = Logger(category: "jobs")

    init(engine: JobEngine, settings: SettingsStore, notifier: BatchNotifier) {
        self.engine = engine
        self.settings = settings
        self.notifier = notifier
    }

    var isBusy: Bool { !active.isEmpty }

    var pausedExtractions: [HatchExtractionSession] {
        hatchSessions.filter { session in
            session.state != "finished"
                && !active.contains {
                    $0.operation == .archiveHatchExtract && $0.fileNames.contains(session.input.lastPathComponent)
                }
        }
    }

    func resume(_ session: HatchExtractionSession) {
        run(
            OperationRequest(
                op: .archiveHatchExtract, options: .archive(.hatchExtract(password: nil, sessionID: session.id)),
                inputs: [session.input]))
    }

    func revealExtraction(_ session: HatchExtractionSession) {
        NSWorkspace.shared.activateFileViewerSelecting([session.output])
    }

    func start(entry: MenuEntry, inputs: [URL]) {
        guard !terminating else { return }
        if entry.op == .filesFinish {
            guard MenuLayout.isApplicable(entry, selection: inputs) else {
                presentFailure?(
                    entry.op, String(localized: "This recipe does not support every selected file."))
                return
            }
            presentPanel?(entry, inputs)
            return
        }
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
            let failureText = failures.joined(separator: "\n")
            guard !inputs.isEmpty else {
                presentFailure?(entry.op, failureText)
                return
            }
            if !failures.isEmpty { notifier.notify(title: MenuStrings.operationName(entry.op), body: failureText) }
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
    func run(_ request: OperationRequest, settings suppliedSettings: Settings? = nil) -> Task<BatchOutcome?, Never> {
        let snapshot = suppliedSettings ?? settings.planning
        return run(settings: snapshot, request: request) {
            await Task.detached { OperationPlanner.batch(for: request, settings: snapshot) }.value
        }
    }

    @discardableResult
    func run(batch: Batch, settings suppliedSettings: Settings? = nil) -> Task<BatchOutcome?, Never> {
        run(settings: suppliedSettings ?? settings.planning, request: nil) { batch }
    }

    private func run(
        settings snapshot: Settings, request: OperationRequest?,
        preparing makeBatch: @escaping @Sendable () async -> Batch
    ) -> Task<BatchOutcome?, Never> {
        guard !terminating else { return Task { nil } }
        let engine = engine
        let id = UUID()
        let task = Task { () -> BatchOutcome? in
            let batch = await makeBatch()
            guard !self.terminating, !Task.isCancelled, !batch.items.isEmpty else {
                self.forget(id)
                return nil
            }
            let started = ActiveBatch(
                id: id, batchID: batch.id, operation: batch.operation,
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
        runningJobs[id] = RunningJob(cancel: task.cancel, waitForCompletion: { _ = await task.value })
        return task
    }

    /// Activity shows scans; Stop cancels them.
    func scan<Result: Sendable>(
        _ op: OperationID, folders: [URL],
        _ work: @escaping @Sendable (_ progress: @escaping @Sendable (Double) -> Void) throws -> Result
    ) async throws -> Result {
        guard !terminating else { throw CancellationError() }
        let id = UUID()
        let started = ActiveBatch(
            id: id, batchID: id, operation: op, fileNames: folders.map(\.lastPathComponent), isScan: true)
        active.append(started)
        onStart?(started)
        let reporter = ProgressReporter { fraction in
            guard let index = self.active.firstIndex(where: { $0.id == id }) else { return }
            self.active[index].progress = max(self.active[index].progress, fraction)
        }
        let task = Task.detached { try work(reporter.report) }
        runningJobs[id] = RunningJob(cancel: task.cancel, waitForCompletion: { _ = await task.result })
        defer {
            forget(id)
            onScanEnd?(id)
        }
        let result = try await task.value
        // Stop can arrive after the final check.
        if task.isCancelled { throw CancellationError() }
        return result
    }

    func cancel(_ id: UUID) {
        runningJobs[id]?.cancel()
    }

    func canUndo(_ id: UUID) -> Bool {
        !terminating && !active.contains { $0.batchID == id } && undoTasks[id] == nil
            && recent.first(where: { $0.id == id })?.canUndo != false
    }

    func prepareForTermination() async throws {
        terminating = true
        let pendingJobs = Array(runningJobs.values)
        for job in pendingJobs { job.cancel() }
        let pendingUndos = Array(undoTasks.values)
        await waitForCleanup(of: pendingJobs)
        for task in pendingUndos { await task.value }
        do {
            try await engine.prepareForTermination()
        } catch {
            terminating = false
            throw error
        }
    }

    private func waitForCleanup(of jobs: [RunningJob]) async {
        guard !jobs.isEmpty else { return }
        let completion = AsyncStream<Bool>.makeStream()
        let waiter = Task {
            for job in jobs { await job.waitForCompletion() }
            completion.continuation.yield(true)
            completion.continuation.finish()
        }
        let timeout = DispatchWorkItem {
            completion.continuation.yield(false)
            completion.continuation.finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.terminationCleanupTimeout, execute: timeout)
        defer {
            waiter.cancel()
            timeout.cancel()
            completion.continuation.finish()
        }
        for await finished in completion.stream {
            if !finished {
                logger.warning("Job cleanup timed out during termination; remaining staging will be retried at launch")
            }
            break
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
        refreshExtractions()
    }

    private func refreshExtractions() {
        do {
            hatchSessions = try engine.hatchExtractions.sessions()
        } catch {
            logger.error("Extraction recovery could not be read: \(error.localizedDescription, privacy: .private)")
        }
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
        runningJobs[id] = nil
        active.removeAll { $0.id == id }
    }

    private func finish(_ outcome: BatchOutcome, request: OperationRequest?, activeID: UUID) {
        let batch = active.first { $0.id == activeID }
        forget(activeID)
        guard !terminating else { return }
        if outcome.operation == .archiveHatchExtract { refreshExtractions() }
        completed.insert(
            CompletedBatch(
                date: Date(), operation: outcome.operation, summary: BatchSummary(outcome),
                hasFailures: Self.hasFailures(outcome)),
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
        let asked =
            request.flatMap { request in
                questions.first.map { askAgain?(request, questions.map(\.0), $0.1) ?? false }
            } ?? false
        let shownInActivity = batch.map { showsFinished?($0, outcome) ?? false } ?? false
        // Only the banner can open Privacy settings.
        let needsBanner = !shownInActivity || Self.deniedPermission(outcome)
        if needsBanner, !asked || questions.count < outcome.outcomes.count { notifier.notify(outcome) }
        Task { await refreshRecent() }
    }

    // User cancellation is not a failure.
    private static func hasFailures(_ outcome: BatchOutcome) -> Bool {
        outcome.historyFailed
            || outcome.outcomes.contains { result in
                guard case .failed(let error) = result else { return false }
                return error != .cancelled
            }
    }

    private static func deniedPermission(_ outcome: BatchOutcome) -> Bool {
        outcome.outcomes.contains { result in
            guard case .failed(.permissionDenied) = result else { return false }
            return true
        }
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
