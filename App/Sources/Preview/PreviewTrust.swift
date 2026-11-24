import Darwin
import Engine
import Foundation
import os

// Includes ctime so in-place rewrites invalidate consent.
struct PreviewFileStamp: Hashable, Sendable {
    let stamp: FileStamp
    let statusChangedSeconds: Int
    let statusChangedNanoseconds: Int

    init(fileStatus status: stat) {
        stamp = FileStamp(fileStatus: status, includingIdentity: true)
        statusChangedSeconds = status.st_ctimespec.tv_sec
        statusChangedNanoseconds = status.st_ctimespec.tv_nsec
    }

    init(of url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.init(fileStatus: status)
    }
}

struct PreviewScriptConsentKey: Hashable, Sendable {
    let resolvedPath: String
    let stamp: PreviewFileStamp
}

struct PreviewTrust: Equatable, Sendable {
    enum Level: Equatable, Sendable {
        case standard, trusted, restricted
    }

    private static let quarantineAttribute = "com.apple.quarantine"

    let level: Level
    // Consent follows the symlink target.
    let resolvedPath: String
    let stamp: PreviewFileStamp?

    init(level: Level, resolvedPath: String, stamp: PreviewFileStamp? = nil) {
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
        let stamp = try? PreviewFileStamp(of: resolved)
        return Self(level: level, resolvedPath: resolved.path, stamp: stamp)
    }

    // Evaluates quarantine and identity from one descriptor.
    static func evaluate(
        linkURL: URL, resolvedURL: URL, fileDescriptor: Int32, status: stat, trustedFolders: [String]
    ) -> Self {
        let linkPath = linkURL.standardizedFileURL.path
        let quarantined =
            (linkPath != resolvedURL.path && isQuarantined(linkPath, options: XATTR_NOFOLLOW))
            || isQuarantined(fileDescriptor: fileDescriptor)
        let level: Level =
            if quarantined {
                .restricted
            } else if trustedFolders.contains(where: { contains(folder: $0, file: resolvedURL) }) {
                .trusted
            } else {
                .standard
            }
        let stamp = PreviewFileStamp(fileStatus: status)
        return Self(level: level, resolvedPath: resolvedURL.path, stamp: stamp)
    }

    static func isUnchangedUnquarantined(_ url: URL, expectedStamp: PreviewFileStamp) -> Bool {
        let current = evaluate(url, trustedFolders: [])
        return !current.restricted && current.stamp == expectedStamp
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

    private static func isQuarantined(fileDescriptor: Int32) -> Bool {
        guard fgetxattr(fileDescriptor, quarantineAttribute, nil, 0, 0, 0) < 0 else { return true }
        let code = errno
        if code == ENOATTR || code == ENOTSUP { return false }
        Logger(category: "finder-preview").error(
            "Quarantine fd check failed (errno \(code, privacy: .public)), treating the file as downloaded")
        return true
    }

    private static func contains(folder: String, file: URL) -> Bool {
        let folderComponents = URL(fileURLWithPath: folder, isDirectory: true).resolvingSymlinksInPath()
            .standardizedFileURL.pathComponents
        let fileComponents = file.pathComponents
        return fileComponents.count > folderComponents.count && fileComponents.starts(with: folderComponents)
    }
}
