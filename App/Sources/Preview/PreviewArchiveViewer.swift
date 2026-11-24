import Engine
import Formats
import MenuCatalog
import Observation
import SwiftUI

struct PreviewArchiveListing: Sendable {
    let nodes: [ArchiveNode]
    let entryCount: Int
    let itemCount: Int
    let expandedBytes: Int64
    let ending: ArchiveContents.Ending
    let hasEncryptedItems: Bool
    let foldersFirst: Bool

    init(reading url: URL, foldersFirst: Bool = PreviewArchiveSort.finderKeepsFoldersOnTop) throws {
        let contents = try ArchiveContents.list(url.resolvingSymlinksInPath()) { try Task.checkCancellation() }
        let entries = contents.entries.enumerated().map { index, entry in
            ArchiveEntry(
                id: index, path: entry.path, isDirectory: entry.isDirectory, size: entry.size,
                isEncrypted: entry.isEncrypted, modified: entry.modified)
        }
        nodes = try PreviewArchiveSort.nameSorted(ArchiveTree.nodes(entries), foldersFirst: foldersFirst)
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

    var summary: String {
        String(
            localized: "\(itemCount) items, \(expandedBytes.formatted(.byteCount(style: .file))) uncompressed",
            comment: "Archive preview summary")
    }

    var shortSummary: String {
        String(localized: "\(itemCount) items", comment: "Archive preview summary for narrow panels")
    }
}

enum PreviewArchiveFailure: Equatable {
    case unsupported, damaged, passwordProtected, tooLarge, unreadable

    init(_ error: any Error) {
        switch error {
        case ArchiveContents.Failure.unsupported: self = .unsupported
        case ArchiveContents.Failure.damaged: self = .damaged
        case ArchiveContents.Failure.passwordProtected: self = .passwordProtected
        case ArchiveContents.Failure.tooLarge, ArchiveTreeError.tooLarge: self = .tooLarge
        default: self = .unreadable
        }
    }

    var message: Text {
        switch self {
        case .unsupported: Text("MacEase can't list this kind of archive.")
        case .damaged: Text("This archive is damaged, so its contents can't be listed.")
        case .passwordProtected: Text("This archive is password-protected.")
        case .tooLarge: Text("This archive has too many items to list.")
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

    private static let filterDelay = Duration.milliseconds(150)
    // Larger expansions would stall the panel.
    static let filterExpansionLimit = 2_000

    private(set) var phase = Phase.loading
    private(set) var visibleNodes: [ArchiveNode] = []
    private(set) var visibleRevision = 0
    private(set) var visibleCount = 0
    private var generation = 0
    private var query = ""

    func load(_ url: URL) async {
        generation += 1
        let expected = generation
        phase = .loading
        do {
            let listing = try await offMain { try PreviewArchiveListing(reading: url) }
            guard expected == generation, !Task.isCancelled else { return }
            phase = .listed(listing)
            show(listing.nodes, count: listing.itemCount)
            AccessibilityNotification.Announcement(listing.summary).post()
        } catch is CancellationError {
            return
        } catch {
            guard expected == generation, !Task.isCancelled else { return }
            phase = .failed(PreviewArchiveFailure(error))
        }
    }

    func filter(_ search: String) async {
        guard case .listed(let listing) = phase, search != query else { return }
        query = search
        guard !search.isEmpty else { return show(listing.nodes, count: listing.itemCount) }
        do {
            try await Task.sleep(for: Self.filterDelay)
            let matches = try await offMain {
                let nodes = ArchiveTree.filtered(listing.nodes, query: search)
                return (nodes, ArchiveTree.count(nodes))
            }
            guard query == search else { return }
            show(matches.0, count: matches.1)
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

    var body: some View {
        VStack(spacing: 0) {
            PreviewToolbar {
                if case .listed = model.phase {
                    TextField("Search", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: Self.searchWidth)
                }
                Spacer(minLength: 0)
                if let presentPanel, MenuLayout.isApplicable(Self.browseEntry, selection: [url]) {
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
            if listing.nodes.isEmpty {
                PreviewFailure(message: Text("This archive is empty."))
            } else if model.visibleNodes.isEmpty {
                PreviewFailure(message: Text("No items match."))
            } else {
                PreviewArchiveOutline(
                    roots: model.visibleNodes, revision: model.visibleRevision,
                    expandsAll: model.isFiltering && model.visibleCount <= PreviewArchiveModel.filterExpansionLimit,
                    foldersFirst: listing.foldersFirst)
            }
        }
    }

    @ViewBuilder private func notes(_ listing: PreviewArchiveListing) -> some View {
        switch listing.ending {
        case .complete:
            PreviewNote(
                symbol: "archivebox", text: Text(verbatim: listing.summary),
                shortText: Text(verbatim: listing.shortSummary))
        case .entryLimit, .nameLimit, .timeLimit:
            PreviewNote(
                symbol: "info.circle", text: Text("Showing the first \(listing.entryCount) items."),
                shortText: Text("First \(listing.entryCount) items"))
        case .damaged:
            PreviewNote(
                symbol: "exclamationmark.triangle.fill",
                text: Text("This archive is damaged. Showing the first \(listing.entryCount) items."),
                shortText: Text("Damaged · first \(listing.entryCount) items"), tint: .yellow)
        }
        if listing.hasEncryptedItems {
            PreviewNote(symbol: "lock.fill", text: Text("Items with a lock are password-protected."))
        }
    }
}
