import AVKit
import AppKit
import Engine
import Formats
import ImageIO
import MenuCatalog
import Observation
import SwiftUI

private enum ArchivePreviewLimit {
    static let fileBytes: Int64 = 256 * 1024 * 1024
    static let textBytes = 8 * 1024 * 1024
    static let rasterSide: CGFloat = 2048
}

private enum ArchiveBrowserPanelError: LocalizedError {
    case treeTooLarge

    var errorDescription: String? {
        switch self {
        case .treeTooLarge:
            String(localized: "Archive folder paths exceed the 32 MiB display limit.", comment: "Archive tree limit")
        }
    }
}

fileprivate struct ArchiveNode: Identifiable, Sendable {
    let id: String
    let path: String
    let name: String
    let entry: ArchiveEntry?
    let children: [ArchiveNode]?

    var isDirectory: Bool { children != nil }
}

fileprivate enum ArchivePreview: Sendable {
    case image(CGImage)
    case pdf(CGImage, page: Int, count: Int)
    case media(URL, Int)
    case text(String, truncated: Bool)
}

@MainActor
@Observable
final class ArchiveBrowserPanelModel {
    let source: URL
    private(set) var session: ArchiveBrowserSession
    private let staging: StagingArea
    private let runBatch: @MainActor (Batch) -> Void
    private(set) var entries: [ArchiveEntry] = []
    fileprivate private(set) var nodes: [ArchiveNode] = []
    fileprivate private(set) var preview: ArchivePreview?
    private(set) var isLoading = false
    private(set) var isPreviewing = false
    private(set) var isExporting = false
    private(set) var isReloading = false
    private(set) var error: String?
    private(set) var previewError: String?
    private(set) var previewNeedsReload = false
    private(set) var failedPDFPage: Int?
    var search = ""
    var selection: Set<String> = []
    var password = ""
    private var loadTask: Task<Void, Never>?
    private var loadTasks: [UUID: Task<Void, Never>] = [:]
    private var loadGeneration = 0
    private var previewTask: Task<Void, Never>?
    private var previewTasks: [UUID: Task<Void, Never>] = [:]
    private var exportTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var previewID: Int?
    private var previewURL: URL?
    private var releaseTasks: [UUID: Task<Void, Never>] = [:]
    private var mountedMediaIDs: Set<Int> = []
    private var teardownWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var tornDown: Set<Int> = []
    private var previewGeneration = 0
    private var closed = false

    init(source: URL, staging: StagingArea, runBatch: @escaping @MainActor (Batch) -> Void) {
        self.source = source
        self.staging = staging
        session = ArchiveBrowserSession(source: source, staging: staging)
        self.runBatch = runBatch
    }

    fileprivate var visibleNodes: [ArchiveNode] {
        guard !search.isEmpty else { return nodes }
        let query = search.localizedLowercase
        func matching(_ node: ArchiveNode) -> ArchiveNode? {
            let children = node.children?.compactMap(matching)
            guard node.path.localizedLowercase.contains(query) || !(children?.isEmpty ?? true) else { return nil }
            return ArchiveNode(
                id: node.id, path: node.path, name: node.name, entry: node.entry,
                children: node.children == nil ? nil : children)
        }
        return nodes.compactMap(matching)
    }

    var selectedEntries: [ArchiveEntry] {
        let entryIDs = Set(
            selection.compactMap { row in
                row.hasPrefix("entry:") ? Int(row.dropFirst("entry:".count)) : nil
            })
        var folders = Set(
            selection.compactMap { row in
                row.hasPrefix("folder:") ? String(row.dropFirst("folder:".count)) : nil
            })
        folders.formUnion(
            entries.filter { entryIDs.contains($0.id) && $0.isDirectory }.map { Self.normalized($0.path) })
        return entries.filter { entry in
            if entryIDs.contains(entry.id) { return true }
            var ancestor = ""
            for part in Self.normalized(entry.path).split(separator: "/").dropLast() {
                ancestor += ancestor.isEmpty ? String(part) : "/" + part
                if folders.contains(ancestor) { return true }
            }
            return false
        }
    }

    var canExport: Bool { !closed && !isLoading && !isExporting && !isReloading && !selectedEntries.isEmpty }

