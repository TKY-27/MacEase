import Foundation

enum FinderPreviewFileType: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case text
    case html
    case markdown
    case svg
    case pdf
    case font
    case image
    case video
    case audio

    var id: String { rawValue }
}

struct FinderPreviewSettings: Codable, Equatable, Sendable {
    static let defaultsKey = "finderPreview.settings"
    static let codeFontSizeRange = 9...24
    static let defaultCodeFontSize = 12
    static let defaultFontSampleText = "The quick brown fox jumps over the lazy dog.\n0123456789 !@#$%&*()"

    var disabledKinds: Set<FinderPreviewFileType>
    /// Empty means the system monospaced font.
    var codeFontFamily: String
    var codeFontSize: Int {
        didSet {
            let clamped = Self.clampFontSize(codeFontSize)
            if codeFontSize != clamped { codeFontSize = clamped }
        }
    }
    var wrapLines: Bool
    /// Empty uses `defaultFontSampleText`.
    var fontSampleText: String
    var trustedFolders: [String] {
        didSet {
            let normalized = Self.normalizeFolders(trustedFolders)
            if trustedFolders != normalized { trustedFolders = normalized }
        }
    }

    init(
        disabledKinds: Set<FinderPreviewFileType> = [],
        codeFontFamily: String = "",
        codeFontSize: Int = defaultCodeFontSize,
        wrapLines: Bool = true,
        fontSampleText: String = "",
        trustedFolders: [String] = []
    ) {
        self.disabledKinds = disabledKinds
        self.codeFontFamily = codeFontFamily
        self.codeFontSize = Self.clampFontSize(codeFontSize)
        self.wrapLines = wrapLines
        self.fontSampleText = fontSampleText
        self.trustedFolders = Self.normalizeFolders(trustedFolders)
    }

    var effectiveFontSampleText: String {
        fontSampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultFontSampleText : fontSampleText
    }

    mutating func addTrustedFolder(_ url: URL) {
        trustedFolders.append(Self.standardizeFolderURL(url))
    }

    mutating func removeTrustedFolder(_ path: String) {
        let target = Self.standardizeFolderPath(path)
        trustedFolders.removeAll { $0 == target }
    }

    static func standardizeFolderURL(_ url: URL) -> String {
        standardizeFolderPath(url.path)
    }

    static func standardizeFolderPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    static func decode(_ stored: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: stored)
    }

    private enum CodingKeys: String, CodingKey {
        case disabledKinds, codeFontFamily, codeFontSize, wrapLines, fontSampleText, trustedFolders
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKinds = try container.decodeIfPresent([String].self, forKey: .disabledKinds) ?? []
        disabledKinds = Set(rawKinds.compactMap(FinderPreviewFileType.init(rawValue:)))
        codeFontFamily = try container.decodeIfPresent(String.self, forKey: .codeFontFamily) ?? ""
        let decodedSize = try container.decodeIfPresent(Int.self, forKey: .codeFontSize) ?? Self.defaultCodeFontSize
        codeFontSize = Self.clampFontSize(decodedSize)
        wrapLines = try container.decodeIfPresent(Bool.self, forKey: .wrapLines) ?? true
        fontSampleText = try container.decodeIfPresent(String.self, forKey: .fontSampleText) ?? ""
        let decodedFolders = try container.decodeIfPresent([String].self, forKey: .trustedFolders) ?? []
        trustedFolders = Self.normalizeFolders(decodedFolders)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(disabledKinds.map(\.rawValue).sorted(), forKey: .disabledKinds)
        try container.encode(codeFontFamily, forKey: .codeFontFamily)
        try container.encode(codeFontSize, forKey: .codeFontSize)
        try container.encode(wrapLines, forKey: .wrapLines)
        try container.encode(fontSampleText, forKey: .fontSampleText)
        try container.encode(trustedFolders, forKey: .trustedFolders)
    }

    private static func clampFontSize(_ value: Int) -> Int {
        min(max(value, codeFontSizeRange.lowerBound), codeFontSizeRange.upperBound)
    }

    private static func normalizeFolders(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []
        for path in paths {
            let standardized = standardizeFolderPath(path)
            guard !standardized.isEmpty, seen.insert(standardized).inserted else { continue }
            normalized.append(standardized)
        }
        return normalized
    }
}
