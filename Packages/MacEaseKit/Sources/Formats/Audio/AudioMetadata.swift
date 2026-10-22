import Foundation

public enum AudioMetadata {
    public static let maximumChannels = 8
    public static let maximumSampleRate = 768_000.0
    public static let maximumBitDepth = 64

    public static func validate(sampleRate: Double, channels: Int, bitDepth: Int? = nil) throws {
        guard (1...maximumChannels).contains(channels) else {
            throw FormatError.corrupt(
                String(localized: "Audio channel count out of range", comment: "Rejects unsafe audio metadata"))
        }
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= maximumSampleRate else {
            throw FormatError.corrupt(
                String(localized: "Audio sample rate out of range", comment: "Rejects unsafe audio metadata"))
        }
        if let bitDepth, !(1...maximumBitDepth).contains(bitDepth) {
            throw FormatError.corrupt(
                String(localized: "Audio bit depth out of range", comment: "Rejects unsafe audio metadata"))
        }
    }
}
