import CryptoKit
import Foundation

public enum MenuPlacement: String, Codable, Sendable {
    case finder, primary, more
}

public struct MenuEntry: Codable, Hashable, Sendable {
    public static let customPreset = "custom"

    public let op: OperationID
    public let preset: String?
    public let kind: FileKind
    public let path: [String]
    public let separatorBefore: Bool
    public let operationSeparatorBefore: Bool
    public let targetBytes: Int64?
    public let resizeValue: Int?
    public let parameterVersion: String?
    public let minimumSelection: Int
    public let maximumSelection: Int?
    public let sourceFormats: Set<String>?
    public let targetFormat: String?
    public let requiresSingleSourceFormat: Bool
    public let rotationDegrees: Double?
    public let frameRate: Int?
    public let targetLoudness: Double?
    public let recipeID: UUID?
    public let recipeRevision: String?
    public let acceptedKinds: Set<FileKind>?
    public let groupID: String?
    public let placement: MenuPlacement

    public init(
        op: OperationID, preset: String?, path: [String], separatorBefore: Bool = false,
        operationSeparatorBefore: Bool = false, targetBytes: Int64? = nil, resizeValue: Int? = nil,
        parameterVersion: String? = nil,
        rotationDegrees: Double? = nil, frameRate: Int? = nil, targetLoudness: Double? = nil,
        recipeID: UUID? = nil, recipeRevision: String? = nil, acceptedKinds: Set<FileKind>? = nil,
        groupID: String? = nil, placement: MenuPlacement? = nil
    ) {
        self.groupID = groupID
        self.placement = placement ?? op.defaultMenuPlacement
        self.op = op
        self.preset = preset
        self.kind = op.kind
        self.path = path
        self.separatorBefore = separatorBefore
        self.operationSeparatorBefore = operationSeparatorBefore
        self.targetBytes = targetBytes
        self.resizeValue = resizeValue
        self.parameterVersion = parameterVersion
        self.minimumSelection = op.minimumSelection
        self.maximumSelection = preset == "choose-frame" ? 1 : op.maximumSelection
        self.requiresSingleSourceFormat = op == .textConvert
        self.rotationDegrees = rotationDegrees
        self.frameRate = frameRate
        self.targetLoudness = targetLoudness
        self.recipeID = recipeID
        self.recipeRevision = recipeRevision
        self.acceptedKinds = acceptedKinds ?? (op == .filesFinish ? [.image, .video, .pdf] : nil)
        switch op {
        case .imageTraceSVG: self.sourceFormats = ["png"]
        case .archiveBrowse: self.sourceFormats = ["zip"]
        case .archiveExtract: self.sourceFormats = ["rar"]
        case .archiveHatchExtract:
            self.sourceFormats = ["zip", "7z", "tar", "tar.gz", "zip.split", "7z.split", "tar.gz.split"]
        case .imageHDRToSDR: self.sourceFormats = ["heic", "jpeg", "avif", "jxl", "png"]
        case .videoHDRToSDR: self.sourceFormats = ["mov", "mp4", "m4v"]
        case .imageConvert where !["png", "jpeg", "tiff"].contains(preset):
            self.sourceFormats = FileKind.imageConversionSources
        case .textJSON: self.sourceFormats = ["json"]
        case .textConvert:
            self.sourceFormats = preset.flatMap { preset in
                guard preset != "txt", let source = preset.split(separator: "-").first else { return nil }
                return [String(source)]
            }
        default: self.sourceFormats = nil
        }
        switch op {
        case .imageConvert, .videoConvert:
            self.targetFormat = preset.map(FileKind.canonicalFormat)
        case .audioConvert:
            self.targetFormat = preset.flatMap {
                $0.hasPrefix("m4a-") || $0.hasPrefix("caf-") ? nil : FileKind.canonicalFormat($0)
            }
        case .textConvert: self.targetFormat = preset == "txt" ? "txt" : nil
        default: self.targetFormat = nil
        }
    }

    public var resolvedGroupID: String { groupID ?? op.menuGroupID(preset: preset) }

    public var isCustom: Bool { preset == Self.customPreset }
}

public struct KindTitle: Codable, Hashable, Sendable {
    public let title: String

    public init(title: String) {
        self.title = title
    }
}

/// A Commands scope row, in display order.
public struct MenuCommandItem: Codable, Hashable, Sendable {
    public let group: MenuGroupID
    public let title: String
    public let placement: MenuPlacement

    public init(group: MenuGroupID, title: String, placement: MenuPlacement) {
        self.group = group
        self.title = title
        self.placement = placement
    }

    public var command: HostCommand? { HostCommand(group: group) }
}

/// Entries arrive in display order.
public struct MenuFile: Codable, Equatable, Sendable {
    public static let currentSchema = 4

    public let schema: Int
    public let catalogVersion: String
    public let token: String
    public let hostAvailable: Bool
    public let entries: [MenuEntry]
    public let kinds: [String: KindTitle]
    public let moreTitle: String?
    public let commands: [MenuCommandItem]
    public var monitoredDirectoryPaths: [String]?

