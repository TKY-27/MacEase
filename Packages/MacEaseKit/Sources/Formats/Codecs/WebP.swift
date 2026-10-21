import CWebP
import CoreGraphics
import Foundation

/// Still WebP through libwebp, metadata through WebPMux.
public enum WebPEncoder {
    /// Slowest, smallest libwebp method.
    static let method: Int32 = 6
    /// Matches JPEG XL: top quality means lossless.
    public static let losslessQuality = 100.0

    public static func encode(_ pixels: PixelBuffer, quality: Double, xmp: Data? = nil) throws -> Data {
        var config = try configuration(quality: quality)
        let writer = UnsafeMutablePointer<WebPMemoryWriter>.allocate(capacity: 1)
        WebPMemoryWriterInit(writer)
        defer {
            WebPMemoryWriterClear(writer)
            writer.deallocate()
        }
        try withPicture(pixels) { picture in
            picture.pointee.writer = WebPMemoryWrite
            picture.pointee.custom_ptr = UnsafeMutableRawPointer(writer)
            guard WebPEncode(&config, picture) != 0 else {
                throw FormatError.encoderFailure("WebP encode error \(picture.pointee.error_code.rawValue)")
            }
        }
        let bitstream = Data(bytes: writer.pointee.mem, count: writer.pointee.size)
        let chunks = metadataChunks(colorSpace: pixels.colorSpace, xmp: xmp)
        return chunks.isEmpty ? bitstream : try remux(bitstream, adding: chunks)
    }

    static func configuration(quality: Double) throws -> WebPConfig {
        guard quality.isFinite else { throw FormatError.encoderFailure("invalid WebP config") }
        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { throw FormatError.encoderFailure("WebP version mismatch") }
        config.quality = Float(min(max(quality, 0), losslessQuality))
        config.lossless = quality >= losslessQuality ? 1 : 0
        config.method = method
        config.use_sharp_yuv = 1
        config.thread_level = 1
        guard WebPValidateConfig(&config) != 0 else { throw FormatError.encoderFailure("invalid WebP config") }
        return config
    }

    static func withPicture(_ pixels: PixelBuffer, _ body: (UnsafeMutablePointer<WebPPicture>) throws -> Void)
        throws
    {
        guard pixels.width > 0, pixels.height > 0,
            Int32(exactly: pixels.width) != nil, Int32(exactly: pixels.height) != nil,
            pixels.width <= Int(Int32.max) / 4
        else {
            throw FormatError.corrupt(
                String(localized: "WebP dimensions out of range", comment: "Invalid image metadata"))
        }
        let picture = UnsafeMutablePointer<WebPPicture>.allocate(capacity: 1)
        defer { picture.deallocate() }
        guard WebPPictureInit(picture) != 0 else { throw FormatError.encoderFailure("WebP version mismatch") }
        picture.pointee.use_argb = 1
        picture.pointee.width = Int32(pixels.width)
        picture.pointee.height = Int32(pixels.height)
        defer { WebPPictureFree(picture) }
        let imported = pixels.rgba.withUnsafeBufferPointer { rgba in
            WebPPictureImportRGBA(picture, rgba.baseAddress, Int32(pixels.width * 4))
        }
        guard imported != 0 else { throw FormatError.encoderFailure("WebP picture import failed") }
        try body(picture)
    }

    /// WebP assumes sRGB without a profile.
    static func metadataChunks(colorSpace: CGColorSpace, xmp: Data?) -> [(fourCC: String, payload: Data)] {
        var chunks: [(String, Data)] = []
        if colorSpace.name != CGColorSpace.sRGB, let icc = colorSpace.copyICCData() as Data? {
            chunks.append(("ICCP", icc))
        }
        if let xmp { chunks.append(("XMP ", xmp)) }
        return chunks
    }

