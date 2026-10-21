import Foundation

public enum ImageMemoryLimits {
    public static let residentBytes: Int64 = 1_500_000_000
    public static let frameworkBytes: Int64 = 500_000_000
    public static let workingBytes = residentBytes - frameworkBytes
    public static let encodedBytes = workingBytes / 4
}

struct DecodedImageBudget {
    static let maximumBytes = 100_000_000
    private static let bytesPerPixel = 4
    private static let frameOverhead = 1_024
    private var remaining = maximumBytes

    static func validateEncodedData(_ payload: Data) throws {
        guard payload.count <= ImageMemoryLimits.encodedBytes else {
            throw FormatError.inputTooLarge(limitBytes: ImageMemoryLimits.encodedBytes)
        }
    }

    mutating func reserve(width: Int, height: Int) throws {
        guard width > 0, height > 0,
            width <= (Self.maximumBytes - Self.frameOverhead) / Self.bytesPerPixel,
            height <= (Self.maximumBytes - Self.frameOverhead) / (width * Self.bytesPerPixel)
        else { throw Self.exceeded }
        let bytes = width * height * Self.bytesPerPixel + Self.frameOverhead
        guard bytes <= remaining else { throw Self.exceeded }
        remaining -= bytes
    }

    static let exceeded = FormatError.frameMemoryExceeded
}
