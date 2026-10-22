import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

@testable import Formats

enum VideoFixture {
    /// Encodes frames as H.264 MP4 through AVAssetWriter.
    static func write(_ frames: [PixelBuffer], fps: Int32, to url: URL) async throws {
        guard let first = frames.first else { return }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: first.width, AVVideoHeightKey: first.height,
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: first.width, kCVPixelBufferHeightKey as String: first.height,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FormatError.io("writer did not start") }
        writer.startSession(atSourceTime: .zero)
        for (index, frame) in frames.enumerated() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw FormatError.io("no pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw FormatError.io("no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<frame.height {
                    let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<frame.width {
                        let source = (y * frame.width + x) * 4
                        row[x * 4] = frame.rgba[source + 2]
                        row[x * 4 + 1] = frame.rgba[source + 1]
                        row[x * 4 + 2] = frame.rgba[source]
                        row[x * 4 + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    /// Frames as a GIF encoder receives them.
    static func frames(of url: URL, count: Int, fps: Int32) async throws -> [PixelBuffer] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var frames: [PixelBuffer] = []
        for index in 0..<count {
            let (image, _) = try await generator.image(at: CMTime(value: CMTimeValue(index), timescale: fps))
            frames.append(try PixelBuffer(cgImage: image))
        }
        return frames
    }
}
