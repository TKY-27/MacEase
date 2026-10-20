import Charts
import Engine
import SwiftUI

/// Scans off the main actor.
struct ScanningPanel<Result: Sendable, Content: View>: View {
    let title: String
    /// Named in error messages.
    let subject: URL
    let close: () -> Void
    let scan: @Sendable (_ progress: @escaping @Sendable (Double) -> Void) throws -> Result
    @ViewBuilder let content: (Result) -> Content

    @State private var result: Result?
    @State private var fraction = 0.0
    @State private var failure: String?

    var body: some View {
        Group {
            if let result {
                content(result)
            } else if let failure {
                PanelFailure(message: failure, close: close)
            } else {
                ScanProgress(title: title, fraction: fraction, cancel: close)
            }
        }
        .task {
            let reporter = ProgressReporter { fraction = $0 }
            let scan = scan
            do {
                result = try await offMain { try scan(reporter.report) }
            } catch is CancellationError {
                return
            } catch {
                failure = UserMessages.describe(
                    EngineError.wrapping(error, path: subject.path), file: subject.lastPathComponent)
            }
        }
    }
}

/// Paths below the scanned folders.
private func relativePath(_ url: URL, roots: [URL]) -> String {
    let parent = roots.first { url.path.hasPrefix($0.path + "/") }?.deletingLastPathComponent().path
    guard let parent else { return url.path }
    return String(url.path.dropFirst(parent.count + 1))
}

private struct NothingFound: View {
    let message: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Label(message, systemImage: "checkmark.circle")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            PanelBar(actionTitle: String(localized: "Done", comment: "Panel button"), cancel: close, run: close)
        }
        .frame(width: PanelLayout.width)
    }
}

struct DuplicatesPanel: View {
    let groups: [DuplicateGroup]
    let roots: [URL]
    let allowsPermanentDelete: Bool
    let cancel: () -> Void
    let run: (_ removals: [DuplicateRemoval], _ permanently: Bool) -> Void

    @State private var kept: [Int: URL] = [:]
    @State private var confirmsPermanentDelete = false

    var body: some View {
        if groups.isEmpty {
            NothingFound(message: String(localized: "No duplicates found.", comment: "Duplicates panel"), close: cancel)
        } else {
            VStack(spacing: 0) {
                List {
                    ForEach(groups.indices, id: \.self) { index in
                        Section {
                            Picker("Keep", selection: keptBinding(index)) {
                                ForEach(groups[index].files, id: \.self) { file in
                                    Text(relativePath(file, roots: roots)).tag(file)
                                }
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                            .accessibilityLabel(
                                Text("Copy to keep among \(groups[index].files.count) identical files"))
                        } header: {
                            Text(
                                "\(groups[index].files.count) copies of \(groups[index].bytesPerFile.fileSize) — keep one"
                            )
                        }
                    }
                }
                .frame(height: PanelLayout.listHeight)
                PanelBar(
                    actionTitle: String(localized: "Move to Trash", comment: "Duplicates panel action"), cancel: cancel
                ) {
                    run(removals, false)
                } accessory: {
                    Text("Frees \(reclaimable.fileSize)")
                        .foregroundStyle(.secondary)
                    if allowsPermanentDelete {
                        Button("Delete Permanently…", role: .destructive) { confirmsPermanentDelete = true }
                    }
                }
            }
            .frame(width: PanelLayout.wideWidth)
            .confirmationDialog(
                Text("Delete \(removals.flatMap(\.removed).count) files permanently?"),
                isPresented: $confirmsPermanentDelete
            ) {
                Button("Delete Permanently", role: .destructive) { run(removals, true) }
            } message: {
                Text("Permanently deleted files cannot be restored.")
            }
        }
    }

    private var reclaimable: Int64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    private var removals: [DuplicateRemoval] {
        groups.indices.map { index in
            let keep = kept[index] ?? groups[index].files[0]
            return DuplicateRemoval(kept: keep, removed: groups[index].files.filter { $0 != keep })
        }
    }

    private func keptBinding(_ index: Int) -> Binding<URL> {
        Binding {
            kept[index] ?? groups[index].files[0]
        } set: {
            kept[index] = $0
        }
    }
}

struct EmptyFoldersPanel: View {
    let folders: [URL]
    let roots: [URL]
    let allowsPermanentDelete: Bool
    let cancel: () -> Void
    let run: (_ folders: [URL], _ permanently: Bool) -> Void

