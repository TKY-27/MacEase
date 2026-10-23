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

extension JSONIndent {
    var unit: String {
        switch self {
        case .two: "  "
        case .four: "    "
        case .tab: "\t"
        }
    }
}
