import AppKit
import Darwin
import Engine
import MenuCatalog

@MainActor
final class FinderCommands {
    enum Failure: LocalizedError, Equatable {
        case invalidSelection, invalidFolder, invalidTemplate
        case nothingCut, cutInProgress, moveInProgress, pasteboardWrite
        case missingTerminal(URL)
        case itemFailed(EngineError, file: String)

        var errorDescription: String? {
            switch self {
            case .invalidSelection: String(localized: "Select a file or folder and try again.")
            case .invalidFolder: String(localized: "Choose an existing folder and try again.")
            case .invalidTemplate:
                String(
                    localized:
                        "This New File template is no longer enabled. Enable it in Settings > Finder Menu > New File options."
                )
            case .nothingCut:
                String(localized: "There are no cut items to move. Cut the items again, then choose Move Here.")
            case .cutInProgress:
                String(
                    localized:
                        "Cut is still preparing the selected items. Wait for it to finish, then choose Move Here.")
            case .moveInProgress:
                String(localized: "A move is already in progress. Wait for it to finish, then try again.")
            case .pasteboardWrite: String(localized: "The clipboard could not be updated. Try again.")
            case .missingTerminal(let application):
                String(
                    localized:
                        "The terminal application at \(application.path) is unavailable. Choose another application in Settings."
                )
            case .itemFailed(let error, let file):
                UserMessages.describe(error, file: file)
            }
        }
    }

    private enum CutState {
        case empty
        case capturing(revision: UUID, task: Task<[MoveItem], any Error>, initialChangeCount: Int)
        case ready(revision: UUID, items: [MoveItem], changeCount: Int)
        case moving(revision: UUID, items: [MoveItem], changeCount: Int)
    }

    private static let pasteboardCheckInterval: TimeInterval = 0.5
    private let jobs: JobCenter
    private let settings: SettingsStore
    private let pasteboard: NSPasteboard
    private let reveal: ([URL]) -> Void
    private let openTerminal: (URL, URL) async throws -> Void
    private let captureMoveItems: @Sendable ([URL]) async throws -> [MoveItem]
    private var cutState: CutState = .empty
    private var terminated = false
    private var pasteboardTimer: Timer?
    var onCutChange: (() -> Void)?

