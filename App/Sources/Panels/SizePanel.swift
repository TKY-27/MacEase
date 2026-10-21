import Engine
import ImageIO
import SwiftUI
import os

/// A blank dimension keeps proportions.
struct SizeChoice: Codable, Equatable {
    static let pixelRange = 1...65_535

    var width: Int?
    var height: Int?
    var allowsUpscale = false

    var isValid: Bool {
        (width != nil || height != nil)
            && [width, height].allSatisfy { $0.map(Self.pixelRange.contains) ?? true }
    }
}

/// Videos never upscale or stretch.
struct SizePanel: View {
    let isVideo: Bool
    let firstFile: URL
    @State var choice: SizeChoice
    let cancel: () -> Void
    let run: (SizeChoice) -> Void

    @State private var source: CGSize?
    @FocusState private var widthFocused: Bool

    private static let fieldWidth: CGFloat = 96

    var body: some View {
        PanelForm(
            actionTitle: String(localized: "Resize", comment: "Size panel action"),
            canRun: choice.options(isVideo: isVideo) != nil,
            cancel: cancel
        ) {
            run(choice)
        } content: {
            Section {
                dimensionField(String(localized: "Width", comment: "Size panel field"), value: $choice.width)
                    .focused($widthFocused)
                dimensionField(String(localized: "Height", comment: "Size panel field"), value: $choice.height)
                if !isVideo {
                    Toggle("Allow enlarging", isOn: $choice.allowsUpscale)
                }
            } footer: {
                footer
            }
            LabeledContent {
                Text(resultText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } label: {
                Text(firstFile.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .task { source = await Self.dimensions(of: firstFile, isVideo: isVideo) }
        .onAppear { widthFocused = true }
    }

    private func dimensionField(_ title: String, value: Binding<Int?>) -> some View {
        LabeledContent(title) {
            HStack(spacing: PanelLayout.unitSpacing) {
                TextField(title, value: value, format: .number.grouping(.never), prompt: Text("Auto"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: Self.fieldWidth)
                Text("px", comment: "Pixel unit after a size field")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        let outOfRange = [choice.width, choice.height].contains {
            $0.map { !SizeChoice.pixelRange.contains($0) } ?? false
        }
        if outOfRange {
            ProblemLabel(
                text: String(
                    localized:
                        "Enter sizes from \(SizeChoice.pixelRange.lowerBound) to \(SizeChoice.pixelRange.upperBound) pixels.",
                    comment: "Size panel validation"))
        } else {
            Text("Leave one field empty to keep proportions. Fill both to fit inside.")
                .foregroundStyle(.secondary)
        }
    }

    private var resultText: String {
        guard let source, source.width > 0, source.height > 0 else {
            return String(localized: "Unknown size", comment: "Size panel preview without dimensions")
        }
        guard choice.isValid else { return Self.format(source) }
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

    func options(isVideo: Bool) -> OperationOptions? {
        guard isValid else { return nil }
        if isVideo { return .video(.resize(.size(width: width ?? Self.unbounded, height: height ?? Self.unbounded))) }
        let size: ImageSize
        switch (width, height) {
        case (let width?, let height?): size = .fit(width: width, height: height)
        case (let width?, nil): size = .width(width)
        case (nil, let height?): size = .height(height)
        case (nil, nil): return nil
        }
        return .image(.resize(ImageResize(size: size, allowsUpscale: allowsUpscale)))
    }

    func resulting(from source: CGSize, allowsUpscale: Bool) -> CGSize {
        let scales = [
            width.map { Double($0) / source.width }, height.map { Double($0) / source.height },
        ].compactMap { $0 }
        let scale = scales.min() ?? 1
        let applied = allowsUpscale ? scale : min(scale, 1)
        return CGSize(width: (source.width * applied).rounded(), height: (source.height * applied).rounded())
    }
}
