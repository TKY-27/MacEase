import AVFoundation
import Foundation

enum AudioMetadataLoss {
    private static let regeneratedIdentifiers: Set<AVMetadataIdentifier> = [
        .commonIdentifierSoftware, .quickTimeUserDataSoftware, .quickTimeMetadataSoftware,
        .iTunesMetadataEncodingTool, .id3MetadataEncodedWith,
        AVMetadataIdentifier(rawValue: "vorb/VENDOR"), AVMetadataIdentifier(rawValue: "vorb/ENCODER"),
        AVMetadataIdentifier(rawValue: "itlk/com.apple.iTunes.iTunSMPB"),
        AVMetadataIdentifier(rawValue: "caaf/info-approximate%20duration%20in%20seconds"),
    ]

    static func hasUnsupportedTags(_ url: URL) async throws -> Bool {
        for entry in try await AVURLAsset(url: url).load(.metadata) {
            try Task.checkCancellation()
            switch entry.commonKey {
            case .commonKeyTitle, .commonKeyArtist, .commonKeyAlbumName, .commonKeyArtwork, .commonKeySoftware: continue
            default: break
            }
            if let identifier = entry.identifier, regeneratedIdentifiers.contains(identifier) { continue }
            if let text = try await entry.load(.stringValue), text.isEmpty { continue }
            return true
        }
        return false
    }
}