    private static func remux(_ bitstream: Data, adding chunks: [(fourCC: String, payload: Data)]) throws -> Data {
        try bitstream.withUnsafeBytes { raw in
            var image = WebPData(bytes: raw.bindMemory(to: UInt8.self).baseAddress, size: raw.count)
            guard let mux = WebPMuxCreate(&image, 0) else { throw FormatError.encoderFailure("WebPMux create") }
            defer { WebPMuxDelete(mux) }
            for chunk in chunks {
                let status = chunk.payload.withUnsafeBytes { payload in
                    var data = WebPData(bytes: payload.bindMemory(to: UInt8.self).baseAddress, size: payload.count)
                    return WebPMuxSetChunk(mux, chunk.fourCC, &data, 1)
                }
                guard status == WEBP_MUX_OK else { throw FormatError.encoderFailure("WebPMux chunk \(chunk.fourCC)") }
            }
            var assembled = WebPData()
            defer { WebPDataClear(&assembled) }
            guard WebPMuxAssemble(mux, &assembled) == WEBP_MUX_OK else {
                throw FormatError.encoderFailure("WebPMux assemble")
            }
            return Data(bytes: assembled.bytes, count: assembled.size)
        }
    }
}

/// Embeds the first frame's profile.
public final class WebPAnimationEncoder {
    public final class Stream {
        public enum Error: Swift.Error, Equatable {
            case encodedSizeExceeded
        }

        private static let maximumChunkPixelsBytes = 4 * 1024 * 1024
        private static let maximumChunkFrames = 16

        private let width: Int
        private let height: Int
        private let quality: Double
        private let loops: Bool
        private let maximumEncodedBytes: Int
        private let mux: OpaquePointer
        private let chunkFrameLimit: Int
        private var chunkEncoder: WebPAnimationEncoder?
        private var chunkFrameCount = 0
        private var totalFrameCount = 0
        private var firstFrameBitstream: Data?
        private var elapsedMilliseconds = 0.0
        private var chunkStartMilliseconds = 0
        private var encodedPayloadBytes = 0
        private var colorSpace: CGColorSpace?
        private var hasTransparency = false
        private var finished = false

