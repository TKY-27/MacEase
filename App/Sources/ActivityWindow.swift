import AppKit
import Engine
import MenuCatalog
import Observation
import SwiftUI

/// Automatic progress preserves Finder focus.
@MainActor
final class ActivityWindow: NSObject, NSWindowDelegate {
    private static let appearanceDelay: TimeInterval = 2
    private static let frameName = "Activity"
    private static let topMargin: CGFloat = 96

    private let jobs: JobCenter
    private let settings: SettingsStore
    private let notifier: BatchNotifier
    private let log = ActivityLog()
    private var panel: NSPanel?

    init(jobs: JobCenter, settings: SettingsStore, notifier: BatchNotifier) {
        self.jobs = jobs
        self.settings = settings
        self.notifier = notifier
    }

    func started(_ batch: JobCenter.ActiveBatch) {
        log.rows.append(
            ActivityRow(id: batch.id, batchID: batch.batchID, operation: batch.operation, itemCount: batch.itemCount))
        Timer.scheduledTimer(withTimeInterval: Self.appearanceDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.revealIfStillRunning(batch.id) }
        }
    }

    /// `true` when the result stays visible here.
    func finished(_ batch: JobCenter.ActiveBatch, outcome: BatchOutcome) -> Bool {
        guard let index = log.rows.firstIndex(where: { $0.id == batch.id }) else { return false }
        if outcome.details.contains(where: { $0.pausedArchiveSessionID != nil }), !jobs.pausedExtractions.isEmpty {
            log.rows.remove(at: index)
            AccessibilityNotification.Announcement(String(localized: "Paused.")).post()
            return panel?.isVisible == true
        }
        let names = jobs.downloadSessions[outcome.batchID]?.request.selections.map(\.source.title)
        // Only this window offers the choice.
        let awaitsStreamConsent = jobs.canContinueWithoutStreams(outcome.batchID)
        let result = ActivityResult(
            outcome, fileNames: names, awaitingConsent: awaitsStreamConsent ? jobs.sessions[outcome.batchID] : nil)
        if awaitsStreamConsent {
            log.rows[index].dismissed = false
            present()
        }
        let wasVisible = panel?.isVisible == true
        if wasVisible {
            let operation = MenuStrings.operationName(batch.operation)
            AccessibilityNotification.Announcement(
                String(localized: "\(operation): \(result.summary)", comment: "VoiceOver batch completion")
            ).post()
        }
        log.rows[index].result = result
        if !awaitsStreamConsent, log.rows[index].dismissed || closesAutomatically(result) {
            discard(batch.id, removesNotification: false)
            hideIfEmpty()
        }
        let finished = log.rows.filter { $0.result != nil }
        for old in finished.dropLast(20) { dismiss(old.id) }
        return wasVisible && log.rows.contains(where: { $0.id == batch.id && !$0.dismissed })
    }

    func scanEnded(_ id: UUID) {
        log.rows.removeAll { $0.id == id }
        hideIfEmpty()
    }

    func show() {
        guard !log.rows.isEmpty || !jobs.pausedExtractions.isEmpty else { return }
        for index in log.rows.indices where log.rows[index].result == nil { log.rows[index].dismissed = false }
        present()
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }

    private func present() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        for id in log.rows.filter({ $0.result != nil }).map(\.id) { dismiss(id) }
        for index in log.rows.indices { log.rows[index].dismissed = true }
        sender.orderOut(nil)
        return false
    }

    func dismiss(_ id: UUID) {
        discard(id, removesNotification: true)
    }

    private func discard(_ id: UUID, removesNotification: Bool) {
        guard let index = log.rows.firstIndex(where: { $0.id == id }), log.rows[index].result != nil else { return }
        let row = log.rows.remove(at: index)
        jobs.dismissSession(row.batchID)
        if removesNotification { notifier.dismiss(batchID: row.batchID) }
        hideIfEmpty()
    }

    func dismissBatch(_ batchID: UUID) {
        guard let row = log.rows.first(where: { $0.batchID == batchID && $0.result != nil }) else { return }
        dismiss(row.id)
    }

    private func revealIfStillRunning(_ id: UUID) {
        guard settings.showsActivity, jobs.active.contains(where: { $0.id == id }),
            log.rows.contains(where: { $0.id == id && !$0.dismissed })
        else { return }
        present()
    }

    private func closesAutomatically(_ result: ActivityResult) -> Bool {
        switch result.status {
        case .done: result.warnings.isEmpty && settings.activityClosesAfterSuccess
        case .cancelled: settings.activityClosesAfterCancel
        case .failed: settings.activityClosesAfterFailure
        case .problems: result.problems.contains(where: \.isFailure) && settings.activityClosesAfterFailure
        case .awaitingConfirmation: false
        }
    }

    private func hideIfEmpty() {
        if log.rows.allSatisfy(\.dismissed) && jobs.pausedExtractions.isEmpty { panel?.orderOut(nil) }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered,
            defer: true)
        panel.title = String(localized: "MacEase Activity", comment: "Activity window title")
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        // Finder may be in full screen.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        let view = ActivityView(log: log, jobs: jobs, dismiss: { [weak self] in self?.dismiss($0) })
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        panel.contentViewController = controller
        panel.setContentSize(controller.view.fittingSize)
        if !panel.setFrameUsingName(Self.frameName) { placeAtTop(panel) }
        panel.setFrameAutosaveName(Self.frameName)
        return panel
    }

    private func placeAtTop(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - Self.topMargin - size.height))
    }

}

