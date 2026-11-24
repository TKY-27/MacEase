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

struct PreviewToken: Equatable, Sendable {
    enum Kind: Sendable {
        case keyword, type, string, comment, number, diffAdded, diffRemoved, invisible
    }
    let range: NSRange
    let kind: Kind
}

enum PreviewTokenizer {
    private static let cancellationStride = 4096
    // Bounds unterminated comments and multiline strings.
    private static let maximumBlockUnits = 16_384
    private static let maximumBlockLines = 256
    private static let maximumDelimiterLength = 16
    private static let maximumHeredocTagLength = 32
    private static let maximumUnicodeEscapeDigits = 6
    private static let maximumAsciiDocHeadingLevel = 6
    private static let minimumRstAdornmentLength = 3
    private static let minimumAsciiDocFenceLength = 4

    private static let doubleQuoteRule = PreviewLanguageGrammar.StringRule("\"")
    private static let multilineDoubleQuoteRule = PreviewLanguageGrammar.StringRule("\"", multiline: true)
    private static let verbatimDoubleQuoteRule = PreviewLanguageGrammar.StringRule(
        "\"", escape: .doubled, multiline: true)
    private static let rawDoubleQuoteRule = PreviewLanguageGrammar.StringRule("\"", escape: .none)
    private static let rawSingleQuoteRule = PreviewLanguageGrammar.StringRule("'", escape: .none)
    private static let rawTripleDoubleQuoteRule = PreviewLanguageGrammar.StringRule(
        "\"\"\"", escape: .none, multiline: true)
    private static let rawTripleSingleQuoteRule = PreviewLanguageGrammar.StringRule(
        "'''", escape: .none, multiline: true)

    private static let markupDirectiveLeaders: Set<UInt16> = [UTF16Code.exclamation, UTF16Code.question]
    private static let scalarPreceders: Set<UInt16> = [
        UTF16Code.tab, UTF16Code.lineFeed, UTF16Code.carriageReturn, UTF16Code.space,
        UTF16Code.comma, UTF16Code.colon, UTF16Code.equals, UTF16Code.leftBracket, UTF16Code.leftBrace,
    ]
    private static let objcAtKeywords: Set<String> = [
        "autoreleasepool", "available", "catch", "class", "compatibility_alias", "defs", "dynamic",
        "encode", "end", "finally", "implementation", "import", "interface", "NO", "optional",
        "package", "private", "property", "protected", "protocol", "public", "required", "selector",
        "synchronized", "synthesize", "throw", "try", "YES",
    ]
    private static let rstAdornments: Set<UInt16> = Set("=-~^+*#\"`:.'_".utf16)
    private static let cssUnitSuffixes: Set<String> = [
        "px", "em", "rem", "vh", "vw", "vmin", "vmax", "svh", "dvh", "lvh",
        "ch", "ex", "pt", "pc", "cm", "mm", "in", "s", "ms", "deg", "rad", "turn", "fr",
    ]

    static func tokens(_ text: String, language: PreviewLanguage) throws -> [PreviewToken] {
        let units = cappedUTF16Units(of: text)
        guard !units.isEmpty else { return [] }
        return try units.withUnsafeBufferPointer { buffer in
            var result: [PreviewToken] = []
            if language != .plain {
                let grammar = PreviewLanguageGrammar.grammar(for: language)
                if grammar.features.contains(.diffSyntax) {
                    try tokenizeDiff(buffer, into: &result)
                } else if grammar.features.contains(.rstSyntax) {
                    try tokenizeRestructuredText(buffer, into: &result)
                } else if grammar.features.contains(.asciiDocSyntax) {
                    try tokenizeAsciiDoc(buffer, into: &result)
                } else {
                    try tokenizeGeneral(buffer, baseGrammar: grammar, into: &result)
                }
            }
            try appendInvisibleTokens(buffer, into: &result)
            return result
        }
    }

    private static func cappedUTF16Units(of text: String) -> [UInt16] {
        let limit = PreviewTextSource.highlightBytes
        if text.utf8.count <= limit {
            return Array(text.utf16)
        }
        let utf8 = text.utf8
        var end = utf8.index(utf8.startIndex, offsetBy: limit)
        // Walk back to avoid splitting UTF-8 scalars.
        while end > utf8.startIndex, (utf8[end] & 0xC0) == 0x80 {
            end = utf8.index(before: end)
        }
        return Array(text[..<end].utf16)
    }

    private static func tokenizeGeneral(
        _ buffer: UnsafeBufferPointer<UInt16>,
        baseGrammar: PreviewLanguageGrammar,
        into result: inout [PreviewToken]
    ) throws {
        let count = buffer.count
        var activeGrammar = baseGrammar
        var cursor = 0
        var step = 0
        var atLineStart = true
        var lineStartOffset = 0
        var inMarkupTag = false
        var tagSelfClosing = false
        var pendingEmbedded: PreviewLanguage?
        var embeddedLanguage: PreviewLanguage?

        while cursor < count {
            step &+= 1
            if (step & (cancellationStride - 1)) == 0 { try Task.checkCancellation() }

            if let embedded = embeddedLanguage,
                matchesEmbeddedClose(buffer, at: cursor, language: embedded)
            {
                embeddedLanguage = nil
                activeGrammar = baseGrammar
            }

            let start = cursor
            let unit = buffer[cursor]
            if unit == UTF16Code.lineFeed || unit == UTF16Code.carriageReturn {
                cursor += 1
                atLineStart = true
                lineStartOffset = cursor
                continue
            }
            if unit == UTF16Code.space || unit == UTF16Code.tab {
                cursor += 1
                continue
            }

            let isFirstOnLine = atLineStart
            atLineStart = false
            let previous: UInt16? = start > 0 ? buffer[start - 1] : nil
            let features = activeGrammar.features

            if activeGrammar.triggersSpecial(unit) || (isFirstOnLine && features.contains(.batchRemComment)) {
                if let token = scanSpecial(
                    buffer,
                    at: &cursor,
                    previous: previous,
                    isFirstOnLine: isFirstOnLine,
                    grammar: activeGrammar,
                    inMarkupTag: &inMarkupTag,
                    tagSelfClosing: &tagSelfClosing,
                    pendingEmbedded: &pendingEmbedded,
                    embeddedLanguage: &embeddedLanguage,
                    activeGrammar: &activeGrammar)
                {
                    result.append(token)
                    continue
                }
                if cursor > start { continue }
            }

            if isFirstOnLine,
                features.contains(.keyBeforeEquals) || features.contains(.keyBeforeColonOrEquals),
                let keyEnd = scanKeyAssignment(
                    buffer, from: start, allowColon: features.contains(.keyBeforeColonOrEquals))
            {
                cursor = keyEnd
                result.append(PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .keyword))
                continue
            }

            if isFirstOnLine, start == lineStartOffset, features.contains(.makefileTargets),
                let targetEnd = scanMakefileTarget(buffer, from: start)
            {
                cursor = targetEnd
                result.append(PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .type))
                continue
            }

