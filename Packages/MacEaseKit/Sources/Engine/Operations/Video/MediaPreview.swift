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
    public func frames(
        at seconds: [Double], width: Int, geometry: EditGeometry = EditGeometry(),
        adjustments: MediaAdjustments = MediaAdjustments(), toneMapToSDR: Bool = false, exactFrame: Bool = false
    ) async throws -> [CGImage] {
        let input = try await MediaInput.open(url)
        try geometry.validate()
        try adjustments.validate()
        let edited = geometry.outputSize(CGSize(width: input.displaySize.width, height: input.displaySize.height))
        let display = PixelSize(width: Int(edited.width), height: Int(edited.height))
        guard display.width > 0, display.height > 0 else {
            throw EngineError.invalidInput(.malformed("no video track"))
        }
        guard width > 0,
            let height = Int(exactly: (Double(display.height) * Double(width) / Double(display.width)).rounded())
        else { throw EngineError.invalidInput(.invalidNumericParameter) }
        let edit = FrameEdit(
            displayOrientation: try input.displayOrientation,
            size: PixelSize(width: width, height: max(1, height)).evened(),
            editorGeometry: geometry.isIdentity ? nil : geometry,
            adjustments: adjustments.isIdentity ? nil : adjustments)
        var images: [CGImage] = []
        for second in seconds {
            let (lastFrameStart, startOverflow) = input.duration.subtractingReportingOverflow(input.frameDuration)
            guard !startOverflow else { throw EngineError.decodeFailed("media timestamp out of range") }
            let time = min(
                max(try Nanoseconds.from(seconds: second), 0), max(exactFrame ? input.duration - 1 : lastFrameStart, 0))
            let (frameSpan, spanOverflow) = input.frameDuration.multipliedReportingOverflow(by: Self.sampledFrames)
            let (end, endOverflow) = time.addingReportingOverflow(frameSpan)
            guard !spanOverflow, !endOverflow else { throw EngineError.decodeFailed("media timestamp out of range") }
            let sampler = try await FrameSampler(
                input: input, frameDuration: exactFrame ? 1 : input.frameDuration, edit: edit, start: time,
                end: end, toneMapToSDR: toneMapToSDR)
            guard let frame = try await sampler.next() else { throw EngineError.decodeFailed("no frame at that time") }
            images.append(try CGImage.make(from: frame.image))
        }
        return images
    }
}
