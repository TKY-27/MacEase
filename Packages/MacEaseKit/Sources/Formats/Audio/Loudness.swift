import Accelerate
import Foundation

/// ITU-R BS.1770-4 loudness and true peak.
public final class LoudnessMeter {
    private static let stepSeconds = 0.1
    private static let stepsPerBlock = 4
    private static let absoluteGate = -70.0
    private static let relativeGate = -10.0
    private static let loudnessOffset = -0.691
    private static let surroundWeight = 1.41
    private static let lowFrequencyChannel = 3
    private static let fiveOneChannels = 6
    private static let fiveChannels = 5
    private static let biquadSections = 2

    private let channels: Int
    private let weights: [Double]
    private let stepFrames: Int
    private let setup: vDSP_biquad_SetupD
    private var delays: [[Double]]
    private var peak = TruePeakDetector()
    private var histories: [[Double]]
    private var stepPower = 0.0
    private var stepFill = 0
    private var stepPowers: [Double] = []
    private var truePeakLinear = 0.0

    public init(sampleRate: Double, channels: Int) throws {
        guard
            let setup = vDSP_biquad_CreateSetupD(
                Self.kWeighting(sampleRate: sampleRate), vDSP_Length(Self.biquadSections))
        else {
            throw FormatError.unsupported("loudness at \(sampleRate) Hz")
        }
        self.setup = setup
        self.channels = channels
        stepFrames = max(1, Int((sampleRate * Self.stepSeconds).rounded()))
        weights = (0..<channels).map { channel in
            switch (channels, channel) {
            case (Self.fiveOneChannels, Self.lowFrequencyChannel): 0
            case (Self.fiveOneChannels, 4...), (Self.fiveChannels, 3...): Self.surroundWeight
            default: 1
            }
        }
        delays = Array(repeating: Array(repeating: 0, count: 2 * Self.biquadSections + 2), count: channels)
        histories = Array(repeating: Array(repeating: 0, count: TruePeakDetector.tapsPerPhase - 1), count: channels)
    }

    deinit {
        vDSP_biquad_DestroySetupD(setup)
    }

    /// Shelf, then high-pass; vDSP coefficient order.
    static func kWeighting(sampleRate: Double) -> [Double] {
        let shelfFrequency = 1681.974450955533
        let shelfGain = 3.999843853973347
        let shelfQ = 0.7071752369554196
        let shelfExponent = 0.4996667741545416
        let passFrequency = 38.13547087602444
        let passQ = 0.5003270373238773

        var k = tan(Double.pi * shelfFrequency / sampleRate)
        let high = pow(10, shelfGain / 20)
        let band = pow(high, shelfExponent)
        var a0 = 1 + k / shelfQ + k * k
        let shelf = [
            (high + band * k / shelfQ + k * k) / a0, 2 * (k * k - high) / a0, (high - band * k / shelfQ + k * k) / a0,
            2 * (k * k - 1) / a0, (1 - k / shelfQ + k * k) / a0,
        ]
        k = tan(Double.pi * passFrequency / sampleRate)
        a0 = 1 + k / passQ + k * k
        let pass = [1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / passQ + k * k) / a0]
        return shelf + pass
    }

    public func add(_ interleaved: [Float]) {
        let frames = interleaved.count / channels
        guard frames > 0 else { return }
        var filtered: [[Double]] = []
        for channel in 0..<channels {
            var samples = [Double](repeating: 0, count: frames)
            interleaved.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                vDSP_vspdp(base + channel, vDSP_Stride(channels), &samples, 1, vDSP_Length(frames))
            }
            truePeakLinear = max(truePeakLinear, peak.maximum(samples, history: &histories[channel]))
            var output = [Double](repeating: 0, count: frames)
            vDSP_biquadD(setup, &delays[channel], samples, 1, &output, 1, vDSP_Length(frames))
            filtered.append(output)
        }
        var start = 0
        while start < frames {
            let count = min(stepFrames - stepFill, frames - start)
            for channel in 0..<channels where weights[channel] > 0 {
                var squares = 0.0
                filtered[channel].withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    vDSP_svesqD(base + start, 1, &squares, vDSP_Length(count))
                }
                stepPower += squares * weights[channel]
            }
            start += count
            stepFill += count
            if stepFill == stepFrames {
                stepPowers.append(stepPower)
                stepPower = 0
                stepFill = 0
            }
        }
    }

    /// LUFS; `nil` when everything is gated.
    public var integratedLoudness: Double? {
        guard stepPowers.count >= Self.stepsPerBlock else { return nil }
        let blockFrames = Double(stepFrames * Self.stepsPerBlock)
        let blocks = (0...(stepPowers.count - Self.stepsPerBlock)).map { start in
            stepPowers[start..<(start + Self.stepsPerBlock)].reduce(0, +) / blockFrames
        }
        let audible = blocks.filter { Self.loudness($0) > Self.absoluteGate }
        guard !audible.isEmpty else { return nil }
        let threshold = Self.loudness(audible.reduce(0, +) / Double(audible.count)) + Self.relativeGate
        let gated = audible.filter { Self.loudness($0) > threshold }
        return Self.loudness(gated.reduce(0, +) / Double(gated.count))
    }

    /// dBTP.
    public var truePeak: Double { 20 * log10(truePeakLinear) }

    private static func loudness(_ power: Double) -> Double {
        loudnessOffset + 10 * log10(power)
    }
}

/// Polyphase windowed-sinc interpolation, per BS.1770-4 Annex 2.
struct TruePeakDetector {
    static let phases = 4
    static let tapsPerPhase = 12

    /// Reversed for `vDSP_convD`; unity gain each.
    private let filters: [[Double]] = {
        let length = phases * tapsPerPhase
        let center = Double(length - 1) / 2
        let taps = (0..<length).map { index -> Double in
            let offset = (Double(index) - center) / Double(phases)
            let sinc = offset == 0 ? 1 : sin(Double.pi * offset) / (Double.pi * offset)
            let blackman =
                0.42 - 0.5 * cos(2 * Double.pi * Double(index) / Double(length - 1)) + 0.08
                * cos(4 * Double.pi * Double(index) / Double(length - 1))
            return sinc * blackman
        }
        return (0..<phases).map { phase in
            let filter = stride(from: phase, to: length, by: phases).map { taps[$0] }
            let sum = filter.reduce(0, +)
            return filter.map { $0 / sum }.reversed()
        }
    }()

    func maximum(_ samples: [Double], history: inout [Double]) -> Double {
        let signal = history + samples
        var result = [Double](repeating: 0, count: samples.count)
        var best = 0.0
        for filter in filters {
            vDSP_convD(signal, 1, filter, 1, &result, 1, vDSP_Length(samples.count), vDSP_Length(Self.tapsPerPhase))
            var magnitude = 0.0
            vDSP_maxmgvD(result, 1, &magnitude, vDSP_Length(samples.count))
            best = max(best, magnitude)
        }
        var samplePeak = 0.0
        vDSP_maxmgvD(samples, 1, &samplePeak, vDSP_Length(samples.count))
        history = Array(signal.suffix(Self.tapsPerPhase - 1))
        return max(best, samplePeak)
    }
}
