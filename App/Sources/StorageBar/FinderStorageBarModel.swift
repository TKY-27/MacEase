import Engine
import Foundation
import Observation
import os

struct StorageVolume: Equatable, Sendable {
    struct Capacity: Equatable, Sendable {
        let total: Int64
        let available: Int64

        var usedFraction: Double { Double(total - available) / Double(total) }
    }

    let name: String
    let capacity: Capacity?

    // Counts purgeable space, as Finder does.
    init(name: String, total: Int?, available: Int?, availableForImportantUsage: Int64?) {
        self.name = name
        let important = availableForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
        guard let total, total > 0, let free = important ?? available.map(Int64.init) else {
            capacity = nil
            return
        }
        capacity = Capacity(total: Int64(total), available: min(max(free, 0), Int64(total)))
    }

    // Matching paths avoids touching privacy-protected folders.
    static func root(of location: URL, among volumes: [URL]) -> URL? {
        let path = location.standardizedFileURL.pathComponents
        return volumes.filter { path.starts(with: $0.standardizedFileURL.pathComponents) }
            .max { $0.pathComponents.count < $1.pathComponents.count }
    }

    static func read(volume root: URL) throws -> Self {
        var root = root
        root.removeAllCachedResourceValues()
        let values = try root.resourceValues(forKeys: [
            .volumeURLKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        return Self(
            name: values.volumeLocalizedName
                ?? FileManager.default.displayName(atPath: (values.volume ?? root).path),
            total: values.volumeTotalCapacity, available: values.volumeAvailableCapacity,
            availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage)
    }
}

enum SelectionSize {
    struct Limits: Sendable {
        static let standard = Self(entries: 100_000, duration: .seconds(2))

        let entries: Int
        let duration: Duration
    }

    // Logical sizes, like Finder's Get Info.
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .totalFileSizeKey]

    /// Nil when the limits stop the walk.
    static func total(of urls: [URL], limits: Limits) throws -> Int64? {
        let deadline = ContinuousClock.now + limits.duration
        var visited = 0
        var total: Int64 = 0
        for url in urls {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            guard values.isDirectory == true else {
                total += Int64(values.totalFileSize ?? 0)
                continue
            }
            var unreadable: (any Error)?
            guard
                let entries = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: Array(keys), options: [],
                    errorHandler: { _, error in
                        unreadable = error
                        return false
                    })
            else { throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url]) }
            for case let entry as URL in entries {
                try Task.checkCancellation()
                visited += 1
                guard visited <= limits.entries, ContinuousClock.now < deadline else { return nil }
                let entryValues = try entry.resourceValues(forKeys: keys)
                if entryValues.isRegularFile == true { total += Int64(entryValues.totalFileSize ?? 0) }
            }
            // A partial total would understate the size.
            if let unreadable { throw unreadable }
        }
        return total
    }
}

@MainActor
@Observable
final class FinderStorageBarModel {
    enum Selection: Equatable {
        case measuring(count: Int)
        case measured(count: Int, bytes: Int64)
        case unmeasured(count: Int)
    }

    nonisolated private static let startupDisk = URL(fileURLWithPath: "/")
    // Fast results skip the Calculating flash.
    private static let calculatingDelay: Duration = .milliseconds(200)

    private let limits: SelectionSize.Limits
    private let logger = Logger(category: "storage-bar")
    private(set) var volume: StorageVolume?
    private(set) var showsStartupDisk = false
    private(set) var selection: Selection?
    private var location: URL?
    private var selectedURLs: [URL] = []
    private var generation: UInt64 = 0
    private var sizeTask: Task<Void, Never>?
    private var calculatingTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var volumeRefreshPending = false
    private var locationStale = false

    init(limits: SelectionSize.Limits = .standard) {
        self.limits = limits
    }

    /// Nil `urls` means the selection is unknown.
    func update(urls: [URL]?, folder: URL?) {
        let known = folder ?? urls?.first ?? location
        if known != location || volume == nil || locationStale {
            location = known
            refreshVolume()
        }
        measure(urls ?? [])
    }

    // Old figures stay until the window reports.
    func forgetLocation() {
        location = nil
        locationStale = true
        measure([])
    }

    func reset() {
        location = nil
        locationStale = false
        measure([])
        volume = nil
        volumeTask?.cancel()
        volumeTask = nil
        volumeRefreshPending = false
    }

    // Serial reads survive hung network volumes.
    func refreshVolume() {
        guard volumeTask == nil else {
            volumeRefreshPending = true
            return
        }
        let target = location
        locationStale = false
        volumeTask = Task { [weak self, logger] in
            let read: (volume: StorageVolume, startupDisk: Bool)?
            do {
                read = try await offMain {
                    let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil) ?? []
                    guard let target, let root = StorageVolume.root(of: target, among: volumes) else {
                        return (try StorageVolume.read(volume: Self.startupDisk), true)
                    }
                    do {
                        return (try StorageVolume.read(volume: root), false)
                    } catch {
                        logger.error("Volume unavailable: \(error.localizedDescription, privacy: .private)")
                        return (try StorageVolume.read(volume: Self.startupDisk), true)
                    }
                }
            } catch {
                logger.error("Startup disk unavailable: \(error.localizedDescription, privacy: .private)")
                read = nil
            }
            guard let self, !Task.isCancelled else { return }
            volumeTask = nil
            if let read {
                volume = read.volume
                showsStartupDisk = read.startupDisk
            }
            if volumeRefreshPending {
                volumeRefreshPending = false
                refreshVolume()
            }
        }
    }

    private func measure(_ urls: [URL]) {
        guard urls != selectedURLs else { return }
        selectedURLs = urls
        generation &+= 1
        sizeTask?.cancel()
        calculatingTask?.cancel()
        guard !urls.isEmpty else {
            selection = nil
            return
        }
        let requested = generation
        let limits = limits
        calculatingTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.calculatingDelay) } catch { return }
            guard let self, generation == requested else { return }
            selection = .measuring(count: urls.count)
        }
        sizeTask = Task { [weak self] in
            let bytes: Int64?
            do {
                bytes = try await offMain { try SelectionSize.total(of: urls, limits: limits) }
            } catch is CancellationError {
                return
            } catch {
                self?.logger.error("Selection size unavailable: \(error.localizedDescription, privacy: .private)")
                bytes = nil
            }
            guard let self, generation == requested else { return }
            calculatingTask?.cancel()
            selection = bytes.map { .measured(count: urls.count, bytes: $0) } ?? .unmeasured(count: urls.count)
        }
    }
}
