import AVFoundation
import ImageIO
import os

struct PreviewAudioMetadata: Sendable {
    // Twice the largest artwork the panel draws.
    static let artworkPixelLimit = 512
    var title: String?
    var artist: String?
    var artwork: CGImage?

    // AVAsset isn't Sendable; artwork decodes off-main.
    @MainActor
    static func load(_ asset: AVAsset) async -> PreviewAudioMetadata {
        let items: [AVMetadataItem]
        do {
            items = try await asset.load(.commonMetadata)
        } catch {
            log("metadata", error)
            return PreviewAudioMetadata()
        }
        return PreviewAudioMetadata(
            title: await text(items, .commonIdentifierTitle), artist: await text(items, .commonIdentifierArtist),
            artwork: await artwork(items))
    }

    @MainActor
    private static func text(_ items: [AVMetadataItem], _ identifier: AVMetadataIdentifier) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first else {
            return nil
        }
        do {
            let value = try await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        } catch {
            log("text", error)
            return nil
        }
    }

    @MainActor
    private static func artwork(_ items: [AVMetadataItem]) async -> CGImage? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first
        else { return nil }
        do {
            guard let data = try await item.load(.dataValue) else { return nil }
            let image = try await offMain { decodeArtwork(data) }
            if image == nil { Logger(category: "finder-preview").notice("Embedded audio artwork could not be decoded") }
            return image
        } catch {
            log("artwork", error)
            return nil
        }
    }

    // Embedded artwork is untrusted; decode it bounded.
    private static func decodeArtwork(_ data: Data) -> CGImage? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: artworkPixelLimit,
            ] as CFDictionary)
    }

    private static func log(_ part: String, _ error: any Error) {
        Logger(category: "finder-preview").notice(
            "Audio \(part, privacy: .public) unavailable: \(error.localizedDescription, privacy: .private)")
    }
}
