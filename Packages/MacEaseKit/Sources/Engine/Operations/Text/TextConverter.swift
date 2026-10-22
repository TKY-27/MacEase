import Foundation

enum TextConverter {
    private static let jsonRoot = "root"
    private static let csvRoot = "rows"
    private static let csvRecord = "row"

    static func convert(
        _ data: Data, _ conversion: TextConversion, settings: TextSettings, title: String,
        source: SourceTextEncoding? = nil
    ) throws
        -> String
    {
        let text = { try TextEncoding.decode(data, assuming: source).text }
        let indent = settings.jsonIndent.unit
        switch conversion {
        case .toTXT: return try text()
        case .srtToVTT: return try SubtitleConversion.convert(text(), fromVTT: false)
        case .vttToSRT: return try SubtitleConversion.convert(text(), fromVTT: true)
        case .htmlToPDF, .htmlToText, .jsonToXMLPlist, .jsonToBinaryPlist, .markdownToHTML, .markdownToPDF:
            throw EngineError.invalidInput(.unsupportedFileType)
        case .csvToJSON:
            let objects = try CSVTable(parsing: text()).objects(inferringTypes: settings.csvTypeInference)
            return objects.serialized(indent: indent) + "\n"
        case .csvToXML:
            let objects = try CSVTable(parsing: text()).objects(inferringTypes: settings.csvTypeInference)
            return try XMLConversion.document(root: csvRoot, .object([(csvRecord, objects)]))
        case .csvToHTML:
            return html(try CSVTable(parsing: text()), title: title)
        case .csvToMarkdown:
            return markdown(try CSVTable(parsing: text()))
        case .jsonToCSV:
            return try CSVTable(flattening: JSONParser.parse(text())).text
        case .jsonToXML:
            return try XMLConversion.document(root: jsonRoot, JSONParser.parse(text()))
        case .xmlToJSON:
            return try XMLConversion.json(from: data).serialized(indent: indent) + "\n"
        case .iniToJSON:
            return try ini(text()).serialized(indent: indent) + "\n"
        case .iniToXML:
            return try XMLConversion.document(root: jsonRoot, ini(text()))
        case .yamlToJSON:
            let output = try YAMLConversion.json(fromYAML: text()).serialized(
                indent: indent, maximumBytes: ConversionInput.maximumBytes)
            guard output.utf8.count < ConversionInput.maximumBytes else {
                throw EngineError.invalidInput(.malformed("JSON output exceeds 8 MiB"))
            }
            return output + "\n"
        case .jsonToYAML:
            return try YAMLConversion.yaml(fromJSON: text())
        case .tomlToJSON:
            return try TOMLConversion.json(fromTOML: text()).serialized(indent: indent) + "\n"
        case .jsonToTOML:
            return try TOMLConversion.toml(fromJSON: text())
        }
    }

    /// Sections become objects; later duplicate keys win.
    static func ini(_ text: String) throws -> JSONValue {
        var global: JSONMembers = []
        var sectionNames: [String] = []
        var sections: [String: JSONMembers] = [:]
        var current: String?
        for (offset, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated()
        {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                if sections[name] == nil {
                    sectionNames.append(name)
                    sections[name] = []
                }
                current = name
                continue
            }
            guard let separator = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else {
                throw EngineError.invalidInput(.malformed("INI line \(offset + 1) is not a key and value"))
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = JSONValue.string(line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces))
            if let current {
                assign(value, to: key, in: &sections[current, default: []])
            } else {
                assign(value, to: key, in: &global)
            }
        }
        for (key, _) in global where sections[key] != nil {
            throw EngineError.invalidInput(.malformed("Duplicate JSON keys at $.\(key) are unsupported"))
        }
        return .object(global + sectionNames.map { ($0, .object(sections[$0, default: []])) })
    }

    private static func assign(_ value: JSONValue, to key: String, in members: inout JSONMembers) {
        if let index = members.firstIndex(where: { $0.key == key }) {
            members[index].value = value
        } else {
            members.append((key, value))
        }
    }

    private static func html(_ table: CSVTable, title: String) -> String {
        func cells(_ fields: [String], tag: String) -> String {
            "<tr>" + fields.map { "<\(tag)>\(XMLConversion.escaped($0))</\(tag)>" }.joined() + "</tr>\n"
        }
        return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <title>\(XMLConversion.escaped(title))</title>
            </head>
            <body>
            <table>
            <thead>
            \(cells(table.header, tag: "th"))</thead>
            <tbody>
            \(table.rows.map { cells($0, tag: "td") }.joined())</tbody>
            </table>
            </body>
            </html>

            """
    }

    /// Table cells cannot hold newlines or pipes.
    private static func markdown(_ table: CSVTable) -> String {
        func line(_ fields: [String]) -> String {
            let cells = fields.map { field in
                field.replacing("|", with: "\\|").split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                    .joined(separator: "<br>")
            }
            return "| " + cells.joined(separator: " | ") + " |\n"
        }
        return line(table.header) + line(table.header.map { _ in "---" }) + table.rows.map(line).joined()
    }
}
