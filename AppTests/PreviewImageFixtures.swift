import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

enum PreviewImageFixtures {
    static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "PreviewFixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func bitmap(width: Int, height: Int, draw: (CGContext) -> Void) throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    static func solid(width: Int, height: Int, gray: CGFloat) throws -> CGImage {
        try bitmap(width: width, height: height) { context in
            context.setFillColor(CGColor(gray: gray, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    static func write(
        _ images: [CGImage], to url: URL, type: UTType, container: [CFString: Any] = [:],
        frame: [CFString: Any] = [:]
    ) throws {
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil))
        CGImageDestinationSetProperties(destination, container as CFDictionary)
        for image in images { CGImageDestinationAddImage(destination, image, frame as CFDictionary) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    static func gif(
        frames: Int, size: Int = 64, loopCount: Int?, delay: Double = 0.02, in directory: URL, name: String = "loop.gif"
    ) throws -> URL {
        let url = directory.appending(path: name)
        let images = try (0..<frames).map {
            try solid(width: size, height: size, gray: CGFloat($0) / CGFloat(max(frames - 1, 1)))
        }
        var gif: [CFString: Any] = [:]
        if let loopCount { gif[kCGImagePropertyGIFLoopCount] = loopCount }
        try write(
            images, to: url, type: .gif, container: [kCGImagePropertyGIFDictionary: gif],
            frame: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]])
        return url
    }

    static func text(_ string: String, width: Int, height: Int) throws -> CGImage {
        try bitmap(width: width, height: height) { context in
            context.setFillColor(.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(
                string: string,
                attributes: [.font: NSFont.systemFont(ofSize: CGFloat(height) / 6), .foregroundColor: NSColor.black]
            ).draw(in: NSRect(x: 20, y: 20, width: width - 40, height: height - 40))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func audio(
        in directory: URL, name: String = "song.m4a", seconds: Double = 0.5, sampleRate: Double = 44_100,
        metadata: [AVMetadataItem] = []
    ) async throws -> URL {
        let url = directory.appending(path: name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        writer.metadata = metadata
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let chunkSeconds = min(seconds, 10)
        var start = 0.0
        while start < seconds {
            let sample = try silence(seconds: min(chunkSeconds, seconds - start), at: start, sampleRate: sampleRate)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(input.append(sample))
            start += chunkSeconds
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        return url
    }

    private static func silence(seconds: Double, at start: Double, sampleRate: Double) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(start * sampleRate), timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreate(
                allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                formatDescription: format.formatDescription, sampleCount: CMItemCount(frameCount),
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                sampleBufferOut: &sample), noErr)
        let sampleBuffer = try XCTUnwrap(sample)
        XCTAssertEqual(
            CMSampleBufferSetDataBufferFromAudioBufferList(
                sampleBuffer, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
                bufferList: buffer.audioBufferList), noErr)
        return sampleBuffer
    }

    static func metadata(_ identifier: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol)
        -> AVMetadataItem
    {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        if value is Data { item.dataType = kCMMetadataBaseDataType_PNG as String }
        return item
    }
}
