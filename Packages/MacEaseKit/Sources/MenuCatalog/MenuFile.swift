import CryptoKit
import Foundation

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

    public init(
        op: OperationID, preset: String?, path: [String], separatorBefore: Bool = false,
        operationSeparatorBefore: Bool = false, targetBytes: Int64? = nil, resizeValue: Int? = nil,
        parameterVersion: String? = nil,
        rotationDegrees: Double? = nil, frameRate: Int? = nil, targetLoudness: Double? = nil
    ) {
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
        switch op {
        case .imageTraceSVG: self.sourceFormats = ["png"]
        case .archiveBrowse: self.sourceFormats = ["zip"]
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

    public var isCustom: Bool { preset == Self.customPreset }
}

public struct KindTitle: Codable, Hashable, Sendable {
    public let title: String

    public init(title: String) {
        self.title = title
    }
}

public struct MenuFile: Codable, Equatable, Sendable {
    public static let currentSchema = 2

    public let schema: Int
    public let catalogVersion: String
    public let token: String
    public let hostAvailable: Bool
    public let entries: [MenuEntry]
    public let kinds: [String: KindTitle]
    public var monitoredDirectoryPaths: [String]?

    public init(token: String, hostAvailable: Bool, entries: [MenuEntry], kinds: [FileKind: String]) {
        self.schema = Self.currentSchema
        self.catalogVersion = Self.version(of: entries)
        self.token = token
        self.hostAvailable = hostAvailable
        self.entries = entries
        self.kinds = Dictionary(uniqueKeysWithValues: kinds.map { ($0.key.rawValue, KindTitle(title: $0.value)) })
    }

    public static func version(of entries: [MenuEntry]) -> String {
        let unitSeparator = "\u{1F}"
        let canonical = entries.map { entry in
            let constraints: [String] = [
                String(entry.separatorBefore), String(entry.operationSeparatorBefore),
                entry.targetBytes.map { String($0) } ?? "", entry.resizeValue.map { String($0) } ?? "",
                entry.parameterVersion ?? "",
                String(entry.minimumSelection),
                entry.maximumSelection.map { String($0) } ?? "",
                entry.sourceFormats.map { $0.sorted().joined(separator: ",") } ?? "",
                entry.targetFormat ?? "", String(entry.requiresSingleSourceFormat),
                entry.rotationDegrees.map { String($0) } ?? "",
                entry.frameRate.map { String($0) } ?? "", entry.targetLoudness.map { String($0) } ?? "",
            ]
            return ([entry.op.rawValue, entry.preset ?? "", entry.kind.rawValue] + constraints + entry.path)
                .joined(separator: unitSeparator)
        }.joined(separator: "\u{1E}")
        return SHA256.hash(data: Data(canonical.utf8)).hexEncoded
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
        self = try decoder.decode(MenuFile.self, from: json)
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
        sizeTargets: [String: Int64] = [:], resizeTargets: [String: Int] = [:], parameterVersion: String? = nil
    ) {
        var entries: [MenuEntry] = []
        let visible = Set(visibleOperations)
        let animations: Set<OperationID> = [.videoToGIF, .videoToAnimatedWebP, .videoToAPNG]
        var hasAnimations = false
        var operationBoundaries: Set<FileKind> = []
        for op in OperationID.menuOrder {
            if op.startsGroup { operationBoundaries.insert(op.kind) }
            guard visible.contains(op) else { continue }
            if !titles.speechAvailable, op == .audioSubtitles || op == .videoSubtitles { continue }
            let parent: OperationID =
                switch op {
                case .imageFlip: .imageRotate
                case .imageHDRToSDR: .imageConvert
                case .videoFlip: .videoRotate
                case .videoToGIF, .videoToAnimatedWebP, .videoToAPNG, .videoHDRToSDR: .videoConvert
                default: op
                }
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
                        MenuEntry(
                            op: op, preset: nil, path: isSDR ? [opTitle, titles.operation(op)] : [opTitle],
                            separatorBefore: isSDR,
                            operationSeparatorBefore: operationBoundaries.remove(op.kind) != nil,
                            parameterVersion: parameterVersion))
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
                        MenuEntry(
                            op: op, preset: preset,
                            path: flat ? [titles.preset(op, preset)] : [opTitle, titles.preset(op, preset)],
                            separatorBefore: presetIndex == 0 && boundary,
                            operationSeparatorBefore: operationBoundaries.remove(op.kind) != nil,
                            targetBytes: sizeTargets["\(op.rawValue)/\(preset)"],
                            resizeValue: resizeTargets["\(op.rawValue)/\(preset)"], parameterVersion: parameterVersion,
                            rotationDegrees: preset == "extra-angle" ? extraRotationDegrees : nil,
                            frameRate: op == .videoFPS ? frameRates[preset] : nil,
                            targetLoudness: op == .audioNormalize ? loudnessTargets[preset] : nil))
                    if animations.contains(op) { hasAnimations = true }
                }
            }
        }
        let kinds = Dictionary(uniqueKeysWithValues: FileKind.allCases.map { ($0, titles.kind($0)) })
        self.init(token: token, hostAvailable: hostAvailable, entries: entries, kinds: kinds)
    }
}

extension OperationID {
    fileprivate var startsGroup: Bool {
        switch self {
        case .imageToPDF, .imageAIRename, .videoAICustom, .audioAICustom, .pdfAIRename,
            .textJSON, .folderRemoveDuplicates, .folderAIRename:
            true
        default: false
        }
    }
}
