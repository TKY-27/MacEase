import Engine
import Foundation
import MenuCatalog
import SwiftUI
import os

@MainActor
final class PanelCoordinator {
    private let host = PanelHost()
    private let jobs: JobCenter
    private let store: SettingsStore
    private let supportDirectory: URL
    private let logger = Logger(category: "panels")

    init(jobs: JobCenter, store: SettingsStore, supportDirectory: URL) {
        self.jobs = jobs
        self.store = store
        self.supportDirectory = supportDirectory
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
        switch op {
        case .imageResize, .videoResize: showSize(op, inputs)
        case .imageCompress: showTargetSize(op, inputs, family: .image)
        case .audioCompress: showTargetSize(op, inputs, family: .audio)
        case .imageRotate, .videoRotate: showAngle(op, inputs)
        case .videoTrim, .audioTrim: inputs.forEach { presentTrim(op, file: $0, prefill: nil) }
        case .videoThumbnail: inputs.forEach { showFramePicker(op, file: $0) }
        case .videoToGIF, .videoToAPNG: showAnimation(op, inputs)
        case .imageBackground: showBackground(op, inputs)
        case .imageToPDF, .pdfMerge: showPageOrder(op, inputs)
        case .pdfExtractPages: inputs.forEach { showPageSelect(op, file: $0) }
        case .folderRename: showRename(op, inputs)
        case .imageAIRename, .pdfAIRename, .folderAIRename: showAIRename(op, inputs)
        case .folderRemoveDuplicates: showDuplicates(op, inputs)
        case .folderRemoveEmpty: showEmptyFolders(op, inputs)
        case .folderAnalyze: inputs.forEach { showAnalysis(op, folder: $0) }
        case .imageAICustom, .videoAICustom, .audioAICustom: showCustomAI(op, inputs)
        default:
            if !showOptions(op, inputs) { logger.error("No panel for \(op.rawValue, privacy: .public)") }
        }
    }

    func presentReport(_ text: String, operation op: OperationID) {
        host.show(title: Self.title(op)) { close in
            TextResultPanel(text: text, suggestedName: "\(Self.title(op)).txt", close: close)
        }
    }

    /// Engine answers that need the user first.
    func askAgain(_ request: OperationRequest, files: [URL], reason: InvalidInput) -> Bool {
        switch (request.options, reason) {
        case (.archive, .passwordRequired), (.archive, .wrongPassword):
            showPassword(request.op, files, wasWrong: reason == .wrongPassword)
        case (.text(.encoding(let target, _)), .textEncodingUndetected):
            files.forEach { showEncoding(request.op, file: $0, target: target) }
        default:
            return false
        }
        return true
    }

    /// Public for LINE's over-limit videos.
    func presentTrim(_ op: OperationID, file: URL, prefill: ClosedRange<Double>?) {
        let isVideo = op == .videoTrim
        let mode = PanelMemory.value(for: op, default: store.settings.video.trimMode)
        host.show(title: Self.title(op)) { close in
            TrimPanel(url: file, isVideo: isVideo, prefill: prefill, mode: mode, close: close) { start, end, mode in
                PanelMemory.remember(mode, for: op)
                close()
                let options: OperationOptions =
                    isVideo ? .video(.trim(start: start, end: end, mode: mode)) : .audio(.trim(start: start, end: end))
                self.launch(op, options, [file])
            }
        }
    }

    /// Menu titles end with an ellipsis.
    private static func title(_ op: OperationID) -> String {
        let title = MenuStrings.operation(op)
        for ellipsis in ["…", "..."] where title.hasSuffix(ellipsis) { return String(title.dropLast(ellipsis.count)) }
        return title
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
        host.show(title: Self.title(op)) { close in
            SizePanel(isVideo: isVideo, firstFile: inputs[0], choice: choice, cancel: close) { choice in
                let options: OperationOptions =
                    isVideo ? .video(.resize(choice.videoResize)) : .image(.resize(choice.imageResize))
                self.finish(op, choice, options, inputs, close: close)
            }
        }
    }

    private func showTargetSize(_ op: OperationID, _ inputs: [URL], family: TargetSizeFamily) {
        let presets: [PlatformPreset]
        do {
            presets = try PresetLibrary(supportDirectory: supportDirectory).presets().filter {
                family.limits($0) != nil
            }
        } catch {
            logger.error("Presets unreadable: \(error.localizedDescription, privacy: .public)")
            presets = []
        }
        let choice = PanelMemory.value(for: op, default: TargetSizeChoice())
        host.show(title: Self.title(op)) { close in
            TargetSizePanel(family: family, presets: presets, choice: choice, cancel: close) { choice, options in
                self.finish(op, choice, options, inputs, close: close)
            }
        }
    }

    private func showAngle(_ op: OperationID, _ inputs: [URL]) {
        let isVideo = op == .videoRotate
        let choice = PanelMemory.value(for: op, default: AngleChoice(fill: store.settings.video.rotationFill))
        host.show(title: Self.title(op)) { close in
            AnglePanel(offersTransparency: !isVideo, choice: choice, cancel: close) { choice in
                let options: OperationOptions =
                    isVideo
                    ? .video(.rotate(degrees: Self.positiveDegrees(choice.degrees), fill: choice.fill))
                    : .image(.rotate(degrees: choice.degrees, fill: choice.fillsTransparent ? nil : choice.fill))
                self.finish(op, choice, options, inputs, close: close)
            }
        }
    }