        public init(width: Int, height: Int, quality: Double, loops: Bool, maximumEncodedBytes: Int) throws {
            let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
            let (frameBytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
            guard width > 0, height > 0, Int32(exactly: width) != nil, Int32(exactly: height) != nil,
                !pixelOverflow, !byteOverflow, maximumEncodedBytes > 0, quality.isFinite
            else {
                throw FormatError.encoderFailure("invalid WebP animation dimensions or size limit")
            }
            guard let mux = WebPMuxNew() else { throw FormatError.encoderFailure("WebPMux create") }
            self.width = width
            self.height = height
            self.quality = quality
            self.loops = loops
            self.maximumEncodedBytes = maximumEncodedBytes
            self.mux = mux
            self.chunkFrameLimit = min(Self.maximumChunkFrames, max(1, Self.maximumChunkPixelsBytes / frameBytes))
            var animation = WebPMuxAnimParams(bgcolor: 0, loop_count: loops ? 0 : 1)
            guard WebPMuxSetAnimationParams(mux, &animation) == WEBP_MUX_OK,
                WebPMuxSetCanvasSize(mux, Int32(width), Int32(height)) == WEBP_MUX_OK
            else {
                WebPMuxDelete(mux)
                throw FormatError.encoderFailure("WebPMux animation setup")
            }
        }

        deinit {
            WebPMuxDelete(mux)
        }

        public func add(_ image: CGImage, duration: Double) throws {
            guard !finished else { throw FormatError.encoderFailure("WebP animation already finished") }
            guard image.width == width, image.height == height else {
                throw FormatError.encoderFailure("frames must share one size")
            }
            if chunkFrameCount == chunkFrameLimit { try flushChunk() }
            let pixels = try PixelBuffer(cgImage: image)
            let firstFrameBitstream =
                chunkFrameCount == 0
                ? try WebPEncoder.encode(
                    PixelBuffer(width: width, height: height, rgba: pixels.rgba), quality: quality
                ) : nil
            let encoder =
                try chunkEncoder
                ?? WebPAnimationEncoder(
                    width: width, height: height, quality: quality, loops: loops
                )
            try encoder.add(pixels, duration: duration)
            chunkEncoder = encoder
            if let firstFrameBitstream { self.firstFrameBitstream = firstFrameBitstream }
            if colorSpace == nil { colorSpace = pixels.colorSpace }
            if !hasTransparency { hasTransparency = !pixels.isOpaque }
            elapsedMilliseconds += max(duration, 0) * WebPAnimationEncoder.millisecondsPerSecond
            chunkFrameCount += 1
            totalFrameCount += 1
        }

        public func finish(to url: URL) throws {
            guard !finished else { throw FormatError.encoderFailure("WebP animation already finished") }
            guard totalFrameCount > 0 else { throw FormatError.encoderFailure("no frames") }
            try flushChunk()
            for chunk in WebPEncoder.metadataChunks(colorSpace: colorSpace ?? PixelBuffer.sRGB, xmp: nil) {
                let status = chunk.payload.withUnsafeBytes { payload in
                    var metadata = WebPData(bytes: payload.bindMemory(to: UInt8.self).baseAddress, size: payload.count)
                    return WebPMuxSetChunk(mux, chunk.fourCC, &metadata, 1)
                }
                guard status == WEBP_MUX_OK else { throw FormatError.encoderFailure("WebPMux chunk \(chunk.fourCC)") }
            }
            var assembled = WebPData()
            defer { WebPDataClear(&assembled) }
            guard WebPMuxAssemble(mux, &assembled) == WEBP_MUX_OK else {
                throw FormatError.encoderFailure("WebPMux assemble")
            }
            guard assembled.size <= maximumEncodedBytes else { throw Error.encodedSizeExceeded }
            guard let assembledBytes = assembled.bytes else { throw FormatError.encoderFailure("empty WebP assembly") }
            let bytes = UnsafeMutablePointer(mutating: assembledBytes)
            if hasTransparency, assembled.size > WebPAnimationEncoder.flagsOffset,
                Data(bytes: bytes + WebPAnimationEncoder.firstChunkTag.lowerBound, count: 4) == Data("VP8X".utf8)
            {
                bytes[WebPAnimationEncoder.flagsOffset] |= WebPAnimationEncoder.alphaFlag
            }
            try Data(bytesNoCopy: bytes, count: assembled.size, deallocator: .none).write(to: url)
            finished = true
        }

        private func flushChunk() throws {
            guard let chunkEncoder, let firstFrameBitstream else { return }
            let bitstream = try chunkEncoder.finish()
            guard let roundedElapsed = Int(exactly: elapsedMilliseconds.rounded()) else {
                throw FormatError.encoderFailure("WebP animation duration out of range")
            }
            let chunkDuration = roundedElapsed - chunkStartMilliseconds
            try bitstream.withUnsafeBytes { raw in
                var webP = WebPData(bytes: raw.bindMemory(to: UInt8.self).baseAddress, size: raw.count)
                guard let demux = WebPDemux(&webP) else { throw FormatError.encoderFailure("WebPDemux chunk") }
                defer { WebPDemuxDelete(demux) }
                let encodedFrameCount = Int(WebPDemuxGetI(demux, WEBP_FF_FRAME_COUNT))
                guard encodedFrameCount > 0 else { throw FormatError.encoderFailure("empty WebP chunk") }
                var precedingDuration = 0
                for frameNumber in 1...encodedFrameCount {
                    var frame = WebPIterator()
                    guard WebPDemuxGetFrame(demux, Int32(frameNumber), &frame) != 0 else {
                        throw FormatError.encoderFailure("WebPDemux frame")
                    }
                    defer { WebPDemuxReleaseIterator(&frame) }
                    guard frame.complete != 0 else { throw FormatError.encoderFailure("incomplete WebP frame") }
                    let payloadBytes = frameNumber == 1 ? firstFrameBitstream.count : frame.fragment.size
                    let (nextBytes, overflow) = encodedPayloadBytes.addingReportingOverflow(payloadBytes)
                    guard !overflow, nextBytes <= maximumEncodedBytes else { throw Error.encodedSizeExceeded }
                    let frameDuration =
                        frameNumber == encodedFrameCount
                        ? chunkDuration - precedingDuration : Int(frame.duration)
                    guard let duration = Int32(exactly: frameDuration), duration >= 0 else {
                        throw FormatError.encoderFailure("WebP animation duration out of range")
                    }
                    var muxFrame = WebPMuxFrameInfo(
                        bitstream: frame.fragment,
                        x_offset: frameNumber == 1 ? 0 : frame.x_offset,
                        y_offset: frameNumber == 1 ? 0 : frame.y_offset,
                        duration: duration,
                        id: WEBP_CHUNK_ANMF,
                        dispose_method: frame.dispose_method,
                        blend_method: frameNumber == 1 ? WEBP_MUX_NO_BLEND : frame.blend_method,
                        pad: (0)
                    )
                    var frameFile = firstFrameBitstream
                    if frameNumber != 1 {
                        guard let fragmentBytes = frame.fragment.bytes
                        else {
                            throw FormatError.encoderFailure("invalid WebP frame fragment")
                        }
                        let hasAlphaChunk =
                            frame.fragment.size >= 4
                            && Data(bytes: fragmentBytes, count: 4) == Data("ALPH".utf8)
                        let extendedHeaderBytes = hasAlphaChunk ? 18 : 0
                        guard frame.fragment.size <= Int(UInt32.max) - 4 - extendedHeaderBytes else {
                            throw FormatError.encoderFailure("WebP frame fragment too large")
                        }
                        frameFile = Data("RIFF".utf8)
                        frameFile.appendLittleEndian(UInt32(frame.fragment.size + 4 + extendedHeaderBytes))
                        frameFile.append(contentsOf: "WEBP".utf8)
                        if hasAlphaChunk {
                            frameFile.append(contentsOf: "VP8X".utf8)
                            frameFile.appendLittleEndian(UInt32(10))
                            frameFile.append(contentsOf: [WebPAnimationEncoder.alphaFlag, 0, 0, 0])
                            let frameWidth = UInt32(frame.width - 1)
                            let frameHeight = UInt32(frame.height - 1)
                            frameFile.append(contentsOf: [
                                UInt8(truncatingIfNeeded: frameWidth),
                                UInt8(truncatingIfNeeded: frameWidth >> 8),
                                UInt8(truncatingIfNeeded: frameWidth >> 16),
                                UInt8(truncatingIfNeeded: frameHeight),
                                UInt8(truncatingIfNeeded: frameHeight >> 8),
                                UInt8(truncatingIfNeeded: frameHeight >> 16),
                            ])
                        }
                        frameFile.append(fragmentBytes, count: frame.fragment.size)
                    }
                    let status = frameFile.withUnsafeBytes { frameRaw in
                        muxFrame.bitstream = WebPData(
                            bytes: frameRaw.bindMemory(to: UInt8.self).baseAddress, size: frameRaw.count
                        )
                        return WebPMuxPushFrame(mux, &muxFrame, 1)
                    }
                    guard status == WEBP_MUX_OK else {
                        throw FormatError.encoderFailure("WebPMux frame \(frameNumber): \(status.rawValue)")
                    }
                    encodedPayloadBytes = nextBytes
                    precedingDuration += Int(duration)
                }
            }
            self.chunkEncoder = nil
            self.firstFrameBitstream = nil
            chunkFrameCount = 0
            chunkStartMilliseconds = roundedElapsed
        }
    }