    init(
        jobs: JobCenter, settings: SettingsStore, pasteboard: NSPasteboard = .general,
        reveal: @escaping ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) },
        openTerminal: @escaping (URL, URL) async throws -> Void = { folder, application in
            _ = try await NSWorkspace.shared.open(
                [folder], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
        },
        captureMoveItems: @escaping @Sendable ([URL]) async throws -> [MoveItem] = FinderCommands.captureSelection
    ) {
        self.jobs = jobs
        self.settings = settings
        self.pasteboard = pasteboard
        self.reveal = reveal
        self.openTerminal = openTerminal
        self.captureMoveItems = captureMoveItems
    }

    var cutCount: Int {
        guard case .ready(_, let items, let changeCount) = cutState,
            changeCount == pasteboard.changeCount
        else { return 0 }
        return items.count
    }

    func checkPasteboard() {
        switch cutState {
        case .empty: break
        case .capturing(_, _, let changeCount),
            .ready(_, _, let changeCount),
            .moving(_, _, let changeCount):
            if changeCount != pasteboard.changeCount { clearCut() }
        }
    }

    func clearCut() {
        let shouldNotify: Bool
        switch cutState {
        case .empty, .moving:
            shouldNotify = false
        case .capturing(_, let task, _):
            task.cancel()
            shouldNotify = false
        case .ready:
            shouldNotify = true
        }
        cutState = .empty
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
        if shouldNotify { onCutChange?() }
    }

    func prepareForTermination() {
        terminated = true
        clearCut()
    }

    @discardableResult
    func execute(_ request: HostCommandRequest) async throws -> BatchOutcome? {
        guard !terminated else { return nil }
        let selection = try request.paths.map { path -> URL in
            guard let url = RequestPath.fileURL(for: path) else { throw Failure.invalidSelection }
            return url
        }
        guard !selection.isEmpty else { throw Failure.invalidSelection }
        switch request.action.command {
        case .newFile:
            return try await createFile(request.action.preset, in: selection)
        case .cut:
            try await cut(selection)
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

    nonisolated static func describe(_ error: any Error, paths: [String]) -> String {
        if let failure = error as? Failure { return failure.localizedDescription }
        let fallback = paths.first.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/")
        return mapItemError(error, for: fallback).localizedDescription
    }

    private func entryMetadata(of url: URL) throws -> stat {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            throw Self.mapItemError(error, for: url)
        }
        return metadata
    }

    private func validatedFolder(_ selection: [URL]) throws -> URL {
        guard selection.count == 1, let selected = selection.first else { throw Failure.invalidFolder }
        let metadata = try entryMetadata(of: selected)
        guard metadata.st_mode & S_IFMT == S_IFDIR else { throw Failure.invalidFolder }
        let isPackage: Bool
        do {
            isPackage = try selected.resourceValues(forKeys: [.isPackageKey]).isPackage == true
        } catch {
            throw Self.mapItemError(error, for: selected)
        }
        let directory = URL(fileURLWithPath: selected.path, isDirectory: true)
        guard !isPackage, FileKind(fileURL: directory) == .folder else { throw Failure.invalidFolder }
        return directory
    }

    private func createFile(_ preset: String?, in selection: [URL]) async throws -> BatchOutcome? {
        let destination = try validatedFolder(selection)
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

    private func cut(_ selection: [URL]) async throws {
        clearCut()
        var seen: Set<URL> = []
        let unique = selection.filter { seen.insert($0.standardizedFileURL).inserted }
        let revision = UUID()
        let initialChangeCount = pasteboard.changeCount
        let capture = captureMoveItems
        let task = Task.detached(priority: .userInitiated) {
            try await capture(unique)
        }
        cutState = .capturing(revision: revision, task: task, initialChangeCount: initialChangeCount)
        let captured: [MoveItem]
        do {
            captured = try await task.value
        } catch {
            guard !terminated,
                case .capturing(let currentRevision, _, _) = cutState,
                currentRevision == revision
            else { return }
            cutState = .empty
            if error is CancellationError { return }
            throw error
        }
        guard !terminated,
            case .capturing(let currentRevision, _, let startedChangeCount) = cutState,
            currentRevision == revision
        else { return }
        guard pasteboard.changeCount == startedChangeCount else {
            cutState = .empty
            return
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(captured.map { $0.url as NSURL }) else {
            cutState = .empty
            throw Failure.pasteboardWrite
        }
        cutState = .ready(revision: revision, items: captured, changeCount: pasteboard.changeCount)
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: Self.pasteboardCheckInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.checkPasteboard() }
        }
        onCutChange?()
    }

    private func move(to selection: [URL]) async throws -> BatchOutcome? {
        let destination = try validatedFolder(selection)
        checkPasteboard()
        let revision: UUID
        let captured: [MoveItem]
        let originalChangeCount: Int
        switch cutState {
        case .empty:
            throw Failure.nothingCut
        case .capturing:
            throw Failure.cutInProgress
        case .moving:
            throw Failure.moveInProgress
        case .ready(let readyRevision, let items, let changeCount):
            revision = readyRevision
            captured = items
            originalChangeCount = changeCount
        }
        cutState = .moving(revision: revision, items: captured, changeCount: originalChangeCount)
        onCutChange?()
        let plan = MovePlan(items: captured, destination: destination)
        let outcome = await jobs.run(
            OperationRequest(op: .filesMove, options: .move(plan), inputs: captured.map(\.url))
        ).value
        guard !terminated,
            case .moving(let currentRevision, _, let trackedChangeCount) = cutState,
            currentRevision == revision
        else { return outcome }
        guard let outcome else {
            if pasteboard.changeCount == trackedChangeCount {
                cutState = .ready(revision: revision, items: captured, changeCount: trackedChangeCount)
                onCutChange?()
            } else {
                clearCut()
            }
            return nil
        }
        let remaining = zip(captured, outcome.outcomes).compactMap { entry, result -> MoveItem? in
            switch result {
            case .succeeded(_, let warnings):
                return warnings.contains {
                    if case .copiedAcrossVolumes = $0 { return true }
                    return false
                } ? entry : nil
            case .skipped(.changedSinceScan): return nil
            case .skipped, .failed: return entry
            }
        }
        let ownsPasteboard = pasteboard.changeCount == trackedChangeCount
        if remaining.isEmpty {
            if ownsPasteboard { pasteboard.clearContents() }
            clearCut()
            onCutChange?()
            return outcome
        }
        guard ownsPasteboard else {
            clearCut()
            return outcome
        }
        if remaining.count == captured.count {
            cutState = .ready(revision: revision, items: remaining, changeCount: trackedChangeCount)
            onCutChange?()
            return outcome
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(remaining.map { $0.url as NSURL }) else {
            clearCut()
            throw Failure.pasteboardWrite
        }
        cutState = .ready(revision: revision, items: remaining, changeCount: pasteboard.changeCount)
        onCutChange?()
        return outcome
    }

    private func openTerminal(for selection: [URL]) async throws {
        guard selection.count == 1, let selected = selection.first else { throw Failure.invalidSelection }
        let metadata = try entryMetadata(of: selected)
        let isDirectory = metadata.st_mode & S_IFMT == S_IFDIR
        let isPackage: Bool
        if isDirectory {
            do {
                isPackage = try selected.resourceValues(forKeys: [.isPackageKey]).isPackage == true
            } catch {
                throw Self.mapItemError(error, for: selected)
            }
        } else {
            isPackage = false
        }
        let directory = URL(fileURLWithPath: selected.path, isDirectory: isDirectory && !isPackage)
        guard let folder = FinderPaths.terminalDirectory(for: [directory]) else { throw Failure.invalidSelection }
        let application = settings.terminalApplicationURL
        guard application.isFileURL, let executable = Bundle(url: application)?.executableURL,
            FileManager.default.isExecutableFile(atPath: executable.path)
        else { throw Failure.missingTerminal(application) }
        do {
            try await openTerminal(folder, application)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Self.mapItemError(error, for: folder)
        }
    }

    private nonisolated static func captureSelection(_ urls: [URL]) async throws -> [MoveItem] {
        try urls.map { url in
            try Task.checkCancellation()
            do {
                return try MoveItem.capture(url)
            } catch let error as CancellationError {
                throw error
            } catch {
                throw mapItemError(error, for: url)
            }
        }
    }

    private nonisolated static func mapItemError(_ error: any Error, for url: URL) -> Failure {
        if let failure = error as? Failure { return failure }
        if isMissingFileError(error as NSError) {
            return .itemFailed(.retryInputMissing, file: url.lastPathComponent)
        }
        return .itemFailed(EngineError.wrapping(error, path: url.path), file: url.lastPathComponent)
    }

    private nonisolated static func isMissingFileError(_ error: NSError) -> Bool {
        let missing: Bool =
            switch error.domain {
            case NSCocoaErrorDomain:
                error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
            case NSPOSIXErrorDomain:
                error.code == Int(ENOENT)
            default:
                false
            }
        if missing { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isMissingFileError) ?? false
    }
}
