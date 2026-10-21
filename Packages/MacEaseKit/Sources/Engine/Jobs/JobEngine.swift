import Foundation
import MenuCatalog
import Synchronization
import os

public enum ItemOutcome: Equatable, Sendable {
    case succeeded(outputs: [URL], warnings: [ItemWarning])
    case skipped(SkipReason)
    case failed(EngineError)
}

public struct BatchOutcome: Sendable {
    public let batchID: UUID
    public let operation: OperationID
    public let inputs: [[URL]]
    public let outcomes: [ItemOutcome]
    public let clipboardText: String?
    public let reportText: String?
    public let record: BatchRecord?
    public let historyFailed: Bool

    public var wasCancelled: Bool { outcomes.contains(.failed(.cancelled)) }
}

public final class JobEngine: Sendable {
    public let history: HistoryStore
    public let staging: StagingArea
    private let cpuGate: LaneGate
    private let hardwareVideoGate = LaneGate(width: 1)
    private let committer = FileCommitter()
    private let logger = Logger(category: "jobs")

    public init(supportDirectory: URL, concurrency: Int) throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        history = HistoryStore(supportDirectory: supportDirectory)
        staging = StagingArea(supportDirectory: supportDirectory)
        cpuGate = LaneGate(width: concurrency)
    }

    public func undo(_ id: UUID) async throws -> [UndoOutcome] {
        try await history.undo(id)
    }

    public func prepareForTermination() async throws {
        try await history.prepareForTermination()
    }

    public func setConcurrency(_ width: Int) async {
        await cpuGate.setWidth(width)
    }

    public func saveReport(_ text: String, to destination: URL, operation: OperationID) async -> BatchOutcome {
        let workItem = WorkItem(inputs: []) { context in
            let name = destination.lastPathComponent
            guard destination.isFileURL, AvailableName.checkedName(name) else {
                throw EngineError.invalidInput(.malformed(destination.absoluteString))
            }
            let staged = try context.stagingURL(for: destination.deletingLastPathComponent(), name: name)
            try Data(text.utf8).write(to: staged)
            return .derived(
                nextTo: destination,
                outputs: [StagedFile(url: staged, name: name, check: .text(.utf8))])
        }
        return await run(Batch(operation: operation, items: [workItem]), settings: Settings()) { _ in }
    }

    public func saveReport(_ analysis: FolderAnalysis, as format: AnalysisExportFormat, to destination: URL)
        async throws -> BatchOutcome
    {
        await saveReport(try analysis.serialized(as: format), to: destination, operation: .folderAnalyze)
    }

    private struct ItemResultSummary: Sendable {
        let index: Int
        let outcome: ItemOutcome
        let text: (String, TextDestination)?
    }

    /// Cancel the calling task to stop.
    public func run(
        _ batch: Batch,
        settings: Settings,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> BatchOutcome {
        await history.beginBatch(batch.id)
        let tracker = BatchTracker(itemCount: batch.items.count)
        let summaries = await withTaskGroup(of: ItemResultSummary.self) { group in
            for (index, workItem) in batch.items.enumerated() {
                group.addTask {
                    let context = ItemContext(settings: settings, staging: self.staging) { fraction in
                        progress(tracker.update(index, fraction: fraction))
                    }
                    let (outcome, text) = await self.perform(workItem, of: batch, context: context, tracker: tracker)
                    context.progress(1)
                    return ItemResultSummary(index: index, outcome: outcome, text: text)
                }
            }
            var collected: [ItemResultSummary] = []
            for await summary in group { collected.append(summary) }
            return collected.sorted { $0.index < $1.index }
        }
        do {
            try await history.flush()
        } catch {
            tracker.markHistoryFailed()
            logger.error(
                "History write failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
        }

        await history.endBatch(batch.id)
        let texts = summaries.compactMap(\.text)
        let clipboard = texts.filter { $0.1 == .clipboard }.map(\.0)
        let reports = texts.filter { $0.1 == .report }.map(\.0)
        let showsReport = !reports.isEmpty || (batch.reportsMultipleTexts && clipboard.count > 1)
        return BatchOutcome(
            batchID: batch.id,
            operation: batch.operation,
            inputs: batch.items.map(\.inputs),
            outcomes: summaries.map(\.outcome),
            clipboardText: clipboard.isEmpty ? nil : clipboard.joined(separator: "\n"),
            reportText: showsReport ? (reports.isEmpty ? clipboard : reports).joined(separator: "\n") : nil,
            record: await history.records.last { $0.id == batch.id },
            historyFailed: tracker.historyFailed
        )
    }

    private func perform(
        _ workItem: WorkItem,
        of batch: Batch,
        context: ItemContext,
        tracker: BatchTracker
    ) async -> (ItemOutcome, (String, TextDestination)?) {
        let gate = workItem.lane == .hardwareVideo ? hardwareVideoGate : cpuGate
        let path = workItem.inputs.first?.path ?? ""
        defer { context.removeStaging() }
        let result: ItemResult
        var inputStamps: [URL: FileStamp] = [:]
        do {
            try await gate.acquire()
            do {
                try Self.downloadIfNeeded(workItem.inputs)
                for input in workItem.inputs {
                    let values = try input.resourceValues(forKeys: [.isDirectoryKey])
                    if values.isDirectory != true { inputStamps[input] = try FileStamp(of: input) }
                }
                result = try await workItem.body(context)
                await gate.release()
            } catch {
                await gate.release()
                throw error
            }
            try Task.checkCancellation()
        } catch {
            return (.failed(logged(EngineError.wrapping(error, path: path), batch: batch, workItem: workItem)), nil)
        }
        do {
            try await history.commitGate.acquire()
        } catch {
            return (.failed(EngineError.wrapping(error, path: path)), nil)
        }
        var records: [CommitRecord] = []
        let outcome: (ItemOutcome, (String, TextDestination)?)
        do {
            try await history.checkAcceptingCommits()
            outcome = try await commit(
                result, newFileNaming: workItem.newFileNaming, inputStamps: inputStamps,
                context: context, records: &records)
        } catch FileCommitter.Failure.changedSinceScan {
            outcome = (.skipped(.changedSinceScan), nil)
        } catch {
            let engineError = EngineError.wrapping(error, path: path, otherwise: EngineError.commitFailed)
            outcome = (.failed(logged(engineError, batch: batch, workItem: workItem)), nil)
        }
        do {
            try await history.record(records, batch: batch.id, operation: batch.operation)
        } catch {
            tracker.markHistoryFailed()
            logger.error(
                "History write failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
        }
        await history.commitGate.release()
        return outcome
    }

    private func logged(_ error: EngineError, batch: Batch, workItem: WorkItem) -> EngineError {
        switch error {
        case .unexpected(let detail), .commitFailed(let detail):
            let pathExtension = workItem.inputs.first?.pathExtension ?? ""
            let operation = batch.operation.rawValue
            logger.error(
                "\(operation, privacy: .public) failed on .\(pathExtension, privacy: .public): \(detail, privacy: .private)"
            )
        default:
            break
        }
        return error
    }

    private func commit(
        _ result: ItemResult,
        newFileNaming: NewFileNaming?,
        inputStamps: [URL: FileStamp],
        context: ItemContext,
        records: inout [CommitRecord]
    ) async throws -> (ItemOutcome, (String, TextDestination)?) {
        var outputs: [URL] = []
        switch result {
        case .replace(let original, let output):
            guard let expectedStamp = inputStamps[original] else {
                throw EngineError.commitFailed("Replacement original was not an input")
            }
            if let newFileNaming {
                let named = StagedFile(
                    url: output.url, name: newFileNaming.name(for: original, outputName: output.name),
                    check: output.check)
                let committed = try await committer.derive(named, nextTo: original, expectedStamp: expectedStamp)
                records.append(.derived(output: committed.output.path, stamp: committed.stamp))
                outputs.append(committed.output)
                break
            }
            let cloneDirectory = try context.stagingDirectory(for: original)
            let replaced = try await committer.replace(
                original: original, with: output, cloneDirectory: cloneDirectory, expectedStamp: expectedStamp)
            if let trashed = replaced.trashed {
                records.append(
                    .replaced(
                        original: original.path, trashed: trashed.url.path, output: replaced.output.path,
                        stamp: replaced.stamp,
                        trashStamp: trashed.stamp)
                )
            } else {
                records.append(.derived(output: replaced.output.path, stamp: replaced.stamp))
            }
            if let warning = replaced.warning { context.warn(warning) }
            outputs.append(replaced.output)
        case .derived(let original, let staged):
            for file in staged {
                let output = try await committer.derive(file, nextTo: original)
                records.append(.derived(output: output.output.path, stamp: output.stamp))
                outputs.append(output.output)
            }
        case .rename(let plans):
            for plan in plans {
                try Task.checkCancellation()
                guard AvailableName.checkedName(plan.newName) else {
                    throw EngineError.invalidInput(.malformed(plan.newName))
                }
                guard plan.newName != plan.url.lastPathComponent else { continue }
                let renamed = try committer.rename(plan.url, to: plan.newName)
                records.append(
                    .renamed(
                        from: plan.url.path, to: renamed.output.path,
                        stamp: renamed.stamp))
                outputs.append(renamed.output)
            }
        case .trash(let urls, let permanently, let condition):
            for url in urls {
                if let trashed = try committer.remove(url, permanently: permanently, condition: condition) {
                    records.append(.removed(original: url.path, trashed: trashed.url.path, trashStamp: trashed.stamp))
                }
            }
        case .text(let text, let destination):
            return (.succeeded(outputs: [], warnings: context.warnings), (text, destination))
        case .skipped(let reason):
            return (.skipped(reason), nil)
        }
        return (.succeeded(outputs: outputs, warnings: context.warnings), nil)
    }

    /// Coordination downloads dataless cloud files.
    private static func downloadIfNeeded(_ urls: [URL]) throws {
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey])
            guard values.isUbiquitousItem == true else { continue }
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError)
            {
                _ in
            }
            if let coordinationError { throw coordinationError }
        }
    }
}

private final class BatchTracker: Sendable {
    private let fractions: Mutex<[Double]>
    private let failedHistory = Mutex(false)

    init(itemCount: Int) {
        fractions = Mutex([Double](repeating: 0, count: itemCount))
    }

    /// Returns the batch's mean progress.
    func update(_ index: Int, fraction: Double) -> Double {
        fractions.withLock { values in
            values[index] = fraction
            return values.reduce(0, +) / Double(values.count)
        }
    }

    func markHistoryFailed() {
        failedHistory.withLock { $0 = true }
    }

    var historyFailed: Bool { failedHistory.withLock { $0 } }
}
