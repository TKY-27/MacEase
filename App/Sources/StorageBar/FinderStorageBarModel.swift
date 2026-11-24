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

@MainActor
@Observable
final class FinderStorageBarModel {
    nonisolated private static let startupDisk = URL(fileURLWithPath: "/")

    private let logger = Logger(category: "storage-bar")
    private(set) var volume: StorageVolume?
    private(set) var showsStartupDisk = false
    private(set) var selectionCount: Int?
    private var location: URL?
    private var volumeTask: Task<Void, Never>?
    private var volumeRefreshPending = false
    private var locationStale = false

    /// Nil count means the selection is unknown.
    func update(selectionCount: Int?, folder: URL?) {
        self.selectionCount = selectionCount.flatMap { $0 > 0 ? $0 : nil }
        let known = folder ?? location
        if known != location || volume == nil || locationStale {
            location = known
            refreshVolume()
        }
    }

    // Old figures stay until the window reports.
    func forgetLocation() {
        location = nil
        locationStale = true
        selectionCount = nil
    }

    func reset() {
        location = nil
        locationStale = false
        selectionCount = nil
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
}
