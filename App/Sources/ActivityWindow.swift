import AppKit
import Engine
import MenuCatalog
import Observation
import SwiftUI

/// Never activates MacEase, so Finder keeps focus.
@MainActor
final class ActivityWindow: NSObject, NSWindowDelegate {
    private static let appearanceDelay: TimeInterval = 0.8
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
        let result = ActivityResult(outcome)
        // Hidden rows defer to the banner.
        guard panel?.isVisible == true else {
            log.rows.remove(at: index)
            return false
        }
        let operation = MenuStrings.operationName(batch.operation)
        AccessibilityNotification.Announcement(
            String(localized: "\(operation): \(result.statusText)", comment: "VoiceOver batch completion")
        ).post()
        guard !closesAutomatically(result) else {
            log.rows.remove(at: index)
            hideIfEmpty()
            return false
        }
        log.rows[index].result = result
        return true
    }

    func show() {
        guard !log.rows.isEmpty else { return }
        for index in log.rows.indices { log.rows[index].dismissed = false }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        log.rows.removeAll { $0.result != nil }
        for index in log.rows.indices { log.rows[index].dismissed = true }
        sender.orderOut(nil)
        return false
    }

    private func revealIfStillRunning(_ id: UUID) {
        guard settings.showsActivity, jobs.active.contains(where: { $0.id == id }),
            log.rows.contains(where: { $0.id == id && !$0.dismissed })
        else { return }
        show()
    }

    private func closesAutomatically(_ result: ActivityResult) -> Bool {
        switch result.status {
        case .done: settings.activityClosesAfterSuccess
        case .cancelled: settings.activityClosesAfterCancel
        case .failed: settings.activityClosesAfterFailure
        case .problems: result.problems.contains(where: \.isFailure) && settings.activityClosesAfterFailure
        }
    }

    private func hideIfEmpty() {
        if log.rows.isEmpty { panel?.orderOut(nil) }
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

private struct ActivityResult {
    enum Status {
        case done
        case problems
        case cancelled
        case failed
    }

    let status: Status
    let problems: [ActivityProblem]
    let details: String
    let hasHistory: Bool

    init(_ outcome: BatchOutcome) {
        var problems: [ActivityProblem] = []
        var succeeded = 0
        var failed = 0
        for (result, inputs) in zip(outcome.outcomes, outcome.inputs) {
            let file = inputs.first?.lastPathComponent ?? ""
            switch result {
            case .succeeded(_, let warnings):
                succeeded += 1
                problems += warnings.map { warning in
                    ActivityProblem(
                        message: String(
                            localized: "“\(file)”: \(UserMessages.describe(warning))",
                            comment: "File warning in batch results"),
                        isFailure: false)
                }
            case .skipped(let reason):
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
        details = BatchSummary(outcome).details
        hasHistory = outcome.record != nil
    }

    var statusText: String {
        switch status {
        case .done: String(localized: "Done.", comment: "Activity status")
        case .cancelled: String(localized: "Cancelled.", comment: "Activity status")
        case .failed: String(localized: "Failed.", comment: "Activity status")
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
                ForEach(Array(log.rows.enumerated()), id: \.element.id) { position, row in
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
    private static let visibleProblems = 5

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
        HStack(spacing: Self.lineSpacing * 2) {
            VStack(alignment: .leading, spacing: Self.lineSpacing) {
                title
                ProgressView(value: batch.progress)
                Text(runningStatus(batch))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            Button {
                jobs.cancel(batch.id)
            } label: {
                Label(String(localized: "Stop", comment: "Activity button"), systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Stop", comment: "Activity button"))
            .accessibilityLabel(Text("Stop \(operationName)", comment: "Activity stop button for VoiceOver"))
        }
    }

    private func runningStatus(_ batch: JobCenter.ActiveBatch) -> String {
        let file = batch.currentFileName ?? batch.fileNames.first ?? ""
        guard batch.itemCount > 1 else { return file }
        return String(
            localized: "\(batch.completedItems) of \(batch.itemCount) — \(file)",
            comment: "Activity progress: done, total, current file")
    }

    @ViewBuilder private func finished(_ result: ActivityResult) -> some View {
        VStack(alignment: .leading, spacing: Self.lineSpacing) {
            title
            Text(result.statusText)
                .font(.subheadline)
                .foregroundStyle(result.status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
        .accessibilityElement(children: .combine)
        ForEach(Array(result.problems.prefix(Self.visibleProblems).enumerated()), id: \.offset) { _, problem in
            Label {
                Text(problem.message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: problem.isFailure ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(problem.isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            .font(.callout)
        }
        HStack {
            if result.problems.count > Self.visibleProblems {
                Button(String(localized: "Show All Problems…", comment: "Activity button")) {
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
