import CoreFoundation
import Darwin
import Engine
import Foundation

enum PreviewEncoding: String, CaseIterable, Sendable {
    case automatic, utf8, utf16, utf16LE, utf16BE, utf32, utf32LE, utf32BE, shiftJIS, eucJP, iso2022JP,
        gb18030, big5, eucKR, windows1252, latin1

    init(detected: DetectedTextEncoding) {
        switch detected {
        case .utf8: self = .utf8
        case .utf16LE: self = .utf16LE
        case .utf16BE: self = .utf16BE
        case .utf32LE: self = .utf32LE
        case .utf32BE: self = .utf32BE
        case .gb18030: self = .gb18030
        case .shiftJIS: self = .shiftJIS
        case .eucJP: self = .eucJP
        case .iso2022JP: self = .iso2022JP
        case .windows1252: self = .windows1252
        case .latin1: self = .latin1
        }
    }

    var title: String {
        switch self {
        case .automatic: String(localized: "Detect Encoding")
        case .utf8: String(localized: "UTF-8")
        case .utf16: String(localized: "UTF-16")
        case .utf16LE: String(localized: "UTF-16 LE")
        case .utf16BE: String(localized: "UTF-16 BE")
        case .utf32: String(localized: "UTF-32")
        case .utf32LE: String(localized: "UTF-32 LE")
        case .utf32BE: String(localized: "UTF-32 BE")
        case .shiftJIS: String(localized: "Shift_JIS")
        case .eucJP: String(localized: "EUC-JP")
        case .iso2022JP: String(localized: "ISO-2022-JP")
        case .gb18030: String(localized: "GB18030")
        case .big5: String(localized: "Big5")
        case .eucKR: String(localized: "EUC-KR")
        case .windows1252: String(localized: "Windows-1252")
        case .latin1: String(localized: "ISO-8859-1")
        }
    }

    func decode(_ bytes: Data) throws -> String {
        if self == .automatic { return try TextEncoding.detectedString(from: bytes) }
        let text = try TextEncoding.strictString(from: bytes, encoding: foundation)
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    var foundation: String.Encoding {
        switch self {
        case .automatic, .utf8: return .utf8
        case .utf16: return .utf16
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .utf32: return .utf32
        case .utf32LE: return .utf32LittleEndian
        case .utf32BE: return .utf32BigEndian
        case .shiftJIS:
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
        case .eucJP: return .japaneseEUC
        case .iso2022JP: return .iso2022JP
        case .gb18030:
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case .big5:
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)))
        case .eucKR:
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))
        case .windows1252: return .windowsCP1252
        case .latin1: return .isoLatin1
        }
    }

}

// Keeps one open folder descriptor across rendering.
final class PreviewDirectoryDescriptor: @unchecked Sendable {
    let rawValue: Int32

    init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    deinit {
        close(rawValue)
    }
}

struct PreviewTextSource: Sendable {
    static let maximumBytes = 4 * 1024 * 1024
    static let excerptBytes = 256 * 1024
    static let highlightBytes = 512 * 1024
    private static let readChunkBytes = 64 * 1024
    let bytes: Data
    let truncated: Bool
    let parentDirectory: PreviewDirectoryDescriptor?
    let trust: PreviewTrust?
    let detectedEncoding: PreviewEncoding?

    init(
        bytes: Data, truncated: Bool, parentDirectory: PreviewDirectoryDescriptor? = nil, trust: PreviewTrust? = nil
    ) {
        self.bytes = bytes
        self.truncated = truncated
        self.parentDirectory = parentDirectory
        self.trust = trust
        self.detectedEncoding = (try? TextEncoding.detect(from: bytes, truncated: truncated)).map {
            PreviewEncoding(detected: $0.encoding)
        }
    }

    var binaryPropertyList: Bool { bytes.starts(with: "bplist".utf8) }

    static func read(
        _ url: URL, trustedFolders: [String] = [], keepParentDirectory: Bool = false
    ) throws -> Self {
        try readSnapshot(url, trustedFolders: trustedFolders, keepParentDirectory: keepParentDirectory).source
    }

