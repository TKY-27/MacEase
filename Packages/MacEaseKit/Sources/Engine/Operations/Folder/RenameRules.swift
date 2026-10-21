import Foundation
import ImageIO

/// Prefix, date, base, number, suffix.
public struct RenameRules: Codable, Hashable, Sendable {
    public enum DateSource: String, Codable, CaseIterable, Sendable {
        case creation
        case exif
    }

    public struct Numbering: Codable, Hashable, Sendable {
        public var start: Int
        public var step: Int
        public var digits: Int

        public init(start: Int, step: Int, digits: Int) {
            self.start = start
            self.step = step
            self.digits = digits
        }
    }

    private static let separator = " "
    private static let exifDateLength = 10

    public var prefix: String
    public var suffix: String
    public var find: String
    public var replacement: String
    public var numbering: Numbering?
    public var date: DateSource?

    public init(
        prefix: String = "",
        suffix: String = "",
        find: String = "",
        replacement: String = "",
        numbering: Numbering? = nil,
        date: DateSource? = nil
    ) {
        self.prefix = prefix
        self.suffix = suffix
        self.find = find
        self.replacement = replacement
        self.numbering = numbering
        self.date = date
    }

    /// One folder means its visible children.
    public static func targets(for selection: [URL]) throws -> [URL] {
        guard selection.count == 1, let folder = selection.first else { return selection }
        return try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )
        .map { folder.appending(path: $0.lastPathComponent) }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Resolves collisions so applying matches exactly.
    public func plans(for targets: [URL]) throws -> [RenamePlan] {
        var takenByFolder: [URL: Set<String>] = [:]
        var plans: [RenamePlan] = []
        for (index, url) in targets.enumerated() {
            let folder = url.deletingLastPathComponent()
            var taken =
                try takenByFolder[folder]
                ?? Set(FileManager.default.contentsOfDirectory(atPath: folder.path).map(Self.key))
            let ownKey = Self.key(url.lastPathComponent)
            let name = AvailableName.available(try newName(for: url, index: index)) { candidate in
                let candidateKey = Self.key(candidate)
                return candidateKey != ownKey && taken.contains(candidateKey)
            }
            taken.insert(Self.key(name))
            takenByFolder[folder] = taken
            plans.append(RenamePlan(url: url, newName: name))
        }
        return plans
    }

    // APFS compares names without case or normalization.
    private static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private func newName(for url: URL, index: Int) throws -> String {
        let values = try ContentSniffer.inputValues(url)
        let isFolder = values.isDirectory == true && values.isPackage != true
        let original = url.lastPathComponent
        let pathExtension = isFolder ? "" : (original as NSString).pathExtension
        var base = isFolder ? original : (original as NSString).deletingPathExtension
        if !find.isEmpty { base = base.replacingOccurrences(of: find, with: replacement) }
        let parts = [
            try date.map { try dateText(for: url, source: $0) }, base, numbering.map { number($0, index: index) },
        ]
        let stem = prefix + parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: Self.separator) + suffix
        guard !stem.isEmpty else { throw EngineError.invalidInput(.malformed(original)) }
        return pathExtension.isEmpty ? stem : "\(stem).\(pathExtension)"
    }

    private func number(_ numbering: Numbering, index: Int) -> String {
        String(format: "%0\(numbering.digits)ld", numbering.start + index * numbering.step)
    }

    private func dateText(for url: URL, source: DateSource) throws -> String {
        if source == .exif, let exif = Self.exifDate(of: url) { return exif }
        // Files without EXIF use their creation date.
        guard let created = try url.resourceValues(forKeys: [.creationDateKey]).creationDate else {
            throw EngineError.decodeFailed("creation date")
        }
        return Date.ISO8601FormatStyle(timeZone: .current).year().month().day().format(created)
    }

    private static func exifDate(of url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
            let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
            original.count >= exifDateLength
        else { return nil }
        return original.prefix(exifDateLength).replacingOccurrences(of: ":", with: "-")
    }
}
