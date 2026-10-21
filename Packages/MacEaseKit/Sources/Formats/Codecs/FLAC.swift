import CFLAC
import Foundation

/// FLAC metadata blocks, from the format specification.
enum FLACBlock {
    static let marker = Data("fLaC".utf8)
    static let streamInfo: UInt8 = 0
    static let padding: UInt8 = 1
    static let seekTable: UInt8 = 3
    static let vorbisComment: UInt8 = 4
    static let picture: UInt8 = 6
    static let lastFlag: UInt8 = 0x80
    static let maximumLength = (1 << 24) - 1
    static let streamInfoLength = 34
    private static let packedAudioOffset = 10

    struct Block {
        var type: UInt8
        var body: Data
    }

    static func header(type: UInt8, length: Int, last: Bool) -> Data {
        Data([
            type | (last ? lastFlag : 0), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF),
        ])
    }

    /// Blocks, and where frames begin.
    static func read(_ handle: FileHandle) throws -> (blocks: [Block], framesOffset: UInt64) {
        var prefix = [UInt8](try handle.read(upToCount: ID3Tag.headerLength) ?? Data())
        var offset: UInt64 = 0
        if let tagLength = ID3Tag.length(prefix: prefix) {
            offset = UInt64(tagLength)
            try handle.seek(toOffset: offset)
            prefix = [UInt8](try handle.read(upToCount: marker.count) ?? Data())
        }
        guard prefix.starts(with: marker) else { throw FormatError.corrupt("not a FLAC file") }
        offset += UInt64(marker.count)
        try handle.seek(toOffset: offset)
        var blocks: [Block] = []
        var last = false
        while !last {
            var cursor = ByteCursor(try handle.read(upToCount: 4) ?? Data())
            let flags = try cursor.uint8()
            let length = try cursor.take(3).reduce(0) { $0 << 8 | Int($1) }
            let body = try handle.read(upToCount: length) ?? Data()
            guard body.count == length else { throw FormatError.corrupt("truncated FLAC metadata") }
            if flags & ~lastFlag == streamInfo {
                guard body.count == streamInfoLength else { throw FormatError.corrupt("truncated FLAC metadata") }
                let sampleRate =
                    Int(body[packedAudioOffset]) << 12 | Int(body[packedAudioOffset + 1]) << 4
                    | Int(body[packedAudioOffset + 2] >> 4)
                let channels = Int(body[packedAudioOffset + 2] >> 1 & 0x07) + 1
                let bitDepth = Int(body[packedAudioOffset + 2] & 0x01) << 4 | Int(body[packedAudioOffset + 3] >> 4)
                try AudioMetadata.validate(sampleRate: Double(sampleRate), channels: channels, bitDepth: bitDepth + 1)
                guard (4...32).contains(bitDepth + 1) else {
                    throw FormatError.corrupt(
                        String(localized: "Audio bit depth out of range", comment: "Rejects unsafe audio metadata"))
                }
            }
            blocks.append(Block(type: flags & ~lastFlag, body: body))
            last = flags & lastFlag != 0
            offset += UInt64(4 + length)
        }
        return (blocks, offset)
    }
}

public enum FLACMetadata {
    public static func hasUnpreservedContent(in url: URL) throws -> Bool {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let blocks = try FLACBlock.read(reader).blocks
        let pictures = blocks.filter { $0.type == FLACBlock.picture }.count
        let regenerated: Set<UInt8> = [
            FLACBlock.streamInfo, FLACBlock.padding, FLACBlock.seekTable, FLACBlock.vorbisComment,
            FLACBlock.picture,
        ]
        return pictures > 1 || blocks.contains { !regenerated.contains($0.type) }
    }

    public static func tags(in url: URL) throws -> AudioTags {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var tags = AudioTags()
        for block in try FLACBlock.read(handle).blocks {
            switch block.type {
            case FLACBlock.vorbisComment:
                let artwork = tags.artwork
                tags = try VorbisComment.decode(block.body)
                tags.artwork = tags.artwork ?? artwork
            case FLACBlock.picture where tags.artwork == nil:
                tags.artwork = try FLACPicture.decode(block.body)
            default: break
            }
        }
        return tags
    }
}

/// libFLAC frames behind MacEase's own tags.
public final class FLACFileWriter {
    private static let compressionLevel: UInt32 = 5

    private let encoder: UnsafeMutablePointer<FLAC__StreamEncoder>
    private let output: PatchableFile
    private var outputError: (any Error)?
    private let channels: Int
    private let scale: Float
    private let maximum: Int32

