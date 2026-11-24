import Foundation

@testable import MenuCatalog

/// Frozen schema 3 menu code from 391b1f7.
enum LegacyMenuOracle {
    struct Settings {
        var visibleOperations = OperationID.menuOrder
        var hiddenEntries: Set<String> = []
        var placements: [String: MenuPlacement] = [:]
        var extraRotationDegrees: Double?
        var speechAvailable = true
        var tgaAvailable = true
        var updateTitle: String?
        var previewTitle: String?
    }

    private struct Entry {
        let entry: MenuEntry
        let placement: MenuPlacement?

        var resolvedPlacement: MenuPlacement {
            entry.kind == .any ? .more : placement ?? entry.op.defaultMenuPlacement
        }

        var primaryMenuRank: Int {
            let order = OperationID.primaryMenuOrder
            return order.firstIndex(of: entry.op.menuGroupOperation) ?? order.count
        }
    }

    private enum Node {
        case submenu(title: String, children: [Node])
        case action(title: String, entryIndex: Int)
        case command(String)
        case separator
    }

    static let titles = MenuTitles(
        operation: { $0.rawValue }, preset: { "\($0.rawValue)/\($1)" }, kind: { $0.rawValue })

    /// Flattened Finder context menus, one per selection.
    static func menus(_ settings: Settings, selections: [[URL]]) -> [[String]] {
        let entries = entries(settings)
        return selections.map { menu(entries, settings: settings, selection: $0) }
    }

    private static func menu(_ entries: [Entry], settings: Settings, selection: [URL]) -> [String] {
        var finder: [Node] = []
        var macEase: [Node] = []
        if let title = settings.updateTitle { macEase.append(.command(title)) }
        if let title = settings.previewTitle { macEase.append(.command(title)) }
        let nodes = nodes(entries, selection: selection, moreTitle: "More")
        if let index = entries.firstIndex(where: {
            $0.entry.op == .folderDownloadMedia && SelectionSummary(selection).allows($0.entry)
        }), let title = entries[index].entry.path.last {
            finder.append(.action(title: title, entryIndex: index))
        }
        if !macEase.isEmpty, !nodes.isEmpty { macEase.append(.separator) }
        macEase += nodes
        let all = entries.map(\.entry)
        return flatten(finder, entries: all, prefix: "F ") + flatten(macEase, entries: all, prefix: "M ")
    }

    private static func flatten(_ nodes: [Node], entries: [MenuEntry], prefix: String) -> [String] {
        nodes.flatMap { node -> [String] in
            switch node {
            case .separator: ["\(prefix)—"]
            case .command(let title): ["\(prefix)\(title) [command]"]
            case .action(let title, let index):
                ["\(prefix)\(title) [\(entries[index].op.rawValue)/\(entries[index].preset ?? "")]"]
            case .submenu(let title, let children):
                ["\(prefix)▸ \(title)"] + flatten(children, entries: entries, prefix: prefix + "  ")
            }
        }
    }

    private static func entries(_ settings: Settings) -> [Entry] {
        let titles = MenuTitles(
            operation: titles.operation, preset: titles.preset, kind: titles.kind,
            speechAvailable: settings.speechAvailable, tgaAvailable: settings.tgaAvailable)
        let hiddenEntries = settings.hiddenEntries
        let extraRotationDegrees = settings.extraRotationDegrees
        let placements = settings.placements
        var entries: [Entry] = []
        let visible = Set(settings.visibleOperations)
        let animations: Set<OperationID> = [.videoToGIF, .videoToAnimatedWebP, .videoToAPNG]
        var hasAnimations = false
        var operationBoundaries: Set<FileKind> = []
        for op in OperationID.menuOrder {
            if op.legacyStartsGroup { operationBoundaries.insert(op.kind) }
            guard visible.contains(op) else { continue }
            if !titles.speechAvailable, op == .audioSubtitles || op == .videoSubtitles { continue }
            let parent = op.menuGroupOperation
            let opTitle = titles.operation(parent)
            var groups = op.presetGroups
            if extraRotationDegrees != nil, op == .imageRotate || op == .videoRotate {
                groups[0].append("extra-angle")
            }
            if op.offersCustom { groups.append([MenuEntry.customPreset]) }
            if groups.isEmpty {
                if !hiddenEntries.contains("\(op.rawValue)/") {
                    let isSDR = op == .imageHDRToSDR || op == .videoHDRToSDR
                    entries.append(
                        Entry(
                            entry: MenuEntry(
                                op: op, preset: nil, path: isSDR ? [opTitle, titles.operation(op)] : [opTitle],
                                separatorBefore: isSDR,
                                operationSeparatorBefore: operationBoundaries.remove(op.kind) != nil,
                                groupID: op.menuGroupID(preset: nil)),
                            placement: placements[op.menuGroupID(preset: nil)]))
                }
                continue
            }
            for (groupIndex, presets) in groups.enumerated() {
                let presets = presets.filter {
                    !hiddenEntries.contains("\(op.rawValue)/\($0)")
                        && (op != .imageConvert || $0 != "tga" || titles.tgaAvailable)
                }
                for (presetIndex, preset) in presets.enumerated() {
                    let flat = op == .textJSON
                    let boundary =
                        groupIndex > 0 || op == .imageFlip || op == .videoFlip
                        || (animations.contains(op) && !hasAnimations)
                    entries.append(
                        Entry(
                            entry: MenuEntry(
                                op: op, preset: preset,
                                path: flat ? [titles.preset(op, preset)] : [opTitle, titles.preset(op, preset)],
                                separatorBefore: presetIndex == 0 && boundary,
                                operationSeparatorBefore: operationBoundaries.remove(op.kind) != nil,
                                groupID: op.menuGroupID(preset: preset)),
                            placement: placements[op.menuGroupID(preset: preset)]))
                    if animations.contains(op) { hasAnimations = true }
                }
            }
        }
        return entries
    }