    func load() {
        guard !closed, !isReloading else { return }
        loadTask?.cancel()
        loadGeneration += 1
        let expected = loadGeneration
        isLoading = true
        error = nil
        let taskID = UUID()
        let task = Task {
            defer { loadTasks.removeValue(forKey: taskID) }
            do {
                let listed = try await session.entries()
                guard !Task.isCancelled, !closed, expected == loadGeneration else { return }
                let tree = try await offMain { try Self.makeNodes(listed) }
                guard !Task.isCancelled, !closed, expected == loadGeneration else { return }
                entries = listed
                nodes = tree
                isLoading = false
            } catch is CancellationError {
                if expected == loadGeneration { isLoading = false }
            } catch {
                guard !closed, expected == loadGeneration else { return }
                self.error = Self.message(error, source: source)
                isLoading = false
            }
        }
        loadTask = task
        loadTasks[taskID] = task
    }

    func reload() {
        guard !closed, !isReloading else { return }
        isReloading = true
        loadGeneration += 1
        previewGeneration += 1
        for task in previewTasks.values { task.cancel() }
        for task in loadTasks.values { task.cancel() }
        exportTask?.cancel()
        let oldSession = session
        let oldLoads = Array(loadTasks.values)
        let oldPreviews = Array(previewTasks.values)
        let oldExport = exportTask
        let activeID = previewID
        let wasMounted = activeID.map { mountedMediaIDs.contains($0) } ?? false
        preview = nil
        previewID = nil
        previewURL = nil
        selection.removeAll()
        entries = []
        nodes = []
        error = nil
        previewError = nil
        previewNeedsReload = false
        let retired = activeID.map { releasePreview($0, after: oldPreviews, waitForRenderer: wasMounted) }
        reloadTask = Task {
            for task in oldPreviews { await task.value }
            for task in oldLoads { await task.value }
            await oldExport?.value
            await retired?.value
            for task in Array(releaseTasks.values) { await task.value }
            await oldSession.close()
            guard !closed else { return }
            session = ArchiveBrowserSession(source: source, staging: staging)
            isReloading = false
            load()
        }
    }

    func updatePreview() {
        previewGeneration += 1
        let expected = previewGeneration
        previewTask?.cancel()
        let pending = Array(previewTasks.values)
        let previousID = previewID
        let wasMounted = previousID.map { mountedMediaIDs.contains($0) } ?? false
        preview = nil
        previewID = nil
        previewURL = nil
        previewError = nil
        previewNeedsReload = false
        failedPDFPage = nil
        isPreviewing = false
        let retired = previousID.map { releasePreview($0, after: pending, waitForRenderer: wasMounted) }
        guard !closed, !isReloading, selection.count == 1, let row = selection.first,
            row.hasPrefix("entry:"), let entryID = Int(row.dropFirst("entry:".count)),
            let selected = entries.first(where: { $0.id == entryID }),
            !selected.isDirectory
        else { return }
        let kind = Self.previewKind(for: selected)
        guard kind != .unknown else { return }
        guard selected.size.map({ $0 <= ArchivePreviewLimit.fileBytes }) ?? false else {
            previewError = String(localized: "This file is too large to preview.", comment: "Archive preview size")
            return
        }
        let submittedPassword = password.isEmpty ? nil : password
        isPreviewing = true
        let taskID = UUID()
        let task = Task {
            defer { previewTasks.removeValue(forKey: taskID) }
            var requestedPreview = false
            do {
                for task in pending { await task.value }
                if let retired { await retired.value }
                try Task.checkCancellation()
                requestedPreview = true
                let url = try await session.preview(entryID: selected.id, password: submittedPassword)
                try Task.checkCancellation()
                let rendered = try await Self.render(url, kind: kind, entryID: selected.id)
                try Task.checkCancellation()
                guard !closed, expected == previewGeneration else { throw CancellationError() }
                preview = rendered
                previewID = selected.id
                previewURL = url
                requestedPreview = false
                isPreviewing = false
            } catch {
                if requestedPreview { await session.releasePreview(entryID: selected.id) }
                guard !closed, expected == previewGeneration else { return }
                if error is CancellationError {
                    isPreviewing = false
                    return
                }
                previewError = Self.message(error, source: source)
                previewNeedsReload = (error as? ArchiveBrowserError) == .sourceChanged
                isPreviewing = false
            }
        }
        previewTask = task
        previewTasks[taskID] = task
    }

