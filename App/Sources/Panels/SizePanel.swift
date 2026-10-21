import Engine
import ImageIO
import SwiftUI
import os

struct SizeChoice: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case percent
        case width
        case height
        case fit
        case longEdge
    }

    var mode = Mode.percent
    var percent = 50.0
    var width = 1920
    var height = 1080
    var keepsAspect = true
    var allowsUpscale = false
}

/// Videos never upscale or stretch.
struct SizePanel: View {
    let isVideo: Bool
    let firstFile: URL
    @State var choice: SizeChoice
    let cancel: () -> Void
    let run: (SizeChoice) -> Void

    @State private var source: CGSize?

    private static let percentRange = 1.0...400.0
    private static let pixelRange = 1...65_535

    var body: some View {
        PanelForm(
            actionTitle: String(localized: "Resize", comment: "Size panel action"),
            canRun: choice.mode != .percent || Self.percentRange.contains(choice.percent), cancel: cancel
        ) {
            run(choice)
        } content: {
            Picker("Resize by", selection: $choice.mode) {
                ForEach(SizeChoice.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            valueFields
            if choice.mode == .fit, !isVideo {
                Toggle("Keep aspect ratio", isOn: $choice.keepsAspect)
            }
            if !isVideo {
                Toggle("Allow enlarging", isOn: $choice.allowsUpscale)
            }
            LabeledContent("Result for “\(firstFile.displayName)”") {
                Text(resultText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .task { source = await Self.dimensions(of: firstFile, isVideo: isVideo) }
    }

    @ViewBuilder private var valueFields: some View {
        switch choice.mode {
        case .percent:
            LabeledContent("Percent") {
                TextField("Percent", value: $choice.percent, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
            }
        case .width:
            NumberField(title: Text("Width (pixels)"), value: $choice.width, range: Self.pixelRange)
        case .height:
            NumberField(title: Text("Height (pixels)"), value: $choice.height, range: Self.pixelRange)
        case .fit:
            NumberField(title: Text("Width (pixels)"), value: $choice.width, range: Self.pixelRange)
            NumberField(title: Text("Height (pixels)"), value: $choice.height, range: Self.pixelRange)
        case .longEdge:
            NumberField(title: Text("Long edge (pixels)"), value: $choice.width, range: Self.pixelRange)
        }
    }

    private var resultText: String {
        guard let source, source.width > 0, source.height > 0 else {
            return String(localized: "Unknown size", comment: "Size panel preview without dimensions")
        }
        let result = choice.resulting(from: source, allowsUpscale: choice.allowsUpscale && !isVideo)
        return "\(Self.format(source)) → \(Self.format(result))"
    }

    private static func format(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }

    private static func dimensions(of url: URL, isVideo: Bool) async -> CGSize? {
        do {
            try OperationPlanner.validateInput(url)
            if isVideo {
                let preview = try await MediaPreview(videoAt: url)
                return CGSize(width: preview.displayWidth, height: preview.displayHeight)
            }
            return try await offMain { try imageDimensions(of: url) }
        } catch {
            let failure = error as NSError
            Logger(category: "panels").error(
                "No dimensions for preview (\(failure.domain, privacy: .public) \(failure.code, privacy: .public)): \(failure.localizedDescription, privacy: .private)"
            )
            return nil
        }
    }

    nonisolated private static func imageDimensions(of url: URL) throws -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw EngineError.decodeFailed("image properties") }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        // EXIF orientations 5–8 swap axes.
        let swapsAxes = orientation >= Self.firstQuarterTurnOrientation
        return swapsAxes ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    nonisolated private static let firstQuarterTurnOrientation = 5
}

extension SizeChoice {
    /// Videos fit a box per file.
    private static let unbounded = Int(Int32.max)
    private static let wholePercent = 100.0

    var imageResize: ImageResize {
        let size: ImageSize =
            switch mode {
            case .percent: .percent(percent)
            case .width: .width(width)
            case .height: .height(height)
            case .fit: keepsAspect ? .fit(width: width, height: height) : .exact(width: width, height: height)
            case .longEdge: .longEdge(width)
            }
        return ImageResize(size: size, allowsUpscale: allowsUpscale)
    }

    var videoResize: VideoResize {
        switch mode {
        case .percent: .percent(Int(percent.rounded()))
        case .width: .size(width: width, height: Self.unbounded)
        case .height: .size(width: Self.unbounded, height: height)
        case .fit: .size(width: width, height: height)
        case .longEdge: .size(width: width, height: width)
        }
    }

    func resulting(from source: CGSize, allowsUpscale: Bool) -> CGSize {
        if mode == .fit, !keepsAspect { return CGSize(width: width, height: height) }
        let scale: Double =
            switch mode {
            case .percent: percent / Self.wholePercent
            case .width: Double(width) / source.width
            case .height: Double(height) / source.height
            case .fit: min(Double(width) / source.width, Double(height) / source.height)
            case .longEdge: Double(width) / max(source.width, source.height)
            }
        let applied = allowsUpscale ? scale : min(scale, 1)
        return CGSize(width: (source.width * applied).rounded(), height: (source.height * applied).rounded())
    }
}

extension SizeChoice.Mode {
    var title: String {
        switch self {
        case .percent: String(localized: "Percentage", comment: "Resize mode")
        case .width: String(localized: "Width", comment: "Resize mode")
        case .height: String(localized: "Height", comment: "Resize mode")
        case .fit: String(localized: "Fit in box", comment: "Resize mode")
        case .longEdge: String(localized: "Long edge", comment: "Resize mode")
        }
    }
}