    private static func nodes(_ entries: [Entry], selection: [URL], moreTitle: String) -> [Node] {
        var primary: [FileKind: [(Int, Entry)]] = [:]
        var more: [FileKind: [(Int, Entry)]] = [:]
        for (index, entry) in entries.enumerated() where entry.entry.op != .folderDownloadMedia {
            if entry.resolvedPlacement == .primary {
                primary[entry.entry.kind, default: []].append((index, entry))
            } else {
                more[entry.entry.kind, default: []].append((index, entry))
            }
        }
        let summary = SelectionSummary(selection)
        func count(_ kind: FileKind) -> Int { summary.count(for: kind) }
        let selectedKinds = FileKind.menuOrder.filter { $0 != .any && count($0) > 0 }
        let singleKind = selectedKinds.count == 1 && selectedKinds.first.map(count) == selection.count
        var nodes: [Node] = []
        var moreNodes: [Node] = []
        for kind in FileKind.menuOrder {
            let title = "\(kind.rawValue) (\(count(kind)))"
            let ordered = (primary[kind] ?? []).sorted {
                let left = $0.1.primaryMenuRank
                let right = $1.1.primaryMenuRank
                return left == right ? $0.0 < $1.0 : left < right
            }
            let children = operationNodes(ordered, summary: summary)
            if !children.isEmpty {
                if singleKind { nodes += children } else { nodes.append(.submenu(title: title, children: children)) }
            }
            var overflow = operationNodes(more[kind] ?? [], summary: summary)
            if !singleKind, !selectedKinds.isEmpty {
                overflow = overflow.map { node in
                    switch node {
                    case .action(let operation, let index): .action(title: "\(title): \(operation)", entryIndex: index)
                    case .submenu(let operation, let children):
                        .submenu(title: "\(title): \(operation)", children: children)
                    case .separator, .command: node
                    }
                }
            }
            if !overflow.isEmpty {
                if !moreNodes.isEmpty { moreNodes.append(.separator) }
                moreNodes += overflow
            }
        }
        if !moreNodes.isEmpty {
            if !nodes.isEmpty { nodes.append(.separator) }
            nodes.append(.submenu(title: moreTitle, children: moreNodes))
        }
        return nodes
    }

    private static func operationNodes(_ entries: [(Int, Entry)], summary: SelectionSummary) -> [Node] {
        var nodes: [Node] = []
        var openTitle: String?
        var openGroup: String?
        var openChildren: [Node] = []
        var pendingBoundaries: Set<String> = []
        let rootLevel = ""
        var operationBoundary = false

        func closeSubmenu() {
            if let title = openTitle, !openChildren.isEmpty {
                nodes.append(.submenu(title: title, children: openChildren))
            }
            openTitle = nil
            openGroup = nil
            openChildren = []
        }

        func isSeparator(_ node: Node?) -> Bool {
            if case .separator = node { true } else { false }
        }

        for (index, wrapped) in entries {
            let entry = wrapped.entry
            guard let title = entry.path.first else { continue }
            let parent = entry.path.count > 1 ? entry.resolvedGroupID : rootLevel
            if entry.separatorBefore { pendingBoundaries.insert(parent) }
            if entry.operationSeparatorBefore { operationBoundary = true }
            guard summary.allows(entry) else { continue }
            if entry.path.count == 1 || openGroup != entry.resolvedGroupID {
                closeSubmenu()
                if operationBoundary, !nodes.isEmpty, !isSeparator(nodes.last) { nodes.append(.separator) }
                operationBoundary = false
            }
            if entry.path.count == 1 {
                if pendingBoundaries.remove(parent) != nil, !nodes.isEmpty, !isSeparator(nodes.last) {
                    nodes.append(.separator)
                }
                nodes.append(.action(title: title, entryIndex: index))
            } else if let leafTitle = entry.path.last {
                if openGroup != entry.resolvedGroupID {
                    closeSubmenu()
                    openTitle = title
                    openGroup = entry.resolvedGroupID
                }
                if pendingBoundaries.remove(parent) != nil, !openChildren.isEmpty {
                    openChildren.append(.separator)
                }
                openChildren.append(.action(title: leafTitle, entryIndex: index))
            }
        }
        closeSubmenu()
        return nodes
    }
}

extension OperationID {
    fileprivate var legacyStartsGroup: Bool {
        switch self {
        case .imageToPDF, .imageAIRename, .pdfAIRename,
            .textJSON, .folderRemoveDuplicates, .folderAIRename:
            true
        default: false
        }
    }
}