@MainActor
@Observable
private final class ActivityLog {
    var rows: [ActivityRow] = []
}

private struct ActivityRow: Identifiable {
    let id: UUID
    let batchID: UUID
    let operation: OperationID
    let itemCount: Int
    var dismissed = false
    var result: ActivityResult?
}

struct ActivityProblem {
    let message: String
    let isFailure: Bool
    var technicalDetail: String?

    init(message: String, isFailure: Bool) {
        self.message = message
        self.isFailure = isFailure
    }

    init(_ error: EngineError, file: String) {
        message = UserMessages.describeResult(error, file: file)
        isFailure = error != .cancelled
        technicalDetail = UserMessages.technicalDetail(error)
    }
}

struct ActivityWarning {
    let message: String
    let file: String
    var count: Int

    var summary: String {
        count == 1
            ? String(localized: "“\(file)”: \(message)", comment: "File warning in batch results")
            : String(localized: "\(count) files: \(message)", comment: "Grouped file warning in Activity")
    }
}

/// A question, not a failure.
struct ActivityConfirmation {
    let index: Int
    let file: String
    let streams: [UnpreservedStream]
}

struct ActivityResult {
    enum Status {
        case done
        case problems
        case cancelled
        case failed
        case awaitingConfirmation
    }

    let status: Status
    /// Includes skips, which are not problems.
    let problems: [ActivityProblem]
    let confirmations: [ActivityConfirmation]
    let operation: OperationID
    let replacesOriginals: Bool
    let warnings: [ActivityWarning]
    let skipped: Int
    let details: String
    let hasHistory: Bool

    init(_ outcome: BatchOutcome, fileNames: [String]? = nil, awaitingConsent session: ActivitySession? = nil) {
        var problems: [ActivityProblem] = []
        var confirmations: [ActivityConfirmation] = []
        var warnings: [ActivityWarning] = []
        var succeeded = 0
        var failed = 0
        var skipped = 0
        let questions = session?.unpreservedStreamsByItem ?? [:]
        for index in outcome.outcomes.indices {
            let result = outcome.outcomes[index]
            let file = fileNames?[index] ?? outcome.inputs[index].first?.lastPathComponent ?? ""
            if let streams = questions[index] {
                confirmations.append(ActivityConfirmation(index: index, file: file, streams: streams))
                continue
            }
            switch result {
            case .succeeded(_, let itemWarnings):
                succeeded += 1
                var itemMessages: [String] = []
                for warning in itemWarnings {
                    let message = UserMessages.describe(warning)
                    guard !itemMessages.contains(message) else { continue }
                    itemMessages.append(message)
                    if let index = warnings.firstIndex(where: { $0.message == message }) {
                        warnings[index].count += 1
                    } else {
                        warnings.append(ActivityWarning(message: message, file: file, count: 1))
                    }
                }
            case .skipped(let reason):
                skipped += 1
                problems.append(ActivityProblem(message: UserMessages.describe(reason, file: file), isFailure: false))
            case .failed(.cancelled):
                break
            case .failed(let error):
                failed += 1
                problems.append(ActivityProblem(error, file: file))
            }
        }
        if outcome.historyFailed {
            problems.append(
                ActivityProblem(
                    message: String(localized: "Undo is unavailable because the history could not be saved."),
                    isFailure: true))
        }
        if outcome.wasCancelled {
            status = .cancelled
        } else if succeeded + failed + skipped == 0, !confirmations.isEmpty {
            status = .awaitingConfirmation
        } else if succeeded == 0, failed > 0, confirmations.isEmpty {
            status = .failed
        } else {
            status = problems.isEmpty ? .done : .problems
        }
        self.problems = problems
        self.confirmations = confirmations
        operation = outcome.operation
        replacesOriginals = session?.replacesOriginals ?? false
        self.warnings = warnings
        self.skipped = skipped
        details = BatchSummary(outcome).details
        hasHistory = outcome.record != nil
    }

