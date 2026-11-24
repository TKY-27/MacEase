import Foundation

// RFC 4180 records; header first.
struct PreviewTable: Sendable {
    static let maximumDataRows = 50_000
    static let maximumColumns = 256
    static let maximumCellDisplayLength = 1_000
    private static let cancellationStride = 1_024
    private static let findOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    private static let quote = UInt8(ascii: "\"")
    private static let lineFeed = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")
    private static let plus = UInt8(ascii: "+")
    private static let minus = UInt8(ascii: "-")
    private static let decimalPoint = UInt8(ascii: ".")
    private static let exponent = UInt8(ascii: "e")
    private static let lowercaseBit: UInt8 = 0x20
    private static let asciiDigits = UInt8(ascii: "0")...UInt8(ascii: "9")
    private static let fieldBreakingScalars: Set<Unicode.Scalar> = ["\t", "\n", "\r", "\""]
    private static let ellipsis: Unicode.Scalar = "\u{2026}"
    private static let replacement: Unicode.Scalar = "\u{FFFD}"
    private static let deletePicture: Unicode.Scalar = "\u{2421}"
    private static let controlPictures: [Unicode.Scalar] = (0x2400...0x241F).compactMap(Unicode.Scalar.init)
    private static let separatorDirective = "sep="
    private static let lineBreaks: Set<Character> = ["\n", "\r", "\r\n"]

    enum Delimiter: UInt8, Sendable {
        case comma = 44
        case semicolon = 59
        case tab = 9
    }

    enum Format: Sendable {
        case commaSeparated, tabSeparated

        init?(pathExtension: String) {
            switch pathExtension.lowercased() {
            case "csv": self = .commaSeparated
            case "tsv": self = .tabSeparated
            default: return nil
            }
        }

        // Semicolon, tab and Excel sep= exports.
        func layout(of text: String) -> (delimiter: Delimiter, body: Substring) {
            guard self == .commaSeparated else { return (.tab, text[...]) }
            if let directive = PreviewTable.directive(in: text) { return directive }
            let bytes = Array(text.utf8)
            let widths = [Delimiter.comma, .semicolon, .tab].map {
                ($0, PreviewTable.firstRecordWidth(bytes, separator: $0.rawValue))
            }
            // Ties keep the earlier, more common separator.
            let widest = widths.reduce(widths[0]) { best, candidate in candidate.1 > best.1 ? candidate : best }
            return (widest.0, text[...])
        }
    }

    struct Cell: Equatable, Sendable {
        let position: Int
        let column: Int
    }

    let id = UUID()
    let rows: [[String]]
    let columnCount: Int
    let rowsClipped: Bool
    let columnsClipped: Bool
    let numericColumns: Set<Int>

    var dataRowCount: Int { max(0, rows.count - 1) }
    var fileOrder: [Int] { Array(rows.indices.dropFirst()) }

    func value(row: Int, column: Int) -> String {
        let cells = rows[row]
        return column < cells.count ? cells[column] : ""
    }

    private static func directive(in text: String) -> (delimiter: Delimiter, body: Substring)? {
        guard text.hasPrefix(separatorDirective) else { return nil }
        let rest = text.dropFirst(separatorDirective.count)
        guard let ascii = rest.first?.asciiValue, let delimiter = Delimiter(rawValue: ascii) else { return nil }
        let body = rest.dropFirst()
        if body.isEmpty { return (delimiter, body) }
        guard let lineBreak = body.first, lineBreaks.contains(lineBreak) else { return nil }
        return (delimiter, body.dropFirst())
    }

    // Same field rule as parsing; capped.
    private static func firstRecordWidth(_ bytes: [UInt8], separator: UInt8) -> Int {
        var index = 0
        var fields = 0
        while fields <= maximumColumns {
            index = readField(bytes, from: index, separator: separator).end
            fields += 1
            guard index < bytes.count, bytes[index] == separator else { break }
            index += 1
        }
        return fields
    }

