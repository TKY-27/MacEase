import Engine
import Foundation
import FoundationModels
import MenuCatalog
import os

struct MenuFileWriter {
    let configuration: HostConfiguration

    func write(hiddenOperations: Set<OperationID>, aiEnabled: Bool, javaAvailable: Bool) throws -> MenuFile {
        let aiAvailable = aiEnabled && SystemLanguageModel.default.availability == .available
        let visible = OperationID.allCases.filter { op in
            guard !hiddenOperations.contains(op) else { return false }
            switch op.requirement {
            case .appleIntelligence: return aiAvailable
            case .java: return javaAvailable
            case nil: return true
            }
        }
        let file = MenuFile(
            token: try TokenStore.current(),
            hostAvailable: !InstallLocation.current.isTranslocated,
            visibleOperations: visible,
            titles: MenuStrings.titles
        )
        try FileManager.default.createDirectory(at: configuration.supportDirectory, withIntermediateDirectories: true)
        try PrivateFile.write(file.encoded(), to: configuration.menuFile)
        return file
    }

    static func javaRuntimeIsInstalled() async -> Bool {
        await Task.detached {
            let javaHome = Process()
            javaHome.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
            javaHome.standardOutput = FileHandle.nullDevice
            javaHome.standardError = FileHandle.nullDevice
            do {
                try javaHome.run()
            } catch {
                Logger(category: "java").error(
                    "java_home failed to start: \(error.localizedDescription, privacy: .public)")
                return false
            }
            javaHome.waitUntilExit()
            return javaHome.terminationStatus == 0
        }.value
    }
}