    var noteCount: Int { warnings.reduce(0) { $0 + $1.count } }
    var hasCondensedWarnings: Bool { warnings.contains { $0.count > 1 } }
    var isFailure: Bool { problems.contains(where: \.isFailure) }

    var systemImage: String {
        if isFailure { return "xmark.octagon.fill" }
        return status == .done ? "checkmark.circle.fill" : "info.circle"
    }

    var confirmationStreams: [UnpreservedStream] {
        UnpreservedStream.allCases.filter { kind in confirmations.contains { $0.streams.contains(kind) } }
    }

    /// Status and pending question together.
    var summary: String {
        guard !confirmations.isEmpty, status != .awaitingConfirmation else { return statusText }
        return [statusText, UserMessages.confirmationCount(confirmations.count)].joined(separator: " ")
    }

    var statusText: String {
        switch status {
        case .awaitingConfirmation: UserMessages.confirmationCount(confirmations.count)
        case .done: String(localized: "Done.", comment: "Activity status")
        case .cancelled: String(localized: "Cancelled.", comment: "Activity status")
        case .failed: String(localized: "Failed.", comment: "Activity status")
        case .problems where skipped == problems.count:
            String(localized: "Finished — \(skipped) skipped.", comment: "Activity status without problems")
        case .problems where skipped > 0:
            String(
                AttributedString(
                    localized:
                        "Finished with ^[\(problems.count - skipped) problem](inflect: true), \(skipped) skipped.",
                    comment: "Activity status"
                ).characters)
        case .problems:
            String(
                AttributedString(
                    localized: "Finished with ^[\(problems.count) problem](inflect: true).",
                    comment: "Activity status"
                ).characters)
        }
    }
}

private struct ActivityProblemView: View {
    let problem: ActivityProblem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(problem.message, systemImage: problem.isFailure ? "xmark.octagon.fill" : "info.circle")
                .foregroundStyle(problem.isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            if let detail = problem.technicalDetail {
                DisclosureGroup(String(localized: "Details")) {
                    Text(verbatim: detail)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

private struct StreamOmissionOffer: View {
    let result: ActivityResult
    let enabled: Bool
    let proceed: () -> Void

    private static let spacing: CGFloat = 6
    private static let fileColumnWidth: CGFloat = 180

    var body: some View {
        GroupBox {
            content(result.confirmationStreams)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Self.spacing / 2)
        }
        .fixedSize(horizontal: false, vertical: true)
        .font(.callout)
    }

    private func content(_ streams: [UnpreservedStream]) -> some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            if let only = result.confirmations.first, result.confirmations.count == 1 {
                Text(UserMessages.streamsStatement(file: only.file, streams: only.streams))
            } else {
                Text(UserMessages.streamsListIntroduction)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Self.spacing * 2, verticalSpacing: 2) {
                    ForEach(Array(result.confirmations.enumerated()), id: \.offset) { _, confirmation in
                        GridRow {
                            Text(verbatim: confirmation.file)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: Self.fileColumnWidth, alignment: .leading)
                            Text(UserMessages.unpreservedStreams(confirmation.streams))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(streams, id: \.self) { Text(UserMessages.consequence(of: $0, operation: result.operation)) }
            }
            .foregroundStyle(.secondary)
            Text(
                UserMessages.streamOmissionConsequence(
                    files: result.confirmations.map(\.file), replacesOriginals: result.replacesOriginals)
            )
            .foregroundStyle(.secondary)
            Button(UserMessages.continueWithout(streams), action: proceed)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!enabled)
        }
    }
}

private struct ActivityView: View {
    let log: ActivityLog
    let jobs: JobCenter
    let dismiss: (UUID) -> Void