    public let width: Int
    public let height: Int
    private let encoder: OpaquePointer
    private var config: WebPConfig
    private let xmp: Data?
    private var elapsedMilliseconds = 0.0
    private static let millisecondsPerSecond = 1000.0
    private var colorSpace: CGColorSpace?
    public private(set) var frameCount = 0
    private var hasTransparency = false
    /// VP8X flags byte and its alpha bit.
    private static let firstChunkTag = 12..<16
    private static let flagsOffset = 20
    private static let alphaFlag: UInt8 = 0x10

    public init(width: Int, height: Int, quality: Double, loops: Bool, xmp: Data? = nil) throws {
        let config = try WebPEncoder.configuration(quality: quality)
        var options = WebPAnimEncoderOptions()
        guard WebPAnimEncoderOptionsInit(&options) != 0 else {
            throw FormatError.encoderFailure("WebP version mismatch")
        }
        options.anim_params.loop_count = loops ? 0 : 1
        // Transparent canvas; the default is opaque white.
        options.anim_params.bgcolor = 0
        options.allow_mixed = config.lossless == 0 ? 1 : 0
        guard width > 0, height > 0, Int32(exactly: width) != nil, Int32(exactly: height) != nil else {
            throw FormatError.corrupt(
                String(localized: "WebP dimensions out of range", comment: "Invalid image metadata"))
        }
        guard let encoder = WebPAnimEncoderNew(Int32(width), Int32(height), &options) else {
            throw FormatError.encoderFailure("WebP animation encoder")
        }
        self.width = width
        self.height = height
        self.encoder = encoder
        self.config = config
        self.xmp = xmp
    }

