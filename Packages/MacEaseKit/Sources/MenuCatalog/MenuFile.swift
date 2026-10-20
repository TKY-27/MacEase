import CryptoKit
import Foundation

public struct MenuEntry: Codable, Hashable, Sendable {
    public static let customPreset = "custom"

    public let op: OperationID
    public let preset: String?
    public let kind: FileKind
    public let path: [String]

    public init(op: OperationID, preset: String?, path: [String]) {
        self.op = op
        self.preset = preset
        self.kind = op.kind
        self.path = path
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
    public static let currentSchema = 1

    public let schema: Int
    public let catalogVersion: String
    public let token: String
    public let hostAvailable: Bool
    public let entries: [MenuEntry]
    public let kinds: [String: KindTitle]

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
            ([entry.op.rawValue, entry.preset ?? "", entry.kind.rawValue] + entry.path).joined(separator: unitSeparator)
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
        self = try JSONDecoder().decode(MenuFile.self, from: json)
    }
}

/// Localized titles supplied by the host.
public struct MenuTitles: Sendable {
    public let operation: @Sendable (OperationID) -> String
    public let preset: @Sendable (OperationID, String) -> String
    public let kind: @Sendable (FileKind) -> String

    public init(
        operation: @escaping @Sendable (OperationID) -> String,
        preset: @escaping @Sendable (OperationID, String) -> String,
        kind: @escaping @Sendable (FileKind) -> String
    ) {
        self.operation = operation
        self.preset = preset
        self.kind = kind
    }
}

extension MenuFile {
    public init(
        token: String,
        hostAvailable: Bool,
        visibleOperations: [OperationID],
        titles: MenuTitles
    ) {
        var entries: [MenuEntry] = []
        for op in visibleOperations {
            let opTitle = titles.operation(op)
            guard op.offersCustom else {
                entries.append(MenuEntry(op: op, preset: nil, path: [opTitle]))
                continue
            }
            for preset in op.presets + [MenuEntry.customPreset] {
                entries.append(MenuEntry(op: op, preset: preset, path: [opTitle, titles.preset(op, preset)]))
            }
        }
        let kinds = Dictionary(uniqueKeysWithValues: FileKind.allCases.map { ($0, titles.kind($0)) })
        self.init(token: token, hostAvailable: hostAvailable, entries: entries, kinds: kinds)
    }
}