    static func readSnapshot(
        _ url: URL, trustedFolders: [String] = [], keepParentDirectory: Bool = false
    ) throws -> (source: Self, trust: PreviewTrust, stamp: PreviewFileStamp) {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let folderPath = resolved.deletingLastPathComponent().path
        let folderFD = open(folderPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard folderFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let retainedFolder = PreviewDirectoryDescriptor(rawValue: folderFD)
        // Nonblocking: a FIFO must not hang.
        let fileFD = openat(folderFD, resolved.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fileFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fileFD) }
        var status = stat()
        guard fstat(fileFD, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let stamp = PreviewFileStamp(fileStatus: status)
        let trust = PreviewTrust.evaluate(
            linkURL: url, resolvedURL: resolved, fileDescriptor: fileFD, status: status,
            trustedFolders: trustedFolders)
        let truncated = Int64(status.st_size) > Int64(maximumBytes)
        let limit = truncated ? excerptBytes : maximumBytes
        var bytes = Data()
        var chunk = [UInt8](repeating: 0, count: readChunkBytes)
        while bytes.count < limit {
            try Task.checkCancellation()
            let wanted = min(readChunkBytes, limit - bytes.count)
            let received = chunk.withUnsafeMutableBytes { Darwin.read(fileFD, $0.baseAddress, wanted) }
            if received == 0 { break }
            if received < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            bytes.append(contentsOf: chunk[..<received])
        }
        try Task.checkCancellation()
        let source = Self(
            bytes: bytes, truncated: truncated, parentDirectory: keepParentDirectory ? retainedFolder : nil,
            trust: trust)
        return (source, trust, stamp)
    }

    func decoded(as encoding: PreviewEncoding) throws -> String {
        if encoding == .automatic {
            return try TextEncoding.detectedString(from: bytes, truncated: truncated)
        }
        guard truncated else { return try encoding.decode(bytes) }
        let selected: PreviewEncoding
        if encoding == .utf16 || encoding == .utf32 {
            if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
                selected = .utf32LE
            } else if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
                selected = .utf32BE
            } else if bytes.starts(with: [0xFF, 0xFE]) {
                selected = .utf16LE
            } else if bytes.starts(with: [0xFE, 0xFF]) {
                selected = .utf16BE
            } else if encoding == .utf32 {
                selected = .utf32BE
            } else {
                selected = .utf16BE
            }
        } else {
            selected = encoding
        }
        if [.shiftJIS, .eucJP, .iso2022JP, .gb18030, .big5, .eucKR].contains(selected) {
            do { return try selected.decode(bytes) } catch {
                let omitted = incompleteSuffixLength(encoding: selected)
                guard omitted > 0 else { throw error }
                return try selected.decode(bytes.dropLast(omitted))
            }
        }
        let omitted = incompleteSuffixLength(encoding: selected)
        if omitted > 0 {
            return try selected.decode(bytes.dropLast(omitted))
        }
        return try encoding.decode(bytes)
    }

    private func incompleteSuffixLength(encoding: PreviewEncoding) -> Int {
        guard let last = bytes.last else { return 0 }
        switch encoding {
        case .utf8:
            let tail = Array(bytes.suffix(4))
            guard let start = tail.lastIndex(where: { $0 & 0xC0 != 0x80 }) else { return 0 }
            let lead = tail[start]
            let required: Int
            switch lead {
            case 0xC2...0xDF: required = 2
            case 0xE0...0xEF: required = 3
            case 0xF0...0xF4: required = 4
            default: return 0
            }
            let count = tail.count - start
            guard count < required else { return 0 }
            if count > 1 {
                let second = tail[start + 1]
                if (lead == 0xE0 && second < 0xA0) || (lead == 0xED && second > 0x9F)
                    || (lead == 0xF0 && second < 0x90) || (lead == 0xF4 && second > 0x8F)
                {
                    return 0
                }
            }
            return count
        case .utf16LE, .utf16BE:
            let odd = bytes.count % 2
            let tail = Array(bytes.dropLast(odd).suffix(2))
            guard tail.count == 2 else { return odd }
            let high = encoding == .utf16LE ? tail[1] : tail[0]
            if (0xD8...0xDB).contains(high) {
                if odd == 1 && encoding == .utf16BE && !(0xDC...0xDF).contains(last) { return 0 }
                return odd + 2
            }
            return odd
        case .shiftJIS:
            return (0x81...0x9F).contains(last) || (0xE0...0xFC).contains(last) ? 1 : 0
        case .eucJP:
            let tail = Array(bytes.suffix(2))
            if tail.count == 2 && tail[0] == 0x8F && (0xA1...0xFE).contains(last) { return 2 }
            return last == 0x8E || last == 0x8F || (0xA1...0xFE).contains(last) ? 1 : 0
        case .iso2022JP:
            if last == 0x1B { return 1 }
            if bytes.suffix(2) == Data([0x1B, 0x24]) || bytes.suffix(2) == Data([0x1B, 0x28]) { return 2 }
            guard let escape = bytes.lastIndex(of: 0x1B), escape + 2 < bytes.endIndex,
                bytes[escape + 1] == 0x24, [0x40, 0x42].contains(bytes[escape + 2]),
                (0x21...0x7E).contains(last)
            else { return 0 }
            return (bytes.endIndex - escape - 3) % 2
        case .gb18030:
            let tail = Array(bytes.suffix(3))
            if tail.count == 3, (0x81...0xFE).contains(tail[0]), (0x30...0x39).contains(tail[1]),
                (0x81...0xFE).contains(tail[2])
            {
                return 3
            }
            if tail.count >= 2, (0x81...0xFE).contains(tail[tail.count - 2]),
                (0x30...0x39).contains(tail[tail.count - 1])
            {
                return 2
            }
            return (0x81...0xFE).contains(last) ? 1 : 0
        case .big5, .eucKR:
            return (0x81...0xFE).contains(last) ? 1 : 0
        case .utf32LE, .utf32BE:
            return bytes.count % 4
        case .automatic, .utf16, .utf32, .windows1252, .latin1: return 0
        }
    }

}

