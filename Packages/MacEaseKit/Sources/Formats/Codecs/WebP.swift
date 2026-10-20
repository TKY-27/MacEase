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
    public let width: Int
    public let height: Int
    private let encoder: OpaquePointer
    private var config: WebPConfig
    private let xmp: Data?
    private var elapsedMilliseconds = 0.0
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
        guard width > 0, height > 0, let encoder = WebPAnimEncoderNew(Int32(width), Int32(height), &options) else {
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
        if colorSpace == nil { colorSpace = pixels.colorSpace }
        if !hasTransparency { hasTransparency = !pixels.isOpaque }
        try WebPEncoder.withPicture(pixels) { picture in
            guard WebPAnimEncoderAdd(encoder, picture, Int32(elapsedMilliseconds.rounded()), &config) != 0 else {
                throw FormatError.encoderFailure(errorText)
            }
        }
        elapsedMilliseconds += max(duration, 0) * 1000
        frameCount += 1
    }

    public func add(_ image: CGImage, duration: Double) throws {
        try add(PixelBuffer(cgImage: image), duration: duration)
    }

    public func finish() throws -> Data {
        guard frameCount > 0 else { throw FormatError.encoderFailure("no frames") }
        guard WebPAnimEncoderAdd(encoder, nil, Int32(elapsedMilliseconds.rounded()), nil) != 0 else {
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
