import CoreGraphics
import CoreVideo
import Formats
import ImageIO

struct FrameMemoryBudget {
    static let maximumBytes = ImageMemoryLimits.workingBytes
    private static let retainedCopies: Int64 = 4
    static var retainedImages: Self { Self(limitBytes: maximumBytes / retainedCopies) }
    private static let renderedPageCopies: Int64 = 3
    static var renderedPage: Self { Self(limitBytes: maximumBytes / renderedPageCopies) }
    private static let rowAlignment: Int64 = 64
    private static let frameOverhead: Int64 = 1_024
    private var remaining: Int64

    init(limitBytes: Int64 = maximumBytes) {
        remaining = limitBytes
    }

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

    mutating func reserve(source: CGImageSource, index: Int, oriented: Bool = false) throws {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw EngineError.decodeFailed("image dimensions unavailable") }
        let depth = properties[kCGImagePropertyDepth] as? Int ?? 8
        let componentBytes = depth > 16 ? 4 : depth > 8 ? 2 : 1
        let orientation =
            (properties[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        let rotated = oriented && orientation.swapsAxes
        try reserve(
            width: rotated ? height : width, height: rotated ? width : height, bytesPerPixel: 4 * componentBytes)
    }

    private mutating func reserve(bytesPerRow: Int64, height: Int, frameCount: Int64) throws {
        guard bytesPerRow > 0, height > 0, frameCount >= 0,
            Int64(height) <= (Self.maximumBytes - Self.frameOverhead) / bytesPerRow
        else { throw Self.exceeded }
        let frameBytes = bytesPerRow * Int64(height) + Self.frameOverhead
        guard frameCount <= remaining / frameBytes else { throw Self.exceeded }
        remaining -= frameBytes * frameCount
    }

    static let exceeded = EngineError.invalidInput(.frameMemoryExceeded)
}

extension CGImagePropertyOrientation {
    var swapsAxes: Bool {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored: true
        default: false
        }
    }
}
