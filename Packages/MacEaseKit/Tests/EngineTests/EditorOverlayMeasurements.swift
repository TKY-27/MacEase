import CoreGraphics
import CoreImage
import Foundation
import Testing

@testable import Engine

@Suite(.serialized) struct EditorOverlayMeasurements {
    private static let iterations = 120
    private static let warmupIterations = 10

    @Test func measureAnnotationBitmapAndContentCacheCost() throws {
        let size = CGSize(width: 1280, height: 720)
        let canvas = CGSize(width: 1920, height: 1080)
        for count in [1, EditOverlay.maximumCount] {
            let overlays = (0..<count).map { index in
                EditOverlay(
                    mark: .text(
                        "Annotation \(index)", at: EditPoint(x: 0.5, y: Double(index + 1) / Double(count + 1)),
                        color: .white, size: .small))
            }
            let cache = EditAnnotationCache()
            for cached in [false, true] {
                var milliseconds: [Double] = []
                for iteration in 0..<(Self.warmupIterations + Self.iterations) {
                    let elapsed = try autoreleasepool {
                        let start = ContinuousClock.now
                        let layer = try #require(
                            cached
                                ? cache.layer(
                                    for: overlays, size: size, geometry: EditGeometry(), canvas: canvas,
                                    fullOutputSize: canvas)
                                : overlays.annotationLayer(
                                    size: size, geometry: EditGeometry(), canvas: canvas,
                                    fullOutputSize: canvas))
                        #expect(layer.extent.size == size)
                        return (ContinuousClock.now - start) / .seconds(1) * 1000
                    }
                    if iteration >= Self.warmupIterations { milliseconds.append(elapsed) }
                }
                milliseconds.sort()
                let median = milliseconds[Self.iterations / 2]
                let percentile95 = milliseconds[Int(Double(Self.iterations) * 0.95)]
                print(
                    String(
                        format: "EDITOR_OVERLAY count=%d cached=%@ median_ms=%.4f p95_ms=%.4f",
                        count, String(cached), median, percentile95))
            }
        }
    }
}
