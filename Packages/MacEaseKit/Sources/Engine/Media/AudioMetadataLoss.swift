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

    private static let streamKinds: [AVMetadataIdentifier: UnpreservedStream] = [
        AVMetadataIdentifier(rawValue: "id3/CHAP"): .chapter,
        AVMetadataIdentifier(rawValue: "id3/CTOC"): .chapter,
        .id3MetadataGeneralEncapsulatedObject: .attachment,
        .id3MetadataSynchronizedLyric: .subtitle,
        .id3MetadataEventTimingCodes: .data,
        .id3MetadataPrivate: .data,
        .id3MetadataMPEGLocationLookupTable: .data,
        .id3MetadataSynchronizedTempoCodes: .data,
    ]

    static func hasUnsupportedTags(_ url: URL, omitting streams: Set<UnpreservedStream> = []) async throws -> Bool {
        for entry in try await AVURLAsset(url: url).load(.metadata) {
            try Task.checkCancellation()
            switch entry.commonKey {
            case .commonKeyTitle, .commonKeyArtist, .commonKeyAlbumName, .commonKeyArtwork, .commonKeySoftware: continue
            default: break
            }
            if let identifier = entry.identifier {
                if regeneratedIdentifiers.contains(identifier) { continue }
                if let kind = streamKinds[identifier], streams.contains(kind) { continue }
            }
            if let text = try await entry.load(.stringValue), text.isEmpty { continue }
            return true
        }
        return false
    }
}
