import CoreImage
import Foundation

/// Linear fades at both span ends.
public struct FadeRamp: Hashable, Sendable {
    public static let maximumSeconds = 10.0

    public let duration: Double
    public let fadeIn: Double
    public let fadeOut: Double

    /// Overlapping fades shrink proportionally.
    public init(duration: Double, fadeIn: Double, fadeOut: Double) {
        self.duration = max(0, duration)
        let requestedIn = max(0, fadeIn)
        let requestedOut = max(0, fadeOut)
        let total = requestedIn + requestedOut
        let scale = total > self.duration ? self.duration / total : 1
        self.fadeIn = requestedIn * scale
        self.fadeOut = requestedOut * scale
    }

    public var isIdentity: Bool { fadeIn == 0 && fadeOut == 0 }

    public static func validate(fadeIn: Double, fadeOut: Double) throws {
        guard fadeIn.isFinite, fadeOut.isFinite, (0...maximumSeconds).contains(fadeIn),
            (0...maximumSeconds).contains(fadeOut)
        else { throw EngineError.invalidInput(.invalidNumericParameter) }
    }

    public func gain(at seconds: Double) -> Double {
        var gain = 1.0
        if fadeIn > 0 { gain = min(gain, seconds / fadeIn) }
        if fadeOut > 0 { gain = min(gain, (duration - seconds) / fadeOut) }
        return min(1, max(0, gain))
    }

    /// `firstFrame` counts from the span start.
    func apply(to samples: inout [Float], channels: Int, firstFrame: Int64, sampleRate: Double) {
        guard !isIdentity, channels > 0, sampleRate > 0 else { return }
        let frames = samples.count / channels
        let first = Double(firstFrame) / sampleRate
        let last = Double(firstFrame + Int64(frames)) / sampleRate
        guard first < fadeIn || last > duration - fadeOut else { return }
        for frame in 0..<frames {
            let scale = Float(gain(at: Double(firstFrame + Int64(frame)) / sampleRate))
            guard scale < 1 else { continue }
            for channel in 0..<channels { samples[frame * channels + channel] *= scale }
        }
    }
}

extension CIImage {
    func fadedToBlack(_ gain: Double) -> CIImage {
        applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            ])
    }
}