    /// Integer PCM of 16 or 24 bits.
    public init(url: URL, sampleRate: Int, channels: Int, bitsPerSample: Int, tags: AudioTags) throws {
        try AudioMetadata.validate(sampleRate: Double(sampleRate), channels: channels, bitDepth: bitsPerSample)
        guard bitsPerSample == 16 || bitsPerSample == 24 else {
            throw FormatError.unsupported("FLAC at \(sampleRate) Hz, \(channels) channels, \(bitsPerSample) bits")
        }
        var blocks = [FLACBlock.Block(type: FLACBlock.vorbisComment, body: VorbisComment.encode(tags))]
        if let artwork = tags.artwork {
            blocks.append(FLACBlock.Block(type: FLACBlock.picture, body: FLACPicture.encode(artwork)))
        }
        guard blocks.allSatisfy({ $0.body.count <= FLACBlock.maximumLength }) else {
            throw FormatError.unsupported("FLAC artwork over 16 MB")
        }
        output = try PatchableFile(url: url)
        try output.append(FLACBlock.marker)
        try output.append(FLACBlock.header(type: FLACBlock.streamInfo, length: FLACBlock.streamInfoLength, last: false))
        try output.append(Data(count: FLACBlock.streamInfoLength))
        for (index, block) in blocks.enumerated() {
            try output.append(
                FLACBlock.header(type: block.type, length: block.body.count, last: index == blocks.count - 1))
            try output.append(block.body)
        }
        guard let encoder = FLAC__stream_encoder_new() else { throw FormatError.encoderFailure("FLAC encoder") }
        self.encoder = encoder
        self.channels = channels
        scale = Float(1 << (bitsPerSample - 1))
        maximum = Int32(1 << (bitsPerSample - 1)) - 1
        guard FLAC__stream_encoder_set_channels(encoder, UInt32(channels)) != 0,
            FLAC__stream_encoder_set_bits_per_sample(encoder, UInt32(bitsPerSample)) != 0,
            FLAC__stream_encoder_set_sample_rate(encoder, UInt32(sampleRate)) != 0,
            FLAC__stream_encoder_set_compression_level(encoder, Self.compressionLevel) != 0
        else {
            throw FormatError.unsupported("FLAC at \(sampleRate) Hz, \(channels) channels, \(bitsPerSample) bits")
        }
        let status = FLAC__stream_encoder_init_stream(
            encoder,
            { _, bytes, count, samples, _, context in
                // Native metadata would overwrite MacEase's tags.
                guard samples > 0 else { return FLAC__STREAM_ENCODER_WRITE_STATUS_OK }
                guard let context, let bytes else { return FLAC__STREAM_ENCODER_WRITE_STATUS_FATAL_ERROR }
                let writer = Unmanaged<FLACFileWriter>.fromOpaque(context).takeUnretainedValue()
                do {
                    try writer.output.append(Data(bytes: bytes, count: count))
                    return FLAC__STREAM_ENCODER_WRITE_STATUS_OK
                } catch {
                    writer.outputError = error
                    return FLAC__STREAM_ENCODER_WRITE_STATUS_FATAL_ERROR
                }
            }, nil, nil,
            { _, metadata, context in
                guard let context, let metadata else { return }
                let writer = Unmanaged<FLACFileWriter>.fromOpaque(context).takeUnretainedValue()
                do {
                    try writer.patchStreamInfo(metadata.pointee.data.stream_info)
                } catch {
                    writer.outputError = error
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        guard status == FLAC__STREAM_ENCODER_INIT_STATUS_OK else {
            throw FormatError.encoderFailure(stateDescription)
        }
    }

    deinit {
        FLAC__stream_encoder_delete(encoder)
    }

    public func write(_ interleaved: [Float]) throws {
        guard let frames = UInt32(exactly: interleaved.count / channels) else {
            throw FormatError.encoderFailure(
                String(localized: "Audio frame count out of range", comment: "Rejects oversized audio buffer"))
        }
        let integers = interleaved.map { sample in
            sample.isFinite ? Int32(max(min((sample * scale).rounded(), Float(maximum)), -Float(maximum) - 1)) : 0
        }
        let succeeded = FLAC__stream_encoder_process_interleaved(encoder, integers, frames) != 0
        if let outputError { throw outputError }
        guard succeeded else { throw FormatError.encoderFailure(stateDescription) }
    }

    public func finish() throws {
        let succeeded = FLAC__stream_encoder_finish(encoder) != 0
        if let outputError { throw outputError }
        guard succeeded else { throw FormatError.encoderFailure(stateDescription) }
        try output.close()
    }

    private func patchStreamInfo(_ statistics: FLAC__StreamMetadata_StreamInfo) throws {
        var body = Data()
        body.appendBigEndian(UInt16(statistics.min_blocksize))
        body.appendBigEndian(UInt16(statistics.max_blocksize))
        for size in [statistics.min_framesize, statistics.max_framesize] {
            var encoded = Data()
            encoded.appendBigEndian(size)
            body.append(encoded.suffix(3))
        }
        let packed =
            UInt64(statistics.sample_rate) << 44 | UInt64(statistics.channels - 1) << 41
            | UInt64(statistics.bits_per_sample - 1) << 36 | statistics.total_samples
        body.appendBigEndian(packed)
        withUnsafeBytes(of: statistics.md5sum) { body.append(contentsOf: $0) }
        let headerLength = 4
        try output.patch(body, at: Int64(FLACBlock.marker.count + headerLength))
    }

    private var stateDescription: String {
        String(cString: FLAC__stream_encoder_get_resolved_state_string(encoder))
    }
}
