import Foundation

public enum FileKind: String, Codable, CaseIterable, Sendable {
    case image
    case video
    case audio
    case pdf
    case document
    case plist
    case text
    case archive
    case jar
    case folder
    case any

    private static let kindsByExtension: [String: FileKind] = {
        let table: [FileKind: [String]] = [
            .image: [
                "jpg", "jpeg", "jpe", "png", "apng", "heic", "heif", "hif", "avif", "jxl", "webp", "gif", "tif",
                "tiff", "bmp", "tga", "psd", "ico", "icns", "svg", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf",
                "rw2",
            ],
            .video: ["mp4", "m4v", "mov", "mkv", "webm", "avi", "flv"],
            .audio: ["mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "flac", "ogg", "oga", "opus", "caf"],
            .pdf: ["pdf"],
            .document: ["docx", "odt", "rtf", "rtfd"],
            .plist: ["plist"],
            .text: [
                "txt", "text", "md", "markdown", "log", "csv", "tsv", "ini", "cfg", "conf", "json", "xml",
                "yaml", "yml", "toml", "html", "htm", "css", "js", "mjs", "cjs", "ts", "tsx", "jsx",
                "c", "h", "cpp", "hpp", "cc", "hh", "cs", "java", "kt", "py", "rb", "go", "rs", "php",
                "pl", "lua", "sh", "bash", "bat", "cmd", "ps1", "psm1", "sql", "srt", "vtt", "asc",
                "tex", "rst", "env", "props", "properties", "gradle", "cmake", "m", "mm", "swift", "vb", "r", "jl",
            ],
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
        if !fileURL.hasDirectoryPath, Self.canonicalFormat(for: fileURL).hasSuffix(".split") {
            self = .archive
            return
        }
        self.init(pathExtension: pathExtension, isFolder: fileURL.hasDirectoryPath && !isPackage)
    }

    public static func canonicalFormat(for url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        let suffix = url.pathExtension
        if suffix.count >= 3, suffix.utf8.allSatisfy({ (48...57).contains($0) }), Int(suffix).map({ $0 > 0 }) == true {
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            for format in ["tar.gz", "zip", "7z"] where base.hasSuffix(".\(format)") {
                return "\(format).split"
            }
        }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return "tar.gz" }
        return canonicalFormat(suffix)
    }

    public static func canonicalFormat(_ pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "jpg", "jpe", "jpeg": "jpeg"
        case "tif", "tiff": "tiff"
        case "heif", "hif", "heic": "heic"
        case "aif", "aiff": "aiff"
        case "oga", "ogg": "ogg"
        case "text", "txt": "txt"
        case "cfg", "conf", "ini": "ini"
        case "markdown", "md": "md"
        case "htm", "html": "html"
        case "yml", "yaml": "yaml"
        default: pathExtension.lowercased()
        }
    }

    static var imageConversionSources: Set<String> {
        Set(kindsByExtension.filter { $0.value == .image && $0.key != "psd" }.keys.map(canonicalFormat))
    }

    public static let menuOrder: [FileKind] = [
        .image, .video, .audio, .pdf, .document, .text, .plist, .archive, .jar, .folder, .any,
    ]
}
