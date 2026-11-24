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
    private static let ellipsis: Unicode.Scalar = "\u{2026}"
    private static let replacement: Unicode.Scalar = "\u{FFFD}"
    private static let deletePicture: Unicode.Scalar = "\u{2421}"
    private static let controlPictures: [Unicode.Scalar] = (0x2400...0x241F).compactMap(Unicode.Scalar.init)
    private static let deleteScalar: UInt32 = 0x7F
    // Reordering and invisible line-breaking controls.
    private static let hiddenControls: [ClosedRange<UInt32>] = [
        0x80...0x9F, 0x061C...0x061C, 0x200E...0x200F, 0x2028...0x202E, 0x2066...0x2069,
    ]

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

        // Locale exports often use semicolons or tabs.
        func delimiter(for text: String) -> Delimiter {
            guard self == .commaSeparated else { return .tab }
            var counts: [Delimiter: Int] = [:]
            var quoted = false
            for byte in text.utf8 {
                if byte == PreviewTable.quote {
                    quoted.toggle()
                } else if !quoted, byte == PreviewTable.lineFeed || byte == PreviewTable.carriageReturn {
                    break
                } else if !quoted, let delimiter = Delimiter(rawValue: byte) {
                    counts[delimiter, default: 0] += 1
                }
            }
            // Ties keep the earlier, more common separator.
            return [Delimiter.comma, .semicolon, .tab].reduce(Delimiter.comma) { best, candidate in
                counts[candidate, default: 0] > counts[best, default: 0] ? candidate : best
            }
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

    static func parse(
        _ text: String, delimiter: Delimiter, maximumDataRows: Int = maximumDataRows,
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

    static func number(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let parsed = Double(trimmed), parsed.isFinite else { return nil }
        return parsed
    }

    private static func isNumeric(column: Int, rows: [[String]]) -> Bool {
        var sawNumber = false
        for row in rows.dropFirst() where column < row.count {
            let cell = row[column]
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
            (0..<columnCount).map { value(row: row, column: $0) }.joined(separator: "\t")
        }
        .joined(separator: "\n")
    }

    // Single line; controls stay visible.
    static func displayText(_ raw: String) -> String {
        var shown = String.UnicodeScalarView()
        for (offset, scalar) in raw.unicodeScalars.enumerated() {
            if offset == maximumCellDisplayLength {
                shown.append(ellipsis)
                break
            }
            shown.append(visible(scalar))
        }
        return String(shown)
    }

    private static func visible(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        let value = scalar.value
        if Int(value) < controlPictures.count { return controlPictures[Int(value)] }
        if value == deleteScalar { return deletePicture }
        return hiddenControls.contains { $0.contains(value) } ? replacement : scalar
    }
}
