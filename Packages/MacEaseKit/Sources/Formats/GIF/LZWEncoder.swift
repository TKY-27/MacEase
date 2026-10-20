/// GIF variant of LZW (GIF89a appendix F).
struct LZWEncoder {
    private static let maximumCode = 4095

    private let clearCode: Int
    private let minimumCodeSize: Int
    private var writer = BitWriter()
    private var table = CodeTable()
    private var monitor = ClearMonitor()
    private var codeSize: Int
    private var lastAssigned: Int
    private var consumed = 0
    /// Code of the string matched so far.
    private var current: Int?

    init(minimumCodeSize: Int) {
        self.minimumCodeSize = minimumCodeSize
        clearCode = 1 << minimumCodeSize
        codeSize = minimumCodeSize + 1
        lastAssigned = clearCode + 1
        writer.write(clearCode, bits: codeSize)
    }

    /// Visits symbols extending the current string.
    func forEachExtension(_ body: (UInt8) -> Void) {
        guard let current else { return }
        table.forEachChild(of: current, body)
    }

    mutating func append(_ symbol: UInt8) {
        consumed += 1
        guard let prefix = current else {
            current = Int(symbol)
            return
        }
        if let extended = table.code(prefix: prefix, symbol: symbol) {
            current = extended
            return
        }
        writer.write(prefix, bits: codeSize)
        if lastAssigned < Self.maximumCode {
            lastAssigned += 1
            table.insert(prefix: prefix, symbol: symbol, code: lastAssigned)
            if lastAssigned >= 1 << codeSize, codeSize < 12 { codeSize += 1 }
            if lastAssigned == Self.maximumCode { monitor.tableFilled(at: writer.bitCount, symbols: consumed) }
        } else if monitor.shouldClear(at: writer.bitCount, symbols: consumed) {
            writer.write(clearCode, bits: codeSize)
            table.reset()
            codeSize = minimumCodeSize + 1
            lastAssigned = clearCode + 1
            monitor = ClearMonitor()
        }
        current = Int(symbol)
    }

    mutating func finish() -> [UInt8] {
        if let current {
            writer.write(current, bits: codeSize)
            // The decoder adds an entry, maybe widening.
            if lastAssigned < Self.maximumCode, lastAssigned + 1 == 1 << codeSize, codeSize < 12 { codeSize += 1 }
        }
        writer.write(clearCode + 1, bits: codeSize)
        return writer.finish()
    }
}

/// Clears a full table once compression degrades.
private struct ClearMonitor {
    private static let window = 2048
    private var fillRatio: Double?
    private var windowStart = (bits: 0, symbols: 0)

    mutating func tableFilled(at bits: Int, symbols: Int) {
        fillRatio = Double(bits) / Double(max(symbols, 1))
        windowStart = (bits, symbols)
    }

    mutating func shouldClear(at bits: Int, symbols: Int) -> Bool {
        guard let fillRatio, symbols - windowStart.symbols >= Self.window else { return false }
        let recent = Double(bits - windowStart.bits) / Double(symbols - windowStart.symbols)
        windowStart = (bits, symbols)
        return recent > fillRatio
    }
}

/// Generation-stamped table, so clearing costs nothing.
private struct CodeTable {
    private static let size = 1 << 20
    private var codes = [Int16](repeating: 0, count: size)
    private var stamps = [UInt32](repeating: 0, count: size)
    private var firstChild = [Int16](repeating: -1, count: 4096)
    private var nextSibling = [Int16](repeating: -1, count: 4096)
    private var symbolOf = [UInt8](repeating: 0, count: 4096)
    private var childStamp = [UInt32](repeating: 0, count: 4096)
    private var generation: UInt32 = 1

    func code(prefix: Int, symbol: UInt8) -> Int? {
        let key = prefix << 8 | Int(symbol)
        return stamps[key] == generation ? Int(codes[key]) : nil
    }

    func forEachChild(of prefix: Int, _ body: (UInt8) -> Void) {
        guard childStamp[prefix] == generation else { return }
        var child = Int(firstChild[prefix])
        while child >= 0 {
            body(symbolOf[child])
            child = Int(nextSibling[child])
        }
    }

    mutating func insert(prefix: Int, symbol: UInt8, code: Int) {
        let key = prefix << 8 | Int(symbol)
        codes[key] = Int16(code)
        stamps[key] = generation
        symbolOf[code] = symbol
        nextSibling[code] = childStamp[prefix] == generation ? firstChild[prefix] : -1
        firstChild[prefix] = Int16(code)
        childStamp[prefix] = generation
    }

    mutating func reset() {
        generation += 1
    }
}

private struct BitWriter {
    private var bytes: [UInt8] = []
    private var accumulator = 0
    private var count = 0

    var bitCount: Int { bytes.count * 8 + count }

    mutating func write(_ code: Int, bits: Int) {
        accumulator |= code << count
        count += bits
        while count >= 8 {
            bytes.append(UInt8(accumulator & 0xFF))
            accumulator >>= 8
            count -= 8
        }
    }

    mutating func finish() -> [UInt8] {
        if count > 0 { bytes.append(UInt8(accumulator & 0xFF)) }
        return bytes
    }
}
