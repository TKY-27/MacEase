import Foundation

public enum FileKind: String, Codable, CaseIterable, Sendable {
    case image
    case video
    case audio
    case pdf
    case text
    case archive
    case jar
    case folder
    case any

    private static let kindsByExtension: [String: FileKind] = {
        let table: [FileKind: [String]] = [
            .image: [
                "jpg", "jpeg", "jpe", "png", "apng", "heic", "heif", "hif", "avif", "jxl", "webp", "gif", "tif",
                "tiff", "bmp", "ico", "icns", "svg", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2",
            ],
            .video: ["mp4", "m4v", "mov", "mkv", "webm", "avi", "flv"],
            .audio: ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "oga", "opus", "caf"],
            .pdf: ["pdf"],
            .text: ["txt", "csv", "tsv", "json", "xml", "ini", "cfg", "conf", "md", "log", "yaml", "yml"],
            .archive: ["zip", "7z", "tar", "gz", "tgz", "bz2", "xz", "rar"],
            .jar: ["jar"],
        ]
        var kinds: [String: FileKind] = [:]
        for (kind, extensions) in table {
            for pathExtension in extensions { kinds[pathExtension] = kind }
        }
        return kinds
    }()

    // Finder hands packages over as directories.
    private static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "rtfd", "pages", "numbers", "key",
        "xcodeproj", "xcworkspace", "playground", "photoslibrary", "musiclibrary", "logicx", "band",
        "fcpbundle", "imovielibrary", "scptd", "prefpane", "qlgenerator", "mdimporter", "saver", "wdgt",
        "xcarchive", "xcassets", "mlpackage", "pkg", "mpkg", "lpdf",
    ]

    /// `nil`: only All Files operations apply.
    public init?(pathExtension: String, isFolder: Bool) {
        if isFolder {
            self = .folder
            return
        }
        guard let kind = Self.kindsByExtension[pathExtension.lowercased()] else { return nil }
        self = kind
    }

    /// No file I/O, names only.
    public init?(fileURL: URL) {
        let pathExtension = fileURL.pathExtension.lowercased()
        let isPackage = fileURL.hasDirectoryPath && Self.packageExtensions.contains(pathExtension)
        self.init(pathExtension: pathExtension, isFolder: fileURL.hasDirectoryPath && !isPackage)
    }

    public static let menuOrder: [FileKind] = [.image, .video, .audio, .pdf, .text, .archive, .jar, .folder, .any]
}
