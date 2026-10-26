import Darwin
import Formats
import Foundation
import MenuCatalog

public enum ArchiveOperation: Codable, Hashable, Sendable {
    /// `nil` until the Password panel supplies one.
    case extract(password: String?)
}

enum ArchivePlanner {
    private static let extractionFolderName = "extracted"
    private static let quarantineAttribute = "com.apple.quarantine"

    static func options(for op: OperationID, preset: String?) -> ArchiveOperation? {
        op == .archiveExtract && preset == nil ? .extract(password: nil) : nil
    }

    static func batch(_ operation: ArchiveOperation, op: OperationID, archives: [URL]) -> Batch {
        switch operation {
        case .extract(let password):
            let items = archives.map { archive in
                OperationPlanner.validated(archive, kind: .archive) { context in
                    try extract(archive, password: password, context: context)
                }
            }
            return Batch(operation: op, items: items)
        }
    }

    private static func extract(_ archive: URL, password: String?, context: ItemContext) throws -> ItemResult {
        let staging = try realPath(of: context.stagingDirectory(for: archive))
        let root = staging.appending(path: extractionFolderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let baseName = AvailableName.split(archive.lastPathComponent).base
        let layout: ExtractedLayout
        do {
            layout = try ArchiveExtractor.extract(
                archive, into: root, rawName: baseName, password: password, progress: context.progress)
        } catch let error as ArchiveError {
            throw engineError(error)
        } catch let error as FormatError {
            throw engineError(error)
        }
        try propagateQuarantine(from: archive, to: root)
        let top = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        if layout == .decompressedFile, let file = top.first {
            return .derived(nextTo: archive, outputs: [StagedFile(url: file, name: baseName, check: .decompressed)])
        }
        return .derived(nextTo: archive, outputs: [StagedFile(url: root, name: baseName, check: .folder)])
    }

    /// libarchive refuses to write through `/var`.
    private static func realPath(of url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// Gatekeeper must still see downloaded content.
    static func propagateQuarantine(from archive: URL, to root: URL) throws {
        let size = getxattr(archive.path, quarantineAttribute, nil, 0, 0, 0)
        if size < 0, errno == ENOATTR || errno == ENOTSUP { return }
        var value = [UInt8](repeating: 0, count: max(0, size))
        guard size >= 0, getxattr(archive.path, quarantineAttribute, &value, value.count, 0, 0) == size else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var paths = [root.path]
        if try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            var walkError: (any Error)?
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: []) {
                _, error in
                walkError = error
                return false
            }
            while let url = enumerator?.nextObject() as? URL { paths.append(url.path) }
            if let walkError { throw walkError }
        }
        for path in paths { try setAttribute(value, on: path) }
    }

    /// Links are skipped: `chmod` would follow them.
    private static func setAttribute(_ value: [UInt8], on path: String) throws {
        var status = stat()
        guard lstat(path, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if status.st_mode & S_IFMT == S_IFLNK { return }
        if setxattr(path, quarantineAttribute, value, value.count, 0, XATTR_NOFOLLOW) == 0 { return }
        // Read-only items need owner write access briefly.
        guard errno == EACCES, chmod(path, status.st_mode | S_IWUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let result = setxattr(path, quarantineAttribute, value, value.count, 0, XATTR_NOFOLLOW)
        let failure = errno
        guard chmod(path, status.st_mode) == 0, result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result == 0 ? errno : failure) ?? .EIO)
        }
    }
}

extension ArchivePlanner {
    static func engineError(_ error: ArchiveError) -> EngineError {
        switch error {
        case .passwordRequired: .invalidInput(.passwordRequired)
        case .wrongPassword: .invalidInput(.wrongPassword)
        case .unsafePath(let path): .invalidInput(.unsafeArchivePath(path))
        case .expandsTooMuch(let limit): .invalidInput(.archiveExpandsTooMuch(limitBytes: limit))
        case .duplicateRootName(let name): .duplicateArchiveRootName(name)
        }
    }

    static func engineError(_ error: FormatError) -> EngineError {
        EngineError(error)
    }
}
