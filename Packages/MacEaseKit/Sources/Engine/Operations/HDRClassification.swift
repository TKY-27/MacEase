import Foundation

public enum HDRClassification: String, Codable, Hashable, Sendable {
    case genuineHDR
    case expandedHDR
    case unknownHDR
    case sdr

    public static func image(at url: URL) throws -> Self {
        try ImageSDR.classification(url)
    }

    public static func video(at url: URL) async throws -> Self {
        try await VideoSDR.classification(url)
    }
}
