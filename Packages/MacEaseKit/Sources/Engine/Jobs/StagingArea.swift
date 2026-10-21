import Foundation
import Synchronization
import os

/// Registry lets a crash be cleaned later.
public final class StagingArea: Sendable {
    private struct Paths {
        var live: Set<String> = []
        var tracked: Set<String> = []
        var registryLoaded = false
    }

    private let registry: URL
    private let paths = Mutex(Paths())
    private let logger = Logger(category: "staging")

    public init(supportDirectory: URL) {
        registry = supportDirectory.appending(path: "staging.json")
    }

    func makeDirectory(for original: URL) throws -> URL {
        try paths.withLock { paths in
            try loadRegistry(into: &paths)
            let directory = try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: original,
                create: true
            )
            let tracked = paths.tracked.union([directory.path])
            do {
                try persist(tracked)
            } catch {
                if !delete(directory) { paths.tracked.insert(directory.path) }
                throw error
            }
            paths.tracked = tracked
            paths.live.insert(directory.path)
            return directory
        }
    }

    func remove(_ directory: URL) {
        paths.withLock { paths in
            guard paths.tracked.contains(directory.path) else { return }
            if delete(directory) { paths.tracked.remove(directory.path) }
            paths.live.remove(directory.path)
            persistLogging(paths.tracked)
        }
    }

    /// Removes directories left by a previous run.
    public func removeStale() {
        paths.withLock { paths in
            do {
                try loadRegistry(into: &paths)
            } catch {
                logger.error(
                    "Staging registry unreadable at \(self.registry.path, privacy: .private): \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public): \(error.localizedDescription, privacy: .private)"
                )
                return
            }
            guard !paths.tracked.isEmpty else { return }
            for path in paths.tracked.subtracting(paths.live) {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                guard Self.isItemReplacementDirectory(directory) else {
                    logger.error("Skipped a registry entry that is not a staging directory")
                    paths.tracked.remove(path)
                    continue
                }
                if delete(directory) { paths.tracked.remove(path) }
            }
            persistLogging(paths.tracked)
        }
    }

    private func loadRegistry(into paths: inout Paths) throws {
        guard !paths.registryLoaded else { return }
        do {
            let stale = try JSONDecoder().decode([String].self, from: Data(contentsOf: registry))
            paths.tracked.formUnion(stale)
        } catch CocoaError.fileReadNoSuchFile {
            paths.registryLoaded = true
            return
        }
        paths.registryLoaded = true
    }

    static func isItemReplacementDirectory(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("NSIRD_")
            && url.deletingLastPathComponent().lastPathComponent == "TemporaryItems"
    }

    private func delete(_ directory: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: directory)
            return true
        } catch CocoaError.fileNoSuchFile where !FileManager.default.fileExists(atPath: directory.path) {
            return true
        } catch {
            logger.error(
                "Staging removal failed at \(directory.path, privacy: .private): \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
            return false
        }
    }

    private func persist(_ paths: Set<String>) throws {
        try PrivateFile.write(JSONEncoder().encode(paths.sorted()), to: registry)
    }

    private func persistLogging(_ paths: Set<String>) {
        do {
            try persist(paths)
        } catch {
            logger.error(
                "Staging registry write failed at \(self.registry.path, privacy: .private): \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public): \(error.localizedDescription, privacy: .private)"
            )
        }
    }
}
