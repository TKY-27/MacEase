import Engine
import Formats
import MenuCatalog
import Observation
import SwiftUI
import os

struct PreviewArchiveListing: Sendable {
    let nodes: [ArchiveNode]
    let entryCount: Int
    let itemCount: Int
    let expandedBytes: Int64
    let ending: ArchiveContents.Ending
    let hasEncryptedItems: Bool
    let foldersFirst: Bool

    init(
        reading url: URL, foldersFirst: Bool = PreviewArchiveSort.finderKeepsFoldersOnTop,
        maximumDuration: Duration = ArchiveContents.maximumDuration
    ) throws {
        let contents = try ArchiveContents.list(url.resolvingSymlinksInPath(), maximumDuration: maximumDuration) {
            try Task.checkCancellation()
        }
        let entries = contents.entries.enumerated().map { index, entry in
            ArchiveEntry(
                id: index, path: entry.path, isDirectory: entry.isDirectory, size: entry.size,
                isEncrypted: entry.isEncrypted, modified: entry.modified)
        }
        nodes = try ArchiveTree.nodes(entries, foldersFirst: foldersFirst)
        entryCount = entries.count
        itemCount = ArchiveTree.count(nodes)
        // Hostile headers may declare sizes that overflow.
        expandedBytes = entries.reduce(0) { total, entry in
            let (sum, overflow) = total.addingReportingOverflow(entry.isDirectory ? 0 : entry.size ?? 0)
            return overflow ? .max : sum
        }
        ending = contents.ending
        hasEncryptedItems = entries.contains(where: \.isEncrypted)
        self.foldersFirst = foldersFirst
    }

    var emptyFailure: PreviewArchiveFailure? {
        guard nodes.isEmpty else { return nil }
        switch ending {
        case .complete: return nil
        case .timeLimit: return .timedOut
        case .nameLimit: return .namesTooLarge
        case .entryLimit, .skipLimit: return .tooLarge
        case .damaged: return .damaged
        }
    }

    var summary: String {
        String(
            localized: "\(itemCount) items, \(expandedBytes.formatted(.byteCount(style: .file))) uncompressed",
            comment: "Archive preview summary")
    }

    var shortSummary: String {
        String(localized: "\(itemCount) items", comment: "Archive preview summary for narrow panels")
    }

    var noteText: String {
        switch ending {
        case .complete: summary
        case .entryLimit, .nameLimit, .skipLimit, .timeLimit:
            String(localized: "Showing the first \(itemCount) items.")
        case .damaged:
            String(localized: "This archive is damaged. Showing the first \(itemCount) items.")
        }
    }

    var shortNoteText: String {
        switch ending {
        case .complete: shortSummary
        case .entryLimit, .nameLimit, .skipLimit, .timeLimit:
            String(localized: "First \(itemCount) items")
        case .damaged:
            String(localized: "Damaged · first \(itemCount) items")
        }
    }
}

enum PreviewArchiveFailure: Equatable {
    case unsupported, damaged, tooLarge, namesTooLarge, timedOut, unreadable

    init(_ error: any Error) {
        switch error {
        case ArchiveContents.Failure.unsupported: self = .unsupported
        case ArchiveContents.Failure.damaged: self = .damaged
        case ArchiveContents.Failure.tooLarge: self = .tooLarge
        case ArchiveContents.Failure.namesTooLarge, ArchiveTreeError.tooLarge: self = .namesTooLarge
        default: self = .unreadable
        }
    }

    var message: Text {
        switch self {
        case .unsupported: Text("MacEase can't list this kind of archive.")
        case .damaged: Text("This archive is damaged, so its contents can't be listed.")
        case .tooLarge: Text("This archive has too many items to list.")
        case .namesTooLarge: Text("This archive's item names are too large to list.")
        case .timedOut: Text("This archive couldn't be listed in time.")
        case .unreadable: Text("This archive could not be read.")
        }
    }
}

@MainActor
@Observable
final class PreviewArchiveModel {
    enum Phase {
        case loading
        case listed(PreviewArchiveListing)
        case failed(PreviewArchiveFailure)
    }

    private static let defaultFilterDelay = Duration.milliseconds(150)
    // Larger expansions would stall the panel.
    static let filterExpansionLimit = 2_000

