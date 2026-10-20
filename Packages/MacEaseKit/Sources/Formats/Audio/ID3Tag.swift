import Foundation

/// ID3v2.4 with UTF-8 text.
public enum ID3Tag {
    private static let utf8Encoding: UInt8 = 3
    private static let frontCover: UInt8 = 3
    private static let version: [UInt8] = [4, 0]
    private static let synchsafeBits = 7

    /// Empty when there is nothing to write.
    public static func encode(_ tags: AudioTags) -> Data {
        var frames = Data()
        for (id, text) in [("TIT2", tags.title), ("TPE1", tags.artist), ("TALB", tags.album)] {
            guard let text else { continue }
            frames += frame(id, Data([utf8Encoding]) + Data(text.utf8))
        }
        if let artwork = tags.artwork {
            var body = Data([utf8Encoding]) + Data(artwork.mimeType.utf8) + Data([0, frontCover, 0])
            body.append(artwork.data)
            frames += frame("APIC", body)
        }
        guard !frames.isEmpty else { return Data() }
        var tag = Data("ID3".utf8)
        tag.append(contentsOf: version)
        tag.append(0)
        tag.append(synchsafe(frames.count))
        tag.append(frames)
        return tag
    }

    private static func frame(_ id: String, _ body: Data) -> Data {
        Data(id.utf8) + synchsafe(body.count) + Data([0, 0]) + body
    }

    private static func synchsafe(_ value: Int) -> Data {
        Data((0..<4).reversed().map { UInt8(value >> ($0 * synchsafeBits) & 0x7F) })
    }
}
