import CoreFoundation
import Engine
import Foundation

enum PreviewEncoding: String, CaseIterable, Sendable {
    case automatic, utf8, utf16, utf16LE, utf16BE, shiftJIS, eucJP, iso2022JP, windows1252, latin1

    var title: String {
        switch self {
        case .automatic: String(localized: "Detect Encoding")
        case .utf8: String(localized: "UTF-8")
        case .utf16: String(localized: "UTF-16")
        case .utf16LE: String(localized: "UTF-16 LE")
        case .utf16BE: String(localized: "UTF-16 BE")
        case .shiftJIS: String(localized: "Shift_JIS")
        case .eucJP: String(localized: "EUC-JP")
        case .iso2022JP: String(localized: "ISO-2022-JP")
        case .windows1252: String(localized: "Windows-1252")
        case .latin1: String(localized: "ISO-8859-1")
        }
    }

    func decode(_ bytes: Data) throws -> String {
        if self == .automatic { return try TextEncoding.detectedString(from: bytes) }
        let encoding = foundation
        guard let text = String(data: bytes, encoding: encoding) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    var foundation: String.Encoding {
        switch self {
        case .automatic, .utf8: return .utf8
        case .utf16: return .utf16
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .shiftJIS:
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
        case .eucJP: return .japaneseEUC
        case .iso2022JP: return .iso2022JP
        case .windows1252: return .windowsCP1252
        case .latin1: return .isoLatin1
        }
    }

}

struct PreviewTextSource: Sendable {
    static let maximumBytes = 4 * 1024 * 1024
    static let excerptBytes = 256 * 1024
    static let highlightBytes = 512 * 1024
    let bytes: Data
    let truncated: Bool
    var stamp: FileStamp? = nil

    var binaryPropertyList: Bool { bytes.starts(with: "bplist".utf8) }

    static func read(_ url: URL) throws -> Self {
        var result: Result<Self, Error>?
        var failure: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &failure) { target in
            result = Result { try readCoordinated(target) }
        }
        if let failure { throw failure }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private static func readCoordinated(_ url: URL) throws -> Self {
        let stamp = try FileStamp(of: url)
        let file = try FileHandle(forReadingFrom: url)
        do {
            let size = try file.seekToEnd()
            try file.seek(toOffset: 0)
            let truncated = size > maximumBytes
            let limit = truncated ? excerptBytes : maximumBytes
            var bytes = Data()
            while bytes.count < limit {
                try Task.checkCancellation()
                guard let chunk = try file.read(upToCount: min(64 * 1024, limit - bytes.count)), !chunk.isEmpty else {
                    break
                }
                bytes.append(chunk)
            }
            try Task.checkCancellation()
            guard try FileStamp(of: url) == stamp else { throw EngineError.retryInputChanged }
            try file.close()
            return Self(bytes: bytes, truncated: truncated, stamp: stamp)
        } catch {
            try file.close()
            throw error
        }
    }

    func decoded(as encoding: PreviewEncoding) throws -> String {
        guard truncated else { return try encoding.decode(bytes) }
        let selected: PreviewEncoding
        if encoding == .automatic || encoding == .utf16 {
            if bytes.starts(with: [0xFF, 0xFE]) {
                selected = .utf16LE
            } else if bytes.starts(with: [0xFE, 0xFF]) {
                selected = .utf16BE
            } else {
                selected = encoding == .automatic ? .utf8 : .utf16BE
            }
        } else {
            selected = encoding
        }
        if [.shiftJIS, .eucJP, .iso2022JP].contains(selected) {
            do { return try selected.decode(bytes) } catch {
                return try selected.decode(bytes.dropLast(incompleteSuffixLength(encoding: selected)))
            }
        }
        let omitted = incompleteSuffixLength(encoding: selected)
        if omitted > 0 {
            let prefix = bytes.dropLast(omitted)
            if encoding == .automatic && selected == .utf8 && String(data: prefix, encoding: .utf8) == nil {
                return try encoding.decode(bytes)
            }
            return try selected.decode(prefix)
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
        case .automatic, .utf16, .windows1252, .latin1: return 0
        }
    }

}

enum PreviewLanguage: Sendable {
    case plain, swift, javascript, python, c, json, markup, css, shell, yaml, markdown

    static func resolve(_ suffix: String) -> Self {
        switch suffix.lowercased() {
        case "swift": .swift
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": .javascript
        case "py", "pyw": .python
        case "c", "h", "cpp", "hpp", "cc", "m", "mm", "java", "cs": .c
        case "json": .json
        case "html", "htm", "xml", "plist", "svg": .markup
        case "css", "scss": .css
        case "sh", "bash", "zsh", "fish": .shell
        case "yaml", "yml", "toml": .yaml
        case "md", "markdown": .markdown
        default: .plain
        }
    }

