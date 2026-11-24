import Darwin
import Foundation
import os

struct PreviewTrust: Equatable, Sendable {
    enum Level: Equatable, Sendable {
        case standard, trusted, restricted
    }

    private static let quarantineAttribute = "com.apple.quarantine"

    let level: Level
    // Consent follows the symlink target.
    let resolvedPath: String

    var restricted: Bool { level == .restricted }

    // Quarantine wins over trusted folders.
    static func evaluate(_ url: URL, trustedFolders: [String]) -> Self {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let level: Level =
            if isQuarantined(resolved.path) {
                .restricted
            } else if trustedFolders.contains(where: { contains(folder: $0, file: resolved) }) {
                .trusted
            } else {
                .standard
            }
        return Self(level: level, resolvedPath: resolved.path)
    }

    private static func isQuarantined(_ path: String) -> Bool {
        guard getxattr(path, quarantineAttribute, nil, 0, 0, 0) < 0 else { return true }
        let code = errno
        if code == ENOATTR || code == ENOTSUP { return false }
        // An unreadable attribute could hide a download.
        Logger(category: "finder-preview").error(
            "Quarantine check failed (errno \(code, privacy: .public)), treating the file as downloaded")
        return true
    }

    private static func contains(folder: String, file: URL) -> Bool {
        let folderComponents = URL(fileURLWithPath: folder, isDirectory: true).resolvingSymlinksInPath()
            .standardizedFileURL.pathComponents
        let fileComponents = file.pathComponents
        return fileComponents.count > folderComponents.count && fileComponents.starts(with: folderComponents)
    }
}
