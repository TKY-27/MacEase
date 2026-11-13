import AppKit
import Engine
import Observation
import SwiftUI

@MainActor
@Observable
final class RelatedFilesModel {
    let source: URL
    var folder: URL
    private(set) var matches: [RelatedFileMatch] = []
    private(set) var progress = ""
    private(set) var failure: String?
    private(set) var skippedCount = 0
    private(set) var isSearching = false
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var closed = false

    init(source: URL) {
        self.source = source
        folder = source.deletingLastPathComponent()
    }

    func chooseFolder() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.directoryURL = folder
        if picker.runModal() == .OK, let selected = picker.url { folder = selected }
    }

    func find() {
        guard !isSearching, !closed else { return }
        searchGeneration += 1
        let generation = searchGeneration
        matches = []
        failure = nil
        skippedCount = 0
        progress = ""
        isSearching = true
        let source = source
        let folder = folder
        let progressModel = self
        searchTask = Task.detached { [weak self] in
            do {
                let report = try RelatedFilesScanner.scan(source: source, in: folder) { done, total in
                    let updateInterval = max(1, total / 100 + (total.isMultiple(of: 100) ? 0 : 1))
                    guard done % updateInterval == 0 || done == total else { return }
                    Task { @MainActor in
                        guard progressModel.searchGeneration == generation, progressModel.isSearching else { return }
                        progressModel.progress = "\(done) / \(total)"
                    }
                }
                await MainActor.run {
                    guard let self, !self.closed, self.searchGeneration == generation else { return }
                    self.matches = report.matches
                    self.skippedCount = report.skippedCount
                    self.isSearching = false
                    self.progress = String(localized: "\(report.scannedCount) files scanned")
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self, self.searchGeneration == generation else { return }
                    self.isSearching = false
                }
            } catch {
                await MainActor.run {
                    guard let self, self.searchGeneration == generation else { return }
                    self.failure = error.localizedDescription
                    self.isSearching = false
                }
            }
        }
    }

    func close() {
        closed = true
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
    }
}

struct RelatedFilesPanel: View {
    @State var model: RelatedFilesModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Find Related Files").font(.title2.weight(.semibold))
            Text("Source: \(model.source.lastPathComponent)").foregroundStyle(.secondary)
            HStack {
                Label(model.folder.path, systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
                Button("Choose Folder…", action: model.chooseFolder)
                Spacer()
                Button("Find", action: model.find)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isSearching)
            }
            if model.isSearching {
                HStack {
                    ProgressView()
                    Text(model.progress).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let failure = model.failure { Text(failure).foregroundStyle(.red) }
            if model.skippedCount > 0 {
                Text("\(model.skippedCount) unreadable files skipped").foregroundStyle(.secondary)
            }
            List(model.matches) { match in
                HStack(spacing: 12) {
                    if let thumbnailData = match.thumbnail, let image = NSImage(data: thumbnailData) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 48, height: 48)
                    } else {
                        Image(systemName: "doc").frame(width: 48, height: 48)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(match.url.lastPathComponent).fontWeight(.medium)
                        Text(match.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(kindLabel(match.kind)).font(.caption).foregroundStyle(.secondary)
                    Button("Reveal", systemImage: "arrow.up.right.square") {
                        NSWorkspace.shared.activateFileViewerSelecting([match.url])
                    }
                    .labelStyle(.iconOnly)
                }
            }
            HStack {
                Text(model.progress).font(.caption).foregroundStyle(.secondary); Spacer();
                Button("Close", action: close)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 460)
        .onDisappear { model.close() }
    }

    private func kindLabel(_ kind: RelatedFileKind) -> String {
        switch kind {
        case .exact: String(localized: "Exact content")
        case .visuallySimilar: String(localized: "Visually similar")
        }
    }
}