    @State private var contentHeight: CGFloat = 0

    private static let width: CGFloat = 420
    private static let maximumHeight: CGFloat = 480
    private static let rowSpacing: CGFloat = 14

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(jobs.pausedExtractions) { session in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(MenuStrings.operationName(.archiveHatchExtract)).font(.headline)
                        Text(session.input.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(String(localized: "Paused.")).foregroundStyle(.secondary)
                        HStack {
                            Button(String(localized: "Resume")) { jobs.resume(session) }
                            Spacer()
                            Button(String(localized: "Show in Finder")) { jobs.revealExtraction(session) }
                        }
                        .controlSize(.small)
                    }
                    Divider()
                }
                ForEach(Array(log.rows.filter { !$0.dismissed }.enumerated()), id: \.element.id) { position, row in
                    if position > 0 { Divider() }
                    ActivityRowView(
                        row: row, running: jobs.active.first { $0.id == row.id }, jobs: jobs,
                        dismiss: { dismiss(row.id) })
                }
            }
            .padding()
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                contentHeight = $0
            }
        }
        .frame(width: Self.width, height: min(contentHeight, Self.maximumHeight))
    }
}

private struct ActivityRowView: View {
    let row: ActivityRow
    let running: JobCenter.ActiveBatch?
    let jobs: JobCenter
    let dismiss: () -> Void

    private static let lineSpacing: CGFloat = 6
    private static let visibleNotices = 5

