import CryptoKit
import Engine
import Foundation
import MenuCatalog
import os

struct MenuFileWriter {
    let configuration: HostConfiguration

    func write(
        visibleOperations: [OperationID], hiddenEntries: Set<String>, settings: Settings, monitoredPaths: [String] = [],
        recipes: [Recipe] = []
    ) throws -> MenuFile {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let parameters = try encoder.encode(settings) + encoder.encode(settings.platformPresets)
        let parameterVersion = SHA256.hash(data: parameters).map { String(format: "%02x", $0) }.joined()
        var sizeTargets: [String: Int64] = [:]
        var resizeTargets: [String: Int] = [:]
        for platform in settings.platformPresets {
            sizeTargets["image.compress/\(platform.id)"] = platform.image?.maxBytes
            sizeTargets["video.compress/\(platform.id)"] = platform.video?.maxBytes
        }
        for slot in MenuValues.slots {
            guard let value = settings.menuValues.value(for: slot.id) else { throw MenuValueError.invalidValue }
            switch slot.unit {
            case .megabytes: sizeTargets[slot.id] = Int64(value) * MenuValues.bytesPerMegabyte
            case .percent, .pixels: resizeTargets[slot.id] = value
            }
        }
        if settings.extraRotationEnabled {
            guard settings.extraRotationDegrees.isFinite,
                Settings.extraRotationRange.contains(settings.extraRotationDegrees)
            else {
                throw MenuValueError.invalidValue
            }
        }
        var file = MenuFile(
            token: try TokenStore.current(),
            hostAvailable: !InstallLocation.current.isTranslocated,
            visibleOperations: visibleOperations,
            titles: MenuStrings.titles(settings: settings), hiddenEntries: hiddenEntries,
            extraRotationDegrees: settings.extraRotationEnabled ? settings.extraRotationDegrees : nil,
            frameRates: MenuStrings.frameRates(settings), loudnessTargets: MenuStrings.loudnessTargets(settings),
            sizeTargets: sizeTargets, resizeTargets: resizeTargets, parameterVersion: parameterVersion
        )
        if file.entries.contains(where: { $0.op == .filesFinish }), !recipes.isEmpty {
            let title = MenuStrings.operationName(.filesFinish)
            var entries: [MenuEntry] = []
            for entry in file.entries {
                guard entry.op == .filesFinish else {
                    entries.append(entry)
                    continue
                }
                entries.append(
                    MenuEntry(op: .filesFinish, preset: nil, path: [title, String(localized: "Choose Recipe…")]))
                entries += recipes.map {
                    MenuEntry(
                        op: .filesFinish, preset: nil, path: [title, $0.name],
                        recipeID: $0.id, recipeRevision: String($0.revision), acceptedKinds: $0.supportedKinds)
                }
            }
            file = MenuFile(
                token: file.token, hostAvailable: file.hostAvailable, entries: entries,
                kinds: Dictionary(uniqueKeysWithValues: FileKind.allCases.map { ($0, file.kindTitle($0)) }))
        }
        file.monitoredDirectoryPaths = monitoredPaths
        try FileManager.default.createDirectory(at: configuration.supportDirectory, withIntermediateDirectories: true)
        try PrivateFile.write(file.encoded(), to: configuration.menuFile)
        DistributedNotificationCenter.default().postNotificationName(
            FinderLocations.notificationName(supportFolder: configuration.supportDirectory.lastPathComponent),
            object: nil, userInfo: nil, deliverImmediately: true)
        return file
    }

    static func javaRuntimeIsInstalled() async -> Bool {
        await Task.detached {
            do {
                return try JavaRuntime.executable() != nil
            } catch {
                let failure = error as NSError
                Logger(category: "java").error(
                    "java_home failed to start (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)): \(failure.localizedDescription, privacy: .private)"
                )
                return false
            }
        }.value
    }
}
