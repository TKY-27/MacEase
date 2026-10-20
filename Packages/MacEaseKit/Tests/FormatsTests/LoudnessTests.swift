import Foundation
import Testing

@testable import Formats

/// EBU Tech 3341 cases 1 to 5.
@Suite struct LoudnessTests {
    private static let rate = 48_000.0

    private func tone(
        _ segments: [(decibels: Double, seconds: Double)], frequency: Double = 1_000, rate: Double = rate,
        phase: Double = 0
    ) -> [Float] {
        var samples: [Float] = []
        var index = 0
        for segment in segments {
            let amplitude = pow(10, segment.decibels / 20)
            for _ in 0..<Int(segment.seconds * rate) {
                let value = Float(amplitude * sin(2 * Double.pi * frequency * Double(index) / rate + phase))
                samples.append(value)
                samples.append(value)
                index += 1
            }
        }
        return samples
    }

    private func measure(_ samples: [Float], rate: Double = rate) throws -> LoudnessMeter {
        let meter = try LoudnessMeter(sampleRate: rate, channels: 2)
        let chunk = 48_000 * 2
        for start in stride(from: 0, to: samples.count, by: chunk) {
            meter.add(Array(samples[start..<min(start + chunk, samples.count)]))
        }
        return meter
    }

    @Test func kWeightingMatchesTheRecommendationAt48kHz() {
        let expected = [
            1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585, 1, -2, 1,
            -1.99004745483398, 0.99007225036621,
        ]
        for (value, reference) in zip(LoudnessMeter.kWeighting(sampleRate: Self.rate), expected) {
            #expect(abs(value - reference) < 1e-9)
        }
    }

    @Test(arguments: [
        ([(-23.0, 20.0)], -23.0),
        ([(-33.0, 20.0)], -33.0),
        ([(-36.0, 10.0), (-23.0, 60.0), (-36.0, 10.0)], -23.0),
        ([(-72.0, 10.0), (-36.0, 10.0), (-23.0, 60.0), (-36.0, 10.0), (-72.0, 10.0)], -23.0),
        ([(-26.0, 20.0), (-20.0, 20.1), (-26.0, 20.0)], -23.0),
    ])
    func integratedLoudnessMatchesTech3341(segments: [(Double, Double)], expected: Double) throws {
        let loudness = try #require(try measure(tone(segments.map { ($0.0, $0.1) })).integratedLoudness)
        #expect(abs(loudness - expected) <= 0.1)
    }

    @Test func otherSampleRatesAgree() throws {
        let rate = 44_100.0
        let loudness = try #require(try measure(tone([(-23, 10)], rate: rate), rate: rate).integratedLoudness)
        #expect(abs(loudness + 23) <= 0.1)
    }

    @Test func silenceHasNoLoudness() throws {
        #expect(try measure([Float](repeating: 0, count: 96_000 * 2)).integratedLoudness == nil)
    }

    /// A quarter-rate tone sampled between its peaks.
    @Test func truePeakFindsInterSamplePeaks() throws {
        let samples = tone([(-3, 2)], frequency: Self.rate / 4, phase: Double.pi / 4)
        let samplePeak = 20 * log10(Double(samples.map(abs).max() ?? 0))
        let meter = try measure(samples)
        #expect(abs(samplePeak + 6.01) < 0.01)
        #expect(abs(meter.truePeak + 3) <= 0.2)
    }
}
