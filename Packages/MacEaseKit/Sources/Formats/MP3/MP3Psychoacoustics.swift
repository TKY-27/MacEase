import Foundation

/// Per-band masking thresholds from MDCT energies.
struct PsychoacousticModel {
    /// A full-scale sine counts as 96 dB.
    private static let fullScaleLevel = 96.0
    /// Thresholds may at most double per granule.
    private static let preEchoGrowth = 2.0

    private let sampleRate: Int
    private let tables: MP3Constants.RateTables
    private let longBarks: [Double]
    private let shortBarks: [Double]
    private let longSpreading: [[Double]]
    private let shortSpreading: [[Double]]
    private let longQuiet: [Double]
    private let shortQuiet: [Double]
    private var previousLong: [Double]?

    init(sampleRate: Int, tables: MP3Constants.RateTables, fullScaleEnergy: Double) {
        self.sampleRate = sampleRate
        self.tables = tables
        let lineWidth = Double(sampleRate) / 2 / 576
        let shortLineWidth = Double(sampleRate) / 2 / 192
        func centers(_ bands: [Int], width: Double) -> [Double] {
            (0..<(bands.count - 1)).map { Self.bark(Double(bands[$0] + bands[$0 + 1]) / 2 * width) }
        }
        longBarks = centers(tables.longBands, width: lineWidth)
        shortBarks = centers(tables.shortBands, width: shortLineWidth)
        longSpreading = Self.spreadingMatrix(longBarks)
        shortSpreading = Self.spreadingMatrix(shortBarks)
        func quiet(_ bands: [Int], width: Double, energyScale: Double) -> [Double] {
            (0..<(bands.count - 1)).map { band in
                let lines = bands[band]..<bands[band + 1]
                let lowest = lines.map { Self.absoluteThreshold(hertz: (Double($0) + 0.5) * width) }.min() ?? 0
                return energyScale * pow(10, (lowest - Self.fullScaleLevel) / 10) * Double(lines.count)
            }
        }
        longQuiet = quiet(tables.longBands, width: lineWidth, energyScale: fullScaleEnergy)
        // Short transforms carry a third the energy.
        shortQuiet = quiet(tables.shortBands, width: shortLineWidth, energyScale: fullScaleEnergy / 3)
    }

    /// M/S switches change what each slot holds.
    mutating func resetHistory() {
        previousLong = nil
    }

    static func bark(_ hertz: Double) -> Double {
        13 * atan(0.00076 * hertz) + 3.5 * atan(pow(hertz / 7500, 2))
    }

    /// Terhardt's threshold in quiet, in dB SPL.
    static func absoluteThreshold(hertz: Double) -> Double {
        let kilohertz = max(hertz, 20) / 1000
        return min(
            3.64 * pow(kilohertz, -0.8) - 6.5 * exp(-0.6 * pow(kilohertz - 3.3, 2)) + 0.001 * pow(kilohertz, 4), 96)
    }

    private static func spreadingMatrix(_ barks: [Double]) -> [[Double]] {
        barks.map { maskee in
            barks.map { masker in
                let distance = maskee - masker + 0.474
                let decibels = 15.81 + 7.5 * distance - 17.5 * (1 + distance * distance).squareRoot()
                return pow(10, decibels / 10)
            }
        }
    }

    /// Allowed noise energy per band.
    mutating func allowedNoise(_ spectrum: [Double], blockType: BlockType, quality: Double) -> [Double] {
        if blockType == .short {
            var allowed = [Double](repeating: 0, count: 36)
            for window in 0..<3 {
                let energies = (0..<12).map { band in
                    (tables.shortBands[band]..<tables.shortBands[band + 1]).map { line in
                        spectrum[HybridTransform.shortIndex(line: line, window: window)]
                    }
                }
                let thresholds = masking(energies, barks: shortBarks, spreading: shortSpreading, quiet: shortQuiet)
                for band in 0..<12 { allowed[band * 3 + window] = thresholds[band] * quality }
            }
            previousLong = nil
            return allowed
        }
        let lines = (0..<21).map { band in Array(spectrum[tables.longBands[band]..<tables.longBands[band + 1]]) }
        var thresholds = masking(lines, barks: longBarks, spreading: longSpreading, quiet: longQuiet)
        if let previousLong {
            thresholds = zip(thresholds, previousLong).map { min($0, max($1 * Self.preEchoGrowth, $0 / 4)) }
        }
        previousLong = thresholds
        return thresholds.map { $0 * quality }
    }

    private func masking(_ bands: [[Double]], barks: [Double], spreading: [[Double]], quiet: [Double]) -> [Double] {
        let energies = bands.map { $0.reduce(0) { $0 + $1 * $1 } }
        let tonality = bands.map(Self.tonality)
        return energies.indices.map { maskee in
            var spread = 0.0
            for masker in energies.indices { spread += energies[masker] * spreading[maskee][masker] }
            let offset = tonality[maskee] * (14.5 + barks[maskee]) + (1 - tonality[maskee]) * 5.5
            let threshold = spread * pow(10, -offset / 10)
            return max(min(threshold, energies[maskee]), quiet[maskee])
        }
    }

    /// 0 for noise, 1 for pure tones.
    private static func tonality(_ lines: [Double]) -> Double {
        guard lines.count >= 4 else { return 0.5 }
        let powers = lines.map { $0 * $0 + 1e-24 }
        let arithmetic = powers.reduce(0, +) / Double(powers.count)
        let geometric = exp(powers.map { log($0) }.reduce(0, +) / Double(powers.count))
        let flatness = 10 * log10(geometric / arithmetic)
        return min(max(-flatness / 30, 0), 1)
    }
}

/// Flags granules whose high-passed energy jumps sharply.
struct TransientDetector {
    private static let segment = 64
    private static let attackRatio = 10.0
    private static let energyFloor = 1e-6

    private var previousSample: Float = 0
    private var history: [Double] = []

    mutating func hasAttack(_ samples: ArraySlice<Float>) -> Bool {
        var energies: [Double] = []
        var index = samples.startIndex
        while index < samples.endIndex {
            let end = min(index + Self.segment, samples.endIndex)
            var energy = 0.0
            for position in index..<end {
                let highPassed = Double(samples[position] - previousSample)
                previousSample = samples[position]
                energy += highPassed * highPassed
            }
            energies.append(energy)
            index = end
        }
        var attack = false
        for energy in energies {
            let recent = history.suffix(8)
            let average = recent.isEmpty ? energy : recent.reduce(0, +) / Double(recent.count)
            if energy > Self.energyFloor, energy > average * Self.attackRatio { attack = true }
            history.append(energy)
        }
        history = Array(history.suffix(8))
        return attack
    }
}
