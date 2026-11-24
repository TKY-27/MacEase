import Darwin
import Foundation

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
    private var paths: [Data: Entry] = [:]
    private var identities: [Identity: Entry] = [:]

    init(root: URL) {
        self.root = root
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
