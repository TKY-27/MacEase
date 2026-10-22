import Foundation

/// Writes owner-only (0600) files.
public enum PrivateFile {
    public static func write(_ contents: Data, to url: URL) throws {
        try contents.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Moves unreadable files aside for diagnosis.
    public static func setAside(_ url: URL) throws -> URL {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        let destination = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}
