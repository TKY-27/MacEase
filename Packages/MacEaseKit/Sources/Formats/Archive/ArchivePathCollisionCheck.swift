import Darwin
import Foundation
import os

final class ArchivePathCollisionCheck {
    private struct Identity: Hashable {
        let device: dev_t
        let inode: ino_t
    }
    private struct Entry {
        let directory: Bool
        let label: String
    }
    private let root: URL
    private let probing: Bool
    private var paths: [Data: Entry] = [:]
    private var identities: [Identity: Entry] = [:]

    init(root: URL, probing: Bool = false) {
        self.root = root
        self.probing = probing
    }

    static func verify(_ entries: [(path: String, directory: Bool)], beside destination: URL) throws {
        let root = destination.appending(path: ".MacEaseNames-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let checker = Self(root: root, probing: true)
            for (index, entry) in entries.enumerated() {
                try Task.checkCancellation()
                try checker.check(entry.path, directory: entry.directory, ordinal: index + 1)
            }
        } catch {
            do { try FileManager.default.removeItem(at: root) } catch {
                Logger(subsystem: "MacEase", category: "archive").error(
                    "Archive name-check cleanup failed: \(error.localizedDescription, privacy: .private)")
            }
            throw error
        }
        try FileManager.default.removeItem(at: root)
    }

    func check(_ original: String, directory: Bool, ordinal: Int) throws {
        let path = try ArchiveExtractor.checked(original)
        guard !path.isEmpty, path.split(separator: "/").first != "__MACOSX" else { return }
        let label = "\(ordinal): \(original)"
        let components = path.split(separator: "/")
        var relative = ""
        for (index, component) in components.enumerated() {
            relative += (relative.isEmpty ? "" : "/") + component
            let isDirectory = index + 1 < components.count || directory
            let key = Data(relative.utf8)
            if let previous = paths[key] {
                guard previous.directory && isDirectory else {
                    throw ArchiveError.nameCollision(first: previous.label, second: label)
                }
                continue
            }
            let full = root.path + "/" + relative
            var metadata = stat()
            if full.withCString({ lstat($0, &metadata) }) == 0 {
                let identity = Identity(device: metadata.st_dev, inode: metadata.st_ino)
                let previous = identities[identity]
                guard previous == nil, isDirectory, metadata.st_mode & S_IFMT == S_IFDIR else {
                    throw ArchiveError.nameCollision(first: previous?.label ?? relative, second: label)
                }
            } else if errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let entry = Entry(directory: isDirectory, label: label)
            if probing {
                let status: Int32
                if isDirectory {
                    status = full.withCString { mkdir($0, 0o700) }
                } else {
                    let descriptor = full.withCString {
                        open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    }
                    status = descriptor < 0 ? -1 : 0
                    if descriptor >= 0 { close(descriptor) }
                }
                guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            paths[key] = entry
            try register(relative)
        }
    }

    func didWrite(_ original: String) throws {
        let path = try ArchiveExtractor.checked(original)
        var relative = ""
        for component in path.split(separator: "/") {
            relative += (relative.isEmpty ? "" : "/") + component
            try register(relative)
        }
    }

    private func register(_ relative: String) throws {
        guard let entry = paths[Data(relative.utf8)] else { return }
        var metadata = stat()
        let full = root.path + "/" + relative
        if full.withCString({ lstat($0, &metadata) }) == 0 {
            let identity = Identity(device: metadata.st_dev, inode: metadata.st_ino)
            identities[identity] = entry
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
