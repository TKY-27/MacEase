import Foundation
import MenuCatalog
import UniformTypeIdentifiers

public enum PathFormat: String, Codable, CaseIterable, Sendable {
    case posix
    case shellQuoted
}

public enum FinderPaths {
    public static func copyText(for selection: [URL], format: PathFormat = .posix) -> String {
        switch format {
        case .posix:
            return selection.map(\.path).joined(separator: "\n")
        case .shellQuoted:
            return selection.map { shellQuoted($0.path) }.joined(separator: " ")
        }
    }

    public static func shellQuoted(_ path: String) -> String {
        guard !path.isEmpty else { return "''" }
        if path.utf8.allSatisfy(isUnquotedShellByte) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func terminalDirectory(for selection: [URL], targetFolder: URL? = nil) -> URL? {
        var seen = Set<String>()
        let uniqueSelection = selection.compactMap { url -> URL? in
            guard url.isFileURL else { return nil }
            let standardized = url.standardizedFileURL
            return seen.insert(standardized.path).inserted ? standardized : nil
        }
        guard !uniqueSelection.isEmpty else {
            guard let targetFolder, targetFolder.isFileURL else { return nil }
            return directoryForSingleItem(targetFolder.standardizedFileURL)
        }
        if uniqueSelection.count == 1 {
            return directoryForSingleItem(uniqueSelection[0])
        }
        return commonDirectory(of: uniqueSelection.map(parentDirectory))
    }

    private static func isUnquotedShellByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"),
            UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"),
            UInt8(ascii: "/"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
            true
        default:
            false
        }
    }

    private static func directoryForSingleItem(_ url: URL) -> URL {
        if isPlainFolder(url) {
            return URL(fileURLWithPath: url.path, isDirectory: true)
        }
        return parentDirectory(of: url)
    }

    private static func isPlainFolder(_ url: URL) -> Bool {
        guard url.hasDirectoryPath else { return false }
        let suffix = url.pathExtension.lowercased()
        if suffix.isEmpty { return true }
        if FileKind.isPackageExtension(suffix) { return false }
        return UTType(filenameExtension: suffix)?.conforms(to: .package) != true
    }

    private static func parentDirectory(of url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if standardized.path == "/" { return URL(fileURLWithPath: "/", isDirectory: true) }
        return URL(fileURLWithPath: standardized.deletingLastPathComponent().path, isDirectory: true)
    }

    private static func commonDirectory(of directories: [URL]) -> URL {
        var shared = directories[0].pathComponents
        for directory in directories.dropFirst() {
            let components = directory.pathComponents
            let limit = min(shared.count, components.count)
            var prefixCount = 0
            while prefixCount < limit && shared[prefixCount] == components[prefixCount] {
                prefixCount += 1
            }
            shared = Array(shared.prefix(prefixCount))
        }
        guard shared.count > 1 else { return URL(fileURLWithPath: "/", isDirectory: true) }
        return URL(fileURLWithPath: "/" + shared.dropFirst().joined(separator: "/"), isDirectory: true)
    }
}
