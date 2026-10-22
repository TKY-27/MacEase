import Accelerate
import Foundation

/// 512-tap polyphase analysis (ISO 11172-3 C.1.3).
struct PolyphaseAnalysis {
    private static let window: [Double] = MP3Tables.synthesisWindow.map { $0 / 32 }
    private static let matrix: [Double] = (0..<32).flatMap { (k: Int) -> [Double] in
        (0..<64).map { (i: Int) -> Double in
            let phase = Double((2 * k + 1) * (i - 16))
            return cos(phase * Double.pi / 64)
        }
    }

    /// Newest sample first, as in the standard.
    private var history = [Double](repeating: 0, count: 512)
    private var windowed = [Double](repeating: 0, count: 512)
    private var folded = [Double](repeating: 0, count: 64)

    /// Consumes 32 samples, returns 32 subband samples.
    mutating func analyze<Samples: RandomAccessCollection>(_ samples: Samples) -> [Double]
    where Samples.Element == Float {
        history.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            (base + 32).update(from: base, count: 480)
            var index = 31
            for sample in samples {
                base[index] = Double(sample)
                index -= 1
            }
        }
        vDSP.multiply(history, Self.window, result: &windowed)
        windowed.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            vDSP.add(
                UnsafeBufferPointer(start: base, count: 64), UnsafeBufferPointer(start: base + 64, count: 64),
                result: &folded)
            for block in 2..<8 {
                vDSP.add(folded, UnsafeBufferPointer(start: base + 64 * block, count: 64), result: &folded)
            }
        }
        var output = [Double](repeating: 0, count: 32)
        vDSP_mmulD(Self.matrix, 1, folded, 1, &output, 1, 32, 1, 64)
        return output
    }
}

enum BlockType: Int {
    case normal = 0
    case start = 1
    case short = 2
    case stop = 3
}

/// MDCT, window switching, alias reduction (C.1.5.3).
enum HybridTransform {
    private static let longWindows: [[Double]] = {
        let sine36 = (0..<36).map { sin(Double.pi / 36 * (Double($0) + 0.5)) }
        let sine12 = (0..<12).map { sin(Double.pi / 12 * (Double($0) + 0.5)) }
        let start = (0..<36).map { n -> Double in
            switch n {
            case 0..<18: sine36[n]
            case 18..<24: 1
            case 24..<30: sine12[n - 18]
            default: 0
            }
        }
        let stop = (0..<36).map { n -> Double in
            switch n {
            case 0..<6: 0
            case 6..<12: sine12[n - 6]
            case 12..<18: 1
            default: sine36[n]
            }
        }
        return [sine36, start, sine36, stop]
    }()

    private static let shortWindow = (0..<12).map { sin(Double.pi / 12 * (Double($0) + 0.5)) }

    /// Scale 2/M matches the decoder's IMDCT.
    private static let longBasis = basis(coefficients: 18, offset: 19)
    private static let shortBasis = basis(coefficients: 6, offset: 7)

    private static func basis(coefficients: Int, offset: Int) -> [Double] {
        let length = 2 * coefficients
        let scale = 2 / Double(coefficients)
        var values: [Double] = []
        for k in 0..<coefficients {
            for n in 0..<length {
                let angle = Double.pi / Double(2 * length) * Double(2 * n + offset) * Double(2 * k + 1)
                values.append(cos(angle) * scale)
            }
        }
        return values
    }

    /// Inputs are 18 slots of 32 subbands.
    static func transform(previous: [[Double]], current: [[Double]], blockType: BlockType) -> [Double] {
        var output = [Double](repeating: 0, count: MP3Constants.granuleSize)
        var input = [Double](repeating: 0, count: 36)
        for subband in 0..<32 {
            for slot in 0..<18 {
                let invert = subband % 2 == 1 && slot % 2 == 1
                input[slot] = invert ? -previous[slot][subband] : previous[slot][subband]
                input[slot + 18] = invert ? -current[slot][subband] : current[slot][subband]
            }
            let base = subband * 18
            if blockType == .short {
                for window in 0..<3 {
                    for k in 0..<6 {
                        var sum = 0.0
                        for n in 0..<12 {
                            sum += input[6 + 6 * window + n] * shortWindow[n] * shortBasis[k * 12 + n]
                        }
                        output[base + 3 * k + window] = sum
                    }
                }
            } else {
                let window = longWindows[blockType.rawValue]
                for k in 0..<18 {
                    var sum = 0.0
                    for n in 0..<36 { sum += input[n] * window[n] * longBasis[k * 36 + n] }
                    output[base + k] = sum
                }
            }
        }
        if blockType != .short { reduceAliasing(&output) }
        return output
    }

    private static func reduceAliasing(_ spectrum: inout [Double]) {
        for subband in 1..<32 {
            for (index, coefficient) in MP3Constants.aliasCoefficients.enumerated() {
                let lower = subband * 18 - 1 - index
                let upper = subband * 18 + index
                let a = spectrum[lower]
                let b = spectrum[upper]
                spectrum[lower] = a * coefficient.cs + b * coefficient.ca
                spectrum[upper] = b * coefficient.cs - a * coefficient.ca
            }
        }
    }

    /// Index of short-block line `line` in `window`.
    static func shortIndex(line: Int, window: Int) -> Int {
        (line / 6) * 18 + 3 * (line % 6) + window
    }
}
