import CYaml
import Foundation
import Yams

/// Uses the YAML 1.2 core schema.
enum YAMLConversion {
    private static let maximumExpandedBytes = ConversionInput.maximumBytes
    private static let indent = 2
    private static let unlimitedWidth = -1
    private static let mergeKey = "<<"
    private static let trueWords: Set<String> = ["true", "True", "TRUE"]
    private static let falseWords: Set<String> = ["false", "False", "FALSE"]

    static func json(fromYAML text: String) throws -> JSONValue {
        try checkBounds(text)
        let root: Node?
        do {
            root = try Yams.compose(yaml: text, coreSchema())
        } catch YamlError.duplicatedKeysInMapping(let duplicates, _) {
            throw failure("YAML mapping repeats key \(duplicates.joined(separator: ", "))")
        } catch let error as YamlError {
            throw failure("YAML could not be read: \(error)")
        }
        guard let root else { throw EngineError.invalidInput(.emptyInput) }
        return try json(root, path: "$")
    }

    static func yaml(fromJSON text: String) throws -> String {
        try PropertyListConversion.guardJSONDepth(Data(text.utf8))
        let value = try JSONParser.parse(text)
        let ambiguity = [try coreSchema(), Resolver.default]
        let output = try Yams.serialize(
            node: node(value, path: "$", ambiguity: ambiguity), indent: indent, width: unlimitedWidth,
            allowUnicode: true)
        guard output.utf8.count <= ConversionInput.maximumBytes else {
            throw EngineError.invalidInput(.tooLarge(limitBytes: Int64(ConversionInput.maximumBytes)))
        }
        guard try json(fromYAML: output).serialized(indent: nil) == value.serialized(indent: nil) else {
            throw failure("YAML cannot preserve the supplied values")
        }
        return output
    }

    private static func coreSchema() throws -> Resolver {
        try Resolver.basic.appending(.null)
            .appending(.bool, "^(?:true|True|TRUE|false|False|FALSE)$")
            .appending(.int, "^(?:[-+]?[0-9]+|0o[0-7]+|0x[0-9a-fA-F]+)$")
            .appending(
                .float,
                "^(?:[-+]?(?:\\.[0-9]+|[0-9]+(?:\\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?|[-+]?\\.(?:inf|Inf|INF)|\\.(?:nan|NaN|NAN))$"
            )
    }

    /// Bounds nesting and aliases before Yams recurses.
    private static func checkBounds(_ text: String) throws {
        guard text.utf8.count <= ConversionInput.maximumBytes else {
            throw EngineError.invalidInput(.tooLarge(limitBytes: Int64(ConversionInput.maximumBytes)))
        }
        var parser = yaml_parser_t()
        guard yaml_parser_initialize(&parser) != 0 else {
            throw EngineError.decodeFailed("YAML parser could not start")
        }
        defer { yaml_parser_delete(&parser) }
        var source = text
        try source.withUTF8 { bytes in
            yaml_parser_set_input_string(&parser, bytes.baseAddress, bytes.count)
            var budget = ExpansionBudget()
            var documents = 0
            while true {
                try Task.checkCancellation()
                var event = yaml_event_t()
                guard yaml_parser_parse(&parser, &event) != 0 else { throw syntaxError(parser) }
                defer { yaml_event_delete(&event) }
                switch event.type {
                case YAML_STREAM_END_EVENT:
                    return
                case YAML_DOCUMENT_START_EVENT:
                    documents += 1
                    guard documents == 1 else { throw failure("YAML streams with several documents are unsupported") }
                case YAML_SCALAR_EVENT:
                    try budget.scalar(anchor: name(event.data.scalar.anchor), bytes: event.data.scalar.length)
                case YAML_SEQUENCE_START_EVENT:
                    try budget.open(anchor: name(event.data.sequence_start.anchor))
                case YAML_MAPPING_START_EVENT:
                    try budget.open(anchor: name(event.data.mapping_start.anchor))
                case YAML_SEQUENCE_END_EVENT, YAML_MAPPING_END_EVENT:
                    budget.close()
                case YAML_ALIAS_EVENT:
                    try budget.alias(anchor: name(event.data.alias.anchor))
                default:
                    break
                }
            }
        }
    }

    /// Sizes and heights as Yams expands aliases.
    private struct ExpansionBudget {
        private var anchors: [String: (size: Int, height: Int, bytes: Int)] = [:]
        private var openCollections: [(anchor: String?, firstNode: Int, firstByte: Int, childHeight: Int)] = []
        private var nodes = 0
        private var bytes = 0

        mutating func scalar(anchor: String?, bytes: Int) throws {
            try add(size: 1, height: 0, bytes: bytes)
            if let anchor { anchors[anchor] = (1, 0, bytes) }
        }

        mutating func open(anchor: String?) throws {
            try add(size: 1, height: 1, bytes: 0)
            openCollections.append((anchor, nodes - 1, bytes, 0))
        }

        mutating func close() {
            guard let collection = openCollections.popLast() else { return }
            let height = collection.childHeight + 1
            if let anchor = collection.anchor {
                anchors[anchor] = (nodes - collection.firstNode, height, bytes - collection.firstByte)
            }
            raiseParent(to: height)
        }

        mutating func alias(anchor: String?) throws {
            guard let anchor, let expansion = anchors[anchor] else {
                throw failure("YAML alias refers to an unknown anchor")
            }
            try add(size: expansion.size, height: expansion.height, bytes: expansion.bytes)
            raiseParent(to: expansion.height)
        }

