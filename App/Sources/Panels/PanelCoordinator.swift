import AppKit
import Engine
import Foundation
import MenuCatalog
import SwiftUI
import UniformTypeIdentifiers
import os

@MainActor
final class PanelCoordinator {
    private let host = PanelHost()
    private let jobs: JobCenter
    private let store: SettingsStore
    private let logger = Logger(category: "panels")

    init(jobs: JobCenter, store: SettingsStore) {
        self.jobs = jobs
        self.store = store
    }

    func present(_ entry: MenuEntry, inputs: [URL]) {
        let op = entry.op
        let inputs = inputs.filter { url in
            let kind = FileKind(fileURL: url)
            return op.kind == .any ? kind != .folder : kind == op.kind
        }
        guard !inputs.isEmpty else {
            logger.error("No \(op.kind.rawValue, privacy: .public) inputs for \(op.rawValue, privacy: .public)")
            return
        }
        guard inputs.count >= op.minimumSelection,
            op.maximumSelection.map({ inputs.count <= $0 }) ?? true,
            entry.preset != "choose-frame" || inputs.count == 1
        else {
            logger.error("Invalid selection count for \(op.rawValue, privacy: .public)")
            return
        }
        switch op {
        case .imageResize, .videoResize: showSize(op, inputs)
        case .imageCompress, .videoCompress, .audioCompress: showTargetSize(op, inputs)
        case .videoTrim, .audioTrim: presentTrim(op, file: inputs[0], prefill: nil)
        case .videoThumbnail where entry.preset == "choose-frame": showFramePicker(op, file: inputs[0])
        case .imageToPDF, .pdfMerge: showPageOrder(op, inputs)
        case .pdfExtractPages: showPageSelect(op, file: inputs[0])
        case .folderRename: showRename(op, inputs)
        case .imageAIRename, .pdfAIRename, .folderAIRename: showAIRename(op, inputs)
        case .folderRemoveDuplicates: showDuplicates(op, inputs)
        case .folderRemoveEmpty: showEmptyFolders(op, inputs)
        case .folderAnalyze: showAnalysis(op, inputs)
        case .imageAICustom, .videoAICustom, .audioAICustom: showCustomAI(op, inputs)
        default:
            logger.error("No panel for \(op.rawValue, privacy: .public)")
        }
    }

    func presentReport(_ text: String, operation op: OperationID) {
        host.show(title: MenuStrings.operationName(op)) { close in
            TextResultPanel(text: text, close: close) {
                self.saveReport(text, suggestedName: "\(MenuStrings.operationName(op)).txt", operation: op)
            }
        }
    }

