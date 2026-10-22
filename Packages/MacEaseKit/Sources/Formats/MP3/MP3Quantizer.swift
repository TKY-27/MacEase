import Foundation

/// ISO 11172-3 C.1.5.4 rate and distortion loops.
struct GranuleQuantizer {
    struct Result {
        var side: GranuleSide
        var lines: [Int]
        var scalefactors: [Int]
        var plan: MP3Huffman.Plan
        var part2Bits: Int
        var totalBits: Int { part2Bits + plan.bits }
    }

    /// More iterations shape noise but cost speed.
    private static let maximumIterations = 8
    private static let coarseningSteps = 6
    private static let maximumPart23 = 4095
    private static let power43: [Double] = (0...MP3Constants.maximumQuantized).map { pow(Double($0), 4.0 / 3.0) }
    private static let rounding = 0.4054
    private static let overflowLimit = Double(MP3Constants.maximumQuantized + 1)

    private let blockType: BlockType
    private let tables: MP3Constants.RateTables
    /// Lines in Huffman coding order.
    private let magnitudes: [Double]
    private let signs: [Bool]
    private let magnitudes34: [Double]
    private let bandRanges: [Range<Int>]
    private let allowedNoise: [Double]

    /// 21 long or 36 short-window bands.
    init(spectrum: [Double], blockType: BlockType, tables: MP3Constants.RateTables, allowedNoise: [Double]) {
        self.blockType = blockType
        self.tables = tables
        var ordered = spectrum
        var ranges: [Range<Int>] = []
        if blockType == .short {
            var position = 0
            for band in 0..<(tables.shortBands.count - 1) {
                let lines = tables.shortBands[band]..<tables.shortBands[band + 1]
                for window in 0..<3 {
                    ranges.append(position..<(position + lines.count))
                    for line in lines {
                        ordered[position] = spectrum[HybridTransform.shortIndex(line: line, window: window)]
                        position += 1
                    }
                }
            }
        } else {
            for band in 0..<(tables.longBands.count - 1) {
                ranges.append(tables.longBands[band]..<tables.longBands[band + 1])
            }
        }
        magnitudes = ordered.map(abs)
        signs = ordered.map { $0 < 0 }
        magnitudes34 = magnitudes.map { pow($0, 0.75) }
        bandRanges = ranges
        self.allowedNoise = allowedNoise
    }

    private var scaledBandCount: Int { blockType == .short ? 36 : 21 }

    private func exponent(band: Int, globalGain: Int, scalefactors: [Int]) -> Double {
        let scalefactor = band < scaledBandCount ? Double(scalefactors[band]) : 0
        return 0.25 * Double(globalGain - 210) - 0.5 * scalefactor
    }

    /// `nil` on Huffman range overflow.
    private func quantize(globalGain: Int, scalefactors: [Int]) -> [Int]? {
        var lines = [Int](repeating: 0, count: magnitudes.count)
        var overflow = false
        lines.withUnsafeMutableBufferPointer { output in
            magnitudes34.withUnsafeBufferPointer { input in
                signs.withUnsafeBufferPointer { negative in
                    for (band, range) in bandRanges.enumerated() {
                        let power = exponent(band: band, globalGain: globalGain, scalefactors: scalefactors)
                        let multiplier = pow(2, -0.75 * power)
                        for line in range {
                            let scaled = input[line] * multiplier + Self.rounding
                            guard scaled < Self.overflowLimit else {
                                overflow = true
                                return
                            }
                            let value = Int(scaled)
                            output[line] = negative[line] ? -value : value
                        }
                    }
                }
            }
        }
        return overflow ? nil : lines
    }

    private func noise(_ lines: [Int], globalGain: Int, scalefactors: [Int]) -> [Double] {
        lines.withUnsafeBufferPointer { quantized in
            magnitudes.withUnsafeBufferPointer { original in
                Self.power43.withUnsafeBufferPointer { power43 in
                    bandRanges.enumerated().map { band, range in
                        let step = pow(2, exponent(band: band, globalGain: globalGain, scalefactors: scalefactors))
                        var sum = 0.0
                        for line in range {
                            let error = original[line] - power43[abs(quantized[line])] * step
                            sum += error * error
                        }
                        return sum
                    }
                }
            }
        }
    }

