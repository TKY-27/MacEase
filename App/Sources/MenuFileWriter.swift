import Engine
import Foundation
import MenuCatalog
import os

struct MenuFileWriter {
    let configuration: HostConfiguration

    func write(visibleOperations: [OperationID]) throws -> MenuFile {
        let file = MenuFile(
            token: try TokenStore.current(),
            hostAvailable: !InstallLocation.current.isTranslocated,
            visibleOperations: visibleOperations,
            titles: MenuStrings.titles
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