enum PreviewLanguage: CaseIterable, Equatable, Sendable {
    case plain, swift, javascript, python, c, cpp, objectiveC, objectiveCPP, go, rust, ruby, php,
        java, kotlin, csharp, scala, dart, lua, perl, r, shell, powershell, batch, sql,
        json, yaml, toml, ini, dockerfile, makefile, cmake, groovy, hcl, protobuf, graphql,
        css, markup, markdown, latex, restructuredText, asciiDoc, diff,
        fsharp, vb, julia, elixir, clojure, solidity

    static func resolve(_ suffix: String, fileName: String? = nil) -> Self {
        if let name = fileName?.lowercased(), let exact = exactFileNames[name] {
            return exact
        }
        let lowered = suffix.lowercased()
        switch lowered {
        case "swift": return .swift
        case "js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx": return .javascript
        case "py", "pyw", "pyi": return .python
        case "c", "h": return .c
        case "cc", "cpp", "cxx", "hh", "hpp", "hxx", "inl": return .cpp
        case "m": return .objectiveC
        case "mm": return .objectiveCPP
        case "go": return .go
        case "rs": return .rust
        case "rb": return .ruby
        case "php": return .php
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "cs", "csx": return .csharp
        case "scala": return .scala
        case "dart": return .dart
        case "lua": return .lua
        case "pl", "pm": return .perl
        case "r": return .r
        case "sh", "bash", "zsh", "fish": return .shell
        case "ps1", "psm1", "psd1": return .powershell
        case "bat", "cmd": return .batch
        case "sql": return .sql
        case "json", "jsonc", "json5": return .json
        case "yaml", "yml": return .yaml
        case "toml": return .toml
        case "ini", "cfg", "conf", "properties", "reg", "inf", "env", "editorconfig", "gitmodules": return .ini
        case "dockerfile": return .dockerfile
        case "mk", "mak", "make": return .makefile
        case "cmake": return .cmake
        case "gradle", "groovy": return .groovy
        case "hcl", "tf", "tfvars": return .hcl
        case "proto": return .protobuf
        case "graphql", "gql": return .graphql
        case "css", "scss", "sass", "less": return .css
        case "html", "htm", "xhtml", "xml", "xaml", "csproj", "vcxproj", "fsproj", "vbproj",
            "props", "targets", "plist", "manifest", "svg", "vue", "svelte", "astro":
            return .markup
        case "md", "markdown", "mdx": return .markdown
        case "tex", "sty", "cls": return .latex
        case "rst": return .restructuredText
        case "adoc", "asciidoc": return .asciiDoc
        case "diff", "patch": return .diff
        case "fs", "fsx": return .fsharp
        case "vb", "vbs": return .vb
        case "jl": return .julia
        case "ex", "exs": return .elixir
        case "clj": return .clojure
        case "sol": return .solidity
        default:
            if let name = fileName?.lowercased() {
                if name.hasPrefix(".env.") { return .ini }
                if name.hasPrefix("dockerfile.") { return .dockerfile }
            }
            return .plain
        }
    }

    private static let exactFileNames: [String: Self] = [
        "cmakelists.txt": .cmake,
        "makefile": .makefile,
        "gnumakefile": .makefile,
        "dockerfile": .dockerfile,
        "containerfile": .dockerfile,
        ".dockerfile": .dockerfile,
        "gemfile": .ruby,
        "rakefile": .ruby,
        "podfile": .ruby,
        "brewfile": .ruby,
        "fastfile": .ruby,
        "vagrantfile": .ruby,
        "jenkinsfile": .groovy,
        ".env": .ini,
        ".editorconfig": .ini,
        ".gitmodules": .ini,
        ".gitconfig": .ini,
        ".npmrc": .ini,
        ".gitignore": .plain,
        ".gitattributes": .plain,
        ".bashrc": .shell,
        ".zshrc": .shell,
        ".bash_profile": .shell,
        ".zprofile": .shell,
        ".zshenv": .shell,
        ".profile": .shell,
    ]
}