    private(set) var phase = Phase.loading
    private(set) var visibleNodes: [ArchiveNode] = []
    private(set) var visibleRevision = 0
    private(set) var visibleCount = 0
    private(set) var sortColumn = PreviewArchiveColumn.name
    private(set) var sortAscending = true
    private(set) var query = ""
    private var generation = 0
    private var transformGeneration = 0
    private var transformTask: Task<Void, Never>?
    private var sortedNodes: [ArchiveNode] = []
    private var appliedSort = PreviewArchiveSort(foldersFirst: false)
    private let filterDelay: Duration
    private let loadListing: @Sendable (URL) async throws -> PreviewArchiveListing

    init(
        filterDelay: Duration = defaultFilterDelay,
        loadListing: @escaping @Sendable (URL) async throws -> PreviewArchiveListing = { url in
            try await offMain { try PreviewArchiveListing(reading: url) }
        }
    ) {
        self.filterDelay = filterDelay
        self.loadListing = loadListing
    }

    func load(_ url: URL) async {
        generation += 1
        transformGeneration += 1
        transformTask?.cancel()
        transformTask = nil
        query = ""
        sortColumn = .name
        sortAscending = true
        sortedNodes = []
        visibleNodes = []
        visibleCount = 0
        let expected = generation
        phase = .loading
        do {
            let listing = try await loadListing(url)
            guard expected == generation, !Task.isCancelled else { return }
            if let failure = listing.emptyFailure {
                phase = .failed(failure)
                return
            }
            phase = .listed(listing)
            sortedNodes = listing.nodes
            appliedSort = PreviewArchiveSort(column: .name, ascending: true, foldersFirst: listing.foldersFirst)
            show(listing.nodes, count: listing.itemCount)
            AccessibilityNotification.Announcement(listing.summary).post()
        } catch is CancellationError {
            return
        } catch {
            guard expected == generation, !Task.isCancelled else { return }
            Logger(category: "finder-preview").error("Archive listing failed: \(String(describing: error))")
            phase = .failed(PreviewArchiveFailure(error))
        }
    }

    func filter(_ search: String) async {
        guard case .listed(let listing) = phase, search != query else { return }
        query = search
        transformGeneration += 1
        transformTask?.cancel()
        transformTask = nil
        let expectedGeneration = generation
        let expectedTransform = transformGeneration
        let targetSort = PreviewArchiveSort(
            column: sortColumn, ascending: sortAscending, foldersFirst: listing.foldersFirst)
        let needsResort = appliedSort != targetSort
        if search.isEmpty, !needsResort {
            return show(sortedNodes, count: listing.itemCount)
        }
        do {
            if !search.isEmpty, filterDelay > .zero {
                try await Task.sleep(for: filterDelay)
            }
            guard expectedGeneration == generation, expectedTransform == transformGeneration, !Task.isCancelled else {
                return
            }
            let baseNodes = needsResort ? listing.nodes : sortedNodes
            let result = try await offMain {
                let ordered = needsResort ? try targetSort.sorted(baseNodes) : baseNodes
                let displayed =
                    search.isEmpty
                    ? ordered
                    : try ArchiveTree.filtered(ordered, query: search) { try Task.checkCancellation() }
                let count = search.isEmpty ? listing.itemCount : ArchiveTree.count(displayed)
                return (ordered, displayed, count)
            }
            guard expectedGeneration == generation, expectedTransform == transformGeneration, !Task.isCancelled else {
                return
            }
            if needsResort {
                sortedNodes = result.0
                appliedSort = targetSort
            }
            show(result.1, count: result.2)
        } catch {
            return
        }
    }

    func sort(by column: PreviewArchiveColumn, ascending: Bool) {
        guard case .listed = phase, column != sortColumn || ascending != sortAscending else { return }
        transformTask?.cancel()
        transformTask = Task { [weak self] in
            await self?.applySort(column: column, ascending: ascending)
        }
    }

