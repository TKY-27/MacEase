import CoreFoundation
import Foundation

enum PropertyListConversion {
    private static let maximumBytes = 8 * 1024 * 1024
    static let maximumDepth = 64
    static let maximumNodes = 100_000
    private static let tagKey = "$maceaseType"

    static func json(from bytes: Data, indent: String) throws -> String {
        guard bytes.count <= maximumBytes else { throw failure("Property list exceeds 8 MiB") }
        if !bytes.starts(with: "bplist".utf8) { try XMLKeyValidator.validate(bytes) }
        var format = PropertyListSerialization.PropertyListFormat.xml
        let propertyList = try PropertyListSerialization.propertyList(
            from: bytes, options: [], format: &format)
        var nodes = 0
        var expandedBytes = 0
        let value = try jsonValue(propertyList, depth: 0, nodes: &nodes, expandedBytes: &expandedBytes)
        do {
            return try value.serialized(indent: indent, maximumBytes: maximumBytes - "\n".utf8.count) + "\n"
        } catch EngineError.invalidInput(.malformed(_)) {
            throw failure("JSON output exceeds 8 MiB")
        }
    }

    static func plist(from text: String, format: PropertyListSerialization.PropertyListFormat) throws
        -> Data
    {
        let bytes = Data(text.utf8)
        guard bytes.count <= maximumBytes else { throw failure("JSON exceeds 8 MiB") }
        try guardJSONDepth(bytes)
        let value = try JSONParser.parse(text)
        var nodes = 0
        let propertyList = try propertyListValue(value, depth: 0, nodes: &nodes)
        let output = try PropertyListSerialization.data(
            fromPropertyList: propertyList, format: format, options: 0)
        guard output.count <= maximumBytes else { throw failure("Property list output exceeds 8 MiB") }
        let decoded = try PropertyListSerialization.propertyList(from: output, options: [], format: nil)
        var expectedNodes = 0
        var decodedNodes = 0
        var expectedExpandedBytes = 0
        var decodedExpandedBytes = 0
        let expectedValue = try jsonValue(
            propertyList, depth: 0, nodes: &expectedNodes, expandedBytes: &expectedExpandedBytes)
        let decodedValue = try jsonValue(
            decoded, depth: 0, nodes: &decodedNodes, expandedBytes: &decodedExpandedBytes)
        guard expectedValue.serialized(indent: "") == decodedValue.serialized(indent: "") else {
            throw failure("This property list format cannot preserve the supplied values")
        }
        return output
    }

