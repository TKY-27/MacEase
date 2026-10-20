import Foundation

public struct Artwork: Equatable, Sendable {
    public var data: Data
    public var mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

/// The tags MacEase carries across audio conversions.
public struct AudioTags: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var artwork: Artwork?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, artwork: Artwork? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
    }

    public var isEmpty: Bool { self == AudioTags() }
}

/// Bounds-checked little- and big-endian reads.
struct ByteCursor {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: some Sequence<UInt8>) {
        self.bytes = Array(bytes)
    }

    var remaining: Int { bytes.count - offset }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw FormatError.corrupt("truncated audio header") }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func uint8() throws -> UInt8 { try take(1)[0] }

    mutating func uint16LE() throws -> UInt16 { UInt16(littleEndian: try take(2), at: 0) }

    mutating func uint32LE() throws -> UInt32 { UInt32(littleEndian: try take(4), at: 0) }

    mutating func uint32BE() throws -> UInt32 { UInt32(bigEndian: try take(4), at: 0) }

    mutating func uint64LE() throws -> UInt64 {
        UInt64(try uint32LE()) | UInt64(try uint32LE()) << 32
    }
}

/// Xiph comments for Vorbis, Opus and FLAC.
public enum VorbisComment {
    static let vendor = "MacEase"
    private static let pictureField = "METADATA_BLOCK_PICTURE"

    /// Without Vorbis's trailing framing bit.
    public static func encode(_ tags: AudioTags) -> Data {
        var fields: [String] = []
        if let title = tags.title { fields.append("TITLE=\(title)") }
        if let artist = tags.artist { fields.append("ARTIST=\(artist)") }
        if let album = tags.album { fields.append("ALBUM=\(album)") }
        if let artwork = tags.artwork {
            fields.append("\(pictureField)=\(FLACPicture.encode(artwork).base64EncodedString())")
        }
        var body = Data()
        body.appendLittleEndian(UInt32(vendor.utf8.count))
        body.append(Data(vendor.utf8))
        body.appendLittleEndian(UInt32(fields.count))
        for field in fields {
            body.appendLittleEndian(UInt32(field.utf8.count))
            body.append(Data(field.utf8))
        }
        return body
    }

    public static func decode(_ body: some Sequence<UInt8>) throws -> AudioTags {
        var cursor = ByteCursor(body)
        _ = try cursor.take(Int(try cursor.uint32LE()))
        let count = Int(try cursor.uint32LE())
        var tags = AudioTags()
        for _ in 0..<count {
            let field = String(decoding: try cursor.take(Int(try cursor.uint32LE())), as: UTF8.self)
            guard let separator = field.firstIndex(of: "=") else { continue }
            let value = String(field[field.index(after: separator)...])
            switch field[..<separator].uppercased() {
            case "TITLE": tags.title = tags.title ?? value
            case "ARTIST": tags.artist = tags.artist ?? value
            case "ALBUM": tags.album = tags.album ?? value
            case pictureField where tags.artwork == nil:
                guard let block = Data(base64Encoded: value) else { throw FormatError.corrupt("picture is not base64") }
                tags.artwork = try FLACPicture.decode(block)
            default: break
            }
        }
        return tags
    }
}

/// FLAC PICTURE block body, also Ogg's METADATA_BLOCK_PICTURE.
public enum FLACPicture {
    private static let frontCover: UInt32 = 3

    public static func encode(_ artwork: Artwork) -> Data {
        var body = Data()
        body.appendBigEndian(frontCover)
        body.appendBigEndian(UInt32(artwork.mimeType.utf8.count))
        body.append(Data(artwork.mimeType.utf8))
        // Empty description and unknown dimensions.
        for _ in 0..<5 { body.appendBigEndian(UInt32(0)) }
        body.appendBigEndian(UInt32(artwork.data.count))
        body.append(artwork.data)
        return body
    }

    public static func decode(_ body: some Sequence<UInt8>) throws -> Artwork {
        var cursor = ByteCursor(body)
        _ = try cursor.uint32BE()
        let mimeType = String(decoding: try cursor.take(Int(try cursor.uint32BE())), as: UTF8.self)
        _ = try cursor.take(Int(try cursor.uint32BE()))
        _ = try cursor.take(16)
        let data = Data(try cursor.take(Int(try cursor.uint32BE())))
        return Artwork(data: data, mimeType: mimeType)
    }
}
