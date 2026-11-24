import AVFoundation
import ImageIO
import os

struct PreviewAudioMetadata: Sendable {
    // Twice the largest artwork the panel draws.
    static let artworkPixelLimit = 512
    static let artworkByteLimit = 16 << 20
    static let artworkSourceEdgePixelsLimit = 8_192
    static let artworkSourcePixelLimit = 32_000_000
    var title: String?
    var artist: String?
    var artwork: CGImage?

    // AVAsset isn't Sendable; artwork decodes off-main.
    @MainActor
    static func load(_ asset: AVAsset) async -> PreviewAudioMetadata {
        guard !Task.isCancelled else { return PreviewAudioMetadata() }
        let entries: [AVMetadataItem]
        do {
            entries = try await asset.load(.commonMetadata)
        } catch is CancellationError {
            return PreviewAudioMetadata()
        } catch {
            guard !Task.isCancelled else { return PreviewAudioMetadata() }
            log("metadata", error)
            return PreviewAudioMetadata()
        }
        guard !Task.isCancelled else { return PreviewAudioMetadata() }
        let title = await text(entries, .commonIdentifierTitle)
        guard !Task.isCancelled else { return PreviewAudioMetadata() }
        let artist = await text(entries, .commonIdentifierArtist)
        guard !Task.isCancelled else { return PreviewAudioMetadata() }
        let cover = await artwork(entries)
        guard !Task.isCancelled else { return PreviewAudioMetadata() }
        return PreviewAudioMetadata(title: title, artist: artist, artwork: cover)
    }

    @MainActor
    private static func text(_ entries: [AVMetadataItem], _ identifier: AVMetadataIdentifier) async -> String? {
        guard !Task.isCancelled,
            let entry = AVMetadataItem.metadataItems(from: entries, filteredByIdentifier: identifier).first
        else { return nil }
        do {
            let value = try await entry.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Task.isCancelled else { return nil }
            return value?.isEmpty == false ? value : nil
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            log("text", error)
            return nil
        }
    }

    @MainActor
    private static func artwork(_ entries: [AVMetadataItem]) async -> CGImage? {
        guard !Task.isCancelled,
            let entry = AVMetadataItem.metadataItems(from: entries, filteredByIdentifier: .commonIdentifierArtwork)
                .first
        else { return nil }
        do {
            guard let encodedArtwork = try await entry.load(.dataValue) else { return nil }
            try Task.checkCancellation()
            guard encodedArtwork.count <= artworkByteLimit else {
                Logger(category: "finder-preview").notice("Embedded audio artwork exceeds byte limit")
                return nil
            }
            let image = try await offMain {
                try Task.checkCancellation()
                return decodeArtwork(encodedArtwork)
            }
            guard !Task.isCancelled else { return nil }
            if image == nil { Logger(category: "finder-preview").notice("Embedded audio artwork could not be decoded") }
            return image
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            log("artwork", error)
            return nil
        }
    }

    // Embedded artwork is untrusted; decode it bounded.
    static func decodeArtwork(_ encodedArtwork: Data) -> CGImage? {
        guard encodedArtwork.count <= artworkByteLimit,
            let source = CGImageSourceCreateWithData(
                encodedArtwork as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0,
            width <= artworkSourceEdgePixelsLimit, height <= artworkSourceEdgePixelsLimit
        else { return nil }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= artworkSourcePixelLimit else { return nil }
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