    private static let fullTurn = 360.0

    /// Video presets express left turns as 270.
    private static func positiveDegrees(_ degrees: Double) -> Double {
        (degrees.truncatingRemainder(dividingBy: fullTurn) + fullTurn).truncatingRemainder(dividingBy: fullTurn)
    }

    private func showFramePicker(_ op: OperationID, file: URL) {
        host.show(title: Self.title(op)) { close in
            FramePickerPanel(url: file, close: close) { seconds in
                close()
                self.launch(op, .video(.still(.at(seconds: seconds))), [file])
            }
        }
    }

    private func showAnimation(_ op: OperationID, _ inputs: [URL]) {
        let settings = store.settings
        let defaults = AnimationChoice(
            width: settings.video.gifWidth, framesPerSecond: settings.video.gifFrameRate,
            colors: settings.video.gifColors, dithering: settings.image.gifDithering, loops: settings.video.gifLoops)
        let isGIF = op == .videoToGIF
        let choice = PanelMemory.value(for: op, default: defaults)
        host.show(title: Self.title(op)) { close in
            AnimationPanel(firstFile: inputs[0], isGIF: isGIF, choice: choice, cancel: close) { choice in
                let options: OperationOptions =
                    isGIF ? .video(.gif(choice.rendering)) : .video(.apng(choice.rendering))
                self.finish(op, choice, options, inputs, close: close)
            }
        }
    }