    public init(
        token: String, hostAvailable: Bool, entries: [MenuEntry], kinds: [FileKind: String], moreTitle: String? = nil,
        commands: [MenuCommandItem] = []
    ) {
        self.schema = Self.currentSchema
        self.moreTitle = moreTitle
        self.commands = commands
        self.catalogVersion = Self.version(of: entries, moreTitle: moreTitle, commands: commands)
        self.token = token
        self.hostAvailable = hostAvailable
        self.entries = entries
        self.kinds = Dictionary(uniqueKeysWithValues: kinds.map { ($0.key.rawValue, KindTitle(title: $0.value)) })
    }

    public static func version(
        of entries: [MenuEntry], moreTitle: String? = nil, commands: [MenuCommandItem] = []
    ) -> String {
        let unitSeparator = "\u{1F}"
        let canonical = entries.map { entry in
            let constraints: [String] = [
                entry.groupID ?? "", entry.placement.rawValue,
                String(entry.separatorBefore), String(entry.operationSeparatorBefore),
                entry.targetBytes.map { String($0) } ?? "", entry.resizeValue.map { String($0) } ?? "",
                entry.parameterVersion ?? "",
                String(entry.minimumSelection),
                entry.maximumSelection.map { String($0) } ?? "",
                entry.sourceFormats.map { $0.sorted().joined(separator: ",") } ?? "",
                entry.targetFormat ?? "", String(entry.requiresSingleSourceFormat),
                entry.rotationDegrees.map { String($0) } ?? "",
                entry.frameRate.map { String($0) } ?? "", entry.targetLoudness.map { String($0) } ?? "",
                entry.recipeID?.uuidString ?? "", entry.recipeRevision ?? "",
                entry.acceptedKinds.map { $0.map(\.rawValue).sorted().joined(separator: ",") } ?? "",
            ]
            return ([entry.op.rawValue, entry.preset ?? "", entry.kind.rawValue] + constraints + entry.path)
                .joined(separator: unitSeparator)
        }.joined(separator: "\u{1E}")
        let localized = moreTitle.map { canonical + "\u{1E}" + $0 } ?? canonical
        let withCommands = commands.reduce(localized) { hashed, item in
            hashed + "\u{1E}command\u{1F}"
                + [item.group.rawValue, item.title, item.placement.rawValue].joined(separator: unitSeparator)
        }
        return SHA256.hash(data: Data(withCommands.utf8)).hexEncoded
    }

    public func kindTitle(_ kind: FileKind) -> String {
        kinds[kind.rawValue]?.title ?? kind.rawValue
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public init(json: Data) throws {
        let decoder = JSONDecoder()
        let schema = try decoder.decode(MenuSchema.self, from: json).schema
        guard schema == Self.currentSchema else { throw MenuFileError.unsupportedSchema(schema) }
        let file = try decoder.decode(MenuFile.self, from: json)
        // Mismatched indices would run another operation.
        guard file.catalogVersion == Self.version(of: file.entries, moreTitle: file.moreTitle, commands: file.commands)
        else { throw MenuFileError.catalogMismatch }
        self = file
    }
}

/// Localized titles supplied by the host.
public struct MenuTitles: Sendable {
    public let operation: @Sendable (OperationID) -> String
    public let preset: @Sendable (OperationID, String) -> String
    public let kind: @Sendable (FileKind) -> String
    public let speechAvailable: Bool
    public let tgaAvailable: Bool

    public init(
        operation: @escaping @Sendable (OperationID) -> String,
        preset: @escaping @Sendable (OperationID, String) -> String,
        kind: @escaping @Sendable (FileKind) -> String,
        speechAvailable: Bool = true, tgaAvailable: Bool = true
    ) {
        self.operation = operation
        self.preset = preset
        self.kind = kind
        self.speechAvailable = speechAvailable
        self.tgaAvailable = tgaAvailable
    }
}

public enum MenuFileError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case catalogMismatch
}

private struct MenuSchema: Decodable {
    let schema: Int
}