        private mutating func raiseParent(to height: Int) {
            guard let last = openCollections.indices.last else { return }
            openCollections[last].childHeight = max(openCollections[last].childHeight, height)
        }

        private mutating func add(size: Int, height: Int, bytes: Int) throws {
            nodes += size
            guard openCollections.count + height <= PropertyListConversion.maximumDepth else {
                throw failure("Conversion exceeds 64 levels")
            }
            guard nodes <= PropertyListConversion.maximumNodes else {
                throw failure("Conversion exceeds 100000 values")
            }
            guard bytes <= maximumExpandedBytes - self.bytes else {
                throw failure("YAML expansion exceeds 8 MiB")
            }
            self.bytes += bytes
        }
    }

    private static func name(_ anchor: UnsafeMutablePointer<yaml_char_t>?) -> String? {
        anchor.map { String(cString: $0) }
    }

    private static func syntaxError(_ parser: yaml_parser_t) -> EngineError {
        let problem = parser.problem.map { String(cString: $0) } ?? "invalid syntax"
        return failure("YAML syntax error at line \(parser.problem_mark.line + 1): \(problem)")
    }

    private static func json(_ node: Node, path: String) throws -> JSONValue {
        try Task.checkCancellation()
        switch node {
        case .scalar(let scalar):
            return try json(scalar, tag: node.tag, path: path)
        case .sequence(let sequence):
            guard node.tag == Tag(.seq) else { throw unsupportedTag(node.tag, at: path) }
            return .array(try sequence.enumerated().map { try json($1, path: "\(path)[\($0)]") })
        case .mapping(let mapping):
            guard node.tag == Tag(.map) else { throw unsupportedTag(node.tag, at: path) }
            return .object(
                try mapping.map { key, value in
                    guard case .scalar(let scalar) = key, key.tag == Tag(.str) else {
                        throw failure("YAML key at \(path) is not a string")
                    }
                    guard scalar.style != .plain || scalar.string != mergeKey else {
                        throw failure("YAML merge key at \(path) is unsupported")
                    }
                    return (scalar.string, try json(value, path: "\(path).\(scalar.string)"))
                })
        case .alias:
            throw failure("YAML alias at \(path) was not resolved")
        }
    }

    private static func json(_ scalar: Node.Scalar, tag: Tag, path: String) throws -> JSONValue {
        let text = scalar.string
        switch tag {
        case Tag(.str): return .string(text)
        case Tag(.null): return .null
        case Tag(.bool):
            if trueWords.contains(text) { return .bool(true) }
            if falseWords.contains(text) { return .bool(false) }
        case Tag(.int):
            if let literal = integerLiteral(text) { return .number(literal) }
        case Tag(.float):
            if let real = Double(text), real.isFinite {
                return .number(JSONParser.isNumber(text) ? text : String(real))
            }
        default:
            throw unsupportedTag(tag, at: path)
        }
        throw failure("YAML \(tag) value at \(path) is invalid, out of range or not finite")
    }

    private static func integerLiteral(_ text: String) -> String? {
        if let hexadecimal = text.wholeMatch(of: /0x([0-9a-fA-F]+)/) {
            return Int64(hexadecimal.1, radix: 16).map(String.init)
        }
        if let octal = text.wholeMatch(of: /0o([0-7]+)/) {
            return Int64(octal.1, radix: 8).map(String.init)
        }
        guard let decimal = text.wholeMatch(of: /([-+]?)0*([0-9]+)/) else { return nil }
        return (decimal.1 == "-" ? "-" : "") + decimal.2
    }

    private static func node(_ value: JSONValue, path: String, ambiguity: [Resolver]) throws -> Node {
        switch value {
        case .object(let members):
            let keys = members.map(\.key)
            guard Set(keys).count == keys.count else { throw failure("Duplicate JSON keys at \(path) are unsupported") }
            return .mapping(
                Node.Mapping(
                    try members.map { key, child in
                        (
                            string(key, ambiguity: ambiguity),
                            try node(child, path: "\(path).\(key)", ambiguity: ambiguity)
                        )
                    }))
        case .array(let elements):
            return .sequence(
                Node.Sequence(
                    try elements.enumerated().map { try node($1, path: "\(path)[\($0)]", ambiguity: ambiguity) }))
        case .string(let text):
            return string(text, ambiguity: ambiguity)
        case .number(let literal):
            guard Double(literal)?.isFinite == true else { throw failure("Number at \(path) is not finite") }
            return Node(literal, .implicit, .plain)
        case .bool(let flag):
            return Node(flag ? "true" : "false", .implicit, .plain)
        case .null:
            return Node("null", .implicit, .plain)
        }
    }

    /// Quote strings any reader could retype.
    private static func string(_ text: String, ambiguity: [Resolver]) -> Node {
        let plain = Node(text)
        let retyped = ambiguity.contains { $0.resolveTag(of: plain) != .str }
        return Node(text, Tag(.str), retyped ? .doubleQuoted : .any)
    }

    private static func unsupportedTag(_ tag: Tag, at path: String) -> EngineError {
        failure("YAML tag \(tag) at \(path) is unsupported")
    }

    private static func failure(_ message: String) -> EngineError {
        .invalidInput(.malformed(message))
    }
}
