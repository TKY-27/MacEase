import AppKit
import Engine
import ImageIO
import SwiftUI
import os

private struct PreviewImageFrame: Sendable {
    let pixels: CGImage
    let delay: Double
}

private struct PreviewImageDetails: Sendable {
    let width: Int
    let height: Int
    let profile: String
    let hdr: Bool
    let byteCount: Int64
    let frameCount: Int
}

private actor PreviewImageSource {
    private var source: CGImageSource?
    private var maximumEdge = 0
    private static let defaultDelay = 0.1
    private static let minimumDelay = 0.02

    func open(_ url: URL) throws -> (PreviewImageDetails, PreviewImageFrame) {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { throw CocoaError(.fileReadCorruptFile) }
        self.source = source
        maximumEdge = max(width, height)
        let signal = try ImageSDR.content(source, index: 0)
        let first = try frame(0)
        let animated =
            properties[kCGImagePropertyGIFDictionary] != nil
            || properties[kCGImagePropertyPNGDictionary] != nil || properties[kCGImagePropertyWebPDictionary] != nil
        let profile =
            properties[kCGImagePropertyProfileName] as? String
            ?? first.pixels.colorSpace?.name.map { $0 as String } ?? String(localized: "Unknown Color Space")
        let hdr = signal.gainMap || signal.pixels
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let byteCount = attributes.fileSize else { throw CocoaError(.fileReadUnknown) }
        return (
            PreviewImageDetails(
                width: width, height: height, profile: profile, hdr: hdr, byteCount: Int64(byteCount),
                frameCount: animated ? CGImageSourceGetCount(source) : 1), first
        )
    }

    func frame(_ index: Int) throws -> PreviewImageFrame {
        try Task.checkCancellation()
        guard let source,
            let pixels = CGImageSourceCreateThumbnailAtIndex(
                source, index,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
                    kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
                ] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        let timings: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        var delay = Self.defaultDelay
        for (dictionary, unclamped, clamped) in timings {
            if let animation = properties[dictionary] as? [CFString: Any],
                let duration = (animation[unclamped] ?? animation[clamped]) as? Double, duration.isFinite
            {
                delay = max(Self.minimumDelay, duration); break
            }
        }
        try Task.checkCancellation()
        return PreviewImageFrame(pixels: pixels, delay: delay)
    }
}

struct PreviewImageViewer: View {
    let url: URL
    @State private var pixels: CGImage?
    @State private var details: PreviewImageDetails?
    @State private var fit = true
    @State private var zoomRequest = 0
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Fit") {
                    fit = true; zoomRequest += 1
                }
                Button("100%") {
                    fit = false; zoomRequest += 1
                }
                Spacer()
            }
            .controlSize(.small).padding(8)
            Divider()
            if failed {
                PreviewFailure()
            } else if let pixels {
                PreviewImageCanvas(pixels: pixels, fit: fit, zoomRequest: zoomRequest)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let details {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(details.width) × \(details.height) pixels · \(details.byteCount.fileSize)")
                    Text(verbatim: details.profile)
                    Text(details.hdr ? String(localized: "HDR: Yes") : String(localized: "HDR: No"))
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
        .task { await load() }
        .onDisappear {
            pixels = nil; details = nil
        }
    }

    private func load() async {
        let source = PreviewImageSource()
        do {
            let (metadata, first) = try await source.open(url)
            try Task.checkCancellation()
            details = metadata
            pixels = first.pixels
            guard metadata.frameCount > 1 else { return }
            var delay = first.delay
            var index = 1
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(delay))
                let frame = try await source.frame(index)
                try Task.checkCancellation()
                pixels = frame.pixels
                delay = frame.delay
                index = (index + 1) % metadata.frameCount
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            pixels = nil
            failed = true
            Logger(category: "finder-preview").error(
                "Preview image failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

private struct PreviewImageCanvas: NSViewRepresentable {
    let pixels: CGImage
    let fit: Bool
    let zoomRequest: Int

    func makeNSView(context: Context) -> PreviewImageScroll {
        let scroll = PreviewImageScroll()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.01
        scroll.maxMagnification = 16
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.setAccessibilityLabel(String(localized: "Image Preview"))
        scroll.documentView = image
        return scroll
    }

    func updateNSView(_ scroll: PreviewImageScroll, context: Context) {
        guard let image = scroll.documentView as? NSImageView else { return }
        let size = NSSize(width: pixels.width, height: pixels.height)
        image.image = NSImage(cgImage: pixels, size: size)
        image.setFrameSize(size)
        if scroll.zoomRequest != zoomRequest {
            scroll.zoomRequest = zoomRequest
            scroll.fitting = fit
            scroll.adjustZoom()
        }
    }

    final class PreviewImageScroll: NSScrollView {
        var zoomRequest = -1
        var fitting = true

        override func layout() {
            super.layout()
            if fitting { adjustZoom() }
        }

        func adjustZoom() {
            guard let documentView, documentView.bounds.width > 0, documentView.bounds.height > 0 else { return }
            let scale =
                fitting
                ? min(contentSize.width / documentView.bounds.width, contentSize.height / documentView.bounds.height)
                : 1 / (window?.backingScaleFactor ?? 1)
            let target = max(minMagnification, min(maxMagnification, scale))
            if abs(magnification - target) > 0.001 { magnification = target }
        }

        override func magnify(with event: NSEvent) {
            fitting = false
            super.magnify(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            fitting = false
            let target = magnification * exp(-event.scrollingDeltaY * 0.01)
            setMagnification(
                max(minMagnification, min(maxMagnification, target)),
                centeredAt: NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY))
        }
    }
}
