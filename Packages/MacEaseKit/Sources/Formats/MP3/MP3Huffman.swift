import Foundation

/// One granule's side information, one channel.
struct GranuleSide {
    var part23Length = 0
    var bigValues = 0
    var globalGain = 210
    var scalefacCompress = 0
    var blockType = BlockType.normal
    var tableSelect = [0, 0, 0]
    var region0Count = 0
    var region1Count = 0
    var preflag = false
    var scalefacScale = false
    var count1TableB = false
}

/// Huffman coding in coding order.
enum MP3Huffman {
    struct Plan {
        var bigValues: Int
        var count1End: Int
        var tableSelect: [Int]
        var region0Count: Int
        var region1Count: Int
        var count1TableB: Bool
        var bits: Int
    }

    /// Escape tables share code tables.
    private static let codeTables: [MP3Tables.HuffmanTable?] = (0..<32).map { number in
        switch number {
        case 16...23: MP3Tables.huffman[16]
        case 24...31: MP3Tables.huffman[24]
        default: MP3Tables.huffman[number]
        }
    }
    private static let linbits: [Int] = (0..<32).map { MP3Constants.linbits[$0] ?? 0 }
    private static let plainTables = MP3Constants.tableLimits
    private static let unusable = 1 << 24
    private static let switchedRegionEnd = 36
    private static let quadrupleB = MP3Tables.HuffmanTable(
        size: 16, codes: (0..<16).map { UInt32(15 - $0) }, lengths: [UInt8](repeating: 4, count: 16)
    )

    /// Where big values and count1 regions end.
    static func regions(_ lines: [Int]) -> (bigValueEnd: Int, count1End: Int) {
        var end = lines.count
        while end > 1, lines[end - 1] == 0, lines[end - 2] == 0 { end -= 2 }
        var start = end
        while start > 3, abs(lines[start - 1]) <= 1, abs(lines[start - 2]) <= 1, abs(lines[start - 3]) <= 1,
            abs(lines[start - 4]) <= 1
        {
            start -= 4
        }
        return (start, end)
    }

    /// Running costs make region queries O(1).
    private struct CostTable {
        var plain: [[Int]]
        var escapeBase: [[Int]]
        var escapes: [Int]
        var nonzero: [Int]
        let lines: [Int]

        init(_ lines: [Int], pairs: Int) {
            self.lines = lines
            plain = [[Int]](repeating: [Int](repeating: 0, count: pairs + 1), count: plainTables.count)
            escapeBase = [[Int]](repeating: [Int](repeating: 0, count: pairs + 1), count: 2)
            escapes = [Int](repeating: 0, count: pairs + 1)
            nonzero = [Int](repeating: 0, count: pairs + 1)
            for pair in 0..<pairs {
                let x = abs(lines[2 * pair])
                let y = abs(lines[2 * pair + 1])
                let signs = (x != 0 ? 1 : 0) + (y != 0 ? 1 : 0)
                let largest = max(x, y)
                for (slot, entry) in plainTables.enumerated() {
                    var cost = unusable
                    if largest <= entry.limit, let table = codeTables[entry.table] {
                        cost = Int(table.lengths[x * table.size + y]) + signs
                    }
                    plain[slot][pair + 1] = plain[slot][pair] + cost
                }
                let clippedX = min(x, 15)
                let clippedY = min(y, 15)
                for (slot, number) in [16, 24].enumerated() {
                    guard let table = codeTables[number] else { continue }
                    let cost = Int(table.lengths[clippedX * table.size + clippedY]) + signs
                    escapeBase[slot][pair + 1] = escapeBase[slot][pair] + cost
                }
                escapes[pair + 1] = escapes[pair] + (x >= 15 ? 1 : 0) + (y >= 15 ? 1 : 0)
                nonzero[pair + 1] = nonzero[pair] + (largest > 0 ? 1 : 0)
            }
        }

