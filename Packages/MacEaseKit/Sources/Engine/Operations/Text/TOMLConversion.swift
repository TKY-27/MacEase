import CoreFoundation
import Foundation
import TOMLKit

/// Dates and times become RFC 3339 strings.
enum TOMLConversion {
    // shortcut: TOMLKit leaks tables; raise when fixed.
    static let maximumBytes = 1024 * 1024
    private static let minutesPerHour = 60
    private static let fractionDigits = 9
    // C strings would silently truncate at NUL.
    private static let nulSpellings = ["\u{0}", "\\u0000", "\\U00000000"]

    static func json(fromTOML text: String) throws -> JSONValue {
        guard text.utf8.count <= maximumBytes else {
            throw EngineError.invalidInput(.tooLarge(limitBytes: Int64(maximumBytes)))
        }
        guard !nulSpellings.contains(where: text.contains) else { throw failure("TOML NUL characters are unsupported") }
        let table: TOMLTable
        do {
            table = try TOMLTable(string: text)
        } catch let error as TOMLParseError {
            throw failure("TOML syntax error at line \(error.source.begin.line): \(error.description)")
        }
        var nodes = 0
        return try json(table, path: "$", depth: 0, nodes: &nodes)
    }

    static func toml(fromJSON text: String) throws -> String {
        try PropertyListConversion.guardJSONDepth(Data(text.utf8))
        let value = try JSONParser.parse(text)
        guard case .object = value else { throw failure("TOML requires a JSON object at the root") }
        let table = TOMLTable()
        var nodes = 0
        try fill(table, from: value, path: "$", depth: 0, nodes: &nodes)
        let output = table.convert(
            to: .toml,
            options: [.allowLiteralStrings, .allowMultilineStrings, .allowUnicodeStrings, .relaxedFloatPrecision])
        guard output.utf8.count <= ConversionInput.maximumBytes else {
            throw EngineError.invalidInput(.tooLarge(limitBytes: Int64(ConversionInput.maximumBytes)))
        }
        guard try json(fromTOML: output).serialized(indent: nil) == canonical(value).serialized(indent: nil) else {
            throw failure("TOML cannot preserve the supplied values")
        }
        return output
    }

    private static func json(_ value: any TOMLValueConvertible, path: String, depth: Int, nodes: inout Int) throws
        -> JSONValue
    {
        try PropertyListConversion.account(depth, nodes: &nodes)
        if let table = value.table {
            var members: JSONMembers = []
            for (key, child) in table {
                members.append((key, try json(child, path: "\(path).\(key)", depth: depth + 1, nodes: &nodes)))
            }
            return .object(members)
        }
        if let array = value.array {
            var elements: [JSONValue] = []
            for (index, child) in array.enumerated() {
                elements.append(try json(child, path: "\(path)[\(index)]", depth: depth + 1, nodes: &nodes))
            }
            return .array(elements)
        }
        if let string = value.string { return .string(string) }
        if let integer = value.int { return .number(String(integer)) }
        if let real = value.double {
            guard real.isFinite else { throw failure("TOML number at \(path) is not finite") }
            return .number(String(real))
        }
        if let flag = value.bool { return .bool(flag) }
        if let dateTime = value.dateTime { return .string(rfc3339(dateTime)) }
        if let date = value.date { return .string(rfc3339(date)) }
        if let time = value.time { return .string(rfc3339(time)) }
        throw failure("TOML value at \(path) is unsupported")
    }

    /// Fill in place; TOMLKit copies inserted children.
    private static func fill(
        _ container: any TOMLValueConvertible, from value: JSONValue, path: String, depth: Int, nodes: inout Int
    ) throws {
        try PropertyListConversion.account(depth, nodes: &nodes)
        switch value {
        case .object(let members):
            let keys = members.map(\.key)
            guard Set(keys).count == keys.count else { throw failure("Duplicate JSON keys at \(path) are unsupported") }
            guard let table = container.table else { throw failure("TOML table at \(path) could not be created") }
            for (key, child) in members {
                let childPath = "\(path).\(key)"
                table[try checked(key, path: childPath)] = try placeholder(child, path: childPath)
                guard let slot = table[key] else { throw failure("TOML value at \(childPath) could not be created") }
                try fill(slot, from: child, path: childPath, depth: depth + 1, nodes: &nodes)
            }
        case .array(let elements):
            guard let array = container.array else { throw failure("TOML array at \(path) could not be created") }
            for (index, child) in elements.enumerated() {
                let childPath = "\(path)[\(index)]"
                array.append(try placeholder(child, path: childPath))
                try fill(array[index], from: child, path: childPath, depth: depth + 1, nodes: &nodes)
            }
        case .string, .number, .bool, .null:
            return
        }
    }

    private static func placeholder(_ value: JSONValue, path: String) throws -> any TOMLValueConvertible {
        switch value {
        case .object: return TOMLTable()
        case .array: return TOMLArray()
        case .string(let text): return try checked(text, path: path)
        case .number(let literal):
            let number = try PropertyListConversion.plistNumber(literal)
            return CFNumberIsFloatType(number) ? number.doubleValue : Int(number.int64Value)
        case .bool(let flag): return flag
        case .null: throw failure("JSON null at \(path) has no TOML value")
        }
    }

    /// Mirrors toml++ byte-ordered keys and binary64 numbers.
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

    private static func checked(_ text: String, path: String) throws -> String {
        guard !text.contains("\u{0}") else { throw failure("TOML NUL characters at \(path) are unsupported") }
        return text
    }

    private static func rfc3339(_ date: TOMLDate) -> String {
        String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
    }

    private static func rfc3339(_ time: TOMLTime) -> String {
        let whole = String(format: "%02d:%02d:%02d", time.hour, time.minute, time.second)
        guard time.nanoSecond > 0 else { return whole }
        let fraction = String(format: "%0\(fractionDigits)d", time.nanoSecond)
        return whole + "." + fraction.replacing(/0+$/, with: "")
    }

    private static func rfc3339(_ dateTime: TOMLDateTime) -> String {
        let local = rfc3339(dateTime.date) + "T" + rfc3339(dateTime.time)
        guard let minutes = dateTime.offset?.offset else { return local }
        guard minutes != 0 else { return local + "Z" }
        let sign = minutes < 0 ? "-" : "+"
        return local + sign
            + String(format: "%02d:%02d", abs(minutes) / minutesPerHour, abs(minutes) % minutesPerHour)
    }

    private static func failure(_ message: String) -> EngineError {
        .invalidInput(.malformed(message))
    }
}
