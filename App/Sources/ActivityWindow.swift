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
    private let log = ActivityLog()
    private var panel: NSPanel?

    init(jobs: JobCenter, settings: SettingsStore) {
        self.jobs = jobs
        self.settings = settings
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
        if outcome.operation == .archiveHatchExtract, outcome.wasCancelled, !jobs.pausedExtractions.isEmpty {
            log.rows.remove(at: index)
            AccessibilityNotification.Announcement(String(localized: "Paused.")).post()
            return panel?.isVisible == true
        }
        let names = jobs.downloadSessions[outcome.batchID]?.request.selections.map(\.source.title)
        let result = ActivityResult(outcome, fileNames: names)
        let wasVisible = panel?.isVisible == true
        if wasVisible {
            let operation = MenuStrings.operationName(batch.operation)
            AccessibilityNotification.Announcement(
                String(localized: "\(operation): \(result.statusText)", comment: "VoiceOver batch completion")
            ).post()
        }
        log.rows[index].result = result
        if closesAutomatically(result) {
            log.rows[index].dismissed = true
            hideIfEmpty()
        }
        let finished = log.rows.filter { $0.result != nil }
        for old in finished.dropLast(20) {
            log.rows.removeAll { $0.id == old.id }
            jobs.dismissSession(old.batchID)
        }
        return wasVisible && !log.rows.contains(where: { $0.id == batch.id && $0.dismissed })
    }

    func scanEnded(_ id: UUID) {
        log.rows.removeAll { $0.id == id }
        hideIfEmpty()
    }

    func show() {
        guard !log.rows.isEmpty || !jobs.pausedExtractions.isEmpty else { return }
        for index in log.rows.indices { log.rows[index].dismissed = false }
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
        for index in log.rows.indices { log.rows[index].dismissed = true }
        sender.orderOut(nil)
        return false
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
        let view = ActivityView(log: log, jobs: jobs)
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

private struct ActivityProblem {
    let message: String
    let isFailure: Bool
}

private struct ActivityWarning {
    let message: String
    let file: String
    var count: Int

    var summary: ActivityProblem {
        let text =
            count == 1
            ? String(localized: "“\(file)”: \(message)", comment: "File warning in batch results")
            : String(localized: "\(count) files: \(message)", comment: "Grouped file warning in Activity")
        return ActivityProblem(message: text, isFailure: false)
    }
}

private struct ActivityResult {
    enum Status {
        case done
        case problems
        case cancelled
        case failed
    }

    let status: Status
    /// Includes skips, which are not problems.
    let problems: [ActivityProblem]
    let warnings: [ActivityWarning]
    let skipped: Int
    let details: String
    let hasHistory: Bool

    init(_ outcome: BatchOutcome, fileNames: [String]? = nil) {
        var problems: [ActivityProblem] = []
        var warnings: [ActivityWarning] = []
        var succeeded = 0
        var failed = 0
        var skipped = 0
        for index in outcome.outcomes.indices {
            let result = outcome.outcomes[index]
            let file = fileNames?[index] ?? outcome.inputs[index].first?.lastPathComponent ?? ""
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
                problems.append(ActivityProblem(message: UserMessages.describe(error, file: file), isFailure: true))
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
        } else if succeeded == 0, failed > 0 {
            status = .failed
        } else {
            status = problems.isEmpty ? .done : .problems
        }
        self.problems = problems
        self.warnings = warnings
        self.skipped = skipped
        details = BatchSummary(outcome).details
        hasHistory = outcome.record != nil
    }

    var notices: [ActivityProblem] { problems + warnings.map(\.summary) }
    var hasCondensedWarnings: Bool { warnings.contains { $0.count > 1 } }

    var statusText: String {
        switch status {
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

private struct ActivityView: View {
    let log: ActivityLog
    let jobs: JobCenter

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
                    ActivityRowView(row: row, running: jobs.active.first { $0.id == row.id }, jobs: jobs)
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
        let pausesExtraction = batch.operation == .archiveHatchExtract
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

    @ViewBuilder private func fileStatus(_ outcome: ItemOutcome, file: String) -> some View {
        switch outcome {
        case .succeeded:
            if [OperationID.imageCompress, .videoCompress, .audioCompress, .pdfCompress].contains(row.operation) {
                Text("Compression complete.").foregroundStyle(.secondary)
            } else if [OperationID.imageConvert, .videoConvert, .audioConvert].contains(row.operation) {
                Text("Conversion complete.").foregroundStyle(.secondary)
            } else {
                Text("Done.").foregroundStyle(.secondary)
            }
        case .skipped(let reason): Text(UserMessages.describe(reason, file: file)).foregroundStyle(.secondary)
        case .failed(let error):
            Text(UserMessages.describe(error, file: file))
                .foregroundStyle(error == .cancelled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
        }
    }

    private func fileResult(_ session: ActivitySession, index: Int) -> some View {
        let outcome = session.outcome
        let details = outcome.details[index]
        return VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: outcome.inputs[index].first?.lastPathComponent ?? "")
                .lineLimit(1).truncationMode(.middle)
            fileStatus(outcome.outcomes[index], file: outcome.inputs[index].first?.lastPathComponent ?? "")
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
        VStack(alignment: .leading, spacing: Self.lineSpacing) {
            title
            Text(result.statusText)
                .font(.subheadline)
                .foregroundStyle(result.status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
        .accessibilityElement(children: .combine)
        ForEach(Array(result.notices.prefix(Self.visibleNotices).enumerated()), id: \.offset) { _, problem in
            Label {
                Text(problem.message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: problem.isFailure ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(problem.isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            .font(.callout)
        }
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
            if result.notices.count > Self.visibleNotices || result.hasCondensedWarnings {
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