    private func scalefactorBits(_ scalefactors: [Int]) -> (compress: Int, bits: Int)? {
        let split = blockType == .short ? 18 : 11
        let firstLimit = scalefactors[..<split].max() ?? 0
        let secondLimit = scalefactors[split..<scaledBandCount].max() ?? 0
        let firstCount = blockType == .short ? 18 : 11
        let secondCount = blockType == .short ? 18 : 10
        var best: (compress: Int, bits: Int)?
        for (compress, widths) in MP3Constants.slen.enumerated()
        where (1 << widths.0) > firstLimit && (1 << widths.1) > secondLimit {
            let bits = widths.0 * firstCount + widths.1 * secondCount
            if bits < best?.bits ?? .max { best = (compress, bits) }
        }
        return best
    }

    private func attempt(gain: Int, scalefactors: [Int], part2Bits: Int, budget: Int) -> [Int]? {
        guard let lines = quantize(globalGain: gain, scalefactors: scalefactors) else { return nil }
        let bits = MP3Huffman.estimate(lines, longBands: tables.longBands, windowSwitching: blockType != .normal)
        return bits + part2Bits <= budget ? lines : nil
    }

    /// Finest fitting quantization, searched from `hint`.
    private func innerLoop(budget: Int, scalefactors: [Int], part2Bits: Int, hint: Int?) -> (gain: Int, lines: [Int])? {
        if let hint {
            if let fitting = attempt(gain: hint, scalefactors: scalefactors, part2Bits: part2Bits, budget: budget) {
                var found = (gain: hint, lines: fitting)
                var gain = hint - 1
                while gain >= 0,
                    let finer = attempt(gain: gain, scalefactors: scalefactors, part2Bits: part2Bits, budget: budget)
                {
                    found = (gain, finer)
                    gain -= 1
                }
                return found
            }
            for gain in (hint + 1)...255 {
                if let coarser = attempt(gain: gain, scalefactors: scalefactors, part2Bits: part2Bits, budget: budget) {
                    return (gain, coarser)
                }
            }
            return nil
        }
        var low = 0
        var high = 255
        var found: (gain: Int, lines: [Int])?
        while low <= high {
            let gain = (low + high) / 2
            if let fitting = attempt(gain: gain, scalefactors: scalefactors, part2Bits: part2Bits, budget: budget) {
                found = (gain, fitting)
                high = gain - 1
            } else {
                low = gain + 1
            }
        }
        return found
    }

    func encode(budget: Int) throws -> Result {
        let limit = min(budget, Self.maximumPart23)
        var scalefactors = [Int](repeating: 0, count: scaledBandCount)
        var best: (gain: Int, compress: Int, scalefactors: [Int], lines: [Int], part2Bits: Int)?
        var bestScore = Double.infinity
        var hint: Int?
        for _ in 0..<Self.maximumIterations {
            guard let (compress, part2Bits) = scalefactorBits(scalefactors),
                let (gain, lines) = innerLoop(
                    budget: limit, scalefactors: scalefactors, part2Bits: part2Bits, hint: hint
                )
            else { break }
            hint = gain
            let bandNoise = noise(lines, globalGain: gain, scalefactors: scalefactors)
            var score = 0.0
            var violating: [Int] = []
            for band in 0..<scaledBandCount where bandNoise[band] > allowedNoise[band] {
                score += 10 * log10(bandNoise[band] / max(allowedNoise[band], 1e-20))
                violating.append(band)
            }
            if score < bestScore {
                bestScore = score
                best = (gain, compress, scalefactors, lines, part2Bits)
            }
            guard !violating.isEmpty, violating.count < scaledBandCount else { break }
            for band in violating { scalefactors[band] += 1 }
        }
        guard let best else { throw FormatError.encoderFailure("no quantization fits \(limit) bits") }
        let plan = MP3Huffman.plan(best.lines, longBands: tables.longBands, windowSwitching: blockType != .normal)
        return result(
            gain: best.gain, compress: best.compress, scalefactors: best.scalefactors, lines: best.lines, plan: plan,
            part2Bits: best.part2Bits
        )
    }

