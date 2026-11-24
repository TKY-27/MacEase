import Darwin
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

    struct MountedVolume: Equatable, Sendable {
        let root: URL
        let totalBytes: Int64?
        let availableBytes: Int64?
    }

    nonisolated static let startupDisk = URL(fileURLWithPath: "/", isDirectory: true)
    private static let volumesDirectory = "Volumes"
    private static let mountHeadroom = 8

    let name: String
    let capacity: Capacity?

    // Counts purgeable space, as Finder does.
    init(name: String, total: Int64?, available: Int64?, availableForImportantUsage: Int64?) {
        self.name = name
        let important = availableForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
        guard let total, total > 0, let free = important ?? available else {
            capacity = nil
            return
        }
        capacity = Capacity(total: total, available: min(max(free, 0), total))
    }

    // Lexical match avoids touching protected folders.
    static func root(of location: URL, among volumes: [URL]) -> URL? {
        let locationComponents = standardizedComponents(of: location)
        let matched =
            volumes
            .map { (url: $0, components: standardizedComponents(of: $0)) }
            .filter { locationComponents.starts(with: $0.components) }
            .max { $0.components.count < $1.components.count }
        guard let matched else { return nil }
        // Ejected /Volumes mounts never fall back.
        if isUnderVolumesMount(locationComponents), matched.components.count == 1 {
            return nil
        }
        return matched.url
    }

    // Reads mount table without opening volumes.
    static func mountedVolumes() -> [MountedVolume] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var entries = [Darwin.statfs](repeating: Darwin.statfs(), count: Int(count) + mountHeadroom)
        let bufferSize = Int32(entries.count * MemoryLayout<Darwin.statfs>.stride)
        let filled = getfsstat(&entries, bufferSize, MNT_NOWAIT)
        guard filled > 0 else { return [] }
        return (0..<Int(filled)).compactMap { mountedVolume(from: entries[$0]) }
    }

    static func read(volume root: URL, among mounted: [MountedVolume]? = nil) throws -> Self {
        let targetComponents = standardizedComponents(of: root)
        if targetComponents == [startupDisk.path] {
            return try readStartupDisk()
        }
        let volumes = mounted ?? mountedVolumes()
        guard let match = volumes.first(where: { standardizedComponents(of: $0.root) == targetComponents }) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: root])
        }
        return fromMounted(match)
    }

    static func readStartupDisk() throws -> Self {
        var root = startupDisk
        root.removeAllCachedResourceValues()
        let values = try root.resourceValues(forKeys: [
            .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        return Self(
            name: values.volumeLocalizedName ?? FileManager.default.displayName(atPath: startupDisk.path),
            total: values.volumeTotalCapacity.map(Int64.init),
            available: values.volumeAvailableCapacity.map(Int64.init),
            availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage)
    }

    static func fromMounted(_ mounted: MountedVolume) -> Self {
        let label = mounted.root.lastPathComponent
        return Self(
            name: label.isEmpty ? mounted.root.path : label,
            total: mounted.totalBytes, available: mounted.availableBytes,
            availableForImportantUsage: nil)
    }

    private static func mountedVolume(from entry: Darwin.statfs) -> MountedVolume? {
        var copy = entry
        let path = withUnsafePointer(to: &copy.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        guard !path.isEmpty else { return nil }
        let blockSize = UInt64(entry.f_bsize)
        return MountedVolume(
            root: URL(fileURLWithPath: path, isDirectory: true),
            totalBytes: byteCount(blocks: entry.f_blocks, blockSize: blockSize),
            availableBytes: byteCount(blocks: entry.f_bavail, blockSize: blockSize))
    }

    private static func byteCount(blocks: UInt64, blockSize: UInt64) -> Int64? {
        let (product, overflow) = blocks.multipliedReportingOverflow(by: blockSize)
        guard !overflow else { return nil }
        return Int64(exactly: product)
    }

    private static func standardizedComponents(of url: URL) -> [String] {
        url.standardized.pathComponents
    }

    private static func isUnderVolumesMount(_ components: [String]) -> Bool {
        components.count >= 3 && components[0] == startupDisk.path && components[1] == volumesDirectory
    }
}

@MainActor
@Observable
final class FinderStorageBarModel {
    struct VolumeSnapshot: Equatable, Sendable {
        let volume: StorageVolume
        let startupDisk: Bool
        let mountRoot: URL?
    }

    typealias VolumeReader = @Sendable (URL?) async throws -> VolumeSnapshot

    private let readVolume: VolumeReader
    private let logger = Logger(category: "storage-bar")
    private(set) var volume: StorageVolume?
    private(set) var showsStartupDisk = false
    private(set) var selectionCount: Int?
    private var location: URL?
    private var resolvedMountRoot: URL?
    private var locationVersion: UInt64 = 0
    private var volumeTask: Task<Void, Never>?
    private var volumeRefreshPending = false
    private var locationStale = false

    init(readVolume: @escaping VolumeReader = Self.defaultReadVolume) {
        self.readVolume = readVolume
    }

    /// Nil count means the selection is unknown.
    func update(selectionCount: Int?, folder: URL?) {
        self.selectionCount = selectionCount.flatMap { $0 > 0 ? $0 : nil }
        let known = folder ?? location
        if known != location || volume == nil || locationStale {
            if known != location {
                location = known
                resolvedMountRoot = nil
                locationVersion &+= 1
            }
            refreshVolume()
        }
    }

    // Old figures stay until the window reports.
    func forgetLocation() {
        location = nil
        resolvedMountRoot = nil
        locationStale = true
        selectionCount = nil
        locationVersion &+= 1
    }

    func cancelPendingWork() {
        locationVersion &+= 1
        volumeTask?.cancel()
        volumeTask = nil
        volumeRefreshPending = false
    }

    func reset() {
        location = nil
        resolvedMountRoot = nil
        locationStale = false
        selectionCount = nil
        volume = nil
        showsStartupDisk = false
        cancelPendingWork()
    }

    // Serial reads keep one request in flight.
    func refreshVolume() {
        guard volumeTask == nil else {
            volumeRefreshPending = true
            return
        }
        let target = location
        let requestedVersion = locationVersion
        locationStale = false
        let reader = readVolume
        volumeTask = Task { [weak self, logger] in
            let read: VolumeSnapshot?
            do {
                read = try await reader(target)
            } catch is CancellationError {
                return
            } catch {
                logger.error("Volume unavailable: \(error.localizedDescription, privacy: .private)")
                read = nil
            }
            guard let self, !Task.isCancelled else { return }
            volumeTask = nil
            if locationVersion == requestedVersion, location == target, let read {
                apply(read)
            }
            if volumeRefreshPending {
                volumeRefreshPending = false
                refreshVolume()
            }
        }
    }

    private func apply(_ snapshot: VolumeSnapshot) {
        let ejectedNonRoot =
            resolvedMountRoot != nil
            && resolvedMountRoot?.standardized.path != StorageVolume.startupDisk.path
            && snapshot.mountRoot?.standardized.path == StorageVolume.startupDisk.path
        volume = snapshot.volume
        if ejectedNonRoot {
            showsStartupDisk = true
            resolvedMountRoot = nil
        } else {
            showsStartupDisk = snapshot.startupDisk
            resolvedMountRoot = snapshot.mountRoot
        }
    }

    nonisolated static func defaultReadVolume(for target: URL?) async throws -> VolumeSnapshot {
        try await offMain {
            try readVolumeSync(for: target, mounted: StorageVolume.mountedVolumes())
        }
    }

    nonisolated static func readVolumeSync(
        for target: URL?, mounted: [StorageVolume.MountedVolume],
        readStartup: () throws -> StorageVolume = StorageVolume.readStartupDisk
    ) throws -> VolumeSnapshot {
        guard let target, let root = StorageVolume.root(of: target, among: mounted.map(\.root)) else {
            return VolumeSnapshot(volume: try readStartup(), startupDisk: true, mountRoot: nil)
        }
        if root.standardized.path == StorageVolume.startupDisk.path {
            return VolumeSnapshot(volume: try readStartup(), startupDisk: false, mountRoot: root)
        }
        guard let match = mounted.first(where: { $0.root.standardized.path == root.standardized.path }) else {
            return VolumeSnapshot(volume: try readStartup(), startupDisk: true, mountRoot: nil)
        }
        return VolumeSnapshot(volume: StorageVolume.fromMounted(match), startupDisk: false, mountRoot: match.root)
    }
}
