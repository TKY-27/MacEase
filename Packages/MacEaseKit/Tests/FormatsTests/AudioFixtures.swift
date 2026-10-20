import AVFoundation
import Foundation

@testable import Formats

enum AudioFixtures {
    /// Plucked chords, bass, hi-hats and a snare.
    static func music(seconds: Double = 6, sampleRate: Int = 44_100) -> (left: [Float], right: [Float]) {
        var random = FixtureRandom(seed: 11)
        let count = Int(seconds * Double(sampleRate))
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        let rate = Double(sampleRate)
        let chords: [[Double]] = [
            [261.63, 329.63, 392.0], [220.0, 261.63, 329.63], [174.61, 220.0, 261.63], [196.0, 246.94, 293.66],
        ]
        let beat = 0.5
        for start in stride(from: 0.0, to: seconds, by: beat) {
            let chord = chords[Int(start / (beat * 4)) % chords.count]
            let first = Int(start * rate)
            for (voice, frequency) in chord.enumerated() {
                let pan = Float(voice) / 2
                for offset in 0..<min(Int(beat * 1.6 * rate), count - first) {
                    let time = Double(offset) / rate
                    var value = 0.0
                    for harmonic in 1...6 {
                        value += sin(2 * .pi * frequency * Double(harmonic) * time) / Double(harmonic * harmonic)
                    }
                    let sample = Float(value * exp(-time * 3) * 0.12)
                    left[first + offset] += sample * (1 - pan * 0.5)
                    right[first + offset] += sample * (0.5 + pan * 0.5)
                }
            }
            let bass = chord[0] / 2
            for offset in 0..<min(Int(beat * rate), count - first) {
                let time = Double(offset) / rate
                let sample = Float(sin(2 * .pi * bass * time) * exp(-time * 4) * 0.25)
                left[first + offset] += sample
                right[first + offset] += sample
            }
            for hat in [0.0, beat / 2] {
                let hatStart = Int((start + hat) * rate)
                var previous = 0.0
                for offset in 0..<min(Int(0.08 * rate), count - hatStart) {
                    let noise = random.unit() * 2 - 1
                    let highPassed = noise - previous
                    previous = noise
                    let sample = Float(highPassed * exp(-Double(offset) / rate * 40) * 0.06)
                    left[hatStart + offset] += sample
                    right[hatStart + offset] += sample * 0.8
                }
            }
            if Int(start / beat) % 2 == 1 {
                for offset in 0..<min(Int(0.15 * rate), count - first) {
                    let time = Double(offset) / rate
                    let sample = Float(
                        (random.unit() * 2 - 1) * exp(-time * 25) * 0.18 + sin(2 * .pi * 180 * time) * exp(-time * 30)
                            * 0.2)
                    left[first + offset] += sample
                    right[first + offset] += sample
                }
            }
        }
        return (left, right)
    }

    static func decode(_ url: URL) throws -> (left: [Float], right: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw FormatError.io("buffer") }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw FormatError.io("channels") }
        let frames = Int(buffer.frameLength)
        let left = Array(UnsafeBufferPointer(start: channels[0], count: frames))
        let right =
            buffer.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: channels[1], count: frames)) : left
        return (left, right, file.processingFormat.sampleRate)
    }

    /// Lag of `decoded` behind `reference`, by cross-correlation.
    static func delay(of decoded: [Float], behind reference: [Float], maximum: Int = 4000) -> Int {
        let window = 1 << 15
        var best = (lag: 0, score: -Double.infinity)
        let start = min(reference.count / 4, 44_100)
        for lag in 0..<maximum {
            var score = 0.0
            for index in stride(from: start, to: min(start + window, reference.count, decoded.count - lag), by: 2) {
                score += Double(reference[index]) * Double(decoded[index + lag])
            }
            if score > best.score { best = (lag, score) }
        }
        return best.lag
    }

    /// Mean segment SNR, clamped to [-10, 35].
    static func segmentalSNR(_ reference: [Float], _ decoded: [Float], lag: Int, segment: Int = 1024) -> Double {
        var values: [Double] = []
        var index = 0
        while index + segment <= reference.count, index + lag + segment <= decoded.count {
            var signal = 0.0
            var noise = 0.0
            for offset in index..<(index + segment) {
                let reference = Double(reference[offset])
                signal += reference * reference
                let error = reference - Double(decoded[offset + lag])
                noise += error * error
            }
            if signal > 1e-6 * Double(segment) {
                values.append(min(max(10 * log10(signal / max(noise, 1e-20)), -10), 35))
            }
            index += segment
        }
        return values.reduce(0, +) / Double(max(values.count, 1))
    }

    /// Band energy from averaged DFTs.
    static func bandEnergy(_ samples: [Float], sampleRate: Double, from low: Double, to high: Double) -> Double {
        let size = 4096
        var total = 0.0
        var position = 0
        while position + size <= samples.count {
            for bin in Int(low / sampleRate * Double(size))..<Int(high / sampleRate * Double(size)) {
                var real = 0.0
                var imaginary = 0.0
                for n in stride(from: 0, to: size, by: 1) {
                    let window = 0.5 - 0.5 * cos(2 * .pi * Double(n) / Double(size))
                    let angle = -2 * .pi * Double(bin) * Double(n) / Double(size)
                    let value = Double(samples[position + n]) * window
                    real += value * cos(angle)
                    imaginary += value * sin(angle)
                }
                total += real * real + imaginary * imaginary
            }
            position += size * 4
        }
        return total
    }
}
