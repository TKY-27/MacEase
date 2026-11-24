import Darwin
import Engine
import Foundation
import os

struct PreviewScriptConsentKey: Hashable, Sendable {
    let resolvedPath: String
    let stamp: FileStamp
}

struct PreviewTrust: Equatable, Sendable {
    enum Level: Equatable, Sendable {
        case standard, trusted, restricted
    }

    private static let quarantineAttribute = "com.apple.quarantine"

    let level: Level
    // Consent follows the symlink target.
    let resolvedPath: String
    let stamp: FileStamp?

    init(level: Level, resolvedPath: String, stamp: FileStamp? = nil) {
        self.level = level
        self.resolvedPath = resolvedPath
        self.stamp = stamp
    }

    var restricted: Bool { level == .restricted }

    var consentKey: PreviewScriptConsentKey? {
        stamp.map { PreviewScriptConsentKey(resolvedPath: resolvedPath, stamp: $0) }
    }

    // Quarantine wins over trusted folders.
    static func evaluate(_ url: URL, trustedFolders: [String]) -> Self {
        let linkPath = url.standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let quarantined =
            (linkPath != resolved.path && isQuarantined(linkPath, options: XATTR_NOFOLLOW))
            || isQuarantined(resolved.path, options: 0)
        let level: Level =
            if quarantined {
                .restricted
            } else if trustedFolders.contains(where: { contains(folder: $0, file: resolved) }) {
                .trusted
            } else {
                .standard
            }
        let stamp = try? FileStamp(of: resolved, includingIdentity: true)
        return Self(level: level, resolvedPath: resolved.path, stamp: stamp)
    }

    private static func isQuarantined(_ path: String, options: Int32) -> Bool {
        guard getxattr(path, quarantineAttribute, nil, 0, 0, options) < 0 else { return true }
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