    func showPDFPage(_ page: Int) {
        guard !closed, let url = previewURL, let entryID = previewID,
            case .pdf(_, let current, let count)? = preview,
            (1...count).contains(page), page != current
        else { return }
        previewTask?.cancel()
        previewGeneration += 1
        let expected = previewGeneration
        previewError = nil
        failedPDFPage = nil
        isPreviewing = true
        let taskID = UUID()
        let task = Task {
            defer { previewTasks.removeValue(forKey: taskID) }
            do {
                let rendered = try await Self.renderPDF(url, page: page)
                guard !Task.isCancelled, !closed, expected == previewGeneration, previewID == entryID else { return }
                preview = rendered
                previewError = nil
                isPreviewing = false
            } catch is CancellationError {
                if expected == previewGeneration { isPreviewing = false }
            } catch {
                guard !closed, expected == previewGeneration else { return }
                previewError = Self.message(error, source: source)
                failedPDFPage = page
                isPreviewing = false
            }
        }
        previewTask = task
        previewTasks[taskID] = task
    }

    func export() {
        guard canExport else { return }
        let chosen = selectedEntries
        let singleFile =
            chosen.count == 1 && !chosen[0].isDirectory && selection.count == 1
            && !selection.contains(where: { $0.hasPrefix("folder:") })
        let destination: URL?
        if singleFile {
            let panel = NSSavePanel()
            panel.nameFieldStringValue =
                chosen[0].path.split(separator: "/").last.map(String.init) ?? source.lastPathComponent
            panel.message = String(
                localized: "Existing files are kept. If the name is taken, a numbered name is used.",
                comment: "Explains collision-safe saving")
            destination = panel.runModal() == .OK ? panel.url : nil
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = String(localized: "Choose Destination", comment: "Archive export folder")
            destination = panel.runModal() == .OK ? panel.url : nil
        }
        guard let destination, canExport else { return }
        let ids = Set(chosen.map(\.id))
        isExporting = true
        error = nil
        exportTask = Task {
            do {
                let batch = try await session.batch(
                    entryIDs: ids, password: password.isEmpty ? nil : password,
                    to: destination, operation: .archiveBrowse, exportsFolder: !singleFile)
                guard !closed, !Task.isCancelled else { return }
                runBatch(batch)
                isExporting = false
            } catch is CancellationError {
                isExporting = false
            } catch {
                guard !closed else { return }
                self.error = Self.message(error, source: source)
                isExporting = false
            }
        }
    }

    func close() async {
        closed = true
        await reloadTask?.value
        loadGeneration += 1
        previewGeneration += 1
        for task in previewTasks.values { task.cancel() }
        for task in loadTasks.values { task.cancel() }
        exportTask?.cancel()
        let pending = Array(previewTasks.values)
        let activeID = previewID
        let wasMounted = activeID.map { mountedMediaIDs.contains($0) } ?? false
        preview = nil
        previewID = nil
        previewURL = nil
        let retired = activeID.map { releasePreview($0, after: pending, waitForRenderer: wasMounted) }
        for task in pending { await task.value }
        for task in Array(loadTasks.values) { await task.value }
        await exportTask?.value
        await retired?.value
        for task in Array(releaseTasks.values) { await task.value }
        await session.close()
    }

    private func releasePreview(
        _ id: Int, after pending: [Task<Void, Never>], waitForRenderer: Bool
    ) -> Task<Void, Never> {
        let taskID = UUID()
        let task = Task {
            if waitForRenderer { await rendererTeardown(id) }
            for task in pending { await task.value }
            await session.releasePreview(entryID: id)
            releaseTasks.removeValue(forKey: taskID)
        }
        releaseTasks[taskID] = task
        return task
    }

    func rendererDidAttach(_ id: Int) -> Bool {
        guard !closed, previewID == id, case .media? = preview else { return false }
        mountedMediaIDs.insert(id)
        return true
    }

