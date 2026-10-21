import Darwin
import Foundation

typealias JSONMembers = [(key: String, value: JSONValue)]

/// `JSONSerialization` loses key order and literals.
enum JSONValue {
    case object([(key: String, value: JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    func serialized(indent: String?) -> String {
        var output = ""
        write(indent: indent, level: 0) { output += $0 }
        return output
    }

    func serialized(indent: String?, maximumBytes: Int) throws -> String {
        var output = ""
        var byteCount = 0
        try write(indent: indent, level: 0) { fragment in
            try Task.checkCancellation()
            let bytes = fragment.utf8.count
            guard bytes <= maximumBytes - byteCount else {
                throw EngineError.invalidInput(.malformed("JSON output exceeds \(maximumBytes) bytes"))
            }
            byteCount += bytes
            output += fragment
        }
        return output
    }

    func sortingKeys(settings: TextSettings, recursive: Bool) -> JSONValue {
        switch self {
        case .object(let members):
            let sorted = members.enumerated().sorted { left, right in
                let leftRank = Self.pinnedRank(left.element.key, in: settings.jsonPinnedKeys)
                let rightRank = Self.pinnedRank(right.element.key, in: settings.jsonPinnedKeys)
                if leftRank != rightRank { return leftRank < rightRank }
                let order = Self.keyOrder(left.element.key, right.element.key, comparison: settings.jsonKeyComparison)
                if order == .orderedSame { return left.offset < right.offset }
                return settings.jsonDescending ? order == .orderedDescending : order == .orderedAscending
            }.map(\.element)
            return .object(
                sorted.map { member in
                    (
                        member.key,
                        recursive ? member.value.sortingKeys(settings: settings, recursive: true) : member.value
                    )
                })
        case .array(let elements):
            let children = recursive ? elements.map { $0.sortingKeys(settings: settings, recursive: true) } : elements
            guard settings.jsonSortPrimitiveArrays, children.allSatisfy(\.isPrimitive) else { return .array(children) }
            let sorted = children.enumerated().map {
                (offset: $0.offset, value: $0.element, key: $0.element.serialized(indent: nil))
            }
            .sorted { left, right in
                let order = Self.ordinalOrder(left.key, right.key)
                if order == .orderedSame { return left.offset < right.offset }
                return settings.jsonDescending ? order == .orderedDescending : order == .orderedAscending
            }.map(\.value)
            return .array(sorted)
        case .string, .number, .bool, .null:
            return self
        }
    }

    private var isPrimitive: Bool {
        switch self {
        case .string, .number, .bool, .null: true
        case .object, .array: false
        }
    }

    private static let comparisonLocale = Locale(identifier: "en_US_POSIX")

    private static func pinnedRank(_ key: String, in pinnedKeys: [String]) -> Int {
        let foldedKey = caseFolded(key)
        return pinnedKeys.firstIndex {
            ordinalOrder(foldedKey, caseFolded($0)) == .orderedSame
        } ?? pinnedKeys.count
    }

    private static func keyOrder(_ left: String, _ right: String, comparison: JSONKeyComparison) -> ComparisonResult {
        let primary: ComparisonResult
        switch comparison {
        case .ordinal: return ordinalOrder(left, right)
        case .caseInsensitive:
            primary = ordinalOrder(caseFolded(left), caseFolded(right))
        case .natural:
            primary = caseFolded(left).compare(
                caseFolded(right), options: [.literal, .numeric], locale: comparisonLocale)
        }
        return primary == .orderedSame ? ordinalOrder(left, right) : primary
    }

    private static func caseFolded(_ key: String) -> String {
        key.folding(options: .caseInsensitive, locale: comparisonLocale)
    }

    private static func ordinalOrder(_ left: String, _ right: String) -> ComparisonResult {
        if left.unicodeScalars.lexicographicallyPrecedes(right.unicodeScalars) { return .orderedAscending }
        if right.unicodeScalars.lexicographicallyPrecedes(left.unicodeScalars) { return .orderedDescending }
        return .orderedSame
    }

    fileprivate func write(indent: String?, level: Int, append: (String) throws -> Void) rethrows {
        switch self {
        case .object(let members):
            guard !members.isEmpty else {
                try append("{}")
                return
            }
            try append("{")
            for (index, member) in members.enumerated() {
                if index > 0 { try append(",") }
                try Self.breakLine(indent: indent, level: level + 1, append: append)
                try Self.writeQuoted(member.key, append: append)
                try append(indent == nil ? ":" : ": ")
                try member.value.write(indent: indent, level: level + 1, append: append)
            }
            try Self.breakLine(indent: indent, level: level, append: append)
            try append("}")
        case .array(let elements):
            guard !elements.isEmpty else {
                try append("[]")
                return
            }
            try append("[")
            for (index, element) in elements.enumerated() {
                if index > 0 { try append(",") }
                try Self.breakLine(indent: indent, level: level + 1, append: append)
                try element.write(indent: indent, level: level + 1, append: append)
            }
            try Self.breakLine(indent: indent, level: level, append: append)
            try append("]")
        case .string(let text): try Self.writeQuoted(text, append: append)
        case .number(let literal): try append(literal)
        case .bool(let flag): try append(flag ? "true" : "false")
        case .null: try append("null")
        }
    }

    private static func breakLine(indent: String?, level: Int, append: (String) throws -> Void) rethrows {
        guard let indent else { return }
        try append("\n" + String(repeating: indent, count: level))
    }

    private static func writeQuoted(_ text: String, append: (String) throws -> Void) rethrows {
        let chunkScalars = 1024
        var result = "\""
        for (index, scalar) in text.unicodeScalars.enumerated() {
            if index.isMultiple(of: chunkScalars) {
                try append(result)
                result.removeAll(keepingCapacity: true)
            }
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                result += "\\u" + String(repeating: "0", count: JSONParser.hexQuadLength - hex.count) + hex
            default: result.unicodeScalars.append(scalar)
            }
        }
        try append(result + "\"")
    }
}

enum JSONFormatter {
    private static let outputChunkBytes = 64 * 1024

    static func write(_ text: String, _ formatting: JSONFormatting, settings: TextSettings, to destination: URL) throws
    {
        let value = try JSONParser.parse(text)
        let output =
            formatting == .sortKeys
            ? value.sortingKeys(settings: settings, recursive: settings.keySortScope == .recursive) : value
        let indentation = formatting == .minify ? nil : settings.jsonIndent.unit
        try Task.checkCancellation()

        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var buffer = Data()
        buffer.reserveCapacity(outputChunkBytes)
        try output.write(indent: indentation, level: 0) { fragment in
            var utf8Fragment = fragment
            try utf8Fragment.withUTF8 { bytes in
                var offset = 0
                while offset < bytes.count {
                    try Task.checkCancellation()
                    let count = min(outputChunkBytes - buffer.count, bytes.count - offset)
                    buffer.append(contentsOf: bytes[offset..<(offset + count)])
                    offset += count
                    if buffer.count == outputChunkBytes {
                        try file.write(contentsOf: buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
            }
        }
        if formatting != .minify { buffer.append(UInt8(ascii: "\n")) }
        try Task.checkCancellation()
        if !buffer.isEmpty { try file.write(contentsOf: buffer) }
        try file.close()

    }
}

extension JSONIndent {
    var unit: String {
        switch self {
        case .two: "  "
        case .four: "    "
        case .tab: "\t"
        }
    }
}

struct JSONParser {
    private static let maximumDepth = 512
    private static let surrogateBits: UInt32 = 10
    private static let highSurrogates: ClosedRange<UInt32> = 0xD800...0xDBFF
    private static let lowSurrogates: ClosedRange<UInt32> = 0xDC00...0xDFFF
    private static let supplementaryBase: UInt32 = 0x10000
    static let hexQuadLength = 4
    private static let hexDigitBits: UInt32 = 4
    private static let firstPrintable: UInt8 = 0x20
    private static let lineFeed = UInt8(ascii: "\n")
    private static let continuationMask: UInt8 = 0xC0
    private static let continuationTag: UInt8 = 0x80
    private static let whitespace: Set<UInt8> = [
        UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"),
    ]
    private static let simpleEscapes: [UInt8: UInt8] = [
        UInt8(ascii: "\""): UInt8(ascii: "\""), UInt8(ascii: "\\"): UInt8(ascii: "\\"),
        UInt8(ascii: "/"): UInt8(ascii: "/"),
        UInt8(ascii: "b"): 0x08, UInt8(ascii: "f"): 0x0C, UInt8(ascii: "n"): UInt8(ascii: "\n"),
        UInt8(ascii: "r"): UInt8(ascii: "\r"),
        UInt8(ascii: "t"): UInt8(ascii: "\t"),
    ]

    private let bytes: [UInt8]
    private var position = 0

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    static func parse(_ text: String) throws -> JSONValue {
        var parser = JSONParser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.position == parser.bytes.count else { throw parser.syntaxError() }
        return value
    }

    static func isNumber(_ text: String) -> Bool {
        var parser = JSONParser(bytes: Array(text.utf8))
        do {
            _ = try parser.number()
        } catch {
            return false
        }
        return parser.position == parser.bytes.count
    }

    private var current: UInt8? { position < bytes.count ? bytes[position] : nil }

    private mutating func value(depth: Int) throws -> JSONValue {
        guard depth < Self.maximumDepth else {
            throw EngineError.invalidInput(.malformed("JSON nests deeper than \(Self.maximumDepth) levels"))
        }
        switch current {
        case UInt8(ascii: "{"): return try object(depth: depth)
        case UInt8(ascii: "["): return try array(depth: depth)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): return try literal("true", .bool(true))
        case UInt8(ascii: "f"): return try literal("false", .bool(false))
        case UInt8(ascii: "n"): return try literal("null", .null)
        default: return .number(try number())
        }
    }

    private mutating func object(depth: Int) throws -> JSONValue {
        position += 1
        skipWhitespace()
        var members: JSONMembers = []
        if current == UInt8(ascii: "}") {
            position += 1
            return .object(members)
        }
        while true {
            guard current == UInt8(ascii: "\"") else { throw syntaxError() }
            let key = try string()
            skipWhitespace()
            try expect(UInt8(ascii: ":"))
            skipWhitespace()
            members.append((key, try value(depth: depth + 1)))
            skipWhitespace()
            guard current == UInt8(ascii: ",") else { break }
            position += 1
            skipWhitespace()
        }
        try expect(UInt8(ascii: "}"))
        return .object(members)
    }

    private mutating func array(depth: Int) throws -> JSONValue {
        position += 1
        skipWhitespace()
        var elements: [JSONValue] = []
        if current == UInt8(ascii: "]") {
            position += 1
            return .array(elements)
        }
        while true {
            elements.append(try value(depth: depth + 1))
            skipWhitespace()
            guard current == UInt8(ascii: ",") else { break }
            position += 1
            skipWhitespace()
        }
        try expect(UInt8(ascii: "]"))
        return .array(elements)
    }

    private mutating func string() throws -> String {
        position += 1
        var buffer: [UInt8] = []
        while let byte = current {
            switch byte {
            case UInt8(ascii: "\""):
                position += 1
                return String(decoding: buffer, as: UTF8.self)
            case UInt8(ascii: "\\"):
                position += 1
                buffer += try escape()
            case _ where byte < Self.firstPrintable:
                throw syntaxError()
            default:
                buffer.append(byte)
                position += 1
            }
        }
        throw syntaxError()
    }

    private mutating func escape() throws -> [UInt8] {
        guard let byte = current else { throw syntaxError() }
        if let replacement = Self.simpleEscapes[byte] {
            position += 1
            return [replacement]
        }
        guard byte == UInt8(ascii: "u") else { throw syntaxError() }
        position += 1
        var code = try hexQuad()
        if Self.highSurrogates.contains(code) {
            guard current == UInt8(ascii: "\\") else { throw syntaxError() }
            position += 1
            guard current == UInt8(ascii: "u") else { throw syntaxError() }
            position += 1
            let low = try hexQuad()
            guard Self.lowSurrogates.contains(low) else { throw syntaxError() }
            code =
                Self.supplementaryBase + ((code - Self.highSurrogates.lowerBound) << Self.surrogateBits)
                + (low - Self.lowSurrogates.lowerBound)
        }
        guard let scalar = Unicode.Scalar(code) else { throw syntaxError() }
        return Array(String(scalar).utf8)
    }

    private mutating func hexQuad() throws -> UInt32 {
        var code: UInt32 = 0
        for _ in 0..<Self.hexQuadLength {
            guard let byte = current, let digit = Character(Unicode.Scalar(byte)).hexDigitValue else {
                throw syntaxError()
            }
            code = code << Self.hexDigitBits | UInt32(digit)
            position += 1
        }
        return code
    }

    private mutating func number() throws -> String {
        let start = position
        if current == UInt8(ascii: "-") { position += 1 }
        if current == UInt8(ascii: "0") {
            position += 1
        } else {
            try digits()
        }
        if current == UInt8(ascii: ".") {
            position += 1
            try digits()
        }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            position += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { position += 1 }
            try digits()
        }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    private mutating func digits() throws {
        let start = position
        while let byte = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { position += 1 }
        guard position > start else { throw syntaxError() }
    }

    private mutating func literal(_ word: String, _ value: JSONValue) throws -> JSONValue {
        for expected in word.utf8 {
            guard current == expected else { throw syntaxError() }
            position += 1
        }
        return value
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard current == byte else { throw syntaxError() }
        position += 1
    }

    private mutating func skipWhitespace() {
        while let byte = current, Self.whitespace.contains(byte) { position += 1 }
    }

    /// Columns count Unicode scalars, as editors do.
    private func syntaxError() -> EngineError {
        var line = 1
        var column = 1
        for byte in bytes[..<min(position, bytes.count)] {
            if byte == Self.lineFeed {
                line += 1
                column = 1
            } else if byte & Self.continuationMask != Self.continuationTag {
                column += 1
            }
        }
        return EngineError.invalidInput(.jsonSyntax(line: line, column: column))
    }
}
