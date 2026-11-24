import AppKit
import Engine
import MenuCatalog

@MainActor
final class FinderCommands {
    enum Failure: LocalizedError {
        case invalidSelection, invalidFolder, invalidTemplate, pasteboardWrite
        case missingTerminal(URL)

        var errorDescription: String? {
            switch self {
            case .invalidSelection: String(localized: "Select a file or folder and try again.")
            case .invalidFolder: String(localized: "Choose an existing folder and try again.")
            case .invalidTemplate: String(localized: "This New File template is no longer enabled.")
            case .pasteboardWrite: String(localized: "The clipboard could not be updated. Try again.")
            case .missingTerminal(let application):
                String(
                    localized:
                        "The terminal application at \(application.path) is unavailable. Choose another application in Settings."
                )
            }
        }
    }

    private static let pasteboardCheckInterval: TimeInterval = 0.5
    private let jobs: JobCenter
    private let settings: SettingsStore
    private let pasteboard: NSPasteboard
    private let reveal: ([URL]) -> Void
    private let openTerminal: (URL, URL) async throws -> Void
    private var cutItems: [MoveItem] = []
    private var cutChangeCount: Int?
    private var cutRevision = UUID()
    private var moving = false
    private var terminated = false
    private var pasteboardTimer: Timer?
    var onCutChange: (() -> Void)?

    init(
        jobs: JobCenter, settings: SettingsStore, pasteboard: NSPasteboard = .general,
        reveal: @escaping ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) },
        openTerminal: @escaping (URL, URL) async throws -> Void = { folder, application in
            _ = try await NSWorkspace.shared.open(
                [folder], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
        }
    ) {
        self.jobs = jobs
        self.settings = settings
        self.pasteboard = pasteboard
        self.reveal = reveal
        self.openTerminal = openTerminal
    }

    var cutCount: Int {
        !moving && cutChangeCount == pasteboard.changeCount ? cutItems.count : 0
    }

    func checkPasteboard() {
        if let cutChangeCount, cutChangeCount != pasteboard.changeCount { clearCut() }
    }

    func clearCut() {
        let hadCut = !cutItems.isEmpty
        cutItems = []
        cutChangeCount = nil
        cutRevision = UUID()
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
        if hadCut { onCutChange?() }
    }

    func prepareForTermination() {
        terminated = true
        clearCut()
    }

    @discardableResult
    func execute(_ request: HostCommandRequest) async throws -> BatchOutcome? {
        guard !terminated else { return nil }
        let selection = try request.paths.map { path -> URL in
            guard path.hasPrefix("/"), !path.contains("\u{0}") else { throw Failure.invalidSelection }
            return URL(fileURLWithPath: path)
        }
        guard !selection.isEmpty else { throw Failure.invalidSelection }
        switch request.action.command {
        case .newFile:
            return try await createFile(request.action.preset, in: selection)
        case .cut:
            try cut(selection)
        case .moveHere:
            return try await move(to: selection)
        case .copyPath:
            guard let preset = request.action.preset, let format = PathFormat(rawValue: preset) else {
                throw Failure.invalidSelection
            }
            pasteboard.clearContents()
            guard pasteboard.setString(FinderPaths.copyText(for: selection, format: format), forType: .string) else {
                throw Failure.pasteboardWrite
            }
            checkPasteboard()
        case .openTerminal:
            try await openTerminal(for: selection)
        case .update, .preview:
            throw Failure.invalidSelection
        }
        return nil
    }

    private func folder(_ selection: [URL]) throws -> URL {
        guard selection.count == 1, let selected = selection.first else { throw Failure.invalidFolder }
        let attributes = try selected.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let directory = URL(fileURLWithPath: selected.path, isDirectory: true)
        guard attributes.isDirectory == true, attributes.isPackage != true, FileKind(fileURL: directory) == .folder
        else { throw Failure.invalidFolder }
        return directory
    }

    private func createFile(_ preset: String?, in selection: [URL]) async throws -> BatchOutcome? {
        let destination = try folder(selection)
        guard let preset, let kind = NewFileTemplate.BuiltIn(rawValue: preset),
            settings.enabledNewFileTemplates.contains(kind)
        else { throw Failure.invalidTemplate }
        let template = try NewFileTemplate.builtIn(kind, defaultBaseName: String(localized: "Untitled"))
        let outcome = await jobs.run(
            OperationRequest(op: .folderNewFile, options: .folder(.newFile(template)), inputs: [destination])
        ).value
        let outputs =
            outcome?.outcomes.flatMap { result -> [URL] in
                if case .succeeded(let outputs, _) = result { return outputs }
                return []
            } ?? []
        if !outputs.isEmpty, !terminated { reveal(outputs) }
        return outcome
    }

    private func cut(_ selection: [URL]) throws {
        clearCut()
        var seen: Set<URL> = []
        let captured = try selection.filter { seen.insert($0.standardizedFileURL).inserted }.map(MoveItem.capture)
        pasteboard.clearContents()
        guard pasteboard.writeObjects(captured.map { $0.url as NSURL }) else { throw Failure.pasteboardWrite }
        cutItems = captured
        cutChangeCount = pasteboard.changeCount
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: Self.pasteboardCheckInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.checkPasteboard() }
        }
        onCutChange?()
    }

    private func move(to selection: [URL]) async throws -> BatchOutcome? {
        let destination = try folder(selection)
        checkPasteboard()
        guard !moving, !cutItems.isEmpty else { throw Failure.invalidSelection }
        let captured = cutItems
        let revision = cutRevision
        moving = true
        onCutChange?()
        defer {
            moving = false
            onCutChange?()
        }
        let plan = MovePlan(items: captured, destination: destination)
        let outcome = await jobs.run(
            OperationRequest(op: .filesMove, options: .move(plan), inputs: captured.map(\.url))
        ).value
        guard cutRevision == revision, let outcome else { return outcome }
        cutItems = zip(captured, outcome.outcomes).compactMap { captured, result in
            switch result {
            case .succeeded(_, let warnings):
                return warnings.contains {
                    if case .copiedAcrossVolumes = $0 { return true }
                    return false
                } ? captured : nil
            case .skipped(.changedSinceScan): return nil
            case .skipped, .failed: return captured
            }
        }
        if cutItems.isEmpty { clearCut() }
        return outcome
    }

    private func openTerminal(for selection: [URL]) async throws {
        guard selection.count == 1, let selected = selection.first else { throw Failure.invalidSelection }
        let attributes = try selected.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let directory = URL(
            fileURLWithPath: selected.path, isDirectory: attributes.isDirectory == true && attributes.isPackage != true)
        guard let folder = FinderPaths.terminalDirectory(for: [directory]) else { throw Failure.invalidSelection }
        let application = settings.terminalApplicationURL
        guard application.isFileURL, let executable = Bundle(url: application)?.executableURL,
            FileManager.default.isExecutableFile(atPath: executable.path)
        else { throw Failure.missingTerminal(application) }
        try await openTerminal(folder, application)
    }
}
