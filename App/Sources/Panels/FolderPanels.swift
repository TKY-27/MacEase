import Charts
import Engine
import SwiftUI

/// Paths below the scanned folders.
func relativePath(_ url: URL, roots: [URL]) -> String {
    let parent = roots.first { url.path.hasPrefix($0.path + "/") }?.deletingLastPathComponent().path
    guard let parent else { return url.path }
    return String(url.path.dropFirst(parent.count + 1))
}

struct NothingFound: View {
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

struct AnalyzePanel: View {
    let analysis: FolderAnalysis
    @State var format: AnalysisExportFormat
    let close: () -> Void
    let export: (AnalysisExportFormat) -> Void

    private static let chartedTypes = 8
    private static let chartHeight: CGFloat = 120

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if analysis.roots.count > 1 {
                        LabeledContent(String(localized: "Folders", comment: "Analyzed folder roots")) {
                            Text(analysis.roots.map(\.requested.lastPathComponent).formatted(.list(type: .and)))
                        }
                    }
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
                TableColumn("Largest Files") { Text(relativePath($0.url, roots: analysis.roots.map(\.canonical))) }
                TableColumn("Size") { Text($0.bytes.fileSize).monospacedDigit() }
            }
            .frame(height: PanelLayout.listHeight)
            PanelBar(
                actionTitle: String(localized: "Export…", comment: "Analyze panel action"),
                cancelTitle: String(localized: "Done", comment: "Panel button"), cancel: close
            ) {
                export(format)
            } accessory: {
                Picker(String(localized: "Format", comment: "Analysis export format"), selection: $format) {
                    ForEach(AnalysisExportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
            }
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

extension AnalysisExportFormat {
    var title: String {
        switch self {
        case .csv: "CSV"
        case .json: "JSON"
        case .html: "HTML"
        case .txt: String(localized: "Plain Text", comment: "Analysis export format")
        case .markdown: "Markdown"
        }
    }
}
