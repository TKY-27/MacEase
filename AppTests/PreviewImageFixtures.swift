import AVFoundation
import AppKit
import Compression
import ImageIO
import UniformTypeIdentifiers
import XCTest

enum PreviewImageFixtures {
    static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "PreviewFixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func bitmap(
        width: Int, height: Int, bitsPerComponent: Int = 8, colorSpaceName: CFString = CGColorSpace.sRGB,
        draw: (CGContext) -> Void
    ) throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: 0,
                space: try XCTUnwrap(CGColorSpace(name: colorSpaceName)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        return try XCTUnwrap(context.makeImage())
    }

    static func solid(
        width: Int, height: Int, gray: CGFloat, bitsPerComponent: Int = 8, colorSpaceName: CFString = CGColorSpace.sRGB
    ) throws -> CGImage {
        try bitmap(width: width, height: height, bitsPerComponent: bitsPerComponent, colorSpaceName: colorSpaceName) {
            context in
            context.setFillColor(CGColor(gray: gray, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    static func write(
        _ images: [CGImage], to url: URL, type: UTType, container: [CFString: Any] = [:],
        frame: [CFString: Any] = [:]
    ) throws {
        try write(images, to: url, typeIdentifier: type.identifier, container: container, frame: frame)
    }

    static func write(
        _ images: [CGImage], to url: URL, typeIdentifier: String, container: [CFString: Any] = [:],
        frame: [CFString: Any] = [:]
    ) throws {
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, typeIdentifier as CFString, images.count, nil))
        if !container.isEmpty { CGImageDestinationSetProperties(destination, container as CFDictionary) }
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
            frame: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay]])
        return url
    }

    static func animatedWebP(loopCount: UInt16, delaysMs: [UInt32], in directory: URL, name: String = "anim.webp")
        throws -> URL
    {
        func le32(_ value: UInt32) -> [UInt8] {
            [
                UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
                UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
            ]
        }
        func riffChunk(_ tag: String, _ payload: [UInt8]) -> [UInt8] {
            var bytes = Array(tag.utf8) + le32(UInt32(payload.count)) + payload
            if payload.count % 2 == 1 { bytes.append(0) }
            return bytes
        }
        // Minimal valid 1x1 lossless VP8L bitstream.
        let vp8lPayload: [UInt8] = [0x2F, 0x00, 0x00, 0x00, 0x00, 0x07, 0x10, 0xFE, 0x8F, 0xFE, 0x07]
        let frameImageChunk = riffChunk("VP8L", vp8lPayload)
        let vp8x = riffChunk("VP8X", [0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let anim = riffChunk("ANIM", [0, 0, 0, 0, UInt8(loopCount & 0xFF), UInt8(loopCount >> 8)])
        var body = Array("WEBP".utf8) + vp8x + anim
        for durationMs in delaysMs {
            let header: [UInt8] = [
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                UInt8(durationMs & 0xFF), UInt8((durationMs >> 8) & 0xFF), UInt8((durationMs >> 16) & 0xFF),
                0,
            ]
            body.append(contentsOf: riffChunk("ANMF", header + frameImageChunk))
        }
        let encoded = Data(Array("RIFF".utf8) + le32(UInt32(body.count)) + body)
        let url = directory.appending(path: name)
        try encoded.write(to: url)
        return url
    }

    static func manyFrameGIF(frameCount: Int, in directory: URL, name: String = "many.gif") throws -> URL {
        var encoded = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 1, 0, 1, 0, 0x80, 0, 0, 0, 0, 0, 255, 255, 255])
        encoded.append(contentsOf: [
            0x21, 0xFF, 0x0B, 0x4E, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45, 0x32, 0x2E, 0x30, 0x03, 0x01, 0, 0, 0,
        ])
        let frameBytes: [UInt8] = [
            0x21, 0xF9, 0x04, 0x00, 0x02, 0x00, 0x00, 0x00,
            0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0x00,
            0x02, 0x02, 0x44, 0x01, 0x00,
        ]
        encoded.reserveCapacity(encoded.count + frameBytes.count * frameCount + 1)
        for _ in 0..<frameCount { encoded.append(contentsOf: frameBytes) }
        encoded.append(0x3B)
        let url = directory.appending(path: name)
        try encoded.write(to: url)
        return url
    }

    // Stream-encodes a tiny valid 1-bit PNG.
    static func monochromePNG(width: Int, height: Int) -> Data {
        func crc32(_ bytes: [UInt8]) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc & 1) != 0 ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1) }
            }
            return crc ^ 0xFFFF_FFFF
        }
        func be32(_ value: UInt32) -> [UInt8] {
            [
                UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
            ]
        }
        func pngChunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let chunkBytes = Array(type.utf8) + payload
            return be32(UInt32(payload.count)) + chunkBytes + be32(crc32(chunkBytes))
        }
        let rowBytes = (width + 7) / 8 + 1
        let totalBytes = rowBytes * height
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { scratch.deallocate() }
        var stream = compression_stream(
            dst_ptr: scratch, dst_size: 0, src_ptr: UnsafePointer(scratch), src_size: 0, state: nil)
        compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
        defer { compression_stream_destroy(&stream) }
        let zeros = [UInt8](repeating: 0, count: 65_536)
        var output = [UInt8](repeating: 0, count: 65_536)
        var compressed = Data([0x78, 0x01])
        var remaining = totalBytes
        zeros.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                guard let inputBase = inputBuffer.baseAddress, let outputBase = outputBuffer.baseAddress else { return }
                while remaining > 0 {
                    let take = min(remaining, inputBuffer.count)
                    remaining -= take
                    stream.src_ptr = inputBase
                    stream.src_size = take
                    let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    repeat {
                        stream.dst_ptr = outputBase
                        stream.dst_size = outputBuffer.count
                        let status = compression_stream_process(&stream, flags)
                        let produced = outputBuffer.count - stream.dst_size
                        if produced > 0 { compressed.append(outputBase, count: produced) }
                        if status == COMPRESSION_STATUS_END { break }
                    } while stream.src_size > 0 || remaining == 0
                }
            }
        }
        let s1: UInt32 = 1
        let s2 = UInt32(totalBytes % 65_521)
        compressed.append(contentsOf: [
            UInt8((s2 >> 8) & 0xFF), UInt8(s2 & 0xFF), UInt8((s1 >> 8) & 0xFF), UInt8(s1 & 0xFF),
        ])
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(contentsOf: pngChunk("IHDR", be32(UInt32(width)) + be32(UInt32(height)) + [1, 0, 0, 0, 0]))
        png.append(contentsOf: pngChunk("IDAT", Array(compressed)))
        png.append(contentsOf: pngChunk("IEND", []))
        return png
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
        let entry = AVMutableMetadataItem()
        entry.identifier = identifier
        entry.value = value
        if value is Data { entry.dataType = kCMMetadataBaseDataType_PNG as String }
        return entry
    }
}