    deinit {
        WebPAnimEncoderDelete(encoder)
    }

    /// `duration` is in seconds.
    public func add(_ pixels: PixelBuffer, duration: Double) throws {
        guard pixels.width == width, pixels.height == height else {
            throw FormatError.encoderFailure("frames must share one size")
        }
        let nextMilliseconds = elapsedMilliseconds + max(duration, 0) * Self.millisecondsPerSecond
        guard duration.isFinite, nextMilliseconds.isFinite, Int32(exactly: nextMilliseconds.rounded()) != nil,
            let timestamp = Int32(exactly: elapsedMilliseconds.rounded())
        else {
            throw FormatError.encoderFailure(
                String(localized: "WebP animation duration out of range", comment: "Unrepresentable animation timeline")
            )
        }
        if colorSpace == nil { colorSpace = pixels.colorSpace }
        if !hasTransparency { hasTransparency = !pixels.isOpaque }
        try WebPEncoder.withPicture(pixels) { picture in
            guard WebPAnimEncoderAdd(encoder, picture, timestamp, &config) != 0 else {
                throw FormatError.encoderFailure(errorText)
            }
        }
        elapsedMilliseconds = nextMilliseconds
        frameCount += 1
    }

    public func add(_ image: CGImage, duration: Double) throws {
        try add(PixelBuffer(cgImage: image), duration: duration)
    }

    public func finish() throws -> Data {
        guard frameCount > 0 else { throw FormatError.encoderFailure("no frames") }
        guard let timestamp = Int32(exactly: elapsedMilliseconds.rounded()) else {
            throw FormatError.encoderFailure(
                String(localized: "WebP animation duration out of range", comment: "Unrepresentable animation timeline")
            )
        }
        guard WebPAnimEncoderAdd(encoder, nil, timestamp, nil) != 0 else {
            throw FormatError.encoderFailure(errorText)
        }
        for chunk in WebPEncoder.metadataChunks(colorSpace: colorSpace ?? PixelBuffer.sRGB, xmp: xmp) {
            let status = chunk.payload.withUnsafeBytes { payload in
                var data = WebPData(bytes: payload.bindMemory(to: UInt8.self).baseAddress, size: payload.count)
                return WebPAnimEncoderSetChunk(encoder, chunk.fourCC, &data, 1)
            }
            guard status == WEBP_MUX_OK else { throw FormatError.encoderFailure("WebP chunk \(chunk.fourCC)") }
        }
        var assembled = WebPData()
        defer { WebPDataClear(&assembled) }
        guard WebPAnimEncoderAssemble(encoder, &assembled) != 0 else { throw FormatError.encoderFailure(errorText) }
        var output = Data(bytes: assembled.bytes, count: assembled.size)
        // ImageIO trusts this flag over subframes.
        if hasTransparency, output.count > Self.flagsOffset, output[Self.firstChunkTag] == Data("VP8X".utf8) {
            output[Self.flagsOffset] |= Self.alphaFlag
        }
        return output
    }

    private var errorText: String {
        WebPAnimEncoderGetError(encoder).map { String(cString: $0) } ?? "WebP animation error"
    }
}