        func best(_ pairs: Range<Int>) -> (table: Int, bits: Int) {
            // All-zero regions use table 0, costing nothing.
            guard nonzero[pairs.upperBound] > nonzero[pairs.lowerBound] else { return (0, 0) }
            var best = (table: 0, bits: Int.max)
            for (slot, entry) in plainTables.enumerated() {
                let bits = plain[slot][pairs.upperBound] - plain[slot][pairs.lowerBound]
                if bits < best.bits { best = (entry.table, bits) }
            }
            guard best.bits >= unusable else { return best }
            var largest = 0
            for line in (2 * pairs.lowerBound)..<(2 * pairs.upperBound) { largest = max(largest, abs(lines[line])) }
            let escapeCount = escapes[pairs.upperBound] - escapes[pairs.lowerBound]
            best = (table: 0, bits: Int.max)
            for (slot, family) in [16...23, 24...31].enumerated() {
                guard let number = family.first(where: { (1 << MP3Huffman.linbits[$0]) > largest - 15 }) else {
                    continue
                }
                let bits =
                    escapeBase[slot][pairs.upperBound] - escapeBase[slot][pairs.lowerBound]
                    + escapeCount * MP3Huffman.linbits[number]
                if bits < best.bits { best = (number, bits) }
            }
            return best
        }
    }

    static func count1Bits(_ lines: [Int], from start: Int, to end: Int) -> (bits: Int, tableB: Bool) {
        var bitsA = 0
        var bitsB = 0
        var index = start
        while index < end {
            let value = quadrupleValue(lines, index)
            let signs =
                (lines[index] != 0 ? 1 : 0) + (lines[index + 1] != 0 ? 1 : 0) + (lines[index + 2] != 0 ? 1 : 0)
                + (lines[index + 3] != 0 ? 1 : 0)
            bitsA += Int(MP3Tables.quadrupleA.lengths[value]) + signs
            bitsB += 4 + signs
            index += 4
        }
        return bitsA <= bitsB ? (bitsA, false) : (bitsB, true)
    }

    private static func quadrupleValue(_ lines: [Int], _ index: Int) -> Int {
        (abs(lines[index]) << 3) | (abs(lines[index + 1]) << 2) | (abs(lines[index + 2]) << 1) | abs(lines[index + 3])
    }

    /// One heuristic split; never below optimal.
    static func estimate(_ lines: [Int], longBands: [Int], windowSwitching: Bool) -> Int {
        let (bigValueEnd, count1End) = regions(lines)
        var bits = count1Bits(lines, from: bigValueEnd, to: count1End).bits
        let boundaries: [Int]
        if windowSwitching {
            boundaries = [min(switchedRegionEnd, bigValueEnd), bigValueEnd]
        } else {
            let first = longBands.firstIndex { $0 >= bigValueEnd / 4 } ?? 1
            let second = longBands.firstIndex { $0 >= bigValueEnd / 2 } ?? 2
            let region0 = min(max(first - 1, 0), 15)
            let region1 = min(max(second - region0 - 2, 0), 7)
            boundaries = [
                min(longBands[region0 + 1], bigValueEnd),
                min(longBands[min(region0 + region1 + 2, longBands.count - 1)], bigValueEnd), bigValueEnd,
            ]
        }
        var start = 0
        for end in boundaries {
            bits += regionBits(lines, start..<end)
            start = end
        }
        return bits
    }

    private static func regionBits(_ lines: [Int], _ range: Range<Int>) -> Int {
        guard !range.isEmpty else { return 0 }
        var largest = 0
        for line in range { largest = max(largest, abs(lines[line])) }
        guard largest > 0 else { return 0 }
        let candidates: [Int]
        if largest <= 15 {
            candidates = plainTables.filter { $0.limit >= largest }.prefix(3).map(\.table)
        } else {
            candidates = [16...23, 24...31].compactMap { family in
                family.first { (1 << linbits[$0]) > largest - 15 }
            }
        }
        var best = Int.max
        lines.withUnsafeBufferPointer { values in
            for number in candidates {
                guard let table = codeTables[number] else { continue }
                let extra = linbits[number]
                let size = table.size
                table.lengths.withUnsafeBufferPointer { lengths in
                    var bits = 0
                    var line = range.lowerBound
                    while line < range.upperBound {
                        let x = abs(values[line])
                        let y = abs(values[line + 1])
                        bits += Int(lengths[min(x, 15) * size + min(y, 15)])
                        bits += (x != 0 ? 1 : 0) + (y != 0 ? 1 : 0) + (x >= 15 ? extra : 0) + (y >= 15 ? extra : 0)
                        line += 2
                    }
                    best = min(best, bits)
                }
            }
        }
        return best
    }

