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
        write(to: &output, indent: indent, level: 0)
        return output
    }

    /// Top level sorts only the outermost objects.
    func sortingKeys(recursive: Bool) -> JSONValue {
        switch self {
        case .object(let members):
            let sorted = members.sorted { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) }
            return .object(recursive ? sorted.map { ($0.key, $0.value.sortingKeys(recursive: true)) } : sorted)
        case .array(let elements):
            return .array(elements.map { $0.sortingKeys(recursive: recursive) })
        case .string, .number, .bool, .null:
            return self
        }
    }

    private func write(to output: inout String, indent: String?, level: Int) {
        switch self {
        case .object(let members):
            guard !members.isEmpty else {
                output += "{}"
                return
            }
            output += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { output += "," }
                Self.breakLine(&output, indent: indent, level: level + 1)
                output += Self.quoted(member.key) + (indent == nil ? ":" : ": ")
                member.value.write(to: &output, indent: indent, level: level + 1)
            }
            Self.breakLine(&output, indent: indent, level: level)
            output += "}"
        case .array(let elements):
            guard !elements.isEmpty else {
                output += "[]"
                return
            }
            output += "["
            for (index, element) in elements.enumerated() {
                if index > 0 { output += "," }
                Self.breakLine(&output, indent: indent, level: level + 1)
                element.write(to: &output, indent: indent, level: level + 1)
            }
            Self.breakLine(&output, indent: indent, level: level)
            output += "]"
        case .string(let text): output += Self.quoted(text)
        case .number(let literal): output += literal
        case .bool(let flag): output += flag ? "true" : "false"
        case .null: output += "null"
        }
    }

    private static func breakLine(_ output: inout String, indent: String?, level: Int) {
        guard let indent else { return }
        output += "\n" + String(repeating: indent, count: level)
    }

    private static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
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
        return result + "\""
    }
}

enum JSONFormatter {
    static func format(_ text: String, _ formatting: JSONFormatting, settings: TextSettings) throws -> String {
        let value = try JSONParser.parse(text)
        switch formatting {
        case .pretty: return value.serialized(indent: settings.jsonIndent.unit) + "\n"
        case .minify: return value.serialized(indent: nil)
        case .sortKeys:
            let sorted = value.sortingKeys(recursive: settings.keySortScope == .recursive)
            return sorted.serialized(indent: settings.jsonIndent.unit) + "\n"
        }
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
