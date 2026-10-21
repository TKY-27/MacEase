import CoreFoundation
import Foundation
import TOMLBridge

enum TOMLConversion {
    static let maximumBytes = 1024 * 1024
    private static let minutesPerHour = 60
    private static let fractionDigits = 9
    private static let nulSpellings = ["\u{0}", "\\u0000", "\\U00000000"]

    static func json(fromTOML text: String) throws -> JSONValue {
        guard text.utf8.count <= maximumBytes else {
            throw EngineError.invalidInput(.tooLarge(limitBytes: Int64(maximumBytes)))
        }
        guard !nulSpellings.contains(where: text.contains) else { throw failure("TOML NUL characters are unsupported") }
        var parseError = MCTomlParseError()
        let document = text.withCString { mc_toml_parse($0, text.utf8.count, &parseError) }
        guard let document else {
            defer { mc_toml_free_bytes(parseError.message) }
            let message =
                parseError.message.bytes.map {
                    String(decoding: UnsafeRawBufferPointer(start: $0, count: parseError.message.length), as: UTF8.self)
                } ?? "TOML parser failed"
            if parseError.line > 0 {
                throw failure("TOML syntax error at line \(parseError.line): \(message)")
            }
            throw failure("TOML parsing error: \(message)")
        }
        defer { mc_toml_destroy(document) }
        guard let root = mc_toml_root(document) else { throw failure("TOML root is unavailable") }
        var nodes = 0
        return try json(root, path: "$", depth: 0, nodes: &nodes)
    }

    static func toml(fromJSON text: String) throws -> String {
        guard text.utf8.count <= maximumBytes else {
            throw EngineError.invalidInput(.tooLarge(limitBytes: Int64(maximumBytes)))
        }
        try PropertyListConversion.guardJSONDepth(Data(text.utf8))
        let value = try JSONParser.parse(text)
        guard case .object = value else { throw failure("TOML requires a JSON object at the root") }
        guard let document = mc_toml_create() else { throw failure("TOML table could not be created") }
        defer { mc_toml_destroy(document) }
        guard let root = mc_toml_root(document) else { throw failure("TOML root is unavailable") }
        var nodes = 0
        try fill(root, from: value, path: "$", depth: 0, nodes: &nodes)
        var rendered = MCTomlOwnedBytes()
        guard mc_toml_render(document, &rendered) else { throw failure("TOML output could not be created") }
        defer { mc_toml_free_bytes(rendered) }
        guard rendered.length <= ConversionInput.maximumBytes else {
            throw EngineError.invalidInput(.tooLarge(limitBytes: Int64(ConversionInput.maximumBytes)))
        }
        guard let outputBytes = rendered.bytes else { throw failure("TOML output is unavailable") }
        let output = String(decoding: UnsafeRawBufferPointer(start: outputBytes, count: rendered.length), as: UTF8.self)
        guard try json(fromTOML: output).serialized(indent: nil) == canonical(value).serialized(indent: nil) else {
            throw failure("TOML cannot preserve the supplied values")
        }
        return output
    }

    private static func json(_ node: OpaquePointer, path: String, depth: Int, nodes: inout Int) throws -> JSONValue {
        try PropertyListConversion.account(depth, nodes: &nodes)
        switch mc_toml_kind(node) {
        case Int32(MCTomlTable):
            var members: JSONMembers = []
            guard let cursor = mc_toml_cursor_create(node) else {
                throw failure("TOML table at \(path) is unavailable")
            }
            defer { mc_toml_cursor_destroy(cursor) }
            for _ in 0..<mc_toml_count(node) {
                var borrowedKey = MCTomlString()
                var child: OpaquePointer?
                guard mc_toml_cursor_next(cursor, &borrowedKey, &child), let child else {
                    throw failure("TOML child at \(path) is unavailable")
                }
                let key = try string(borrowedKey)
                members.append((key, try json(child, path: "\(path).\(key)", depth: depth + 1, nodes: &nodes)))
            }
            return .object(members)
        case Int32(MCTomlArray):
            var elements: [JSONValue] = []
            for index in 0..<mc_toml_count(node) {
                guard let child = mc_toml_array_child(node, index) else {
                    throw failure("TOML child at \(path) is unavailable")
                }
                elements.append(try json(child, path: "\(path)[\(index)]", depth: depth + 1, nodes: &nodes))
            }
            return .array(elements)
        case Int32(MCTomlStringValue): return .string(try string(mc_toml_string(node)))
        case Int32(MCTomlInteger): return .number(String(mc_toml_integer(node)))
        case Int32(MCTomlFloat):
            let real = mc_toml_float(node)
            guard real.isFinite else { throw failure("TOML number at \(path) is not finite") }
            return .number(String(real))
        case Int32(MCTomlBool): return .bool(mc_toml_bool(node))
        case Int32(MCTomlDate): return .string(rfc3339Date(mc_toml_calendar(node)))
        case Int32(MCTomlTime): return .string(rfc3339Time(mc_toml_calendar(node)))
        case Int32(MCTomlDateTime):
            let calendar = mc_toml_calendar(node)
            let local = rfc3339Date(calendar) + "T" + rfc3339Time(calendar)
            guard calendar.hasOffset else { return .string(local) }
            let minutes = Int(calendar.offsetMinutes)
            guard minutes != 0 else { return .string(local + "Z") }
            let sign = minutes < 0 ? "-" : "+"
            return .string(
                local + sign
                    + String(format: "%02d:%02d", abs(minutes) / minutesPerHour, abs(minutes) % minutesPerHour))
        default: throw failure("TOML value at \(path) is unsupported")
        }
    }