    /// All splits; switched windows split fixed.
    static func plan(_ lines: [Int], longBands: [Int], windowSwitching: Bool) -> Plan {
        let (bigValueEnd, count1End) = regions(lines)
        let count1 = count1Bits(lines, from: bigValueEnd, to: count1End)
        let pairs = bigValueEnd / 2
        let costs = CostTable(lines, pairs: pairs)
        var best = Plan(
            bigValues: pairs, count1End: count1End, tableSelect: [0, 0, 0], region0Count: 7,
            region1Count: 13, count1TableB: count1.tableB, bits: Int.max
        )
        if windowSwitching {
            let split = min(switchedRegionEnd / 2, pairs)
            let first = costs.best(0..<split)
            let second = costs.best(split..<pairs)
            best.tableSelect = [first.table, second.table, 0]
            best.bits = first.bits + second.bits + count1.bits
            return best
        }
        for region0Count in 0..<16 {
            let end0 = min(longBands[region0Count + 1] / 2, pairs)
            let first = costs.best(0..<end0)
            for region1Count in 0..<8 where region0Count + region1Count + 2 < longBands.count {
                let end1 = min(longBands[region0Count + region1Count + 2] / 2, pairs)
                let second = costs.best(end0..<end1)
                let third = costs.best(end1..<pairs)
                let bits = first.bits + second.bits + third.bits + count1.bits
                if bits < best.bits {
                    best.bits = bits
                    best.tableSelect = [first.table, second.table, third.table]
                    best.region0Count = region0Count
                    best.region1Count = region1Count
                }
            }
        }
        return best
    }

    static func write(
        _ lines: [Int], plan: Plan, longBands: [Int], windowSwitching: Bool, into writer: inout MSBBitWriter
    ) {
        let bigValueEnd = plan.bigValues * 2
        let boundaries: [Int]
        if windowSwitching {
            boundaries = [min(switchedRegionEnd, bigValueEnd), bigValueEnd, bigValueEnd]
        } else {
            let end0 = min(longBands[plan.region0Count + 1], bigValueEnd)
            let end1 = min(longBands[min(plan.region0Count + plan.region1Count + 2, longBands.count - 1)], bigValueEnd)
            boundaries = [end0, end1, bigValueEnd]
        }
        var index = 0
        for region in 0..<3 {
            let table = plan.tableSelect[region]
            while index < boundaries[region] {
                writePair(lines[index], lines[index + 1], table: table, into: &writer)
                index += 2
            }
        }
        let quadruple = plan.count1TableB ? quadrupleB : MP3Tables.quadrupleA
        index = bigValueEnd
        while index < plan.count1End {
            let value = quadrupleValue(lines, index)
            writer.write(quadruple.codes[value], bits: Int(quadruple.lengths[value]))
            for offset in 0..<4 where lines[index + offset] != 0 {
                writer.write(lines[index + offset] < 0 ? 1 : 0, bits: 1)
            }
            index += 4
        }
    }

    private static func writePair(_ x: Int, _ y: Int, table: Int, into writer: inout MSBBitWriter) {
        guard table != 0, let huffman = codeTables[table] else { return }
        let linbits = linbits[table]
        let entry = min(abs(x), 15) * huffman.size + min(abs(y), 15)
        writer.write(huffman.codes[entry], bits: Int(huffman.lengths[entry]))
        if linbits > 0, abs(x) >= 15 { writer.write(UInt32(abs(x) - 15), bits: linbits) }
        if x != 0 { writer.write(x < 0 ? 1 : 0, bits: 1) }
        if linbits > 0, abs(y) >= 15 { writer.write(UInt32(abs(y) - 15), bits: linbits) }
        if y != 0 { writer.write(y < 0 ? 1 : 0, bits: 1) }
    }
}
