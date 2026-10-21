import CoreGraphics
import Formats
import Foundation

/// Read-only probes for host panels.
public struct MediaPreview: Sendable {
    public let durationSeconds: Double
    /// Zero for files without video.
    public let displayWidth: Int
    public let displayHeight: Int
    private let url: URL
    /// One frame can straddle the requested time.
    private static let sampledFrames: Int64 = 2

    public init(videoAt url: URL) async throws {
        let input = try await MediaInput.open(url)
        self.url = url
        durationSeconds = Double(input.duration) / Double(Nanoseconds.perSecond)
        displayWidth = input.displaySize.width
        displayHeight = input.displaySize.height
    }

    /// Each frame decodes from a keyframe.
    public func frames(at seconds: [Double], width: Int) async throws -> [CGImage] {
        let input = try await MediaInput.open(url)
        let display = input.displaySize
        guard display.width > 0, display.height > 0 else {
            throw EngineError.invalidInput(.malformed("no video track"))
        }
        guard width > 0,
            let height = Int(exactly: (Double(display.height) * Double(width) / Double(display.width)).rounded())
        else { throw EngineError.invalidInput(.invalidNumericParameter) }
        let edit = FrameEdit(
            rotation: input.displayRotation, size: PixelSize(width: width, height: max(1, height)).evened())
        var images: [CGImage] = []
        for second in seconds {
            let (lastFrameStart, startOverflow) = input.duration.subtractingReportingOverflow(input.frameDuration)
            guard !startOverflow else { throw EngineError.decodeFailed("media timestamp out of range") }
            let time = min(max(try Nanoseconds.from(seconds: second), 0), max(lastFrameStart, 0))
            let (frameSpan, spanOverflow) = input.frameDuration.multipliedReportingOverflow(by: Self.sampledFrames)
            let (end, endOverflow) = time.addingReportingOverflow(frameSpan)
            guard !spanOverflow, !endOverflow else { throw EngineError.decodeFailed("media timestamp out of range") }
            let sampler = try await FrameSampler(
                input: input, frameDuration: input.frameDuration, edit: edit, start: time,
                end: end)
            guard let frame = try await sampler.next() else { throw EngineError.decodeFailed("no frame at that time") }
            images.append(try CGImage.make(from: frame.image))
        }
        return images
    }
}