    var keywords: Set<String> {
        let words: String
        switch self {
        case .swift:
            words =
                "actor as async await break case catch class continue default defer do else enum extension false fileprivate for func guard if import in init inout internal is let nil nonisolated open private protocol public repeat rethrows return self static struct super switch throw throws true try typealias var weak where while"
        case .javascript:
            words =
                "async await break case catch class const continue debugger default delete do else export extends false finally for from function if import in instanceof interface let new null of return static super switch this throw true try typeof undefined var void while yield type"
        case .python:
            words =
                "and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield"
        case .c:
            words =
                "auto bool break case catch char class const continue default delete do double else enum extern false float for if import int long namespace new null nullptr private protected public return short signed sizeof static struct super switch template this throw true try typedef union unsigned using virtual void volatile while"
        case .json: words = "true false null"
        case .shell:
            words = "if then else elif fi for while do done case esac function in select until export local return"
        case .yaml: words = "true false null yes no on off"
        case .css: words = "important inherit initial unset none auto var calc media supports keyframes"
        case .plain, .markup, .markdown: words = ""
        }
        return Set(words.split(separator: " ").map(String.init))
    }
}

struct PreviewToken: Equatable, Sendable {
    enum Kind: Sendable { case keyword, string, comment, number }
    let range: NSRange
    let kind: Kind
}

enum PreviewTokenizer {
    static func tokens(_ text: String, language: PreviewLanguage) throws -> [PreviewToken] {
        guard language != .plain else { return [] }
        let prefix = String(decoding: text.utf8.prefix(PreviewTextSource.highlightBytes), as: UTF8.self)
        let units = Array(prefix.utf16)
        let keywords = language.keywords
        var cursor = 0
        var result: [PreviewToken] = []
        func matches(_ literal: String) -> Bool {
            units[cursor...].starts(with: literal.utf16)
        }
        func lineEnd() -> Int {
            var end = cursor
            while end < units.count, units[end] != 10, units[end] != 13 { end += 1 }
            return end
        }
        while cursor < units.count {
            try Task.checkCancellation()
            let start = cursor
            let unit = units[cursor]
            var kind: PreviewToken.Kind?
            if [.markup, .markdown].contains(language) && matches("<!--") {
                cursor += 4
                while cursor < units.count, !matches("-->") { cursor += 1 }
                cursor = min(units.count, cursor + 3)
                kind = .comment
            } else if [.swift, .javascript, .c, .css].contains(language) && matches("/*") {
                cursor += 2
                var depth = 1
                while cursor < units.count, depth > 0 {
                    if matches("*/") {
                        depth -= 1; cursor += 2
                    } else if language == .swift && matches("/*") {
                        depth += 1; cursor += 2
                    } else {
                        cursor += 1
                    }
                }
                kind = .comment
            } else if ([.swift, .javascript, .c].contains(language) && matches("//"))
                || ([.python, .shell, .yaml].contains(language) && unit == 35)
            {
                cursor = lineEnd()
                kind = .comment
            } else if unit == 34 || unit == 39 || (unit == 96 && [.javascript, .shell, .markdown].contains(language)) {
                let triple =
                    (language == .python || language == .swift || language == .markdown)
                    && cursor + 2 < units.count && units[cursor + 1] == unit && units[cursor + 2] == unit
                let delimiter = triple ? 3 : 1
                cursor += delimiter
                while cursor < units.count {
                    if units[cursor] == 92 { cursor = min(units.count, cursor + 2); continue }
                    if units[cursor] == unit,
                        !triple || (cursor + 2 < units.count && units[cursor + 1] == unit && units[cursor + 2] == unit)
                    {
                        cursor += delimiter; break
                    }
                    cursor += 1
                }
                kind = .string
            } else if language == .markdown && unit == 35 && (cursor == 0 || units[cursor - 1] == 10) {
                cursor = lineEnd()
                kind = .keyword
            } else if language == .markup && unit == 60 {
                cursor += 1
                if cursor < units.count, units[cursor] == 47 { cursor += 1 }
                while cursor < units.count, identifier(units[cursor]) { cursor += 1 }
                kind = .keyword
            } else if (48...57).contains(unit) {
                cursor += 1
                while cursor < units.count,
                    (48...57).contains(units[cursor]) || [46, 95].contains(units[cursor])
                { cursor += 1 }
                kind = .number
            } else if identifier(unit) {
                cursor += 1
                while cursor < units.count, identifier(units[cursor]) || (48...57).contains(units[cursor]) {
                    cursor += 1
                }
                let word = String(decoding: units[start..<cursor], as: UTF16.self)
                if keywords.contains(word) { kind = .keyword }
                if [.yaml, .css].contains(language), cursor < units.count, units[cursor] == 58 { kind = .keyword }
            } else {
                cursor += 1
            }
            if let kind {
                result.append(PreviewToken(range: NSRange(location: start, length: cursor - start), kind: kind))
            }
        }
        return result
    }

    private static func identifier(_ unit: UInt16) -> Bool {
        (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit > 127
    }
}
