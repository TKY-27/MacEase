import Foundation

enum JSONToken: UInt64 {
    case object, array, string, number, booleanTrue, booleanFalse, null, key

    var primitive: Bool { self != .object && self != .array }
}

enum JSONEvent {
    case begin(JSONToken)
    case bytes([UInt8])
    case end(JSONToken)
}

enum JSONParser {
    static let hexQuadLength = 4

    static func parse(_ text: String) throws -> JSONValue {
        let builder = JSONTreeBuilder()
        let scanner = JSONScanner(bytes: Array(text.utf8), emit: builder.accept)
        try scanner.parse()
        guard let result = builder.result else {
            throw EngineError.invalidInput(.jsonSyntax(line: 1, column: 1))
        }
        return result
    }

    static func isNumber(_ text: String) -> Bool {
        let scanner = JSONScanner(bytes: Array(text.utf8)) { _ in }
        do {
            try scanner.number()
            return try scanner.current() == nil
        } catch {
            return false
        }
    }
}

private final class JSONTreeBuilder {
    private struct Frame {
        var members: JSONMembers = []
        var elements: [JSONValue] = []
        var key = ""
        let kind: JSONToken
    }

    private var frames: [Frame] = []
    private var tokenBytes: [UInt8] = []
    var result: JSONValue?

    func accept(_ event: JSONEvent) {
        switch event {
        case .begin(let kind):
            if kind.primitive { tokenBytes.removeAll(keepingCapacity: true) } else { frames.append(Frame(kind: kind)) }
        case .bytes(let bytes): tokenBytes.append(contentsOf: bytes)
        case .end(let kind):
            let value: JSONValue
            switch kind {
            case .object: value = .object(frames.removeLast().members)
            case .array: value = .array(frames.removeLast().elements)
            case .key:
                frames[frames.count - 1].key = String(decoding: tokenBytes, as: UTF8.self)
                return
            case .string: value = .string(String(decoding: tokenBytes, as: UTF8.self))
            case .number: value = .number(String(decoding: tokenBytes, as: UTF8.self))
            case .booleanTrue: value = .bool(true)
            case .booleanFalse: value = .bool(false)
            case .null: value = .null
            }
            if frames.isEmpty {
                result = value
            } else if frames[frames.count - 1].kind == .object {
                let key = frames[frames.count - 1].key
                frames[frames.count - 1].members.append((key, value))
            } else {
                frames[frames.count - 1].elements.append(value)
            }
        }
    }
}

final class JSONScanner {
    private static let maximumDepth = 512
    private static let tokenChunk = 64 * 1024
    private let file: FileHandle?
    private var buffer: [UInt8]
    private var position = 0
    private var line = 1
    private var column = 1
    private var tokenBytes: [UInt8] = []
    private let emit: (JSONEvent) throws -> Void

    init(bytes: [UInt8], emit: @escaping (JSONEvent) throws -> Void) {
        file = nil
        buffer = bytes
        self.emit = emit
    }

    init(url: URL, emit: @escaping (JSONEvent) throws -> Void) throws {
        file = try FileHandle(forReadingFrom: url)
        buffer = []
        self.emit = emit
    }

    private enum Phase {
        case first, child, separator
    }

    private struct Frame {
        let kind: JSONToken
        var phase = Phase.first
        var closing: UInt8 { kind == .object ? 125 : 93 }
    }

    func parse() throws {
        try skipWhitespace()
        var frames: [Frame] = []
        if let kind = try value(depth: 0) { frames.append(Frame(kind: kind)) }
        while let frame = frames.last {
            let index = frames.count - 1
            switch frame.phase {
            case .first:
                if try current() == frame.closing {
                    advance()
                    try emit(.end(frame.kind))
                    frames.removeLast()
                } else {
                    frames[index].phase = .child
                }
            case .child:
                if frame.kind == .object {
                    guard try current() == 34 else { throw syntaxError() }
                    try string(.key)
                    try skipWhitespace()
                    try expect(58)
                    try skipWhitespace()
                }
                frames[index].phase = .separator
                if let kind = try value(depth: frames.count) { frames.append(Frame(kind: kind)) }
            case .separator:
                try skipWhitespace()
                if try current() == 44 {
                    advance()
                    try skipWhitespace()
                    frames[index].phase = .child
                } else {
                    try expect(frame.closing)
                    try emit(.end(frame.kind))
                    frames.removeLast()
                }
            }
        }
        try skipWhitespace()
        guard try current() == nil else { throw syntaxError() }
        try file?.close()
    }