    private static func jsonValue(
        _ value: Any, depth: Int, nodes: inout Int, expandedBytes: inout Int
    ) throws -> JSONValue {
        try Task.checkCancellation()
        try account(depth, nodes: &nodes)
        if let date = value as? Date {
            try account(extra: 2, nodes: &nodes)
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard date.timeIntervalSince1970.isFinite else { throw failure("Date is not finite") }
            let timestamp = formatter.string(from: date)
            guard formatter.date(from: timestamp) == date else {
                throw failure("Date precision exceeds milliseconds")
            }
            try accountExpanded(timestamp.utf8.count, expandedBytes: &expandedBytes)
            return tagged("date", timestamp)
        }
        if let payload = value as? Data {
            try account(extra: 2, nodes: &nodes)
            let inputGroupBytes = 3
            let outputGroupBytes = 4
            let encodedBytes = ((payload.count + inputGroupBytes - 1) / inputGroupBytes) * outputGroupBytes
            try accountExpanded(encodedBytes, expandedBytes: &expandedBytes)
            return tagged("data", payload.base64EncodedString())
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                let literal = number.boolValue ? "true" : "false"
                try accountExpanded(literal.utf8.count, expandedBytes: &expandedBytes)
                return .bool(number.boolValue)
            }
            let literal = try jsonNumber(number)
            try accountExpanded(literal.utf8.count, expandedBytes: &expandedBytes)
            return .number(literal)
        }
        if let string = value as? String {
            try accountExpanded(string.utf8.count, expandedBytes: &expandedBytes)
            return .string(string)
        }
        if let array = value as? [Any] {
            return .array(
                try array.map {
                    try jsonValue($0, depth: depth + 1, nodes: &nodes, expandedBytes: &expandedBytes)
                })
        }
        if let dictionary = value as? [String: Any] {
            var members: JSONMembers = []
            for (key, child) in dictionary.sorted(by: { scalarOrder($0.key, $1.key) }) {
                try accountExpanded(key.utf8.count, expandedBytes: &expandedBytes)
                members.append(
                    (
                        key,
                        try jsonValue(child, depth: depth + 1, nodes: &nodes, expandedBytes: &expandedBytes)
                    ))
            }
            let object = JSONValue.object(members)
            guard dictionary[tagKey] != nil else { return object }
            try account(extra: 2, nodes: &nodes)
            return taggedDictionary(object)
        }
        throw failure("Property list contains an unsupported value")
    }

    private static func jsonNumber(_ number: NSNumber) throws -> String {
        let type = String(cString: number.objCType)
        if ["c", "s", "i", "l", "q"].contains(type) {
            return String(number.int64Value)
        }
        if ["C", "S", "I", "L", "Q"].contains(type) {
            guard number.stringValue.first != "-", let integer = Int64(number.stringValue) else {
                throw failure("Integer exceeds signed 64-bit range")
            }
            return String(integer)
        }
        let real = number.doubleValue
        guard real.isFinite else { throw failure("Non-finite numbers are unsupported") }
        return String(real)
    }

    private static func propertyListValue(_ value: JSONValue, depth: Int, nodes: inout Int) throws
        -> Any
    {
        try account(depth, nodes: &nodes)
        switch value {
        case .object(let members):
            let keys = members.map(\.key)
            guard Set(keys).count == keys.count else {
                throw failure("Duplicate JSON keys are unsupported")
            }
            if keys.contains(tagKey) {
                return try decodeTagged(members, depth: depth, nodes: &nodes)
            }
            var dictionary: [String: Any] = [:]
            for member in members {
                dictionary[member.key] = try propertyListValue(
                    member.value, depth: depth + 1, nodes: &nodes)
            }
            return dictionary
        case .array(let elements):
            return try elements.map { try propertyListValue($0, depth: depth + 1, nodes: &nodes) }
        case .string(let string): return string
        case .bool(let flag): return NSNumber(value: flag)
        case .number(let literal): return try plistNumber(literal)
        case .null: throw failure("JSON null has no property list value")
        }
    }

    private static func decodeTagged(_ members: JSONMembers, depth: Int, nodes: inout Int) throws
        -> Any
    {
        let keys = members.map(\.key)
        guard keys.count == 2,
            let type = members.first(where: { $0.key == tagKey })?.value,
            case .string(let tag) = type,
            let payload = members.first(where: { $0.key == "value" })?.value
        else {
            throw failure("Ambiguous $maceaseType object")
        }
        switch tag {
        case "date":
            guard case .string(let string) = payload else { throw failure("Invalid date tag") }
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: string), formatter.string(from: date) == string else {
                throw failure("Invalid date tag")
            }
            return date
        case "data":
            guard case .string(let string) = payload,
                let payload = Data(base64Encoded: string), payload.base64EncodedString() == string
            else {
                throw failure("Invalid data tag")
            }
            return payload
        case "dictionary":
            guard case .object(let original) = payload else { throw failure("Invalid dictionary tag") }
            let originalKeys = original.map(\.key)
            guard Set(originalKeys).count == originalKeys.count else {
                throw failure("Duplicate JSON keys are unsupported")
            }
            var dictionary: [String: Any] = [:]
            for member in original {
                dictionary[member.key] = try propertyListValue(
                    member.value, depth: depth + 2, nodes: &nodes)
            }
            return dictionary
        default: throw failure("Unknown $maceaseType value")
        }
    }

    static func plistNumber(_ literal: String) throws -> NSNumber {
        if !literal.contains(".") && !literal.contains("e") && !literal.contains("E") {
            guard let integer = Int64(literal) else {
                throw failure("Integer exceeds signed 64-bit range")
            }
            return NSNumber(value: integer)
        }
        let maximumDecimalDigits = 38
        guard literal.filter(\.isNumber).count <= maximumDecimalDigits,
            let decimal = Decimal(string: literal, locale: Locale(identifier: "en_US_POSIX")),
            let real = Double(literal), real.isFinite,
            let roundTrip = Decimal(string: String(real), locale: Locale(identifier: "en_US_POSIX")),
            decimal == roundTrip
        else { throw failure("Number cannot be represented without precision loss") }
        return NSNumber(value: real)
    }

    private static func tagged(_ type: String, _ value: String) -> JSONValue {
        .object([(tagKey, .string(type)), ("value", .string(value))])
    }

    private static func taggedDictionary(_ value: JSONValue) -> JSONValue {
        .object([(tagKey, .string("dictionary")), ("value", value)])
    }

    private static func account(extra: Int, nodes: inout Int) throws {
        nodes += extra
        guard nodes <= maximumNodes else { throw failure("Conversion exceeds 100000 values") }
    }

    private static func accountExpanded(_ bytes: Int, expandedBytes: inout Int) throws {
        guard bytes <= maximumBytes - expandedBytes else { throw failure("JSON output exceeds 8 MiB") }
        expandedBytes += bytes
    }

    static func account(_ depth: Int, nodes: inout Int) throws {
        guard depth <= maximumDepth else { throw failure("Conversion exceeds 64 levels") }
        nodes += 1
        guard nodes <= maximumNodes else { throw failure("Conversion exceeds 100000 values") }
    }

    static func guardJSONDepth(_ bytes: Data) throws {
        var inString = false
        var escaped = false
        var depth = 0
        var nodes = 0
        let source = Array(bytes)
        for (index, byte) in source.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                    var next = index + 1
                    while next < source.count && [0x20, 0x09, 0x0A, 0x0D].contains(source[next]) { next += 1 }
                    if next == source.count || source[next] != 0x3A { nodes += 1 }
                }
                continue
            }
            if byte == 0x22 {
                inString = true
            } else if byte == 0x7B || byte == 0x5B {
                depth += 1
                nodes += 1
                guard depth <= maximumDepth else { throw failure("Conversion exceeds 64 levels") }
            } else if byte == 0x7D || byte == 0x5D {
                depth -= 1
            } else if ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x3A].contains(byte),
                index == 0 || [0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x3A].contains(source[index - 1])
            {
                nodes += 1
            }
            guard nodes <= maximumNodes else { throw failure("Conversion exceeds 100000 values") }
        }
    }

    private static func scalarOrder(_ left: String, _ right: String) -> Bool {
        left.unicodeScalars.lexicographicallyPrecedes(right.unicodeScalars)
    }

    private static func failure(_ message: String) -> EngineError {
        .invalidInput(.malformed(message))
    }

    private final class XMLKeyValidator: NSObject, XMLParserDelegate {
        private var dictionaries: [Set<String>] = []
        private var key: String?
        private var rejection: EngineError?

        static func validate(_ bytes: Data) throws {
            let parser = XMLParser(data: bytes)
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            let validator = XMLKeyValidator()
            parser.delegate = validator
            let parsed = parser.parse()
            if let rejection = validator.rejection { throw rejection }
            guard parsed else {
                throw failure("XML error at line \(parser.lineNumber), column \(parser.columnNumber)")
            }
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            if elementName == "dict" { dictionaries.append([]) }
            if elementName == "key" { key = "" }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?
        ) {
            if elementName == "key", let key, let last = dictionaries.indices.last {
                if !dictionaries[last].insert(key).inserted {
                    rejection = failure("Duplicate JSON keys are unsupported")
                    parser.abortParsing()
                }
                self.key = nil
            }
            if elementName == "dict" { dictionaries.removeLast() }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            key? += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            key? += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            rejectEntities(parser)
        }

        func parser(
            _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?,
            systemID: String?
        ) {
            rejectEntities(parser)
        }

        private func rejectEntities(_ parser: XMLParser) {
            rejection = failure("XML entity declarations are not supported")
            parser.abortParsing()
        }
    }
}