    /// Coarsest quantization meeting every threshold.
    func encodeForQuality() throws -> Result {
        let zeros = [Int](repeating: 0, count: scaledBandCount)
        var low = 0
        var high = 255
        var coarsest: Int?
        while low <= high {
            let gain = (low + high) / 2
            guard let lines = quantize(globalGain: gain, scalefactors: zeros) else {
                low = gain + 1
                continue
            }
            if violations(lines, gain: gain, scalefactors: zeros) == 0 {
                coarsest = gain
                low = gain + 1
            } else {
                high = gain - 1
            }
        }
        guard let start = coarsest else { return try encode(budget: Self.maximumPart23) }
        var best: Result?
        for gain in start...min(255, start + Self.coarseningSteps) {
            guard let scalefactors = minimalScalefactors(gain: gain),
                let (compress, part2Bits) = scalefactorBits(scalefactors),
                let lines = quantize(globalGain: gain, scalefactors: scalefactors)
            else { break }
            let plan = MP3Huffman.plan(lines, longBands: tables.longBands, windowSwitching: blockType != .normal)
            let candidate = result(
                gain: gain, compress: compress, scalefactors: scalefactors, lines: lines, plan: plan,
                part2Bits: part2Bits)
            if candidate.totalBits < best?.totalBits ?? .max { best = candidate }
        }
        guard let best, best.totalBits <= Self.maximumPart23 else { return try encode(budget: Self.maximumPart23) }
        return best
    }

    private func violations(_ lines: [Int], gain: Int, scalefactors: [Int]) -> Int {
        let bandNoise = noise(lines, globalGain: gain, scalefactors: scalefactors)
        return (0..<scaledBandCount).filter { bandNoise[$0] > allowedNoise[$0] }.count
    }

    /// Least amplification meeting each band's threshold.
    private func minimalScalefactors(gain: Int) -> [Int]? {
        var scalefactors = [Int](repeating: 0, count: scaledBandCount)
        let split = blockType == .short ? 18 : 11
        for band in 0..<scaledBandCount {
            let limit = band < split ? 15 : 7
            var satisfied = false
            for value in 0...limit {
                scalefactors[band] = value
                if bandMeetsThreshold(band, gain: gain, scalefactors: scalefactors) {
                    satisfied = true
                    break
                }
            }
            if !satisfied { return nil }
        }
        return scalefactors
    }

    private func bandMeetsThreshold(_ band: Int, gain: Int, scalefactors: [Int]) -> Bool {
        let power = exponent(band: band, globalGain: gain, scalefactors: scalefactors)
        let multiplier = pow(2, -0.75 * power)
        let step = pow(2, power)
        var sum = 0.0
        for line in bandRanges[band] {
            let scaled = magnitudes34[line] * multiplier + Self.rounding
            guard scaled < Self.overflowLimit else { return false }
            let value = Int(scaled)
            let error = magnitudes[line] - Self.power43[value] * step
            sum += error * error
        }
        return sum <= allowedNoise[band]
    }

    private func result(
        gain: Int,
        compress: Int,
        scalefactors: [Int],
        lines: [Int],
        plan: MP3Huffman.Plan,
        part2Bits: Int
    ) -> Result {
        var side = GranuleSide()
        side.globalGain = gain
        side.scalefacCompress = compress
        side.blockType = blockType
        side.bigValues = plan.bigValues
        side.tableSelect = plan.tableSelect
        side.region0Count = plan.region0Count
        side.region1Count = plan.region1Count
        side.count1TableB = plan.count1TableB
        side.part23Length = part2Bits + plan.bits
        return Result(side: side, lines: lines, scalefactors: scalefactors, plan: plan, part2Bits: part2Bits)
    }

    static func writeScalefactors(_ result: Result, into writer: inout MSBBitWriter) {
        let widths = MP3Constants.slen[result.side.scalefacCompress]
        let split = result.side.blockType == .short ? 18 : 11
        for (band, value) in result.scalefactors.enumerated() {
            writer.write(UInt32(value), bits: band < split ? widths.0 : widths.1)
        }
    }
}
