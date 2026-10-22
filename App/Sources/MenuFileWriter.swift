import CryptoKit
import Engine
import Foundation
import MenuCatalog
import os

struct MenuFileWriter {
    let configuration: HostConfiguration

    func write(visibleOperations: [OperationID], hiddenEntries: Set<String>, settings: Settings) throws -> MenuFile {
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
        let file = MenuFile(
            token: try TokenStore.current(),
            hostAvailable: !InstallLocation.current.isTranslocated,
            visibleOperations: visibleOperations,
            titles: MenuStrings.titles(settings: settings), hiddenEntries: hiddenEntries,
            extraRotationDegrees: settings.extraRotationEnabled ? settings.extraRotationDegrees : nil,
            frameRates: MenuStrings.frameRates(settings), loudnessTargets: MenuStrings.loudnessTargets(settings),
            sizeTargets: sizeTargets, resizeTargets: resizeTargets, parameterVersion: parameterVersion
        )
        try FileManager.default.createDirectory(at: configuration.supportDirectory, withIntermediateDirectories: true)
        try PrivateFile.write(file.encoded(), to: configuration.menuFile)
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