    private func showBackground(_ op: OperationID, _ inputs: [URL]) {
        let image = store.settings.image
        let defaults = BackgroundChoice(
            keyColor: image.colorKey, tolerance: image.colorKeyTolerance, customColor: image.customBackground,
            videoFormat: store.settings.video.transparentFormat)
        let choice = PanelMemory.value(for: op, default: defaults)
        host.show(title: Self.title(op)) { close in
            BackgroundPanel(offersVideoFormat: false, choice: choice, cancel: close) { choice in
                let options = choice.imageOptions(green: image.greenBackground, blue: image.blueBackground)
                self.finish(op, choice, .image(.background(options)), inputs, close: close)
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
            host.show(title: Self.title(op)) { close in
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
            host.show(title: Self.title(op)) { close in
                PageSelectPanel(pages: entries, cancel: close) { pages in
                    close()
                    self.launch(op, .pdf(.extractPages(pages)), [file])
                }
            }
        }
    }

    private func showRename(_ op: OperationID, _ inputs: [URL]) {
        let choice = PanelMemory.value(for: op, default: RenameChoice(settings: store.settings.folder))
        host.show(title: Self.title(op)) { close in
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
            host.show(title: Self.title(op)) { close in
                AIRenamePanel(files: files, cancel: close) { plans in
                    close()
                    self.launch(op, .rename(plans), plans.map(\.url))
                }
            }
        }
    }

    private func showDuplicates(_ op: OperationID, _ inputs: [URL]) {
        let settings = store.settings
        host.show(title: Self.title(op)) { close in
            ScanningPanel(
                title: String(localized: "Looking for duplicates…", comment: "Scan progress"), subject: inputs[0],
                close: close
            ) { progress in
                try DuplicateScanner.groups(in: inputs, settings: settings.folder, progress: progress)
            } content: { groups in
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
        let settings = store.settings
        host.show(title: Self.title(op)) { close in
            ScanningPanel(
                title: String(localized: "Looking for empty folders…", comment: "Scan progress"), subject: inputs[0],
                close: close
            ) { progress in
                try EmptyFolderScanner.folders(in: inputs, settings: settings.folder, progress: progress)
            } content: { folders in
                EmptyFoldersPanel(
                    folders: folders, roots: inputs, allowsPermanentDelete: settings.permanentDelete, cancel: close
                ) { folders, permanently in
                    close()
                    self.launch(op, .folder(.removeEmpty(folders, permanently: permanently)), inputs)
                }
            }
        }
    }

    private func showAnalysis(_ op: OperationID, folder: URL) {
        let settings = store.settings.folder
        host.show(title: "\(Self.title(op)): \(folder.lastPathComponent)") { close in
            ScanningPanel(
                title: String(localized: "Analyzing…", comment: "Scan progress"), subject: folder, close: close
            ) { progress in
                try FolderAnalysis.scan(folder, settings: settings, progress: progress)
            } content: { analysis in
                AnalyzePanel(analysis: analysis, close: close) {
                    close()
                    self.launch(op, .folder(.exportAnalysis(analysis)), [folder])
                }
            }
        }
    }

    private func showCustomAI(_ op: OperationID, _ inputs: [URL]) {
        let settings = store.settings
        let prompt = PanelMemory.value(for: op, default: "")
        let isRunnable = { (step: CustomStep) in
            OperationPlanner.options(for: step.operation, preset: step.preset, settings: settings) != nil
        }
        host.show(title: Self.title(op)) { close in
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
            current = zip(outcome.inputs, outcome.outcomes).flatMap { inputs, result -> [URL] in
                switch result {
                case .succeeded(let outputs, _): outputs
                case .skipped: inputs
                case .failed: []
                }
            }
            if current.isEmpty || outcome.wasCancelled { return }
        }
    }

    private func showPassword(_ op: OperationID, _ archives: [URL], wasWrong: Bool) {
        host.show(title: Self.title(op)) { close in
            PasswordPanel(archives: archives, wasWrong: wasWrong, cancel: close) { password, forAll in
                close()
                let now = forAll ? archives : [archives[0]]
                self.launch(op, .archive(.extract(password: password)), now)
                let later = Array(archives.dropFirst(now.count))
                if !later.isEmpty { self.showPassword(op, later, wasWrong: false) }
            }
        }
    }

    private func showEncoding(_ op: OperationID, file: URL, target: TextEncodingTarget) {
        let encoding = PanelMemory.value(for: op, default: SourceTextEncoding.cp932)
        host.show(title: Self.title(op)) { close in
            EncodingPanel(file: file, encoding: encoding, cancel: close) { source in
                self.finish(op, source, .text(.encoding(target, source: source)), [file], close: close)
            }
        }
    }

    /// Custom… for operations without a dedicated panel.
    private func showOptions(_ op: OperationID, _ inputs: [URL]) -> Bool {
        let settings = store.settings
        var choices = op.presets.map { OptionChoice(id: $0, title: MenuStrings.preset(op, $0)) }
        var number: OptionNumber?
        var build: (String, Int) -> OperationOptions? = { preset, _ in
            OperationPlanner.options(for: op, preset: preset, settings: settings)
        }
        switch op {
        case .anyChecksum:
            choices = ChecksumAlgorithm.allCases.map { OptionChoice(id: $0.rawValue, title: $0.title) }
            build = { id, _ in ChecksumAlgorithm(rawValue: id).map(OperationOptions.checksum) }
        case .videoFPS:
            choices = []
            number = OptionNumber(
                title: String(localized: "Frame rate (fps)"), range: OptionLimits.frameRates,
                initial: OptionLimits.defaultFrameRate)
            build = { _, rate in .video(.frameRate(rate)) }
        case .audioNormalize:
            choices = []
            number = OptionNumber(
                title: String(localized: "Target loudness (LUFS)", comment: "Normalize panel field"),
                range: OptionLimits.loudness, initial: Int(settings.audio.loudnessTarget))
            build = { _, loudness in .audio(.normalize(targetLoudness: Double(loudness))) }
        case .pdfToImages:
            number = OptionNumber(
                title: String(localized: "Resolution (dpi)", comment: "PDF to images panel field"),
                range: OptionLimits.dpi, initial: PDFOperation.defaultDPI)
            build = { id, dpi in StillFormat(rawValue: id).map { .pdf(.toImages($0, dpi: dpi)) } }
        case .imageConvert:
            number = OptionNumber(
                title: String(localized: "Quality", comment: "Convert panel field"), range: OptionLimits.quality,
                initial: settings.image.jpegQuality)
            build = { id, quality in
                ImageFormat(rawValue: id).map { .image(.convert(ImageConversion(format: $0, quality: quality))) }
            }
        default:
            break
        }
        choices = choices.filter { build($0.id, number?.initial ?? 0) != nil }
        guard !choices.isEmpty || number != nil else { return false }
        let remembered = PanelMemory.value(
            for: op, default: OptionMemory(choice: choices.first?.id ?? "", number: number?.initial ?? 0))
        // Presets can disappear between releases.
        let choice = choices.contains { $0.id == remembered.choice } ? remembered.choice : choices.first?.id ?? ""
        let title = Self.title(op)
        host.show(title: title) { close in
            OptionsPanel(
                choiceTitle: title, choices: choices, number: number,
                actionTitle: String(localized: "Run", comment: "Options panel action"),
                selection: choice, value: remembered.number, cancel: close
            ) { choice, value in
                guard let options = build(choice, value) else { return }
                self.finish(op, OptionMemory(choice: choice, number: value), options, inputs, close: close)
            }
        }
        return true
    }

    private func showFailure(_ op: OperationID, _ error: any Error, file: URL) {
        let message = UserMessages.describe(EngineError.wrapping(error, path: file.path), file: file.lastPathComponent)
        host.show(title: Self.title(op)) { close in PanelFailure(message: message, close: close) }
    }
}

private struct OptionMemory: Codable {
    let choice: String
    let number: Int
}

private enum OptionLimits {
    static let frameRates = 1...120
    static let defaultFrameRate = 30
    static let loudness = -40 ... -5
    static let dpi = 36...600
    static let quality = 0...100
}

extension ChecksumAlgorithm {
    fileprivate var title: String {
        switch self {
        case .sha256: "SHA-256"
        case .sha1: "SHA-1"
        case .sha512: "SHA-512"
        case .md5: "MD5"
        }
    }
}
