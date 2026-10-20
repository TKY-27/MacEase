import Foundation

/// RFC 4180; record one is the header.
struct CSVTable {
    private static let delimiters: [Unicode.Scalar] = [",", ";", "\t"]
    private static let quote: Unicode.Scalar = "\""

    let header: [String]
    let rows: [[String]]

    init(header: [String], rows: [[String]]) {
        self.header = header
        self.rows = rows
    }

    init(parsing text: String) throws {
        let records = try Self.records(in: Array(text.unicodeScalars))
        guard let header = records.first else { throw EngineError.invalidInput(.emptyInput) }
        for (index, record) in records.enumerated() where record.count != header.count {
            throw EngineError.invalidInput(
                .malformed("CSV record \(index + 1) has \(record.count) fields, the header has \(header.count)"))
        }
        self.init(header: header, rows: Array(records.dropFirst()))
    }

    /// Requires an array of flat objects.
    init(flattening value: JSONValue) throws {
        guard case .array(let elements) = value else { throw EngineError.invalidInput(.jsonNotFlatArray(path: "$")) }
        guard !elements.isEmpty else { throw EngineError.invalidInput(.emptyInput) }
        var header: [String] = []
        var seen = Set<String>()
        var cells: [[String: String]] = []
        for (index, element) in elements.enumerated() {
            guard case .object(let members) = element else {
                throw EngineError.invalidInput(.jsonNotFlatArray(path: "$[\(index)]"))
            }
            var row: [String: String] = [:]
            for member in members {
                guard let cell = member.value.scalarText else {
                    throw EngineError.invalidInput(.jsonNotFlatArray(path: "$[\(index)].\(member.key)"))
                }
                row[member.key] = cell
                if seen.insert(member.key).inserted { header.append(member.key) }
            }
            cells.append(row)
        }
        self.init(header: header, rows: cells.map { row in header.map { row[$0] ?? "" } })
    }

    func objects(inferringTypes: Bool) -> JSONValue {
        .array(
            rows.map { row in
                .object(zip(header, row).map { ($0, inferringTypes ? Self.inferred($1) : .string($1)) })
            })
    }

    /// RFC 4180 ends records with CRLF.
    var text: String {
        ([header] + rows).map { $0.map(Self.quotedIfNeeded).joined(separator: ",") + "\r\n" }.joined()
    }

    private static func inferred(_ field: String) -> JSONValue {
        switch field {
        case "": .null
        case "true": .bool(true)
        case "false": .bool(false)
        case _ where JSONParser.isNumber(field): .number(field)
        default: .string(field)
        }
    }

    private static func quotedIfNeeded(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return field }
        return "\"" + field.replacing("\"", with: "\"\"") + "\""
    }

    /// Ties favor the comma.
    private static func delimiter(of scalars: [Unicode.Scalar]) -> Unicode.Scalar {
        var counts: [Unicode.Scalar: Int] = [:]
        var inQuotes = false
        for scalar in scalars {
            if scalar == quote {
                inQuotes.toggle()
            } else if !inQuotes, scalar == "\n" || scalar == "\r" {
                break
            } else if !inQuotes, delimiters.contains(scalar) {
                counts[scalar, default: 0] += 1
            }
        }
        var best = delimiters[0]
        for candidate in delimiters where counts[candidate, default: 0] > counts[best, default: 0] { best = candidate }
        return best
    }

    private static func records(in scalars: [Unicode.Scalar]) throws -> [[String]] {
        let delimiter = delimiter(of: scalars)
        var records: [[String]] = []
        var record: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var fieldQuoted = false

        func finishField() {
            record.append(String(field))
            field = String.UnicodeScalarView()
            fieldQuoted = false
        }
        func finishRecord() {
            let isBlankLine = record.isEmpty && field.isEmpty && !fieldQuoted
            if !isBlankLine {
                finishField()
                records.append(record)
            }
            record = []
            field = String.UnicodeScalarView()
            fieldQuoted = false
        }

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            if inQuotes {
                if scalar != quote {
                    field.append(scalar)
                } else if next == quote {
                    field.append(quote)
                    index += 1
                } else {
                    inQuotes = false
                }
            } else if scalar == quote, field.isEmpty, !fieldQuoted {
                inQuotes = true
                fieldQuoted = true
            } else if scalar == delimiter {
                finishField()
            } else if scalar == "\r" || scalar == "\n" {
                if scalar == "\r", next == "\n" { index += 1 }
                finishRecord()
            } else {
                field.append(scalar)
            }
            index += 1
        }
        guard !inQuotes else { throw EngineError.invalidInput(.malformed("a quoted CSV field never closes")) }
        finishRecord()
        return records
    }
}

extension JSONValue {
    /// `nil` for containers; null is empty.
    var scalarText: String? {
        switch self {
        case .string(let text): text
        case .number(let literal): literal
        case .bool(let flag): flag ? "true" : "false"
        case .null: ""
        case .object, .array: nil
        }
    }
}
