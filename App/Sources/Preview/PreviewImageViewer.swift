import AppKit
import Engine
import ImageIO
import SwiftUI
import os

private struct PreviewImageFrame: Sendable {
    let pixels: CGImage
    let delay: Double
}

private actor PreviewImageSource {
    private var source: CGImageSource?
    private var maximumEdge = 0
    private static let defaultDelay = 0.1
    private static let minimumDelay = 0.02
    // Bounds decode memory; larger images preview downscaled.
    private static let maximumPreviewEdge = 4096

    func open(_ url: URL) throws -> (frameCount: Int, first: PreviewImageFrame) {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { throw CocoaError(.fileReadCorruptFile) }
        self.source = source
        maximumEdge = min(max(width, height), Self.maximumPreviewEdge)
        let first = try frame(0)
        let animated =
            properties[kCGImagePropertyGIFDictionary] != nil
            || properties[kCGImagePropertyPNGDictionary] != nil || properties[kCGImagePropertyWebPDictionary] != nil
        return (animated ? CGImageSourceGetCount(source) : 1, first)
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
    @State private var fit = true
    @State private var zoomRequest = 0
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            PreviewToolbar {
                Button("Fit") {
                    fit = true; zoomRequest += 1
                }
                Button("100%") {
                    fit = false; zoomRequest += 1
                }
            }
            .disabled(pixels == nil)
            Group {
                if failed {
                    PreviewFailure()
                } else if let pixels {
                    PreviewImageCanvas(pixels: pixels, fit: fit, zoomRequest: zoomRequest)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
        .task { await load() }
        .onDisappear { pixels = nil }
    }

    private func load() async {
        let source = PreviewImageSource()
        do {
            let (frameCount, first) = try await source.open(url)
            try Task.checkCancellation()
            pixels = first.pixels
            guard frameCount > 1 else { return }
            var delay = first.delay
            var index = 1
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(delay))
                let frame = try await source.frame(index)
                try Task.checkCancellation()
                pixels = frame.pixels
                delay = frame.delay
                index = (index + 1) % frameCount
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
        scroll.contentView = CenteringClipView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
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

    final class CenteringClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            var bounds = super.constrainBoundsRect(proposedBounds)
            guard let documentView else { return bounds }
            let content = documentView.frame
            if bounds.width > content.width { bounds.origin.x = (content.width - bounds.width) / 2 }
            if bounds.height > content.height { bounds.origin.y = (content.height - bounds.height) / 2 }
            return bounds
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
    }
}
