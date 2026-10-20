import Foundation
import Synchronization
import os

/// Registry lets a crash be cleaned later.
public final class StagingArea: Sendable {
    private let registry: URL
    private let live = Mutex<Set<String>>([])
    private let logger = Logger(category: "staging")

    public init(supportDirectory: URL) {
        registry = supportDirectory.appending(path: "staging.json")
    }

    func makeDirectory(for original: URL) throws -> URL {
        let directory = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: original,
            create: true
        )
        try live.withLock { paths in
            paths.insert(directory.path)
            try persist(paths)
        }
        return directory
    }

    func remove(_ directory: URL) {
        delete(directory)
        live.withLock { paths in
            paths.remove(directory.path)
            persistLogging(paths)
        }
    }

    /// Removes directories left by a previous run.
    public func removeStale() {
        guard FileManager.default.fileExists(atPath: registry.path) else { return }
        let stale: [String]
        do {
            stale = try JSONDecoder().decode([String].self, from: Data(contentsOf: registry))
        } catch {
            logger.error("Staging registry unreadable: \(error.localizedDescription, privacy: .public)")
            return
        }
        for path in stale {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            guard Self.isItemReplacementDirectory(directory) else {
                logger.error("Skipped a registry entry that is not a staging directory")
                continue
            }
            delete(directory)
        }
        live.withLock { persistLogging($0) }
    }

    static func isItemReplacementDirectory(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("NSIRD_")
            && url.deletingLastPathComponent().lastPathComponent == "TemporaryItems"
    }

    private func delete(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            logger.error("Staging removal failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persist(_ paths: Set<String>) throws {
        try PrivateFile.write(JSONEncoder().encode(paths.sorted()), to: registry)
    }

    private func persistLogging(_ paths: Set<String>) {
        do {
            try persist(paths)
        } catch {
            logger.error("Staging registry write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
