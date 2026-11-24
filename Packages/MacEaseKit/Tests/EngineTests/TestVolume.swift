import Foundation

/// Keeps test trashing off the user's Trash.
enum TestVolume {
    private static let volume: TestDiskImage = {
        do { return try TestDiskImage() } catch { fatalError("Test volume setup failed: \(error)") }
    }()

    static var root: URL { volume.mount }

    static func makeFolder() throws -> URL {
        let folder = root.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
