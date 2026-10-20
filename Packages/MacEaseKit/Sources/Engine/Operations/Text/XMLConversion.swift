import Foundation

/// Mirrors `@name`, `#text` and sibling arrays.
enum XMLConversion {
    private static let indentUnit = "  "
    private static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    private static let arrayElementName = "item"
    private static let firstAllowedScalar: UInt32 = 0x20
    private static let allowedControls: Set<Unicode.Scalar> = ["\t", "\n", "\r"]

    static func json(from data: Data) throws -> JSONValue {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let builder = XMLTreeBuilder()
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw EngineError.invalidInput(
                .malformed("XML error at line \(parser.lineNumber), column \(parser.columnNumber)"))
        }
        return .object([(root.name, root.json)])
    }

    static func document(root: String, _ value: JSONValue) throws -> String {
        var output = declaration
        try element(named: root, value, level: 0, into: &output)
        return output
    }

    static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }

    private static func element(named key: String, _ value: JSONValue, level: Int, into output: inout String) throws {
        let padding = String(repeating: indentUnit, count: level)
        let name = elementName(key)
        var attributes = ""
        var text = value.scalarText ?? ""
        var children: JSONMembers = []
        switch value {
        case .object(let members):
            for member in members {
                if member.key.hasPrefix("@"), let scalar = member.value.scalarText {
                    attributes += " \(elementName(String(member.key.dropFirst())))=\"\(try xmlText(scalar))\""
                } else if member.key == "#text", let scalar = member.value.scalarText {
                    text = scalar
                } else {
                    children.append(member)
                }
            }
        case .array(let elements):
            children = elements.map { (arrayElementName, $0) }
        case .string, .number, .bool, .null:
            break
        }
        guard !children.isEmpty else {
            output +=
                text.isEmpty
                ? "\(padding)<\(name)\(attributes)/>\n"
                : "\(padding)<\(name)\(attributes)>\(try xmlText(text))</\(name)>\n"
            return
        }
        output += "\(padding)<\(name)\(attributes)>\n"
        if !text.isEmpty { output += padding + indentUnit + (try xmlText(text)) + "\n" }
        for child in children {
            if case .array(let repeated) = child.value {
                for item in repeated { try element(named: child.key, item, level: level + 1, into: &output) }
            } else {
                try element(named: child.key, child.value, level: level + 1, into: &output)
            }
        }
        output += "\(padding)</\(name)>\n"
    }

    /// XML 1.0 forbids most control characters.
    private static func xmlText(_ text: String) throws -> String {
        let forbidden = text.unicodeScalars.contains {
            $0.value < firstAllowedScalar && !allowedControls.contains($0)
        }
        guard !forbidden else {
            throw EngineError.invalidInput(.malformed("text has control characters XML cannot hold"))
        }
        return escaped(text)
    }

    /// Keys may hold characters names cannot.
    private static func elementName(_ key: String) -> String {
        let cleaned = String(key.map { $0.isLetter || $0.isNumber || "_-.".contains($0) ? $0 : "_" })
        guard let first = cleaned.first else { return "_" }
        return first.isLetter || first == "_" ? cleaned : "_" + cleaned
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    final class Node {
        let name: String
        let attributes: [(String, String)]
        var children: [Node] = []
        var text = ""

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes.sorted { $0.key < $1.key }
        }

        var json: JSONValue {
            var members: JSONMembers = attributes.map { ("@" + $0.0, .string($0.1)) }
            var groups: [(name: String, values: [JSONValue])] = []
            var groupIndex: [String: Int] = [:]
            for child in children {
                if let index = groupIndex[child.name] {
                    groups[index].values.append(child.json)
                } else {
                    groupIndex[child.name] = groups.count
                    groups.append((child.name, [child.json]))
                }
            }
            members += groups.map { group in
                (group.name, group.values.count == 1 ? group.values[0] : .array(group.values))
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if members.isEmpty { return trimmed.isEmpty ? .null : .string(trimmed) }
            if !trimmed.isEmpty { members.append(("#text", .string(trimmed))) }
            return .object(members)
        }
    }

    private(set) var root: Node?
    private var open: [Node] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        let node = Node(name: elementName, attributes: attributes)
        open.last?.children.append(node)
        if root == nil { root = node }
        open.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        open.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        open.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        open.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }
}
