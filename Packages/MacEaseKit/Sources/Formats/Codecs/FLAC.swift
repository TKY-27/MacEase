import CFLAC
import Foundation

/// FLAC metadata blocks, from the format specification.
enum FLACBlock {
    static let marker = Data("fLaC".utf8)
    static let streamInfo: UInt8 = 0
    static let padding: UInt8 = 1
    static let vorbisComment: UInt8 = 4
    static let picture: UInt8 = 6
    static let lastFlag: UInt8 = 0x80
    static let maximumLength = (1 << 24) - 1
    private static let id3HeaderLength = 10
    private static let id3FooterFlag: UInt8 = 0x10

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
        var prefix = [UInt8](try handle.read(upToCount: id3HeaderLength) ?? Data())
        var offset: UInt64 = 0
        if prefix.starts(with: Array("ID3".utf8)), prefix.count == id3HeaderLength {
            let size = prefix[6..<10].reduce(0) { $0 << 7 | UInt64($1 & 0x7F) }
            let footer: UInt64 = prefix[5] & id3FooterFlag != 0 ? UInt64(id3HeaderLength) : 0
            offset = UInt64(id3HeaderLength) + size + footer
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
            blocks.append(Block(type: flags & ~lastFlag, body: body))
            last = flags & lastFlag != 0
            offset += UInt64(4 + length)
        }
        return (blocks, offset)
    }
}

public enum FLACMetadata {
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
    private static let copyChunk = 1 << 20

    private let encoder: UnsafeMutablePointer<FLAC__StreamEncoder>
    private let url: URL
    private let framesURL: URL
    private let channels: Int
    private let scale: Float
    private let maximum: Int32
    private let tags: AudioTags

    /// Integer PCM of 16 or 24 bits.
    public init(url: URL, sampleRate: Int, channels: Int, bitsPerSample: Int, tags: AudioTags) throws {
        guard let encoder = FLAC__stream_encoder_new() else { throw FormatError.encoderFailure("FLAC encoder") }
        self.encoder = encoder
        self.url = url
        framesURL = url.appendingPathExtension("frames")
        self.channels = channels
        scale = Float(1 << (bitsPerSample - 1))
        maximum = Int32(1 << (bitsPerSample - 1)) - 1
        self.tags = tags
        guard FLAC__stream_encoder_set_channels(encoder, UInt32(channels)) != 0,
            FLAC__stream_encoder_set_bits_per_sample(encoder, UInt32(bitsPerSample)) != 0,
            FLAC__stream_encoder_set_sample_rate(encoder, UInt32(sampleRate)) != 0,
            FLAC__stream_encoder_set_compression_level(encoder, Self.compressionLevel) != 0,
            FLAC__stream_encoder_init_file(encoder, framesURL.path, nil, nil) == FLAC__STREAM_ENCODER_INIT_STATUS_OK
        else {
            throw FormatError.unsupported("FLAC at \(sampleRate) Hz, \(channels) channels, \(bitsPerSample) bits")
        }
    }

    deinit {
        FLAC__stream_encoder_delete(encoder)
        try? FileManager.default.removeItem(at: framesURL)
    }

    public func write(_ interleaved: [Float]) throws {
        let integers = interleaved.map { sample in
            Int32(max(min((sample * scale).rounded(), Float(maximum)), -Float(maximum) - 1))
        }
        guard FLAC__stream_encoder_process_interleaved(encoder, integers, UInt32(integers.count / channels)) != 0
        else { throw FormatError.encoderFailure(stateDescription) }
    }

    public func finish() throws {
        guard FLAC__stream_encoder_finish(encoder) != 0 else { throw FormatError.encoderFailure(stateDescription) }
        let source = try FileHandle(forReadingFrom: framesURL)
        defer { try? source.close() }
        let (blocks, framesOffset) = try FLACBlock.read(source)
        var kept = blocks.filter { ![FLACBlock.padding, FLACBlock.vorbisComment, FLACBlock.picture].contains($0.type) }
        kept.append(FLACBlock.Block(type: FLACBlock.vorbisComment, body: VorbisComment.encode(tags)))
        if let artwork = tags.artwork {
            kept.append(FLACBlock.Block(type: FLACBlock.picture, body: FLACPicture.encode(artwork)))
        }
        guard kept.allSatisfy({ $0.body.count <= FLACBlock.maximumLength }) else {
            throw FormatError.unsupported("FLAC artwork over 16 MB")
        }
        let output = try PatchableFile(url: url)
        try output.append(FLACBlock.marker)
        for (index, block) in kept.enumerated() {
            try output.append(
                FLACBlock.header(type: block.type, length: block.body.count, last: index == kept.count - 1))
            try output.append(block.body)
        }
        try source.seek(toOffset: framesOffset)
        while let chunk = try source.read(upToCount: Self.copyChunk), !chunk.isEmpty {
            try output.append(chunk)
        }
        try output.close()
    }

    private var stateDescription: String {
        String(cString: FLAC__stream_encoder_get_resolved_state_string(encoder))
    }
}