    var body: some View {
        VStack(alignment: .leading, spacing: Self.lineSpacing) {
            if let running {
                progress(running)
            } else if let result = row.result {
                finished(result)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var operationName: String { MenuStrings.operationName(row.operation) }

    /// Reflects Undo from anywhere.
    private var canUndo: Bool {
        jobs.canUndo(row.batchID) && jobs.recent.first(where: { $0.id == row.batchID })?.undone != true
    }

    private var title: some View {
        Text(verbatim: row.itemCount > 1 ? "\(operationName) (\(row.itemCount))" : operationName)
            .font(.headline)
    }

    private func progress(_ batch: JobCenter.ActiveBatch) -> some View {
        let pausesExtraction = batch.canPauseArchiveExtraction
        let stopTitle = pausesExtraction ? String(localized: "Pause") : String(localized: "Stop")
        return HStack(spacing: Self.lineSpacing * 2) {
            VStack(alignment: .leading, spacing: Self.lineSpacing) {
                title
                if batch.isScan, batch.scanFraction == nil {
                    ProgressView()
                        .progressViewStyle(.linear)
                } else if let fraction = batch.isScan ? batch.scanFraction : batch.currentFileFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                if !batch.isScan {
                    Text(
                        String(
                            localized: "\(batch.completedItems) of \(batch.itemCount) completed",
                            comment: "Activity completed item count")
                    )
                    .monospacedDigit()
                }
                if let status = runningStatus(batch) {
                    Text(status)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            Button {
                jobs.cancel(batch.id)
            } label: {
                Label(stopTitle, systemImage: pausesExtraction ? "pause.circle.fill" : "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(stopTitle)
            .accessibilityLabel(
                pausesExtraction
                    ? Text("Pause \(operationName)", comment: "Activity pause button for VoiceOver")
                    : Text("Stop \(operationName)", comment: "Activity stop button for VoiceOver"))
        }
    }

    private func runningStatus(_ batch: JobCenter.ActiveBatch) -> String? {
        if batch.isScan {
            return String(
                localized: "Scanning \(batch.fileNames.formatted(.list(type: .and)))…",
                comment: "Activity status while scanning folders")
        }
        guard let file = batch.currentFileName, let index = batch.currentItem else { return nil }
        let phase = batch.itemPhases.indices.contains(index) ? UserMessages.describe(batch.itemPhases[index]) : ""
        return phase.isEmpty ? file : "\(file) · \(phase)"
    }

    @ViewBuilder private func fileStatus(
        _ outcome: ItemOutcome, file: String, question: [UnpreservedStream]? = nil
    ) -> some View {
        if let question {
            confirmationStatus(question, pending: UserMessages.streamsStatement(file: file, streams: question))
        } else {
            itemStatus(outcome, file: file)
        }
    }

    @ViewBuilder private func itemStatus(_ outcome: ItemOutcome, file: String) -> some View {
        switch outcome {
        case .succeeded(_, let warnings):
            if [OperationID.imageCompress, .videoCompress, .audioCompress, .pdfCompress].contains(row.operation) {
                Label("Compression complete.", systemImage: "checkmark.circle.fill")
            } else if [OperationID.imageConvert, .videoConvert, .audioConvert].contains(row.operation) {
                Label("Conversion complete.", systemImage: "checkmark.circle.fill")
            } else {
                Label("Done.", systemImage: "checkmark.circle.fill")
            }
            let messages = warnings.map { UserMessages.describe($0) }
            let unique = messages.enumerated().filter { index, message in !messages.prefix(index).contains(message) }
                .map(\.element)
            notes(unique, count: unique.count)
        case .skipped(let reason): Text(UserMessages.describe(reason, file: file)).foregroundStyle(.secondary)
        case .failed(let error):
            ActivityProblemView(problem: ActivityProblem(error, file: file))
        }
    }

    /// Calm tint: a question, not an error.
    @ViewBuilder private func confirmationStatus(_ streams: [UnpreservedStream], pending: String) -> some View {
        if jobs.continuedWithoutStreams.contains(row.batchID) {
            Label(UserMessages.continuedWithout(streams), systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        } else {
            Label {
                Text(pending)
            } icon: {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.tint)
            }
        }
    }

    @ViewBuilder private func notes(_ messages: [String], count: Int) -> some View {
        if count > 0 {
            DisclosureGroup {
                ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                    Text(message).fixedSize(horizontal: false, vertical: true)
                }
            } label: {
                Label(UserMessages.noteCount(count), systemImage: "info.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func fileResult(_ session: ActivitySession, index: Int) -> some View {
        let outcome = session.outcome
        let details = outcome.details[index]
        return VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: outcome.inputs[index].first?.lastPathComponent ?? "")
                .lineLimit(1).truncationMode(.middle)
            fileStatus(
                outcome.outcomes[index], file: outcome.inputs[index].first?.lastPathComponent ?? "",
                question: row.result?.confirmations.first { $0.index == index }?.streams)
            Text(verbatim: String(format: "%.1f s", details.elapsedSeconds))
                .monospacedDigit().foregroundStyle(.secondary)
            if details.outputBytes > 0 {
                Text(verbatim: "\(details.originalBytes.fileSize) → \(details.outputBytes.fileSize)")
                    .monospacedDigit()
                if details.originalBytes > 0 {
                    Text(UserMessages.sizeChange(original: details.originalBytes, output: details.outputBytes))
                        .foregroundStyle(.secondary)
                }
            }
            if let image = details.image {
                if image.reducedDimensions { Text("Dimensions reduced").foregroundStyle(.secondary) }
                if image.quantized {
                    if let colors = image.paletteColors {
                        Text("Palette: up to \(colors) colors").foregroundStyle(.secondary)
                    } else {
                        Text("Colors reduced").foregroundStyle(.secondary)
                    }
                }
                if image.frameCount > 1 || image.isMultiPage {
                    Text("Animated and multipage images cannot be compared.").foregroundStyle(.secondary)
                }
                Text(
                    verbatim:
                        "\(image.originalWidth) × \(image.originalHeight) → \(image.outputWidth) × \(image.outputHeight)"
                )
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func downloadResult(_ session: JobCenter.DownloadSession, index: Int) -> some View {
        let name = session.request.selections[index].source.title
        return VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: name).lineLimit(1).truncationMode(.middle)
            fileStatus(session.outcome.outcomes[index], file: name)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func finished(_ result: ActivityResult) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Self.lineSpacing) {
                title
                if result.status != .awaitingConfirmation {
                    Label(result.statusText, systemImage: result.systemImage)
                        .font(.subheadline)
                        .foregroundStyle(result.isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                }
                if !result.confirmations.isEmpty {
                    confirmationStatus(
                        result.confirmationStreams, pending: UserMessages.confirmationCount(result.confirmations.count)
                    )
                    .font(.subheadline)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Dismiss", comment: "Remove a completed Activity result"))
            .accessibilityLabel(Text("Dismiss", comment: "Remove a completed Activity result"))
        }
        ForEach(Array(result.problems.prefix(Self.visibleNotices).enumerated()), id: \.offset) { _, problem in
            ActivityProblemView(problem: problem)
        }
        if result.problems.count > Self.visibleNotices {
            DisclosureGroup(String(localized: "More Results")) {
                ForEach(Array(result.problems.dropFirst(Self.visibleNotices).enumerated()), id: \.offset) {
                    _, problem in
                    ActivityProblemView(problem: problem)
                }
            }
            .font(.callout)
        }
        if !result.confirmations.isEmpty, !jobs.continuedWithoutStreams.contains(row.batchID) {
            StreamOmissionOffer(result: result, enabled: jobs.canContinueWithoutStreams(row.batchID)) {
                jobs.continueWithoutStreams(row.batchID)
            }
        }
        notes(result.warnings.map(\.summary), count: result.noteCount)
        if let session = jobs.sessions[row.batchID] {
            DisclosureGroup(String(localized: "File Results")) {
                ForEach(session.outcome.outcomes.indices, id: \.self) { index in
                    fileResult(session, index: index)
                }
            }
            .font(.callout)
        } else if let session = jobs.downloadSessions[row.batchID] {
            DisclosureGroup(String(localized: "File Results")) {
                ForEach(session.outcome.outcomes.indices, id: \.self) { index in
                    downloadResult(session, index: index)
                }
            }
            .font(.callout)
        }
        HStack {
            if let session = jobs.sessions[row.batchID] {
                if session.supportsComparison,
                    session.outcome.outcomes.contains(where: {
                        if case .succeeded = $0 { return true }; return false
                    })
                {
                    Button(String(localized: "Compare…")) { jobs.compare(row.batchID) }
                        .disabled(session.comparisonIndices.isEmpty)
                        .help(
                            session.comparisonIndices.isEmpty
                                ? String(localized: "Animated and multipage images cannot be compared.")
                                : String(localized: "Compare original and output images."))
                }
                if !session.failedIndices.isEmpty {
                    Button(String(localized: "Retry Failed…")) { jobs.retry(row.batchID) }
                        .disabled(!jobs.canRetry(row.batchID))
                }
            }
            if let session = jobs.downloadSessions[row.batchID], !session.failedIndices.isEmpty {
                Button(String(localized: "Retry Failed…")) { jobs.retry(row.batchID) }
                    .disabled(!jobs.canRetry(row.batchID))
            }
            if result.problems.count > Self.visibleNotices || result.hasCondensedWarnings {
                Button(String(localized: "Show All…", comment: "Activity button listing every result detail")) {
                    jobs.presentReport?(result.details, row.operation)
                }
            }
            Spacer()
            if result.hasHistory, canUndo {
                Button(String(localized: "Undo", comment: "Activity button")) { jobs.undo(row.batchID) }
                    .accessibilityLabel(Text("Undo \(operationName)", comment: "Activity undo button for VoiceOver"))
            }
            if result.hasHistory {
                Button(String(localized: "Show in Finder", comment: "Activity button")) {
                    jobs.showOutputs(of: row.batchID)
                }
                .accessibilityLabel(
                    Text("Show \(operationName) results in Finder", comment: "Activity reveal button for VoiceOver"))
            }
        }
        .controlSize(.small)
    }
}