    @State private var excluded = Set<URL>()
    @State private var confirmsPermanentDelete = false

    var body: some View {
        if folders.isEmpty {
            NothingFound(
                message: String(localized: "No empty folders found.", comment: "Empty folders panel"), close: cancel)
        } else {
            VStack(spacing: 0) {
                List(folders, id: \.self) { folder in
                    Toggle(relativePath(folder, roots: roots), isOn: includes(folder))
                }
                .frame(height: PanelLayout.listHeight)
                PanelBar(
                    actionTitle: String(localized: "Move to Trash", comment: "Empty folders panel action"),
                    canRun: !selected.isEmpty, cancel: cancel
                ) {
                    run(selected, false)
                } accessory: {
                    if allowsPermanentDelete {
                        Button("Delete Permanently…", role: .destructive) { confirmsPermanentDelete = true }
                            .disabled(selected.isEmpty)
                    }
                }
            }
            .frame(width: PanelLayout.wideWidth)
            .confirmationDialog(
                Text("Delete \(selected.count) folders permanently?"), isPresented: $confirmsPermanentDelete
            ) {
                Button("Delete Permanently", role: .destructive) { run(selected, true) }
            } message: {
                Text("Permanently deleted folders cannot be restored.")
            }
        }
    }

    private var selected: [URL] {
        folders.filter { !excluded.contains($0) }
    }

    private func includes(_ folder: URL) -> Binding<Bool> {
        Binding {
            !excluded.contains(folder)
        } set: { included in
            if included { excluded.remove(folder) } else { excluded.insert(folder) }
        }
    }
}

struct AnalyzePanel: View {
    let analysis: FolderAnalysis
    let close: () -> Void
    let export: () -> Void

    private static let chartedTypes = 8
    private static let chartHeight: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Total size", value: analysis.totalBytes.fileSize)
                    LabeledContent("Files", value: analysis.fileCount.formatted())
                    LabeledContent("Duplicates") {
                        Text("\(analysis.duplicateGroups.count) groups, \(reclaimable.fileSize) reclaimable")
                    }
                    LabeledContent("Empty folders", value: analysis.emptyFolders.count.formatted())
                }
                Section("Size by Type") {
                    Chart(analysis.sizeByType.prefix(Self.chartedTypes), id: \.pathExtension) { total in
                        BarMark(
                            x: .value(String(localized: "Size", comment: "Chart axis"), total.bytes),
                            y: .value(String(localized: "Type", comment: "Chart axis"), typeName(total.pathExtension))
                        )
                        .accessibilityValue(total.bytes.fileSize)
                    }
                    .chartXAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel { Text(value.as(Int64.self)?.fileSize ?? "") }
                        }
                    }
                    .frame(height: Self.chartHeight)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            Table(analysis.largestFiles) {
                TableColumn("Largest Files") { Text(relativePath($0.url, roots: [analysis.folder])) }
                TableColumn("Size") { Text($0.bytes.fileSize).monospacedDigit() }
            }
            .frame(height: PanelLayout.listHeight)
            PanelBar(
                actionTitle: String(localized: "Export as Markdown", comment: "Analyze panel action"),
                cancelTitle: String(localized: "Done", comment: "Panel button"), cancel: close, run: export)
        }
        .frame(width: PanelLayout.wideWidth)
    }

    private var reclaimable: Int64 {
        analysis.duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    private func typeName(_ pathExtension: String) -> String {
        pathExtension.isEmpty ? String(localized: "No extension", comment: "File type in analysis") : pathExtension
    }
}

extension SizedFile: @retroactive Identifiable {
    public var id: URL { url }
}