    private func saveReport(
        _ text: String, suggestedName: String, operation: OperationID, contentType: UTType = .plainText
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [contentType]
        panel.message = String(
            localized: "Existing files are kept. If the name is taken, a numbered name is used.",
            comment: "Explains collision-safe report saving")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            let outcome = await jobs.engine.saveReport(text, to: destination, operation: operation)
            await jobs.refreshRecent()
            var messages: [String] = []
            for result in outcome.outcomes {
                switch result {
                case .succeeded(let outputs, _):
                    for output in outputs where output.lastPathComponent != destination.lastPathComponent {
                        messages.append(
                            String(
                                localized: "Saved as “\(output.lastPathComponent)”.",
                                comment: "Reports final saved name"))
                    }
                case .failed(let error):
                    messages.append(UserMessages.describe(error, file: destination.lastPathComponent))
                case .skipped(let reason):
                    messages.append(UserMessages.describe(reason, file: destination.lastPathComponent))
                }
            }
            if outcome.historyFailed {
                messages.append(
                    String(
                        localized: "Undo is unavailable because the history could not be saved.",
                        comment: "Explains missing undo history"))
            }
            guard !messages.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = MenuStrings.operationName(operation)
            alert.informativeText = messages.joined(separator: "\n")
            alert.runModal()
        }
    }

    /// Engine answers that need the user first.
    func askAgain(_ request: OperationRequest, files: [URL], reason: InvalidInput) -> Bool {
        switch (request.options, reason) {
        case (.archive, .passwordRequired), (.archive, .wrongPassword):
            showPassword(request.op, files, wasWrong: reason == .wrongPassword)
        case (.text(.encoding(let target, _)), .textEncodingUndetected):
            files.forEach { file in
                showEncoding(request.op, file: file) { .encoding(target, source: $0) }
            }
        case (.text(.convert(let conversion, _)), .textEncodingUndetected):
            files.forEach { file in
                showEncoding(request.op, file: file) { .convert(conversion, source: $0) }
            }
        case (.video(.compress), .tooLong(let limit)):
            let prefill = 0...max(limit - Self.trimHeadroomSeconds, 0)
            files.forEach {
                presentTrim(.videoTrim, file: $0, prefill: prefill, then: (request.op, request.options))
            }
        default:
            return false
        }
        return true
    }

    /// Trims can overshoot the end slightly.
    private static let trimHeadroomSeconds = 1.0

    /// `next` runs on the trimmed file.
    func presentTrim(
        _ op: OperationID, file: URL, prefill: ClosedRange<Double>?,
        then next: (op: OperationID, options: OperationOptions)? = nil
    ) {
        let isVideo = op == .videoTrim
        let mode = PanelMemory.value(for: op, default: store.settings.video.trimMode)
        host.show(title: MenuStrings.operationName(op)) { close in
            TrimPanel(url: file, isVideo: isVideo, prefill: prefill, mode: mode, close: close) { start, end, mode in
                PanelMemory.remember(mode, for: op)
                close()
                let options: OperationOptions =
                    isVideo ? .video(.trim(start: start, end: end, mode: mode)) : .audio(.trim(start: start, end: end))
                let trim = self.jobs.run(OperationRequest(op: op, options: options, inputs: [file]))
                guard let next else { return }
                Task {
                    guard let outcome = await trim.value, !outcome.wasCancelled else { return }
                    let trimmed = Self.continuing(outcome)
                    if !trimmed.isEmpty { self.launch(next.op, next.options, trimmed) }
                }
            }
        }
    }

    private func launch(_ op: OperationID, _ options: OperationOptions, _ inputs: [URL]) {
        jobs.run(OperationRequest(op: op, options: options, inputs: inputs))
    }

    private func finish<Choice: Codable>(
        _ op: OperationID, _ choice: Choice, _ options: OperationOptions, _ inputs: [URL], close: () -> Void
    ) {
        PanelMemory.remember(choice, for: op)
        close()
        launch(op, options, inputs)
    }

    private func showSize(_ op: OperationID, _ inputs: [URL]) {
        let isVideo = op == .videoResize
        let choice = PanelMemory.value(for: op, default: SizeChoice())
        host.show(title: MenuStrings.operationName(op)) { close in
            SizePanel(isVideo: isVideo, firstFile: inputs[0], choice: choice, cancel: close) { choice in
                guard let options = choice.options(isVideo: isVideo) else { return }
                self.finish(op, choice, options, inputs, close: close)
            }
        }
    }

    private func showTargetSize(_ op: OperationID, _ inputs: [URL]) {
        let choice = PanelMemory.value(for: op, default: TargetSizeChoice())
        let settings = store.settings
        host.show(title: MenuStrings.operationName(op)) { close in
            TargetSizePanel(op: op, inputs: inputs, settings: settings, choice: choice, cancel: close) {
                choice, options in
                self.finish(op, choice, options, inputs, close: close)
            }
        }
    }

    private func showFramePicker(_ op: OperationID, file: URL) {
        host.show(title: MenuStrings.operationName(op)) { close in
            FramePickerPanel(url: file, close: close) { seconds in
                close()
                self.launch(op, .video(.still(.at(seconds: seconds))), [file])
            }
        }
    }

    private func showPageOrder(_ op: OperationID, _ inputs: [URL]) {
        let isPDF = op == .pdfMerge
        let sorted = inputs.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        Task {
            let entries: [PageEntry]
            do {
                entries = try await offMain { try PageEntry.entries(for: sorted, splitsPages: isPDF) }
            } catch {
                showFailure(op, error, file: sorted[0])
                return
            }
            let actionTitle =
                isPDF
                ? String(localized: "Merge", comment: "Page order action for PDFs")
                : String(localized: "Create PDF", comment: "Page order action for images")
            host.show(title: MenuStrings.operationName(op)) { close in
                PageOrderPanel(actionTitle: actionTitle, pages: entries, cancel: close) { pages in
                    close()
                    var files: [URL] = []
                    for page in pages where !files.contains(page.file) { files.append(page.file) }
                    guard isPDF else { return self.launch(op, .image(.toPDF), files) }
                    let references = pages.compactMap { page in
                        page.pageIndex.map { PDFPageReference(file: page.file, pageIndex: $0) }
                    }
                    self.launch(op, .pdf(.merge(pages: references)), files)
                }
            }
        }
    }

    private func showPageSelect(_ op: OperationID, file: URL) {
        Task {
            let entries: [PageEntry]
            do {
                entries = try await offMain { try PageEntry.entries(for: [file], splitsPages: true) }
            } catch {
                showFailure(op, error, file: file)
                return
            }
            host.show(title: MenuStrings.operationName(op)) { close in
                PageSelectPanel(pages: entries, cancel: close) { pages in
                    close()
                    self.launch(op, .pdf(.extractPages(pages)), [file])
                }
            }
        }
    }

    private func showRename(_ op: OperationID, _ inputs: [URL]) {
        let choice = PanelMemory.value(for: op, default: RenameChoice(settings: store.settings.folder))
        host.show(title: MenuStrings.operationName(op)) { close in
            RenamePanel(selection: inputs, choice: choice, cancel: close) { choice in
                self.finish(op, choice, .folder(.rename(choice.rules)), inputs, close: close)
            }
        }
    }

    private func showAIRename(_ op: OperationID, _ inputs: [URL]) {
        Task {
            let files: [URL]
            do {
                files =
                    op == .folderAIRename
                    ? try await offMain { try inputs.flatMap(AINaming.candidates(in:)) } : inputs
            } catch {
                showFailure(op, error, file: inputs[0])
                return
            }
            host.show(title: MenuStrings.operationName(op)) { close in
                AIRenamePanel(files: files, cancel: close) { plans in
                    close()
                    self.launch(op, .rename(plans), plans.map(\.url))
                }
            }
        }
    }

    /// Scans show in Activity, not a panel.
    private func scan<Result: Sendable>(
        _ op: OperationID, _ folders: [URL],
        _ work: @escaping @Sendable (_ progress: @escaping @Sendable (Double) -> Void) throws -> Result,
        then present: @escaping (Result) -> Void
    ) {
        Task {
            do {
                present(try await jobs.scan(op, folders: folders, work))
            } catch is CancellationError {
                return
            } catch {
                showFailure(op, error, file: folders[0])
            }
        }
    }

    private func showDuplicates(_ op: OperationID, _ inputs: [URL]) {
        let settings = store.settings
        scan(op, inputs) { progress in
            try DuplicateScanner.groups(in: inputs, settings: settings.folder, progress: progress)
        } then: { groups in
            self.host.show(title: MenuStrings.operationName(op)) { close in
                DuplicatesPanel(
                    groups: groups, roots: inputs, allowsPermanentDelete: settings.permanentDelete, cancel: close
                ) { removals, permanently in
                    close()
                    self.launch(op, .folder(.removeDuplicates(removals, permanently: permanently)), inputs)
                }
            }
        }
    }

    private func showEmptyFolders(_ op: OperationID, _ inputs: [URL]) {
        let settings = store.settings.folder
        scan(op, inputs) { progress in
            try EmptyFolderScanner.folders(in: inputs, settings: settings, progress: progress)
        } then: { folders in
            guard !folders.isEmpty else {
                self.host.show(title: MenuStrings.operationName(op)) { close in
                    NothingFound(
                        message: String(localized: "No empty folders found.", comment: "Empty folders panel"),
                        close: close)
                }
                return
            }
            guard let permanently = self.confirmEmptyRemoval(folders, roots: inputs) else { return }
            self.launch(op, .folder(.removeEmpty(folders, permanently: permanently)), inputs)
        }
    }

    private static let listedEmptyFolders = 12

    /// `nil` when cancelled.
    private func confirmEmptyRemoval(_ folders: [URL], roots: [URL]) -> Bool? {
        let listed = folders.prefix(Self.listedEmptyFolders).map { relativePath($0, roots: roots) }
        var lines = listed
        if folders.count > listed.count {
            lines.append(
                String(
                    localized: "…and \(folders.count - listed.count) more",
                    comment: "Remaining count after the listed empty folders"))
        }
        let alert = NSAlert()
        alert.messageText = String(
            AttributedString(
                localized: "Move ^[\(folders.count) empty folder](inflect: true) to the Trash?",
                comment: "Remove Empty Folders confirmation"
            ).characters)
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "Move to Trash", comment: "Empty folders panel action"))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Panel button"))
        if store.settings.permanentDelete {
            alert.addButton(withTitle: String(localized: "Delete Permanently…")).hasDestructiveAction = true
        }
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return false
        case .alertThirdButtonReturn: return confirmPermanentDelete(folders.count) ? true : nil
        default: return nil
        }
    }

    private func confirmPermanentDelete(_ count: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Delete \(count) folders permanently?")
        alert.informativeText = String(localized: "Permanently deleted folders cannot be restored.")
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Panel button"))
        alert.addButton(withTitle: String(localized: "Delete Permanently")).hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func showAnalysis(_ op: OperationID, _ folders: [URL]) {
        let settings = store.settings.folder
        scan(op, folders) { progress in
            try FolderAnalysis.scan(folders, settings: settings, progress: progress)
        } then: { analysis in
            let names = analysis.roots.map(\.requested.lastPathComponent).formatted(.list(type: .and))
            self.host.show(title: "\(MenuStrings.operationName(op)): \(names)") { close in
                AnalyzePanel(analysis: analysis, format: settings.analysisExportFormat, close: close) { format in
                    self.export(analysis, as: format, operation: op)
                }
            }
        }
    }

    private func export(_ analysis: FolderAnalysis, as format: AnalysisExportFormat, operation op: OperationID) {
        let report: String
        do {
            report = try analysis.serialized(as: format)
        } catch {
            showFailure(op, error, file: analysis.folder)
            return
        }
        guard let contentType = UTType(filenameExtension: format.pathExtension, conformingTo: .text) else {
            showFailure(op, EngineError.commitFailed("\(format.rawValue) type unavailable"), file: analysis.folder)
            return
        }
        saveReport(
            report, suggestedName: "\(analysis.folder.lastPathComponent) analysis.\(format.pathExtension)",
            operation: op, contentType: contentType)
    }

    private func showCustomAI(_ op: OperationID, _ inputs: [URL]) {
        let settings = store.settings
        let prompt = PanelMemory.value(for: op, default: "")
        let isRunnable = { (step: CustomStep) in
            OperationPlanner.options(for: step.operation, preset: step.preset, settings: settings) != nil
        }
        host.show(title: MenuStrings.operationName(op)) { close in
            CustomAIPanel(kind: op.kind, prompt: prompt, isRunnable: isRunnable, cancel: close) { prompt, steps in
                PanelMemory.remember(prompt, for: op)
                close()
                Task { await self.runInOrder(steps, inputs: inputs) }
            }
        }
    }

    /// Each step consumes the previous results.
    private func runInOrder(_ steps: [CustomStep], inputs: [URL]) async {
        var current = inputs
        for step in steps {
            guard
                let options = OperationPlanner.options(
                    for: step.operation, preset: step.preset, settings: store.settings),
                let outcome = await jobs.run(OperationRequest(op: step.operation, options: options, inputs: current))
                    .value
            else {
                logger.error("Plan stopped before \(step.operation.rawValue, privacy: .public)")
                return
            }
            current = Self.continuing(outcome)
            if current.isEmpty || outcome.wasCancelled { return }
        }
    }

    /// Files the next chained step consumes.
    private static func continuing(_ outcome: BatchOutcome) -> [URL] {
        zip(outcome.inputs, outcome.outcomes).flatMap { inputs, result -> [URL] in
            switch result {
            case .succeeded(let outputs, _): outputs
            case .skipped: inputs
            case .failed: []
            }
        }
    }

    private func showPassword(_ op: OperationID, _ archives: [URL], wasWrong: Bool) {
        host.show(title: MenuStrings.operationName(op)) { close in
            PasswordPanel(archives: archives, wasWrong: wasWrong, cancel: close) { password, forAll in
                close()
                let now = forAll ? archives : [archives[0]]
                self.launch(op, .archive(.extract(password: password)), now)
                let later = Array(archives.dropFirst(now.count))
                if !later.isEmpty { self.showPassword(op, later, wasWrong: false) }
            }
        }
    }

    private func showEncoding(
        _ op: OperationID, file: URL, operation: @escaping (SourceTextEncoding) -> TextOperation
    ) {
        let encoding = PanelMemory.value(for: op, default: SourceTextEncoding.cp932)
        host.show(title: MenuStrings.operationName(op)) { close in
            EncodingPanel(file: file, encoding: encoding, cancel: close) { source in
                self.finish(op, source, .text(operation(source)), [file], close: close)
            }
        }
    }

    private func showFailure(_ op: OperationID, _ error: any Error, file: URL) {
        showFailure(
            op,
            message: UserMessages.describe(
                EngineError.wrapping(error, path: file.path), file: file.lastPathComponent))
    }

    func showFailure(_ op: OperationID, message: String) {
        host.show(title: MenuStrings.operationName(op)) { close in PanelFailure(message: message, close: close) }
    }
}
