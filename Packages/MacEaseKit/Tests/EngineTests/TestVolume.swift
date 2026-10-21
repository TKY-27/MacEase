import Foundation

/// Keeps test trashing off the user's Trash.
enum TestVolume {
    nonisolated(unsafe) private static var mountPoint = ""
    nonisolated(unsafe) private static var imageFolder = ""

    static let root: URL = {
        let base = FileManager.default.temporaryDirectory.appending(path: "MacEaseTests-\(UUID().uuidString)")
        let image = base.appending(path: "volume.sparseimage")
        let mount = base.appending(path: "mnt")
        do {
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try run([
                "create", "-size", "200m", "-fs", "APFS", "-type", "SPARSE", "-volname", "MacEaseTest", image.path,
            ])
            try run(["attach", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
        } catch {
            fatalError("Test volume setup failed: \(error)")
        }
        mountPoint = mount.path
        imageFolder = base.path
        atexit {
            let hdiutil = Process()
            hdiutil.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            hdiutil.arguments = ["detach", "-force", TestVolume.mountPoint]
            try? hdiutil.run()
            hdiutil.waitUntilExit()
            // Each image is about 100 MB.
            try? FileManager.default.removeItem(atPath: TestVolume.imageFolder)
        }
        return mount
    }()

    static func makeFolder() throws -> URL {
        let folder = root.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func run(_ arguments: [String]) throws {
        let hdiutil = Process()
        hdiutil.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        hdiutil.arguments = arguments
        hdiutil.standardOutput = FileHandle.nullDevice
        try hdiutil.run()
        hdiutil.waitUntilExit()
        guard hdiutil.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
    }
}