    static func parse(
        _ text: some StringProtocol, delimiter: Delimiter, maximumDataRows: Int = maximumDataRows,
        maximumColumns: Int = maximumColumns
    ) throws -> Self {
        let bytes = Array(text.utf8)
        let separator = delimiter.rawValue
        var rows: [[String]] = []
        var record: [String] = []
        var columnsClipped = false
        var rowsClipped = false
        var index = 0
        while !bytes.isEmpty {
            let field = readField(bytes, from: index, separator: separator)
            index = field.end
            if record.count < maximumColumns {
                record.append(field.value)
            } else {
                columnsClipped = true
            }
            if index < bytes.count, bytes[index] == separator {
                index += 1
                continue
            }
            rows.append(record)
            record = []
            if index < bytes.count {
                let pairedLineFeed =
                    bytes[index] == carriageReturn && index + 1 < bytes.count && bytes[index + 1] == lineFeed
                index += pairedLineFeed ? 2 : 1
            }
            if index >= bytes.count { break }
            if rows.count > maximumDataRows {
                rowsClipped = true
                break
            }
            if rows.count.isMultiple(of: cancellationStride) { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        let columnCount = rows.map(\.count).max() ?? 0
        let numeric = try (0..<columnCount).filter { column in
            try Task.checkCancellation()
            return isNumeric(column: column, rows: rows)
        }
        return Self(
            rows: rows, columnCount: columnCount, rowsClipped: rowsClipped, columnsClipped: columnsClipped,
            numericColumns: Set(numeric))
    }

    private static func readField(_ bytes: [UInt8], from start: Int, separator: UInt8) -> (value: String, end: Int) {
        func endsField(_ byte: UInt8) -> Bool { byte == separator || byte == lineFeed || byte == carriageReturn }
        var index = start
        guard index < bytes.count, bytes[index] == quote else {
            while index < bytes.count, !endsField(bytes[index]) { index += 1 }
            return (String(decoding: bytes[start..<index], as: UTF8.self), index)
        }
        var unescaped: [UInt8] = []
        index += 1
        var chunkStart = index
        while index < bytes.count {
            guard bytes[index] == quote else {
                index += 1
                continue
            }
            unescaped += bytes[chunkStart..<index]
            if index + 1 < bytes.count, bytes[index + 1] == quote {
                unescaped.append(quote)
                index += 2
                chunkStart = index
                continue
            }
            index += 1
            chunkStart = index
            // Text after a closing quote stays.
            while index < bytes.count, !endsField(bytes[index]) { index += 1 }
            break
        }
        unescaped += bytes[chunkStart..<index]
        return (String(decoding: unescaped, as: UTF8.self), index)
    }

    // Double also accepts hex, nan and inf.
    static func number(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard isDecimal(Array(trimmed.utf8)), let parsed = Double(trimmed), parsed.isFinite else { return nil }
        return parsed
    }

    private static func isDecimal(_ bytes: [UInt8]) -> Bool {
        var index = 0
        func skip(_ allowed: ClosedRange<UInt8>) -> Int {
            let start = index
            while index < bytes.count, allowed.contains(bytes[index]) { index += 1 }
            return index - start
        }
        func skipSign() {
            if index < bytes.count, bytes[index] == plus || bytes[index] == minus { index += 1 }
        }
        skipSign()
        var digits = skip(asciiDigits)
        if index < bytes.count, bytes[index] == decimalPoint {
            index += 1
            digits += skip(asciiDigits)
        }
        guard digits > 0 else { return false }
        if index < bytes.count, bytes[index] | lowercaseBit == exponent {
            index += 1
            skipSign()
            guard skip(asciiDigits) > 0 else { return false }
        }
        return index == bytes.count
    }

    private static func isNumeric(column: Int, rows: [[String]]) -> Bool {
        var sawNumber = false
        for row in rows.dropFirst() where column < row.count {
            let cell = row[column].trimmingCharacters(in: .whitespaces)
            if cell.isEmpty { continue }
            guard number(cell) != nil else { return false }
            sawNumber = true
        }
        return sawNumber
    }

    // Empty numeric cells sort before numbers.
    func order(sortedBy column: Int, ascending: Bool) throws -> [Int] {
        let numeric = numericColumns.contains(column)
        let keys = fileOrder.map { value(row: $0, column: column) }
        let numbers = numeric ? keys.map(Self.number) : []
        var checked = 0
        let positions = try keys.indices.sorted { left, right in
            checked += 1
            if checked.isMultiple(of: Self.cancellationStride) { try Task.checkCancellation() }
            let comparison: ComparisonResult
            if numeric {
                let (leftNumber, rightNumber) = (numbers[left] ?? -.infinity, numbers[right] ?? -.infinity)
                comparison =
                    leftNumber == rightNumber
                    ? .orderedSame : (leftNumber < rightNumber ? .orderedAscending : .orderedDescending)
            } else {
                comparison = keys[left].localizedStandardCompare(keys[right])
            }
            if comparison == .orderedSame { return left < right }
            return ascending == (comparison == .orderedAscending)
        }
        return positions.map { $0 + 1 }
    }

    func matches(of query: String, in order: [Int]) throws -> [Cell] {
        var found: [Cell] = []
        for (position, row) in order.enumerated() {
            if position.isMultiple(of: Self.cancellationStride) { try Task.checkCancellation() }
            for column in 0..<columnCount {
                let cell = value(row: row, column: column)
                if cell.range(of: query, options: Self.findOptions) != nil {
                    found.append(Cell(position: position, column: column))
                }
            }
        }
        return found
    }

    func copiedText(rows selected: [Int]) -> String {
        selected.map { row in
            (0..<columnCount).map { Self.tabSeparatedField(value(row: row, column: $0)) }.joined(separator: "\t")
        }
        .joined(separator: "\n")
    }

    // Quoted the way spreadsheets write TSV.
    private static func tabSeparatedField(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { fieldBreakingScalars.contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // One line, grapheme-safe; controls stay visible.
    static func displayText(_ raw: String, limit: Int = maximumCellDisplayLength) -> String {
        let bounded = String(String.UnicodeScalarView(raw.unicodeScalars.prefix(limit + 1)))
        let cut = bounded.unicodeScalars.count > limit
        // The last grapheme holds the extra scalar.
        let kept = cut ? bounded[..<bounded.index(before: bounded.endIndex)] : bounded[...]
        let flagged = Set(PreviewInvisibleScanner.flagged(in: kept).map(\.range.location))
        var shown = String.UnicodeScalarView()
        var offset = 0
        for scalar in kept.unicodeScalars {
            shown.append(visible(scalar, flagged: flagged.contains(offset)))
            offset += scalar.utf16.count
        }
        if cut { shown.append(ellipsis) }
        return String(shown)
    }

    // Cells are single lines; breaks show.
    private static func visible(_ scalar: Unicode.Scalar, flagged: Bool) -> Unicode.Scalar {
        switch scalar.value {
        case 0x00...0x1F: return controlPictures[Int(scalar.value)]
        case 0x7F: return deletePicture
        default: return flagged ? replacement : scalar
        }
    }
}