extension MenuFile {
    public init(
        token: String,
        hostAvailable: Bool,
        visibleOperations: [OperationID],
        titles: MenuTitles,
        hiddenEntries: Set<String> = [],
        extraRotationDegrees: Double? = nil,
        frameRates: [String: Int] = [:], loudnessTargets: [String: Double] = [:],
        sizeTargets: [String: Int64] = [:], resizeTargets: [String: Int] = [:], parameterVersion: String? = nil,
        arrangement: MenuArrangement = MenuArrangement(), moreTitle: String? = nil,
        commandTitles: [HostCommand: String] = [:]
    ) {
        let catalog = MenuGroupCatalog.current
        let scopes = Dictionary(
            uniqueKeysWithValues: MenuScope.allCases.map { ($0, arrangement.resolved($0, catalog: catalog)) })
        let placed = Self.placedGroups(scopes.values, catalog: catalog)
        var groups: [String: [MenuEntry]] = [:]
        let visible = Set(visibleOperations)
        let animations: Set<OperationID> = [.videoToGIF, .videoToAnimatedWebP, .videoToAPNG]
        var hasAnimations = false
        var operationBoundaries: Set<FileKind> = []
        for op in OperationID.menuOrder {
            if op.startsGroup { operationBoundaries.insert(op.kind) }
            guard visible.contains(op) else { continue }
            if !titles.speechAvailable, op == .audioSubtitles || op == .videoSubtitles { continue }
            let parent = op.menuGroupOperation
            let opTitle = titles.operation(parent)
            var presetGroups = op.presetGroups
            if extraRotationDegrees != nil, op == .imageRotate || op == .videoRotate {
                presetGroups[0].append(OperationID.extraAnglePreset)
            }
            if op.offersCustom { presetGroups.append([MenuEntry.customPreset]) }
            if presetGroups.isEmpty {
                let groupID = op.menuGroupID(preset: nil)
                if !hiddenEntries.contains("\(op.rawValue)/"), let group = placed[groupID] {
                    let isSDR = op == .imageHDRToSDR || op == .videoHDRToSDR
                    let boundary = operationBoundaries.remove(op.kind) != nil
                    groups[groupID, default: []].append(
                        MenuEntry(
                            op: op, preset: nil, path: isSDR ? [opTitle, titles.operation(op)] : [opTitle],
                            separatorBefore: isSDR, operationSeparatorBefore: boundary && group.keepsClusters,
                            parameterVersion: parameterVersion, groupID: groupID, placement: group.placement))
                }
                continue
            }
            for (groupIndex, presets) in presetGroups.enumerated() {
                let presets = presets.filter {
                    !hiddenEntries.contains("\(op.rawValue)/\($0)")
                        && (op != .imageConvert || $0 != "tga" || titles.tgaAvailable)
                }
                for (presetIndex, preset) in presets.enumerated() {
                    let groupID = op.menuGroupID(preset: preset)
                    guard let group = placed[groupID] else { continue }
                    let flat = op == .textJSON
                    let separated =
                        groupIndex > 0 || op == .imageFlip || op == .videoFlip
                        || (animations.contains(op) && !hasAnimations)
                    let boundary = operationBoundaries.remove(op.kind) != nil
                    groups[groupID, default: []].append(
                        MenuEntry(
                            op: op, preset: preset,
                            path: flat ? [titles.preset(op, preset)] : [opTitle, titles.preset(op, preset)],
                            separatorBefore: presetIndex == 0 && separated,
                            operationSeparatorBefore: boundary && group.keepsClusters,
                            targetBytes: sizeTargets["\(op.rawValue)/\(preset)"],
                            resizeValue: resizeTargets["\(op.rawValue)/\(preset)"], parameterVersion: parameterVersion,
                            rotationDegrees: preset == OperationID.extraAnglePreset ? extraRotationDegrees : nil,
                            frameRate: op == .videoFPS ? frameRates[preset] : nil,
                            targetLoudness: op == .audioNormalize ? loudnessTargets[preset] : nil,
                            groupID: groupID, placement: group.placement))
                    if animations.contains(op) { hasAnimations = true }
                }
            }
        }
        let order = ([.commands] + FileKind.menuOrder.map(MenuScope.init)).compactMap { scopes[$0] }
        let entries = order.flatMap { scope in
            scope.scope.sections.flatMap { scope[$0] }.flatMap { groups[$0.rawValue] ?? [] }
        }
        let kinds = Dictionary(uniqueKeysWithValues: FileKind.allCases.map { ($0, titles.kind($0)) })
        self.init(
            token: token, hostAvailable: hostAvailable, entries: entries, kinds: kinds, moreTitle: moreTitle,
            commands: scopes[.commands].map { Self.commands($0, titles: commandTitles, groups: groups) } ?? [])
    }

    private struct PlacedGroup {
        let placement: MenuPlacement
        let keepsClusters: Bool
    }

    /// Reordered sections drop cluster separators.
    private static func placedGroups(
        _ scopes: some Sequence<ScopeArrangement>, catalog: MenuGroupCatalog
    ) -> [String: PlacedGroup] {
        var placed: [String: PlacedGroup] = [:]
        for scope in scopes {
            for section in scope.scope.sections {
                guard let placement = section.placement else { continue }
                let canonical = catalog.isCanonical(scope[section], in: section, of: scope.scope)
                for group in scope[section] {
                    placed[group.rawValue] = PlacedGroup(placement: placement, keepsClusters: canonical)
                }
            }
        }
        return placed
    }

    private static func commands(
        _ scope: ScopeArrangement, titles: [HostCommand: String], groups: [String: [MenuEntry]]
    ) -> [MenuCommandItem] {
        scope.scope.sections.flatMap { section -> [MenuCommandItem] in
            guard let placement = section.placement else { return [] }
            return scope[section].compactMap { group in
                let title =
                    HostCommand(group: group).flatMap { titles[$0] } ?? groups[group.rawValue]?.first?.path.first
                return title.map { MenuCommandItem(group: group, title: $0, placement: placement) }
            }
        }
    }
}

extension OperationID {
    fileprivate var startsGroup: Bool {
        switch self {
        case .imageToPDF, .imageAIRename, .pdfAIRename,
            .textJSON, .folderRemoveDuplicates, .folderAIRename:
            true
        default: false
        }
    }
}