    func rendererDidTeardown(_ id: Int) {
        guard mountedMediaIDs.remove(id) != nil else { return }
        if let waiter = teardownWaiters.removeValue(forKey: id) {
            waiter.resume()
        } else {
            tornDown.insert(id)
        }
    }

    private func rendererTeardown(_ id: Int) async {
        if tornDown.remove(id) != nil { return }
        await withCheckedContinuation { teardownWaiters[id] = $0 }
    }

    private enum PreviewKind: Equatable {
        case image, pdf, media, text, unknown
    }

    private static func previewKind(for entry: ArchiveEntry) -> PreviewKind {
        let ext = URL(fileURLWithPath: entry.path).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"].contains(ext) {
            return .image
        }
        if ext == "pdf" { return .pdf }
        if ["mp3", "m4a", "wav", "aiff", "mp4", "mov", "m4v"].contains(ext) { return .media }
        if [
            "txt", "md", "markdown", "html", "htm", "js", "ts", "swift", "py", "json", "xml", "yaml", "yml", "toml",
            "csv", "log", "css", "sh", "c", "h", "m", "mm", "cpp", "hpp", "rs", "go", "java", "kt", "srt", "vtt",
        ].contains(ext) {
            return .text
        }
        return .unknown
    }

    private static func render(_ url: URL, kind: PreviewKind, entryID: Int) async throws -> ArchivePreview {
        switch kind {
        case .image:
            return try await offMain {
                let bytes = try Data(contentsOf: url)
                guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                    let pixels = CGImageSourceCreateThumbnailAtIndex(
                        source, 0,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: Int(ArchivePreviewLimit.rasterSide),
                        ] as CFDictionary)
                else { throw EngineError.decodeFailed(url.path) }
                return .image(pixels)
            }
        case .pdf:
            return try await renderPDF(url, page: 1)
        case .media:
            return .media(url, entryID)
        case .text:
            return try await offMain {
                let cap = ArchivePreviewLimit.textBytes
                let file = try FileHandle(forReadingFrom: url)
                defer { file.closeFile() }
                let bytes = try file.read(upToCount: cap + 1) ?? Data()
                let truncated = bytes.count > cap
                let prefix = bytes.prefix(cap)
                var text = String(data: prefix, encoding: .utf8)
                if truncated {
                    for removed in 1...3 where text == nil && prefix.count >= removed {
                        text = String(data: prefix.dropLast(removed), encoding: .utf8)
                    }
                }
                guard let text else {
                    throw EngineError.decodeFailed(url.path)
                }
                return .text(text, truncated: truncated)
            }
        case .unknown:
            throw EngineError.decodeFailed(url.path)
        }
    }

    private static func renderPDF(_ url: URL, page number: Int) async throws -> ArchivePreview {
        try await offMain {
            guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: number) else {
                throw EngineError.decodeFailed(url.path)
            }
            let bounds = page.getBoxRect(.mediaBox)
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
                throw EngineError.decodeFailed(url.path)
            }
            let scale = ArchivePreviewLimit.rasterSide / max(bounds.width, bounds.height)
            let width = max(1, Int((bounds.width * scale).rounded(.up)))
            let height = max(1, Int((bounds.height * scale).rounded(.up)))
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw EngineError.decodeFailed(url.path) }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.concatenate(
                page.getDrawingTransform(
                    .mediaBox, rect: CGRect(x: 0, y: 0, width: width, height: height),
                    rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard let pixels = context.makeImage() else { throw EngineError.decodeFailed(url.path) }
            return .pdf(pixels, page: number, count: document.numberOfPages)
        }
    }

    private static func message(_ error: any Error, source: URL) -> String {
        if let panelError = error as? ArchiveBrowserPanelError { return panelError.localizedDescription }
        if let browserError = error as? ArchiveBrowserError { return browserError.localizedDescription }
        return UserMessages.describe(EngineError.wrapping(error, path: source.path), file: source.lastPathComponent)
    }

    nonisolated private static func normalized(_ path: String) -> String {
        String(path.drop(while: { $0 == "/" }).dropLast(path.hasSuffix("/") ? 1 : 0))
    }

    nonisolated private static func makeNodes(_ entries: [ArchiveEntry]) throws -> [ArchiveNode] {
        let pathLimit = 32 * 1024 * 1024
        var retainedPathBytes = 0
        var folders: [String: Set<String>] = [:]
        var directoryEntries: [String: [ArchiveEntry]] = [:]
        var files: [String: [ArchiveEntry]] = [:]
        func retain(_ path: String) throws {
            let bytes = path.utf8.count
            guard bytes <= pathLimit - retainedPathBytes else { throw ArchiveBrowserPanelError.treeTooLarge }
            retainedPathBytes += bytes
        }
        for entry in entries {
            try Task.checkCancellation()
            let path = normalized(entry.path)
            let components = path.split(separator: "/")
            var parent = ""
            for component in components.prefix(entry.isDirectory ? components.count : max(components.count - 1, 0)) {
                let child = parent.isEmpty ? String(component) : parent + "/" + component
                if folders[parent, default: []].insert(child).inserted { try retain(child) }
                parent = child
            }
            if entry.isDirectory {
                if !(directoryEntries[path] ?? []).isEmpty { try retain(path) }
                directoryEntries[path, default: []].append(entry)
                if folders[path] == nil { folders[path] = [] }
            } else {
                try retain(path)
                files[parent, default: []].append(entry)
            }
        }
        func nodes(in parent: String) -> [ArchiveNode] {
            let directories = (folders[parent] ?? []).sorted { lhs, rhs in
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }.flatMap { path -> [ArchiveNode] in
                let records = directoryEntries[path] ?? []
                let name = String(path.split(separator: "/").last ?? "")
                let owner = ArchiveNode(
                    id: records.first.map { "entry:\($0.id)" } ?? ("folder:" + path),
                    path: path, name: name, entry: records.first, children: nodes(in: path))
                let duplicates = records.dropFirst().map { entry in
                    ArchiveNode(id: "entry:\(entry.id)", path: path, name: name, entry: entry, children: [])
                }
                return [owner] + duplicates
            }
            let leaves = (files[parent] ?? []).sorted { lhs, rhs in
                let order = lhs.path.localizedStandardCompare(rhs.path)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }.map { entry in
                ArchiveNode(
                    id: "entry:\(entry.id)", path: normalized(entry.path),
                    name: String(normalized(entry.path).split(separator: "/").last ?? ""),
                    entry: entry, children: nil)
            }
            return directories + leaves
        }
        return nodes(in: "")
    }
}

