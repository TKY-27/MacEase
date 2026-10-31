import Engine
import ImageIO
import PDFKit
import SwiftUI
import os

/// `pageIndex` is zero-based; images have none.
struct PageEntry: Identifiable, Hashable, Sendable {
    let id = UUID()
    let file: URL
    let pageIndex: Int?

    static func entries(for files: [URL], splitsPages: Bool) throws -> [PageEntry] {
        guard splitsPages else { return files.map { PageEntry(file: $0, pageIndex: nil) } }
        return try files.flatMap { file in
            try OperationPlanner.validateInput(file)
            guard let document = PDFDocument(url: file) else { throw EngineError.decodeFailed("PDF does not open") }
            return (0..<document.pageCount).map { PageEntry(file: file, pageIndex: $0) }
        }
    }

    var title: String {
        guard let pageIndex else { return file.lastPathComponent }
        return String(localized: "\(file.lastPathComponent), page \(pageIndex + 1)", comment: "Page order row")
    }
}

enum PageThumbnail {
    private static let maxPixelEdge = 160

    static func load(_ entry: PageEntry) async -> CGImage? {
        do {
            return try await offMain { try render(entry) }
        } catch {
            let failure = error as NSError
            Logger(category: "panels").error(
                "Thumbnail failed (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)): \(failure.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    private static func render(_ entry: PageEntry) throws -> CGImage {
        try OperationPlanner.validateInput(entry.file)
        if let pageIndex = entry.pageIndex {
            let edge = CGFloat(maxPixelEdge)
            guard let page = PDFDocument(url: entry.file)?.page(at: pageIndex),
                let image = page.thumbnail(of: CGSize(width: edge, height: edge), for: .cropBox)
                    .cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { throw EngineError.decodeFailed("PDF page does not render") }
            return image
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelEdge,
        ]
        guard let source = CGImageSourceCreateWithURL(entry.file as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw EngineError.decodeFailed("image does not decode") }
        return image
    }
}

struct Thumbnail: View {
    let entry: PageEntry
    var edge = PanelLayout.thumbnailEdge
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay { Rectangle().strokeBorder(.separator) }
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: edge, height: edge)
        .task { image = await PageThumbnail.load(entry) }
    }
}

/// Drag to reorder; Delete removes.
struct PageOrderPanel: View {
    let actionTitle: String
    @State var pages: [PageEntry]
    let cancel: () -> Void
    let run: ([PageEntry]) -> Void

    @State private var selection = Set<PageEntry.ID>()

    var body: some View {
        VStack(spacing: 0) {
            Text("Drag to change the order. Press Delete to remove pages.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            List(selection: $selection) {
                ForEach(pages) { page in
                    HStack(spacing: PanelLayout.rowSpacing) {
                        Thumbnail(entry: page)
                        Text(page.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAction(named: Text("Move Up")) { move(page, by: -1) }
                    .accessibilityAction(named: Text("Move Down")) { move(page, by: 1) }
                    .contextMenu {
                        Button("Move Up") { move(page, by: -1) }
                        Button("Move Down") { move(page, by: 1) }
                        Button("Remove", role: .destructive) { remove([page.id]) }
                    }
                }
                .onMove { pages.move(fromOffsets: $0, toOffset: $1) }
            }
            .onDeleteCommand { remove(selection) }
            .frame(height: PanelLayout.listHeight)
            PanelBar(actionTitle: actionTitle, canRun: !pages.isEmpty, cancel: cancel) { run(pages) }
        }
        .frame(width: PanelLayout.width)
    }

    private func move(_ page: PageEntry, by offset: Int) {
        guard let index = pages.firstIndex(of: page), pages.indices.contains(index + offset) else { return }
        pages.swapAt(index, index + offset)
    }

    private func remove(_ ids: Set<PageEntry.ID>) {
        pages.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }
}

/// Field and thumbnails stay in sync.
struct PageSelectPanel: View {
    let pages: [PageEntry]
    let cancel: () -> Void
    let run: (IndexSet) -> Void

    @State private var rangeText = ""

    private static let columns = [GridItem(.adaptive(minimum: PanelLayout.thumbnailEdge * 2))]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Pages", text: $rangeText, prompt: Text(verbatim: "1-3, 5"))
                if PageRanges.parse(rangeText, pageCount: pages.count) == nil {
                    Text("Enter page numbers between 1 and \(pages.count), such as 1-3, 5.")
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVGrid(columns: Self.columns, spacing: PanelLayout.rowSpacing) {
                    ForEach(pages.indices, id: \.self) { index in
                        PageToggle(entry: pages[index], isOn: selected.contains(index)) { toggle(index) }
                    }
                }
                .padding()
            }
            .frame(height: PanelLayout.listHeight)
            PanelBar(
                actionTitle: String(localized: "Extract", comment: "Page select action"), canRun: !selected.isEmpty,
                cancel: cancel
            ) {
                if !selected.isEmpty { run(selected) }
            }
        }
        .frame(width: PanelLayout.wideWidth)
    }

    private var selected: IndexSet {
        PageRanges.parse(rangeText, pageCount: pages.count) ?? IndexSet()
    }

    private func toggle(_ index: Int) {
        var selected = selected
        if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
        rangeText = PageRanges.format(selected)
    }
}

private struct PageToggle: View {
    let entry: PageEntry
    let isOn: Bool
    let toggle: () -> Void

    private static let selectionWidth: CGFloat = 3

    var body: some View {
        Button(action: toggle) {
            VStack {
                Thumbnail(entry: entry, edge: PanelLayout.thumbnailEdge * 2)
                    .overlay {
                        if isOn { Rectangle().strokeBorder(.tint, lineWidth: Self.selectionWidth) }
                    }
                Text((entry.pageIndex ?? 0) + 1, format: .number)
                    .font(.caption)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Page \((entry.pageIndex ?? 0) + 1)"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// One-based ranges such as `1-3, 5, 8-`.
enum PageRanges {
    /// `nil` when any part is invalid.
    static func parse(_ text: String, pageCount: Int) -> IndexSet? {
        var pages = IndexSet()
        for part in text.split(separator: ",") {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1...2).contains(bounds.count) else { return nil }
            let first = bounds[0].isEmpty && bounds.count == 2 ? 1 : Int(bounds[0])
            let last = bounds.count == 1 ? first : (bounds[1].isEmpty ? pageCount : Int(bounds[1]))
            guard let first, let last, 1 <= first, first <= last, last <= pageCount else { return nil }
            pages.insert(integersIn: (first - 1)..<last)
        }
        return pages
    }

    static func format(_ pages: IndexSet) -> String {
        pages.rangeView.map { range in
            range.count == 1 ? "\(range.lowerBound + 1)" : "\(range.lowerBound + 1)-\(range.upperBound)"
        }.joined(separator: ", ")
    }
}
