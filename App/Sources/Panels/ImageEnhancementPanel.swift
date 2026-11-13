import Engine
import Foundation
import ImageIO
import Observation
import SwiftUI

@MainActor
@Observable
final class ImageEnhancementModel {
    let source: URL
    let dimensions: (width: Int, height: Int)?
    private let runBatch: @MainActor (Batch) -> Void
    private(set) var failure: String?

    init(source: URL, run: @escaping @MainActor (Batch) -> Void) {
        self.source = source
        runBatch = run
        dimensions = Self.dimensions(of: source)
    }

    var canRun: Bool {
        guard let dimensions, dimensions.height > 0 else { return false }
        return dimensions.width <= ImageEnhancement.maximumInputPixels / dimensions.height
    }

    func run() -> Bool {
        do {
            runBatch(try ImageEnhancement().makeBatch(source: source))
            return true
        } catch EngineError.unsupportedCodec(let requirement) {
            failure = requirement
            return false
        } catch {
            failure = UserMessages.describe(
                EngineError.wrapping(error, path: source.path), file: source.lastPathComponent)
            return false
        }
    }

    private static func dimensions(of source: URL) -> (width: Int, height: Int)? {
        guard
            let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(image, CGImageSourceGetPrimaryImageIndex(image), nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }
}

struct ImageEnhancementPanel: View {
    @Bindable var model: ImageEnhancementModel
    let close: () -> Void

    var body: some View {
        PanelForm(
            actionTitle: String(localized: "Upscale 2×"), canRun: model.canRun, cancel: close,
            run: {
                if model.run() { close() }
            }
        ) {
            Section("Local image upscaling") {
                LabeledContent("Source", value: model.source.lastPathComponent)
                if let dimensions = model.dimensions {
                    LabeledContent(
                        "Size",
                        value:
                            "\(dimensions.width) × \(dimensions.height) → \(dimensions.width * 2) × \(dimensions.height * 2) px"
                    )
                }
                LabeledContent("Output", value: String(localized: "New PNG next to the original"))
            }
            Section {
                Text("Uses the Swin2SR model on this Mac. No image is uploaded. The original is kept.")
                Text("Limit: 1 megapixel input. Animated, HDR, transparent and over-8-bit images are unsupported.")
                Text("Designed for small images. Processing can take several minutes.")
                    .foregroundStyle(.secondary)
                if !model.canRun {
                    ProblemLabel(text: String(localized: "Choose an image containing at most 1 megapixel."))
                }
            }
            if let failure = model.failure {
                Section { Text(failure).foregroundStyle(.red) }
            }
        }
    }
}