    func current() throws -> UInt8? {
        if position == buffer.count, let file {
            try Task.checkCancellation()
            buffer = Array(try file.readChunk(upToCount: Self.tokenChunk) ?? Data())
            position = 0
        }
        return position < buffer.count ? buffer[position] : nil
    }

    private func advance() {
        let byte = buffer[position]
        position += 1
        if byte == 10 { line += 1; column = 1 } else if byte & 0xC0 != 0x80 { column += 1 }
    }

    private func append(_ byte: UInt8) throws {
        tokenBytes.append(byte)
        if tokenBytes.count == Self.tokenChunk { try flush() }
    }

    private func flush() throws {
        try Task.checkCancellation()
        if !tokenBytes.isEmpty {
            try emit(.bytes(tokenBytes))
            tokenBytes.removeAll(keepingCapacity: true)
        }
    }

    private func value(depth: Int) throws -> JSONToken? {
        guard depth < Self.maximumDepth else {
            throw EngineError.invalidInput(.malformed("JSON nests deeper than \(Self.maximumDepth) levels"))
        }
        switch try current() {
        case 123: return try container(.object)
        case 91: return try container(.array)
        case 34: try string(.string)
        case 116: try literal("true", kind: .booleanTrue)
        case 102: try literal("false", kind: .booleanFalse)
        case 110: try literal("null", kind: .null)
        default: try number()
        }
        return nil
    }

    private func container(_ kind: JSONToken) throws -> JSONToken {
        try Task.checkCancellation()
        try emit(.begin(kind))
        advance()
        try skipWhitespace()
        return kind
    }

    private func string(_ kind: JSONToken) throws {
        try emit(.begin(kind))
        advance()
        while let byte = try current() {
            switch byte {
            case 34:
                advance()
                try flush()
                try emit(.end(kind))
                return
            case 92:
                advance()
                try escape()
            case 0..<32: throw syntaxError()
            default:
                try append(byte)
                advance()
            }
        }
        throw syntaxError()
    }

    private func escape() throws {
        guard let byte = try current() else { throw syntaxError() }
        let replacement: UInt8?
        switch byte {
        case 34, 92, 47: replacement = byte
        case 98: replacement = 8
        case 102: replacement = 12
        case 110: replacement = 10
        case 114: replacement = 13
        case 116: replacement = 9
        default: replacement = nil
        }
        if let replacement {
            advance()
            try append(replacement)
            return
        }
        try expect(117)
        var code = try hexQuad()
        if (0xD800...0xDBFF).contains(code) {
            try expect(92)
            try expect(117)
            let low = try hexQuad()
            guard (0xDC00...0xDFFF).contains(low) else { throw syntaxError() }
            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
        }
        guard let scalar = Unicode.Scalar(code) else { throw syntaxError() }
        for byte in String(scalar).utf8 { try append(byte) }
    }

    private func hexQuad() throws -> UInt32 {
        var code: UInt32 = 0
        for _ in 0..<JSONParser.hexQuadLength {
            guard let byte = try current(), let digit = Character(Unicode.Scalar(byte)).hexDigitValue else {
                throw syntaxError()
            }
            code = code << 4 | UInt32(digit)
            advance()
        }
        return code
    }

    func number() throws {
        try emit(.begin(.number))
        if try current() == 45 { try copyCurrent() }
        if try current() == 48 { try copyCurrent() } else { try digits() }
        if try current() == 46 {
            try copyCurrent()
            try digits()
        }
        if try current() == 101 || current() == 69 {
            try copyCurrent()
            if try current() == 43 || current() == 45 { try copyCurrent() }
            try digits()
        }
        try flush()
        try emit(.end(.number))
    }

    private func copyCurrent() throws {
        guard let byte = try current() else { throw syntaxError() }
        try append(byte)
        advance()
    }

    private func digits() throws {
        var found = false
        while let byte = try current(), (48...57).contains(byte) {
            found = true
            try append(byte)
            advance()
        }
        guard found else { throw syntaxError() }
    }

    private func literal(_ word: String, kind: JSONToken) throws {
        try emit(.begin(kind))
        for expected in word.utf8 {
            try expect(expected)
            try append(expected)
        }
        try flush()
        try emit(.end(kind))
    }

    private func expect(_ byte: UInt8) throws {
        guard try current() == byte else { throw syntaxError() }
        advance()
    }

    private func skipWhitespace() throws {
        while let byte = try current(), byte == 32 || byte == 9 || byte == 10 || byte == 13 { advance() }
    }

    private func syntaxError() -> EngineError {
        EngineError.invalidInput(.jsonSyntax(line: line, column: column))
    }
}