    private static func fill(
        _ container: OpaquePointer, from value: JSONValue, path: String, depth: Int, nodes: inout Int
    ) throws {
        try PropertyListConversion.account(depth, nodes: &nodes)
        switch value {
        case .object(let members):
            let keys = members.map(\.key)
            guard Set(keys).count == keys.count else { throw failure("Duplicate JSON keys at \(path) are unsupported") }
            for (key, child) in members {
                let childPath = "\(path).\(key)"
                let inserted = try insert(
                    child, into: container, key: try checked(key, path: childPath), path: childPath)
                try fill(inserted, from: child, path: childPath, depth: depth + 1, nodes: &nodes)
            }
        case .array(let elements):
            for (index, child) in elements.enumerated() {
                let childPath = "\(path)[\(index)]"
                let inserted = try insert(child, into: container, key: "", path: childPath)
                try fill(inserted, from: child, path: childPath, depth: depth + 1, nodes: &nodes)
            }
        case .string, .number, .bool, .null:
            return
        }
    }

    private static func insert(_ value: JSONValue, into container: OpaquePointer, key: String, path: String) throws
        -> OpaquePointer
    {
        var input = MCTomlInput()
        switch value {
        case .object: input.kind = Int32(MCTomlTable)
        case .array: input.kind = Int32(MCTomlArray)
        case .string(let text):
            _ = try checked(text, path: path)
            input.kind = Int32(MCTomlStringValue)
        case .number(let literal):
            let number = try PropertyListConversion.plistNumber(literal)
            if CFNumberIsFloatType(number) {
                input.kind = Int32(MCTomlFloat)
                input.real = number.doubleValue
            } else {
                input.kind = Int32(MCTomlInteger)
                input.integer = number.int64Value
            }
        case .bool(let flag):
            input.kind = Int32(MCTomlBool)
            input.flag = flag
        case .null: throw failure("JSON null at \(path) has no TOML value")
        }
        var child: OpaquePointer?
        let inserted = key.withCString { keyBytes in
            if case .string(let text) = value {
                return text.withCString { valueBytes in
                    input.bytes = valueBytes
                    input.length = text.utf8.count
                    return mc_toml_insert(container, keyBytes, key.utf8.count, input, &child)
                }
            }
            return mc_toml_insert(container, keyBytes, key.utf8.count, input, &child)
        }
        guard inserted, let child else { throw failure("TOML value at \(path) could not be created") }
        return child
    }

    private static func canonical(_ value: JSONValue) throws -> JSONValue {
        switch value {
        case .object(let members):
            return .object(
                try members.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }.map {
                    ($0.key, try canonical($0.value))
                })
        case .array(let elements):
            return .array(try elements.map(canonical))
        case .number(let literal):
            let number = try PropertyListConversion.plistNumber(literal)
            return .number(CFNumberIsFloatType(number) ? String(number.doubleValue) : String(number.int64Value))
        case .string, .bool, .null:
            return value
        }
    }

    private static func string(_ bytes: MCTomlString) throws -> String {
        guard let pointer = bytes.bytes else { throw failure("TOML string is unavailable") }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: bytes.length), as: UTF8.self)
    }

    private static func checked(_ text: String, path: String) throws -> String {
        guard !text.contains("\u{0}") else { throw failure("TOML NUL characters at \(path) are unsupported") }
        return text
    }

    private static func rfc3339Date(_ calendar: MCTomlCalendar) -> String {
        String(format: "%04d-%02d-%02d", calendar.year, calendar.month, calendar.day)
    }

    private static func rfc3339Time(_ calendar: MCTomlCalendar) -> String {
        let whole = String(format: "%02d:%02d:%02d", calendar.hour, calendar.minute, calendar.second)
        guard calendar.nanosecond > 0 else { return whole }
        let fraction = String(format: "%0\(fractionDigits)d", calendar.nanosecond)
        return whole + "." + fraction.replacing(/0+$/, with: "")
    }

    private static func failure(_ message: String) -> EngineError {
        .invalidInput(.malformed(message))
    }
}