            if activeGrammar.numberStyle != .none, isDigit(unit) {
                cursor = scanNumber(buffer, from: start, style: activeGrammar.numberStyle)
                result.append(PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .number))
                continue
            }

            if isIdentifierStart(unit, features: features) {
                cursor += 1
                while cursor < count, isIdentifierContinue(buffer[cursor], features: features) {
                    cursor += 1
                }
                if let kind = classifyWord(
                    buffer, start: start, end: cursor, isFirstOnLine: isFirstOnLine, grammar: activeGrammar)
                {
                    result.append(PreviewToken(range: NSRange(location: start, length: cursor - start), kind: kind))
                }
                continue
            }

            cursor += 1
        }
    }

    private static func scanSpecial(
        _ buffer: UnsafeBufferPointer<UInt16>,
        at cursor: inout Int,
        previous: UInt16?,
        isFirstOnLine: Bool,
        grammar: PreviewLanguageGrammar,
        inMarkupTag: inout Bool,
        tagSelfClosing: inout Bool,
        pendingEmbedded: inout PreviewLanguage?,
        embeddedLanguage: inout PreviewLanguage?,
        activeGrammar: inout PreviewLanguageGrammar
    ) -> PreviewToken? {
        let unit = buffer[cursor]
        if grammar.triggersComment(unit) || (isFirstOnLine && grammar.features.contains(.batchRemComment)),
            let token = scanCommentOrDirective(
                buffer, at: &cursor, previous: previous, isFirstOnLine: isFirstOnLine, grammar: grammar)
        {
            return token
        }
        if grammar.triggersSpecialLiteral(unit),
            let token = scanSpecialLiteral(buffer, at: &cursor, previous: previous, grammar: grammar)
        {
            return token
        }
        guard grammar.triggersStringOrMarkup(unit) else { return nil }
        return scanMarkupOrQuotedLiteral(
            buffer,
            at: &cursor,
            previous: previous,
            grammar: grammar,
            inMarkupTag: &inMarkupTag,
            tagSelfClosing: &tagSelfClosing,
            pendingEmbedded: &pendingEmbedded,
            embeddedLanguage: &embeddedLanguage,
            activeGrammar: &activeGrammar)
    }

    private static func scanCommentOrDirective(
        _ buffer: UnsafeBufferPointer<UInt16>,
        at cursor: inout Int,
        previous: UInt16?,
        isFirstOnLine: Bool,
        grammar: PreviewLanguageGrammar
    ) -> PreviewToken? {
        let start = cursor
        let count = buffer.count
        let unit = buffer[start]
        let features = grammar.features

        if features.contains(.luaLongBrackets), unit == UTF16Code.minus,
            start + 3 < count, buffer[start + 1] == UTF16Code.minus, buffer[start + 2] == UTF16Code.leftBracket,
            let end = scanLuaLongBracket(buffer, from: start + 2)
        {
            cursor = end
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .comment)
        }

        for block in grammar.blockComments where block.open.first == unit && matches(buffer, at: start, block.open) {
            cursor = scanBlockComment(buffer, from: start, block: block)
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .comment)
        }

        for marker in grammar.lineComments where marker.first == unit && matches(buffer, at: start, marker) {
            if features.contains(.slashCommentSkipsURL), unit == UTF16Code.slash, previous == UTF16Code.colon {
                continue
            }
            if features.contains(.escapedPercentSkipsComment), unit == UTF16Code.percent,
                previous == UTF16Code.backslash
            {
                continue
            }
            cursor = lineEnd(buffer, from: start)
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .comment)
        }

        if isFirstOnLine, features.contains(.batchRemComment), matchesBatchRem(buffer, at: start) {
            cursor = lineEnd(buffer, from: start)
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .comment)
        }

        if isFirstOnLine, features.contains(.markdownHeadings), unit == UTF16Code.hash {
            cursor = lineEnd(buffer, from: start)
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .keyword)
        }

        if isFirstOnLine, features.contains(.hashPreprocessor), unit == UTF16Code.hash {
            var end = start + 1
            while end < count, buffer[end] == UTF16Code.space || buffer[end] == UTF16Code.tab { end += 1 }
            let wordStart = end
            while end < count, isASCIIIdentifier(buffer[end]) { end += 1 }
            if end > wordStart {
                cursor = end
                return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .keyword)
            }
        }

        if isFirstOnLine, features.contains(.iniSectionHeaders), unit == UTF16Code.leftBracket,
            let end = scanSectionHeader(buffer, from: start)
        {
            cursor = end
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .keyword)
        }

        if features.contains(.latexCommands), unit == UTF16Code.backslash {
            cursor = scanLaTeXCommand(buffer, from: start)
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .keyword)
        }

        return nil
    }

    private static func scanSpecialLiteral(
        _ buffer: UnsafeBufferPointer<UInt16>,
        at cursor: inout Int,
        previous: UInt16?,
        grammar: PreviewLanguageGrammar
    ) -> PreviewToken? {
        let start = cursor
        let count = buffer.count
        let unit = buffer[start]
        let features = grammar.features

        if features.contains(.objcAtKeywords), unit == UTF16Code.atSign, start + 1 < count {
            let next = buffer[start + 1]
            if next == UTF16Code.doubleQuote {
                cursor = scanDelimited(buffer, from: start + 1, rule: doubleQuoteRule)
                return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .string)
            }
            if isASCIILetter(next) {
                var end = start + 2
                while end < count, isASCIIIdentifier(buffer[end]) { end += 1 }
                let word = String(decoding: buffer[(start + 1)..<end], as: UTF16.self)
                if objcAtKeywords.contains(word) {
                    cursor = end
                    return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .keyword)
                }
            }
        }

        if features.contains(.powershellHereString), unit == UTF16Code.atSign,
            let end = scanPowerShellHereString(buffer, from: start)
        {
            cursor = end
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .string)
        }

        if features.contains(.rustRawStrings), unit == UTF16Code.lowerR || unit == UTF16Code.lowerB,
            !(previous.map(isPlainIdentifier) ?? false),
            let end = scanRustRawString(buffer, from: start)
        {
            cursor = end
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .string)
        }

        if features.contains(.cppRawStrings), unit == UTF16Code.upperR,
            !(previous.map(isPlainIdentifier) ?? false),
            let end = scanCPPRawString(buffer, from: start)
        {
            cursor = end
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .string)
        }

        if features.contains(.luaLongBrackets), unit == UTF16Code.leftBracket,
            let end = scanLuaLongBracket(buffer, from: start)
        {
            cursor = end
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .string)
        }

        if features.contains(.heredoc), unit == UTF16Code.lessThan,
            let end = scanHeredoc(buffer, from: start)
        {
            cursor = end
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .string)
        }

        if let end = scanPrefixedString(buffer, from: start, previous: previous, grammar: grammar) {
            cursor = end
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .string)
        }

        return nil
    }

    private static func scanMarkupOrQuotedLiteral(
        _ buffer: UnsafeBufferPointer<UInt16>,
        at cursor: inout Int,
        previous: UInt16?,
        grammar: PreviewLanguageGrammar,
        inMarkupTag: inout Bool,
        tagSelfClosing: inout Bool,
        pendingEmbedded: inout PreviewLanguage?,
        embeddedLanguage: inout PreviewLanguage?,
        activeGrammar: inout PreviewLanguageGrammar
    ) -> PreviewToken? {
        let start = cursor
        let count = buffer.count
        let unit = buffer[start]

        if grammar.features.contains(.markupTags) {
            if unit == UTF16Code.lessThan {
                return scanMarkupOpen(
                    buffer, at: &cursor, inMarkupTag: &inMarkupTag,
                    tagSelfClosing: &tagSelfClosing, pendingEmbedded: &pendingEmbedded)
            }
            if inMarkupTag, unit == UTF16Code.slash, start + 1 < count, buffer[start + 1] == UTF16Code.greaterThan {
                tagSelfClosing = true
                cursor += 1
                return nil
            }
            if unit == UTF16Code.greaterThan {
                let wasInTag = inMarkupTag
                inMarkupTag = false
                cursor += 1
                if wasInTag, !tagSelfClosing, let next = pendingEmbedded {
                    embeddedLanguage = next
                    activeGrammar = PreviewLanguageGrammar.grammar(for: next)
                }
                pendingEmbedded = nil
                tagSelfClosing = false
                return nil
            }
        }

        for rule in grammar.strings
        where rule.openFirst == unit
            && (rule.openLength == 1 || matches(buffer, at: start, rule.open))
        {
            switch rule.scope {
            case .anywhere:
                break
            case .notAfterDigit:
                if let previous, isDigit(previous) { continue }
            case .markupTag:
                guard inMarkupTag else { continue }
            case .scalarStart:
                if let previous, !scalarPreceders.contains(previous) { continue }
            case .charLiteral:
                if let end = scanCharLiteral(buffer, from: start) {
                    cursor = end
                    return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .string)
                }
                continue
            }
            cursor = scanDelimited(buffer, from: start, rule: rule)
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .string)
        }

        if grammar.numberStyle == .cssUnit, unit == UTF16Code.hash,
            let end = scanCSSHexColor(buffer, from: start)
        {
            cursor = end
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .number)
        }

        return nil
    }

    private static func scanMarkupOpen(
        _ buffer: UnsafeBufferPointer<UInt16>,
        at cursor: inout Int,
        inMarkupTag: inout Bool,
        tagSelfClosing: inout Bool,
        pendingEmbedded: inout PreviewLanguage?
    ) -> PreviewToken {
        let start = cursor
        let count = buffer.count
        cursor += 1
        var isClosing = false
        if cursor < count, buffer[cursor] == UTF16Code.slash {
            isClosing = true
            cursor += 1
        }
        let nameStart = cursor
        while cursor < count, isMarkupNameChar(buffer[cursor]) { cursor += 1 }
        if cursor > nameStart
            || (nameStart < count && markupDirectiveLeaders.contains(buffer[nameStart]))
        {
            inMarkupTag = true
            tagSelfClosing = false
            pendingEmbedded = nil
            if !isClosing, cursor > nameStart {
                let length = cursor - nameStart
                if length == 6, matchesASCIIFolded(buffer, at: nameStart, "script") {
                    pendingEmbedded = .javascript
                } else if length == 5, matchesASCIIFolded(buffer, at: nameStart, "style") {
                    pendingEmbedded = .css
                }
            }
        }
        return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .keyword)
    }

    private static func matchesEmbeddedClose(
        _ buffer: UnsafeBufferPointer<UInt16>, at index: Int, language: PreviewLanguage
    ) -> Bool {
        let tag = language == .javascript ? "</script" : "</style"
        let length = tag.utf16.count
        guard index + length <= buffer.count, matchesASCIIFolded(buffer, at: index, tag) else { return false }
        if index + length == buffer.count { return true }
        let next = buffer[index + length]
        return next == UTF16Code.greaterThan || next == UTF16Code.space || next == UTF16Code.tab
            || next == UTF16Code.lineFeed || next == UTF16Code.carriageReturn || next == UTF16Code.slash
    }

    private static func scanBlockComment(
        _ buffer: UnsafeBufferPointer<UInt16>, from start: Int, block: PreviewLanguageGrammar.BlockComment
    ) -> Int {
        let count = buffer.count
        let unitLimit = min(count, start + maximumBlockUnits)
        var cursor = start + block.open.count
        var depth = 1
        var lines = 0
        while cursor < unitLimit, depth > 0 {
            if matches(buffer, at: cursor, block.close) {
                depth -= 1
                cursor += block.close.count
            } else if block.nested, matches(buffer, at: cursor, block.open) {
                depth += 1
                cursor += block.open.count
            } else {
                if buffer[cursor] == UTF16Code.lineFeed {
                    lines += 1
                    if lines >= maximumBlockLines { break }
                }
                cursor += 1
            }
        }
        return min(count, cursor)
    }

    private static func scanDelimited(
        _ buffer: UnsafeBufferPointer<UInt16>, from start: Int, rule: PreviewLanguageGrammar.StringRule
    ) -> Int {
        let count = buffer.count
        let unitLimit = rule.multiline ? min(count, start + maximumBlockUnits) : count
        var cursor = start + rule.openLength
        var lines = 0
        let closeFirst = rule.closeFirst
        let closeLength = rule.closeLength
        if closeLength == 1 {
            while cursor < unitLimit {
                let unit = buffer[cursor]
                if unit == closeFirst {
                    if rule.escape == .doubled, cursor + 1 < unitLimit, buffer[cursor + 1] == closeFirst {
                        cursor += 2
                        continue
                    }
                    return cursor + 1
                }
                if unit == UTF16Code.lineFeed || unit == UTF16Code.carriageReturn {
                    if !rule.multiline { return cursor }
                    if unit == UTF16Code.lineFeed {
                        lines += 1
                        if lines >= maximumBlockLines { return cursor }
                    }
                    cursor += 1
                    continue
                }
                if (rule.escape == .backslash && unit == UTF16Code.backslash)
                    || (rule.escape == .backtick && unit == UTF16Code.backtick)
                {
                    cursor = min(unitLimit, cursor + 2)
                    continue
                }
                cursor += 1
            }
            return min(count, cursor)
        }
        while cursor < unitLimit {
            let unit = buffer[cursor]
            if unit == UTF16Code.lineFeed || unit == UTF16Code.carriageReturn {
                if !rule.multiline { break }
                if unit == UTF16Code.lineFeed {
                    lines += 1
                    if lines >= maximumBlockLines { break }
                }
                cursor += 1
                continue
            }
            switch rule.escape {
            case .backslash:
                if unit == UTF16Code.backslash {
                    cursor = min(unitLimit, cursor + 2)
                    continue
                }
            case .backtick:
                if unit == UTF16Code.backtick {
                    cursor = min(unitLimit, cursor + 2)
                    continue
                }
            case .doubled:
                if unit == closeFirst, matches(buffer, at: cursor, rule.close),
                    matches(buffer, at: cursor + closeLength, rule.close)
                {
                    cursor += closeLength * 2
                    continue
                }
            case .none:
                break
            }
            if unit == closeFirst, matches(buffer, at: cursor, rule.close) {
                cursor += closeLength
                break
            }
            cursor += 1
        }
        return min(count, cursor)
    }

    private static func scanCharLiteral(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let count = buffer.count
        var pos = start + 1
        guard pos < count else { return nil }
        let first = buffer[pos]
        guard first != UTF16Code.singleQuote, first != UTF16Code.lineFeed, first != UTF16Code.carriageReturn else {
            return nil
        }
        if first == UTF16Code.backslash {
            pos += 1
            guard pos < count else { return nil }
            let escaped = buffer[pos]
            pos += 1
            if escaped == UTF16Code.lowerX {
                guard pos + 1 < count, isHexDigit(buffer[pos]), isHexDigit(buffer[pos + 1]) else { return nil }
                pos += 2
            } else if escaped == UTF16Code.lowerU, pos < count, buffer[pos] == UTF16Code.leftBrace {
                pos += 1
                var digits = 0
                while pos < count, digits < maximumUnicodeEscapeDigits, isHexDigit(buffer[pos]) {
                    pos += 1
                    digits += 1
                }
                guard digits > 0, pos < count, buffer[pos] == UTF16Code.rightBrace else { return nil }
                pos += 1
            }
        } else if (UTF16Code.leadSurrogateStart...UTF16Code.leadSurrogateEnd).contains(first),
            pos + 1 < count,
            (UTF16Code.trailSurrogateStart...UTF16Code.trailSurrogateEnd).contains(buffer[pos + 1])
        {
            pos += 2
        } else {
            pos += 1
        }
        guard pos < count, buffer[pos] == UTF16Code.singleQuote else { return nil }
        return pos + 1
    }

    private static func scanRustRawString(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let count = buffer.count
        var pos = start
        if buffer[pos] == UTF16Code.lowerB {
            pos += 1
            guard pos < count, buffer[pos] == UTF16Code.lowerR else { return nil }
        }
        pos += 1
        var hashes = 0
        while pos < count, hashes < maximumDelimiterLength, buffer[pos] == UTF16Code.hash {
            pos += 1
            hashes += 1
        }
        guard pos < count, buffer[pos] == UTF16Code.doubleQuote else { return nil }
        pos += 1
        let limit = min(count, start + maximumBlockUnits)
        var lines = 0
        while pos < limit {
            let unit = buffer[pos]
            if unit == UTF16Code.doubleQuote {
                var matched = 0
                while matched < hashes, pos + 1 + matched < count, buffer[pos + 1 + matched] == UTF16Code.hash {
                    matched += 1
                }
                if matched == hashes { return pos + 1 + hashes }
            } else if unit == UTF16Code.lineFeed {
                lines += 1
                if lines >= maximumBlockLines { break }
            }
            pos += 1
        }
        return min(count, pos)
    }

    private static func scanCPPRawString(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let count = buffer.count
        guard start + 2 < count, buffer[start + 1] == UTF16Code.doubleQuote else { return nil }
        let delimStart = start + 2
        var delimEnd = delimStart
        while delimEnd < count, delimEnd - delimStart <= maximumDelimiterLength {
            let unit = buffer[delimEnd]
            if unit == UTF16Code.leftParen { break }
            if unit == UTF16Code.space || unit == UTF16Code.tab || unit == UTF16Code.lineFeed
                || unit == UTF16Code.carriageReturn || unit == UTF16Code.rightParen || unit == UTF16Code.backslash
            {
                return nil
            }
            delimEnd += 1
        }
        guard delimEnd < count, buffer[delimEnd] == UTF16Code.leftParen else { return nil }
        let delimLength = delimEnd - delimStart
        var pos = delimEnd + 1
        let limit = min(count, start + maximumBlockUnits)
        var lines = 0
        while pos < limit {
            if buffer[pos] == UTF16Code.rightParen, pos + delimLength + 1 < count,
                buffer[pos + delimLength + 1] == UTF16Code.doubleQuote
            {
                var matched = true
                for offset in 0..<delimLength where buffer[pos + 1 + offset] != buffer[delimStart + offset] {
                    matched = false
                    break
                }
                if matched { return pos + delimLength + 2 }
            } else if buffer[pos] == UTF16Code.lineFeed {
                lines += 1
                if lines >= maximumBlockLines { break }
            }
            pos += 1
        }
        return min(count, pos)
    }

    private static func scanLuaLongBracket(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let count = buffer.count
        guard start + 1 < count, buffer[start] == UTF16Code.leftBracket else { return nil }
        var pos = start + 1
        var equals = 0
        while pos < count, equals < maximumDelimiterLength, buffer[pos] == UTF16Code.equals {
            pos += 1
            equals += 1
        }
        guard pos < count, buffer[pos] == UTF16Code.leftBracket else { return nil }
        pos += 1
        let limit = min(count, start + maximumBlockUnits)
        var lines = 0
        while pos < limit {
            if buffer[pos] == UTF16Code.rightBracket, pos + equals + 1 < count,
                buffer[pos + equals + 1] == UTF16Code.rightBracket
            {
                var matched = true
                for offset in 0..<equals where buffer[pos + 1 + offset] != UTF16Code.equals {
                    matched = false
                    break
                }
                if matched { return pos + equals + 2 }
            } else if buffer[pos] == UTF16Code.lineFeed {
                lines += 1
                if lines >= maximumBlockLines { break }
            }
            pos += 1
        }
        return min(count, pos)
    }

    private static func scanPowerShellHereString(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let count = buffer.count
        guard start + 2 < count else { return nil }
        let quote = buffer[start + 1]
        guard quote == UTF16Code.doubleQuote || quote == UTF16Code.singleQuote else { return nil }
        var pos = start + 2
        while pos < count, buffer[pos] == UTF16Code.space || buffer[pos] == UTF16Code.tab { pos += 1 }
        guard pos < count, buffer[pos] == UTF16Code.lineFeed || buffer[pos] == UTF16Code.carriageReturn else {
            return nil
        }
        let limit = min(count, start + maximumBlockUnits)
        var lines = 0
        while pos < limit {
            if buffer[pos] == UTF16Code.lineFeed {
                lines += 1
                if lines >= maximumBlockLines { break }
                if pos + 2 < count, buffer[pos + 1] == quote, buffer[pos + 2] == UTF16Code.atSign {
                    return pos + 3
                }
            }
            pos += 1
        }
        return min(count, pos)
    }

    private static func scanHeredoc(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let count = buffer.count
        guard start + 2 < count, buffer[start + 1] == UTF16Code.lessThan else { return nil }
        var pos = start + 2
        var isTriple = false
        var stripIndent = false
        if pos < count, buffer[pos] == UTF16Code.lessThan {
            isTriple = true
            pos += 1
        } else if pos < count, buffer[pos] == UTF16Code.minus || buffer[pos] == UTF16Code.tilde {
            stripIndent = true
            pos += 1
        }
        let hadSpace = pos < count && (buffer[pos] == UTF16Code.space || buffer[pos] == UTF16Code.tab)
        while pos < count, buffer[pos] == UTF16Code.space || buffer[pos] == UTF16Code.tab { pos += 1 }
        guard pos < count else { return nil }
        let quote: UInt16?
        if buffer[pos] == UTF16Code.singleQuote || buffer[pos] == UTF16Code.doubleQuote {
            quote = buffer[pos]
            pos += 1
        } else {
            // Skip bitshift operators like `a << b`.
            if hadSpace && !isTriple && !stripIndent { return nil }
            quote = nil
        }
        let tagStart = pos
        var hasUpper = false
        while pos < count, pos - tagStart < maximumHeredocTagLength, isASCIIIdentifier(buffer[pos]) {
            if (UTF16Code.upperA...UTF16Code.upperZ).contains(buffer[pos]) { hasUpper = true }
            pos += 1
        }
        let tagLength = pos - tagStart
        guard tagLength > 0, isASCIILetter(buffer[tagStart]) || buffer[tagStart] == UTF16Code.underscore else {
            return nil
        }
        if let quote {
            guard pos < count, buffer[pos] == quote else { return nil }
            pos += 1
        } else if !isTriple && !stripIndent && !hasUpper {
            return nil
        }
        let firstLineEnd = lineEnd(buffer, from: pos)
        guard firstLineEnd < count else { return nil }
        var lineCursor = nextLineStart(buffer, after: firstLineEnd)
        let limit = min(count, start + maximumBlockUnits)
        var lines = 0
        while lineCursor < limit, lines < maximumBlockLines {
            lines += 1
            let currentEnd = lineEnd(buffer, from: lineCursor)
            var checkStart = lineCursor
            if stripIndent {
                while checkStart < currentEnd,
                    buffer[checkStart] == UTF16Code.space || buffer[checkStart] == UTF16Code.tab
                {
                    checkStart += 1
                }
            }
            var checkEnd = currentEnd
            if isTriple, checkEnd > checkStart, buffer[checkEnd - 1] == UTF16Code.semicolon {
                checkEnd -= 1
            }
            if checkEnd - checkStart == tagLength {
                var matched = true
                for offset in 0..<tagLength where buffer[checkStart + offset] != buffer[tagStart + offset] {
                    matched = false
                    break
                }
                if matched { return currentEnd }
            }
            lineCursor = nextLineStart(buffer, after: currentEnd)
        }
        return min(count, lineCursor)
    }

    private static func scanPrefixedString(
        _ buffer: UnsafeBufferPointer<UInt16>,
        from start: Int,
        previous: UInt16?,
        grammar: PreviewLanguageGrammar
    ) -> Int? {
        let count = buffer.count
        let features = grammar.features
        let unit = buffer[start]
        if features.contains(.csharpInterpolatedPrefix) {
            if unit == UTF16Code.dollar, start + 2 < count,
                buffer[start + 1] == UTF16Code.atSign, buffer[start + 2] == UTF16Code.doubleQuote
            {
                return scanDelimited(buffer, from: start + 2, rule: verbatimDoubleQuoteRule)
            }
            if unit == UTF16Code.atSign, start + 2 < count,
                buffer[start + 1] == UTF16Code.dollar, buffer[start + 2] == UTF16Code.doubleQuote
            {
                return scanDelimited(buffer, from: start + 2, rule: verbatimDoubleQuoteRule)
            }
            if unit == UTF16Code.dollar, start + 1 < count, buffer[start + 1] == UTF16Code.doubleQuote {
                return scanDelimited(buffer, from: start + 1, rule: doubleQuoteRule)
            }
        }
        guard !(previous.map(isPlainIdentifier) ?? false) else { return nil }
        if features.contains(.pythonStringPrefixes), isPythonPrefixChar(unit) {
            var quotePos = start + 1
            if quotePos < count, isPythonPrefixChar(buffer[quotePos]) { quotePos += 1 }
            if quotePos < count, buffer[quotePos] == UTF16Code.doubleQuote || buffer[quotePos] == UTF16Code.singleQuote
            {
                for rule in grammar.strings where matches(buffer, at: quotePos, rule.open) {
                    return scanDelimited(buffer, from: quotePos, rule: rule)
                }
            }
        }
        if features.contains(.dartRawStringPrefix), unit == UTF16Code.lowerR, start + 1 < count {
            let next = buffer[start + 1]
            if next == UTF16Code.doubleQuote || next == UTF16Code.singleQuote {
                for rule in [
                    rawTripleDoubleQuoteRule, rawTripleSingleQuoteRule, rawDoubleQuoteRule, rawSingleQuoteRule,
                ] where matches(buffer, at: start + 1, rule.open) {
                    return scanDelimited(buffer, from: start + 1, rule: rule)
                }
            }
        }
        if features.contains(.rustByteStringPrefix), unit == UTF16Code.lowerB || unit == UTF16Code.lowerC,
            start + 1 < count
        {
            if buffer[start + 1] == UTF16Code.doubleQuote {
                return scanDelimited(buffer, from: start + 1, rule: multilineDoubleQuoteRule)
            }
            if unit == UTF16Code.lowerB, buffer[start + 1] == UTF16Code.singleQuote,
                let end = scanCharLiteral(buffer, from: start + 1)
            {
                return end
            }
        }
        return nil
    }

    private static func scanSectionHeader(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let count = buffer.count
        var pos = start + 1
        while pos < count, buffer[pos] != UTF16Code.lineFeed, buffer[pos] != UTF16Code.carriageReturn {
            if buffer[pos] == UTF16Code.rightBracket {
                pos += 1
                if pos < count, buffer[pos] == UTF16Code.rightBracket { pos += 1 }
                return pos
            }
            pos += 1
        }
        return nil
    }

    private static func scanLaTeXCommand(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int {
        let count = buffer.count
        guard start + 1 < count else { return start + 1 }
        var pos = start + 1
        if isASCIILetter(buffer[pos]) {
            while pos < count, isASCIILetter(buffer[pos]) { pos += 1 }
            return pos
        }
        if buffer[pos] != UTF16Code.lineFeed && buffer[pos] != UTF16Code.carriageReturn {
            return pos + 1
        }
        return pos
    }

    private static func scanKeyAssignment(
        _ buffer: UnsafeBufferPointer<UInt16>, from start: Int, allowColon: Bool
    ) -> Int? {
        let count = buffer.count
        guard isASCIIKeyStart(buffer[start]) else { return nil }
        var keyEnd = start + 1
        while keyEnd < count, isASCIIKeyContinue(buffer[keyEnd]) { keyEnd += 1 }
        var probe = keyEnd
        while probe < count, buffer[probe] == UTF16Code.space || buffer[probe] == UTF16Code.tab { probe += 1 }
        guard probe < count else { return nil }
        if buffer[probe] == UTF16Code.equals || (allowColon && buffer[probe] == UTF16Code.colon) {
            return keyEnd
        }
        return nil
    }

    private static func scanMakefileTarget(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let count = buffer.count
        let first = buffer[start]
        guard isASCIILetter(first) || first == UTF16Code.dot || first == UTF16Code.underscore else { return nil }
        var pos = start + 1
        while pos < count {
            let unit = buffer[pos]
            if unit == UTF16Code.colon {
                if pos + 1 < count, buffer[pos + 1] == UTF16Code.equals { return nil }
                return pos
            }
            if unit == UTF16Code.equals || unit == UTF16Code.lineFeed || unit == UTF16Code.carriageReturn
                || unit == UTF16Code.hash || unit == UTF16Code.space || unit == UTF16Code.tab
            {
                return nil
            }
            pos += 1
        }
        return nil
    }

    private static func scanNumber(
        _ buffer: UnsafeBufferPointer<UInt16>, from start: Int, style: PreviewLanguageGrammar.NumberStyle
    ) -> Int {
        let count = buffer.count
        var cursor = start + 1
        if buffer[start] == UTF16Code.digitZero, cursor < count {
            let prefix = buffer[cursor]
            if prefix == UTF16Code.lowerX || prefix == UTF16Code.upperX {
                cursor += 1
                while cursor < count,
                    isHexDigit(buffer[cursor]) || buffer[cursor] == UTF16Code.underscore
                        || (style == .cDigitQuote && buffer[cursor] == UTF16Code.singleQuote
                            && cursor + 1 < count && isHexDigit(buffer[cursor + 1]))
                {
                    cursor += 1
                }
                return cursor
            }
            if prefix == UTF16Code.lowerB || prefix == UTF16Code.upperB
                || prefix == UTF16Code.lowerO || prefix == UTF16Code.upperO
            {
                cursor += 1
                while cursor < count,
                    isDigit(buffer[cursor]) || buffer[cursor] == UTF16Code.underscore
                        || (style == .cDigitQuote && buffer[cursor] == UTF16Code.singleQuote
                            && cursor + 1 < count && isDigit(buffer[cursor + 1]))
                {
                    cursor += 1
                }
                return cursor
            }
        }
        while cursor < count {
            let unit = buffer[cursor]
            if isDigit(unit) || unit == UTF16Code.underscore {
                cursor += 1
            } else if style == .cDigitQuote, unit == UTF16Code.singleQuote,
                cursor + 1 < count, isDigit(buffer[cursor + 1])
            {
                cursor += 1
            } else if unit == UTF16Code.dot, cursor + 1 < count, isDigit(buffer[cursor + 1]) {
                cursor += 1
            } else {
                break
            }
        }
        if cursor < count, buffer[cursor] == UTF16Code.lowerE || buffer[cursor] == UTF16Code.upperE {
            var exp = cursor + 1
            if exp < count, buffer[exp] == UTF16Code.plus || buffer[exp] == UTF16Code.minus { exp += 1 }
            if exp < count, isDigit(buffer[exp]) {
                cursor = exp + 1
                while cursor < count, isDigit(buffer[cursor]) || buffer[cursor] == UTF16Code.underscore {
                    cursor += 1
                }
            }
        }
        if style == .cssUnit, cursor < count {
            if buffer[cursor] == UTF16Code.percent {
                cursor += 1
            } else if isASCIILetter(buffer[cursor]) {
                var unitEnd = cursor + 1
                while unitEnd < count, isASCIILetter(buffer[unitEnd]) { unitEnd += 1 }
                let suffix = String(decoding: buffer[cursor..<unitEnd], as: UTF16.self).lowercased()
                if cssUnitSuffixes.contains(suffix) { cursor = unitEnd }
            }
        }
        return cursor
    }

    private static func scanCSSHexColor(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let count = buffer.count
        var pos = start + 1
        while pos < count, isHexDigit(buffer[pos]) { pos += 1 }
        let length = pos - (start + 1)
        guard length == 3 || length == 4 || length == 6 || length == 8 else { return nil }
        if pos < count, isASCIIIdentifier(buffer[pos]) || buffer[pos] == UTF16Code.minus { return nil }
        return pos
    }

    private static func classifyWord(
        _ buffer: UnsafeBufferPointer<UInt16>,
        start: Int,
        end: Int,
        isFirstOnLine: Bool,
        grammar: PreviewLanguageGrammar
    ) -> PreviewToken.Kind? {
        let features = grammar.features
        if features.contains(.keyBeforeColon), end < buffer.count, buffer[end] == UTF16Code.colon {
            if !features.contains(.yamlKeyColonRequiresSpace) || end + 1 == buffer.count
                || isSpaceOrLineBreak(buffer[end + 1])
            {
                return .keyword
            }
        }
        let length = end - start
        guard length >= grammar.minWordLength && length <= grammar.maxWordLength else { return nil }
        if features.contains(.dockerfileInstructions) {
            if isFirstOnLine || (length == 2 && matchesASCIIFolded(buffer, at: start, "as")),
                grammar.lookupWord(buffer, start: start, end: end) == .keyword
            {
                return .keyword
            }
            return nil
        }
        return grammar.lookupWord(buffer, start: start, end: end)
    }

    private static func tokenizeDiff(
        _ buffer: UnsafeBufferPointer<UInt16>, into result: inout [PreviewToken]
    ) throws {
        let count = buffer.count
        var cursor = 0
        var lineIndex = 0
        while cursor < count {
            lineIndex &+= 1
            if (lineIndex & (cancellationStride - 1)) == 0 { try Task.checkCancellation() }
            let end = lineEnd(buffer, from: cursor)
            if end > cursor {
                if let kind = diffLineKind(buffer, start: cursor, end: end) {
                    result.append(PreviewToken(range: NSRange(location: cursor, length: end - cursor), kind: kind))
                }
            }
            cursor = nextLineStart(buffer, after: end)
        }
    }

    private static func diffLineKind(
        _ buffer: UnsafeBufferPointer<UInt16>, start: Int, end: Int
    ) -> PreviewToken.Kind? {
        let first = buffer[start]
        if matchesASCII(buffer, at: start, end: end, "@@") { return .number }
        if matchesASCII(buffer, at: start, end: end, "+++ ")
            || matchesASCII(buffer, at: start, end: end, "+++\t")
            || matchesASCII(buffer, at: start, end: end, "--- ")
            || matchesASCII(buffer, at: start, end: end, "---\t")
            || (end - start == 3
                && (matchesASCII(buffer, at: start, end: end, "+++")
                    || matchesASCII(buffer, at: start, end: end, "---")))
            || matchesASCII(buffer, at: start, end: end, "diff ")
            || matchesASCII(buffer, at: start, end: end, "index ")
            || matchesASCII(buffer, at: start, end: end, "===")
            || matchesASCII(buffer, at: start, end: end, "new file mode ")
            || matchesASCII(buffer, at: start, end: end, "deleted file mode ")
            || matchesASCII(buffer, at: start, end: end, "old mode ")
            || matchesASCII(buffer, at: start, end: end, "new mode ")
            || matchesASCII(buffer, at: start, end: end, "rename from ")
            || matchesASCII(buffer, at: start, end: end, "rename to ")
            || matchesASCII(buffer, at: start, end: end, "similarity index ")
            || matchesASCII(buffer, at: start, end: end, "Binary files ")
            || matchesASCII(buffer, at: start, end: end, "\\ No newline")
        {
            return .keyword
        }
        if first == UTF16Code.plus { return .diffAdded }
        if first == UTF16Code.minus { return .diffRemoved }
        return nil
    }

    private static func tokenizeRestructuredText(
        _ buffer: UnsafeBufferPointer<UInt16>, into result: inout [PreviewToken]
    ) throws {
        let count = buffer.count
        var cursor = 0
        var lineIndex = 0
        var prevStart = 0
        var prevEnd = 0
        var prevHadText = false
        var prevWasAdornment = false
        var prevTokenBaseline = 0
        var pendingOverline: (Int, Int)?
        while cursor < count {
            lineIndex &+= 1
            if (lineIndex & (cancellationStride - 1)) == 0 { try Task.checkCancellation() }
            let end = lineEnd(buffer, from: cursor)
            if isRstAdornment(buffer, start: cursor, end: end) {
                if prevHadText && !prevWasAdornment {
                    result.removeSubrange(prevTokenBaseline..<result.count)
                    if let overline = pendingOverline {
                        result.append(
                            PreviewToken(
                                range: NSRange(location: overline.0, length: overline.1 - overline.0), kind: .keyword))
                    }
                    result.append(
                        PreviewToken(range: NSRange(location: prevStart, length: prevEnd - prevStart), kind: .keyword))
                    result.append(
                        PreviewToken(range: NSRange(location: cursor, length: end - cursor), kind: .keyword))
                    pendingOverline = nil
                } else {
                    pendingOverline = (cursor, end)
                }
                prevHadText = false
                prevWasAdornment = true
            } else {
                prevTokenBaseline = result.count
                let hasText = lineHasNonSpace(buffer, start: cursor, end: end)
                if hasText {
                    scanInlineBackticks(buffer, start: cursor, end: end, doubleFirst: true, into: &result)
                } else {
                    pendingOverline = nil
                }
                prevStart = cursor
                prevEnd = end
                prevHadText = hasText
                prevWasAdornment = false
            }
            cursor = nextLineStart(buffer, after: end)
        }
    }

    private static func tokenizeAsciiDoc(
        _ buffer: UnsafeBufferPointer<UInt16>, into result: inout [PreviewToken]
    ) throws {
        let count = buffer.count
        var cursor = 0
        var lineIndex = 0
        while cursor < count {
            lineIndex &+= 1
            if (lineIndex & (cancellationStride - 1)) == 0 { try Task.checkCancellation() }
            let end = lineEnd(buffer, from: cursor)
            if let fenceChar = asciiDocFenceChar(buffer, start: cursor, end: end) {
                let blockStart = cursor
                let blockLimit = min(count, blockStart + maximumBlockUnits)
                var blockLines = 0
                var scan = nextLineStart(buffer, after: end)
                var blockEnd = end
                while scan < blockLimit, blockLines < maximumBlockLines {
                    blockLines += 1
                    let scanEnd = lineEnd(buffer, from: scan)
                    blockEnd = scanEnd
                    let next = nextLineStart(buffer, after: scanEnd)
                    if asciiDocFenceChar(buffer, start: scan, end: scanEnd) == fenceChar {
                        scan = next
                        break
                    }
                    scan = next
                }
                result.append(
                    PreviewToken(range: NSRange(location: blockStart, length: blockEnd - blockStart), kind: .string))
                cursor = scan
                continue
            }
            if isAsciiDocHeading(buffer, start: cursor, end: end) {
                result.append(PreviewToken(range: NSRange(location: cursor, length: end - cursor), kind: .keyword))
            } else {
                scanInlineBackticks(buffer, start: cursor, end: end, doubleFirst: false, into: &result)
            }
            cursor = nextLineStart(buffer, after: end)
        }
    }

    private static func scanInlineBackticks(
        _ buffer: UnsafeBufferPointer<UInt16>,
        start: Int,
        end: Int,
        doubleFirst: Bool,
        into result: inout [PreviewToken]
    ) {
        var pos = start
        while pos < end {
            if buffer[pos] == UTF16Code.backtick {
                var delimLength = 1
                let maxDelim = doubleFirst ? 2 : 3
                while delimLength < maxDelim, pos + delimLength < end,
                    buffer[pos + delimLength] == UTF16Code.backtick
                {
                    delimLength += 1
                }
                var scan = pos + delimLength
                var closed: Int?
                while scan + delimLength <= end {
                    var matched = true
                    for offset in 0..<delimLength where buffer[scan + offset] != UTF16Code.backtick {
                        matched = false
                        break
                    }
                    if matched {
                        closed = scan + delimLength
                        break
                    }
                    scan += 1
                }
                if let closed, closed > pos + delimLength * 2 {
                    result.append(PreviewToken(range: NSRange(location: pos, length: closed - pos), kind: .string))
                    pos = closed
                    continue
                }
            }
            pos += 1
        }
    }

    private static func appendInvisibleTokens(
        _ buffer: UnsafeBufferPointer<UInt16>, into result: inout [PreviewToken]
    ) throws {
        let count = buffer.count
        var index = 0
        while index < count {
            if (index & (cancellationStride - 1)) == 0 { try Task.checkCancellation() }
            let unit = buffer[index]
            if unit < UTF16Code.space || unit >= UTF16Code.delete {
                if unit == UTF16Code.zeroWidthJoiner {
                    if !isEmojiZWJ(buffer, at: index) {
                        result.append(PreviewToken(range: NSRange(location: index, length: 1), kind: .invisible))
                    }
                } else if isInvisibleOrBidi(unit) {
                    result.append(PreviewToken(range: NSRange(location: index, length: 1), kind: .invisible))
                }
            }
            index += 1
        }
    }

    @inline(__always)
    private static func isInvisibleOrBidi(_ unit: UInt16) -> Bool {
        if unit < UTF16Code.space {
            return unit != UTF16Code.tab && unit != UTF16Code.lineFeed && unit != UTF16Code.carriageReturn
        }
        if unit <= UTF16Code.c1End { return true }
        switch unit {
        case UTF16Code.softHyphen, UTF16Code.arabicLetterMark,
            UTF16Code.zeroWidthSpace, UTF16Code.zeroWidthNonJoiner,
            UTF16Code.leftToRightMark, UTF16Code.rightToLeftMark,
            UTF16Code.lineSeparator, UTF16Code.paragraphSeparator,
            UTF16Code.bidiEmbedStart...UTF16Code.bidiOverrideEnd,
            UTF16Code.wordJoiner...UTF16Code.invisibleOperatorEnd,
            UTF16Code.bidiIsolateStart...UTF16Code.bidiIsolateEnd,
            UTF16Code.byteOrderMark:
            return true
        default:
            return false
        }
    }

    private static func isEmojiZWJ(_ buffer: UnsafeBufferPointer<UInt16>, at index: Int) -> Bool {
        guard let before = scalarBefore(buffer, index: index),
            let after = scalarAt(buffer, index: index + 1)
        else { return false }
        return isNonASCIIEmojiPart(before) && isNonASCIIEmojiPart(after)
    }

    private static func scalarBefore(_ buffer: UnsafeBufferPointer<UInt16>, index: Int) -> Unicode.Scalar? {
        guard index > 0 else { return nil }
        let unit = buffer[index - 1]
        if (UTF16Code.trailSurrogateStart...UTF16Code.trailSurrogateEnd).contains(unit), index >= 2 {
            let lead = buffer[index - 2]
            if (UTF16Code.leadSurrogateStart...UTF16Code.leadSurrogateEnd).contains(lead) {
                let value =
                    0x10000
                    + (UInt32(lead - UTF16Code.leadSurrogateStart) << 10)
                    + UInt32(unit - UTF16Code.trailSurrogateStart)
                return Unicode.Scalar(value)
            }
        }
        return Unicode.Scalar(unit)
    }

    private static func scalarAt(_ buffer: UnsafeBufferPointer<UInt16>, index: Int) -> Unicode.Scalar? {
        guard index < buffer.count else { return nil }
        let unit = buffer[index]
        if (UTF16Code.leadSurrogateStart...UTF16Code.leadSurrogateEnd).contains(unit), index + 1 < buffer.count {
            let trail = buffer[index + 1]
            if (UTF16Code.trailSurrogateStart...UTF16Code.trailSurrogateEnd).contains(trail) {
                let value =
                    0x10000
                    + (UInt32(unit - UTF16Code.leadSurrogateStart) << 10)
                    + UInt32(trail - UTF16Code.trailSurrogateStart)
                return Unicode.Scalar(value)
            }
        }
        return Unicode.Scalar(unit)
    }

    private static func isNonASCIIEmojiPart(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value > UInt32(UTF16Code.delete)
            && (scalar.properties.isEmoji
                || scalar.value == UTF16Code.variationSelector16
                || scalar.value == UTF16Code.combiningEnclosingKeycap)
    }

    private static func isRstAdornment(_ buffer: UnsafeBufferPointer<UInt16>, start: Int, end: Int) -> Bool {
        var trimmedEnd = end
        while trimmedEnd > start,
            buffer[trimmedEnd - 1] == UTF16Code.space || buffer[trimmedEnd - 1] == UTF16Code.tab
        {
            trimmedEnd -= 1
        }
        guard trimmedEnd - start >= minimumRstAdornmentLength else { return false }
        let marker = buffer[start]
        guard rstAdornments.contains(marker) else { return false }
        for index in (start + 1)..<trimmedEnd where buffer[index] != marker { return false }
        return true
    }

    private static func asciiDocFenceChar(_ buffer: UnsafeBufferPointer<UInt16>, start: Int, end: Int) -> UInt16? {
        var trimmedEnd = end
        while trimmedEnd > start,
            buffer[trimmedEnd - 1] == UTF16Code.space || buffer[trimmedEnd - 1] == UTF16Code.tab
        {
            trimmedEnd -= 1
        }
        guard trimmedEnd - start >= minimumAsciiDocFenceLength else { return nil }
        let marker = buffer[start]
        guard marker == UTF16Code.minus || marker == UTF16Code.dot else { return nil }
        for index in (start + 1)..<trimmedEnd where buffer[index] != marker { return nil }
        return marker
    }

    private static func isAsciiDocHeading(_ buffer: UnsafeBufferPointer<UInt16>, start: Int, end: Int) -> Bool {
        var pos = start
        while pos < end, pos - start < maximumAsciiDocHeadingLevel, buffer[pos] == UTF16Code.equals {
            pos += 1
        }
        return pos > start && pos < end && (buffer[pos] == UTF16Code.space || buffer[pos] == UTF16Code.tab)
    }

    private static func lineHasNonSpace(_ buffer: UnsafeBufferPointer<UInt16>, start: Int, end: Int) -> Bool {
        for index in start..<end where buffer[index] != UTF16Code.space && buffer[index] != UTF16Code.tab {
            return true
        }
        return false
    }

    @inline(__always)
    private static func lineEnd(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int {
        var pos = start
        let count = buffer.count
        while pos < count, buffer[pos] != UTF16Code.lineFeed, buffer[pos] != UTF16Code.carriageReturn {
            pos += 1
        }
        return pos
    }

    @inline(__always)
    private static func nextLineStart(_ buffer: UnsafeBufferPointer<UInt16>, after end: Int) -> Int {
        let count = buffer.count
        guard end < count else { return count }
        if buffer[end] == UTF16Code.carriageReturn, end + 1 < count, buffer[end + 1] == UTF16Code.lineFeed {
            return end + 2
        }
        return end + 1
    }

    @inline(__always)
    private static func matches(_ buffer: UnsafeBufferPointer<UInt16>, at index: Int, _ pattern: [UInt16]) -> Bool {
        let length = pattern.count
        guard index + length <= buffer.count else { return false }
        for offset in 0..<length where buffer[index + offset] != pattern[offset] { return false }
        return true
    }

    private static func matchesASCII(
        _ buffer: UnsafeBufferPointer<UInt16>, at start: Int, end: Int, _ literal: String
    ) -> Bool {
        let units = literal.utf8
        guard start + units.count <= end else { return false }
        var offset = 0
        for byte in units {
            if buffer[start + offset] != UInt16(byte) { return false }
            offset += 1
        }
        return true
    }

    private static func matchesASCIIFolded(
        _ buffer: UnsafeBufferPointer<UInt16>, at start: Int, _ lowerLiteral: String
    ) -> Bool {
        let units = lowerLiteral.utf8
        guard start + units.count <= buffer.count else { return false }
        var offset = 0
        for byte in units {
            var actual = buffer[start + offset]
            if (UTF16Code.upperA...UTF16Code.upperZ).contains(actual) { actual &+= UTF16Code.asciiCaseOffset }
            if actual != UInt16(byte) { return false }
            offset += 1
        }
        return true
    }

    private static func matchesBatchRem(_ buffer: UnsafeBufferPointer<UInt16>, at start: Int) -> Bool {
        guard matchesASCIIFolded(buffer, at: start, "rem") else { return false }
        let after = start + 3
        return after == buffer.count || isSpaceOrLineBreak(buffer[after])
    }

    @inline(__always)
    private static func isDigit(_ unit: UInt16) -> Bool {
        (UTF16Code.digitZero...UTF16Code.digitNine).contains(unit)
    }

    @inline(__always)
    private static func isHexDigit(_ unit: UInt16) -> Bool {
        isDigit(unit) || (UTF16Code.upperA...UTF16Code.upperF).contains(unit)
            || (UTF16Code.lowerA...UTF16Code.lowerF).contains(unit)
    }

    @inline(__always)
    private static func isASCIILetter(_ unit: UInt16) -> Bool {
        (UTF16Code.upperA...UTF16Code.upperZ).contains(unit) || (UTF16Code.lowerA...UTF16Code.lowerZ).contains(unit)
    }

    @inline(__always)
    private static func isASCIIIdentifier(_ unit: UInt16) -> Bool {
        isASCIILetter(unit) || isDigit(unit) || unit == UTF16Code.underscore
    }

    @inline(__always)
    private static func isPlainIdentifier(_ unit: UInt16) -> Bool {
        isASCIILetter(unit) || unit == UTF16Code.underscore || unit > UTF16Code.delete
    }

    @inline(__always)
    private static func isIdentifierStart(_ unit: UInt16, features: PreviewLanguageGrammar.Features) -> Bool {
        if isPlainIdentifier(unit) { return true }
        if unit == UTF16Code.dollar, features.contains(.allowDollarIdentifier) { return true }
        if unit == UTF16Code.atSign, features.contains(.allowAtIdentifier) { return true }
        return false
    }

    @inline(__always)
    private static func isIdentifierContinue(_ unit: UInt16, features: PreviewLanguageGrammar.Features) -> Bool {
        if isPlainIdentifier(unit) || isDigit(unit) { return true }
        if unit == UTF16Code.minus, features.contains(.allowHyphenIdentifier) { return true }
        return false
    }

    @inline(__always)
    private static func isMarkupNameChar(_ unit: UInt16) -> Bool {
        isPlainIdentifier(unit) || isDigit(unit) || unit == UTF16Code.minus || unit == UTF16Code.colon
    }

    @inline(__always)
    private static func isASCIIKeyStart(_ unit: UInt16) -> Bool {
        isASCIILetter(unit) || unit == UTF16Code.underscore
    }

    @inline(__always)
    private static func isASCIIKeyContinue(_ unit: UInt16) -> Bool {
        isASCIIIdentifier(unit) || unit == UTF16Code.dot || unit == UTF16Code.minus
    }

    @inline(__always)
    private static func isSpaceOrLineBreak(_ unit: UInt16) -> Bool {
        unit == UTF16Code.space || unit == UTF16Code.tab
            || unit == UTF16Code.lineFeed || unit == UTF16Code.carriageReturn
    }

    @inline(__always)
    private static func isPythonPrefixChar(_ unit: UInt16) -> Bool {
        switch unit {
        case UTF16Code.lowerR, UTF16Code.lowerF, UTF16Code.lowerB, UTF16Code.lowerU,
            UTF16Code.upperR, UTF16Code.upperF, UTF16Code.upperB, UTF16Code.upperU:
            true
        default:
            false
        }
    }
}