    func applySort(column: PreviewArchiveColumn, ascending: Bool) async {
        guard case .listed(let listing) = phase else { return }
        sortColumn = column
        sortAscending = ascending
        transformGeneration += 1
        let expectedGeneration = generation
        let expectedTransform = transformGeneration
        let currentQuery = query
        let targetSort = PreviewArchiveSort(column: column, ascending: ascending, foldersFirst: listing.foldersFirst)
        let sourceNodes = listing.nodes
        do {
            let result = try await offMain {
                let ordered =
                    targetSort.column == .name && targetSort.ascending
                    ? sourceNodes
                    : try targetSort.sorted(sourceNodes)
                let displayed =
                    currentQuery.isEmpty
                    ? ordered
                    : try ArchiveTree.filtered(ordered, query: currentQuery) { try Task.checkCancellation() }
                let count = currentQuery.isEmpty ? listing.itemCount : ArchiveTree.count(displayed)
                return (ordered, displayed, count)
            }
            guard expectedGeneration == generation, expectedTransform == transformGeneration, !Task.isCancelled else {
                return
            }
            sortedNodes = result.0
            appliedSort = targetSort
            show(result.1, count: result.2)
        } catch {
            return
        }
    }

    var isFiltering: Bool { !query.isEmpty }

    private func show(_ nodes: [ArchiveNode], count: Int) {
        visibleNodes = nodes
        visibleCount = count
        visibleRevision += 1
    }
}

struct PreviewPanelAction {
    let present: @MainActor (MenuEntry, [URL]) -> Void

    @MainActor func callAsFunction(_ entry: MenuEntry, _ inputs: [URL]) { present(entry, inputs) }
}

extension EnvironmentValues {
    @Entry var presentPanel: PreviewPanelAction?
}

struct PreviewArchiveViewer: View {
    private static let browseEntry = MenuEntry(op: .archiveBrowse, preset: nil, path: [])
    private static let searchWidth: CGFloat = 220

    let url: URL
    @State private var model = PreviewArchiveModel()
    @State private var search = ""
    @Environment(\.presentPanel) private var presentPanel

    static func canBrowse(_ url: URL) -> Bool {
        MenuLayout.isApplicable(browseEntry, selection: [url])
    }

    var body: some View {
        VStack(spacing: 0) {
            PreviewToolbar {
                if case .listed = model.phase {
                    TextField("Search", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: Self.searchWidth)
                }
                Spacer(minLength: 0)
                if let presentPanel, Self.canBrowse(url) {
                    Button {
                        presentPanel(Self.browseEntry, [url])
                    } label: {
                        Image(systemName: "arrow.up.forward.app").frame(width: 24, height: 24)
                    }
                    .buttonStyle(PreviewButtonStyle(cornerRadius: 6, restingOpacity: 0))
                    .help(MenuStrings.operationName(.archiveBrowse))
                    .accessibilityLabel(MenuStrings.operationName(.archiveBrowse))
                }
            }
            content
        }
        .task { await model.load(url) }
        .task(id: search) { await model.filter(search) }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let failure):
            PreviewFailure(message: failure.message)
        case .listed(let listing):
            notes(listing)
            if listing.ending == .complete, listing.nodes.isEmpty {
                PreviewFailure(message: Text("This archive is empty."))
            } else if model.visibleNodes.isEmpty {
                PreviewFailure(message: Text("No items match."))
            } else {
                PreviewArchiveOutline(
                    roots: model.visibleNodes, revision: model.visibleRevision,
                    expandsAll: model.isFiltering && model.visibleCount <= PreviewArchiveModel.filterExpansionLimit,
                    sortColumn: model.sortColumn, sortAscending: model.sortAscending
                ) { column, ascending in
                    model.sort(by: column, ascending: ascending)
                }
            }
        }
    }

    @ViewBuilder private func notes(_ listing: PreviewArchiveListing) -> some View {
        switch listing.ending {
        case .complete:
            PreviewNote(
                symbol: "archivebox", text: Text(verbatim: listing.noteText),
                shortText: Text(verbatim: listing.shortNoteText))
        case .entryLimit, .nameLimit, .skipLimit, .timeLimit:
            PreviewNote(
                symbol: "info.circle", text: Text(verbatim: listing.noteText),
                shortText: Text(verbatim: listing.shortNoteText))
        case .damaged:
            PreviewNote(
                symbol: "exclamationmark.triangle.fill", text: Text(verbatim: listing.noteText),
                shortText: Text(verbatim: listing.shortNoteText), tint: .yellow)
        }
        if listing.hasEncryptedItems {
            PreviewNote(symbol: "lock.fill", text: Text("Items with a lock are password-protected."))
        }
    }
}
