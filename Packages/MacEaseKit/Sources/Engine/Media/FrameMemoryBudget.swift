import CoreGraphics
import CoreVideo

struct FrameMemoryBudget {
    private static let residentLimit: Int64 = 1_500_000_000
    private static let frameworkReserve: Int64 = 500_000_000
    // Encoders and transforms retain additional pixel copies.
    private static let workingCopies: Int64 = 10
    static let maximumBytes = (residentLimit - frameworkReserve) / workingCopies
    private static let rowAlignment: Int64 = 64
    private static let frameOverhead: Int64 = 1_024
    private var remaining = maximumBytes

    mutating func reserve(width: Int, height: Int, bytesPerPixel: Int = 4, frameCount: Int64 = 1) throws {
        guard width > 0, bytesPerPixel > 0, Int64(width) <= Self.maximumBytes / Int64(bytesPerPixel) else {
            throw Self.exceeded
        }
        let row = Int64(width) * Int64(bytesPerPixel)
        let alignedRow = (row + Self.rowAlignment - 1) / Self.rowAlignment * Self.rowAlignment
        try reserve(bytesPerRow: alignedRow, height: height, frameCount: frameCount)
    }

    mutating func reserve(_ image: CGImage) throws {
        try reserve(bytesPerRow: Int64(image.bytesPerRow), height: image.height, frameCount: 1)
    }

    mutating func reserve(_ image: CVPixelBuffer) throws {
        try reserve(
            bytesPerRow: Int64(CVPixelBufferGetBytesPerRow(image)), height: CVPixelBufferGetHeight(image), frameCount: 1
        )
    }

    private mutating func reserve(bytesPerRow: Int64, height: Int, frameCount: Int64) throws {
        guard bytesPerRow > 0, height > 0, frameCount >= 0,
            Int64(height) <= (Self.maximumBytes - Self.frameOverhead) / bytesPerRow
        else { throw Self.exceeded }
        let frameBytes = bytesPerRow * Int64(height) + Self.frameOverhead
        guard frameCount <= remaining / frameBytes else { throw Self.exceeded }
        remaining -= frameBytes * frameCount
    }

    static func validate(images: [CGImage]) throws {
        var budget = Self()
        for image in images { try budget.reserve(image) }
    }

    static let exceeded = EngineError.invalidInput(.frameMemoryExceeded)
}