struct ArchiveBrowserPanel: View {
    @Bindable var model: ArchiveBrowserPanelModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.source.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                TextField("Search names and paths", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 230)
                Button {
                    model.reload()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(model.isReloading)
            }
            .padding(12)
            Divider()
            HSplitView {
                Group {
                    if model.isLoading || model.isReloading {
                        ProgressView("Reading archive…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = model.error, model.entries.isEmpty {
                        ContentUnavailableView {
                            Label("Could Not Open Archive", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Retry") { model.reload() }
                        }
                    } else {
                        List(selection: $model.selection) {
                            OutlineGroup(model.visibleNodes, children: \.children) { node in
                                HStack {
                                    Label(node.name, systemImage: node.isDirectory ? "folder" : "doc")
                                        .lineLimit(1)
                                    Spacer()
                                    if let size = node.entry?.size, !node.isDirectory {
                                        Text(size.formatted(.byteCount(style: .file)))
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                    if node.entry?.isEncrypted == true {
                                        Image(systemName: "lock").foregroundStyle(.secondary)
                                    }
                                }
                                .tag(node.id)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(node.path)
                                .accessibilityValue(accessibilityDetails(for: node))
                            }
                        }
                    }
                }
                .frame(minWidth: 320)
                previewPane
                    .frame(minWidth: 340)
            }
            Divider()
            HStack {
                Text("\(model.entries.count) entries", comment: "Archive entry count")
                    .foregroundStyle(.secondary)
                Spacer()
                SecureField("Password", text: $model.password)
                    .frame(width: 180)
                    .onSubmit { model.updatePreview() }
                Button("Close", action: close)
                Button("Save…") { model.export() }
                    .disabled(!model.canExport)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            if let error = model.error, !model.entries.isEmpty {
                Text(error).foregroundStyle(.red).padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .frame(minWidth: 850, minHeight: 560)
        .onAppear { model.load() }
        .onChange(of: model.search) { _, _ in model.selection.removeAll() }
        .onChange(of: model.selection) { _, _ in model.updatePreview() }
    }

    private func accessibilityDetails(for node: ArchiveNode) -> String {
        var details: [String] = []
        if node.isDirectory { details.append(String(localized: "Folder", comment: "Archive row kind")) }
        if let size = node.entry?.size, !node.isDirectory {
            details.append(size.formatted(.byteCount(style: .file)))
        }
        if node.entry?.isEncrypted == true {
            details.append(String(localized: "Encrypted", comment: "Archive row status"))
        }
        return details.joined(separator: ", ")
    }

    @ViewBuilder
    private var previewPane: some View {
        if model.isPreviewing {
            ProgressView("Loading preview…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let preview = model.preview {
            switch preview {
            case .image(let pixels):
                Image(nsImage: NSImage(cgImage: pixels, size: .zero)).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .pdf(let pixels, let page, let pages):
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Button {
                            model.showPDFPage(page - 1)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(page == 1)
                        .accessibilityLabel("Previous PDF page")
                        Text("Page \(page) of \(pages)", comment: "Archive PDF preview page")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button {
                            model.showPDFPage(page + 1)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(page == pages)
                        .accessibilityLabel("Next PDF page")
                    }
                    .buttonStyle(.borderless)
                    .padding(8)
                    if let error = model.previewError, let failedPage = model.failedPDFPage {
                        HStack {
                            Text(error).foregroundStyle(.red)
                            Button("Retry") { model.showPDFPage(failedPage) }
                        }
                    }
                    Image(nsImage: NSImage(cgImage: pixels, size: .zero))
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .media(let url, let id):
                ArchiveMediaView(
                    url: url, attach: { model.rendererDidAttach(id) }, release: { model.rendererDidTeardown(id) }
                )
                .id(id)
            case .text(let text, let truncated):
                VStack(alignment: .leading, spacing: 0) {
                    if truncated {
                        Text("Preview shows the first 8 MB.", comment: "Truncated archive text preview")
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                    ScrollView {
                        Text(verbatim: text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(
                            maxWidth: .infinity, alignment: .leading
                        ).padding(12)
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label("No Preview", systemImage: "doc")
            } description: {
                if let error = model.previewError {
                    Text(error)
                } else if model.selection.count == 1, let folder = model.selection.first,
                    folder.hasPrefix("folder:")
                {
                    Text(
                        "\(String(folder.dropFirst("folder:".count))) · Use Save… to export.",
                        comment: "Archive folder details")
                } else if model.selection.count == 1, let row = model.selection.first,
                    row.hasPrefix("entry:"), let id = Int(row.dropFirst("entry:".count)),
                    let selected = model.entries.first(where: { $0.id == id })
                {
                    Text(
                        "\(selected.path) · Preview unavailable. Use Save… to export.", comment: "Archive file details")
                } else {
                    Text("Select one supported file to preview.", comment: "Archive preview guidance")
                }
            } actions: {
                if model.previewError != nil {
                    if model.previewNeedsReload {
                        Button("Reload") { model.reload() }
                    } else {
                        Button("Retry Preview") { model.updatePreview() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ArchiveMediaView: NSViewRepresentable {
    let url: URL
    let attach: @MainActor () -> Bool
    let release: @MainActor () -> Void

    func makeNSView(context: Context) -> AVPlayerView { AVPlayerView() }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if !context.coordinator.didAttach {
            guard context.coordinator.attach() else { return }
            context.coordinator.didAttach = true
        }
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player = AVPlayer(url: url)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(attach: attach, release: release) }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        view.player = nil
        if coordinator.didAttach { coordinator.release() }
    }

    @MainActor final class Coordinator {
        var didAttach = false
        let attach: @MainActor () -> Bool
        let release: @MainActor () -> Void
        init(attach: @escaping @MainActor () -> Bool, release: @escaping @MainActor () -> Void) {
            self.attach = attach
            self.release = release
        }
    }
}
