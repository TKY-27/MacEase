import Engine
import Formats
import SwiftUI
import os

struct AnimationChoice: Codable, Equatable {
    var width = 480
    var framesPerSecond = 15
    var colors = 256
    var dithering = Dithering.ordered
    var loops = true
    var usesRange = false
    var start = 0.0
    var end = 0.0

    var rendering: AnimationRendering {
        var rendering = AnimationRendering(width: width, framesPerSecond: framesPerSecond)
        rendering.colors = colors
        rendering.dithering = dithering
        rendering.loops = loops
        rendering.start = usesRange ? start : nil
        rendering.end = usesRange ? end : nil
        return rendering
    }
}

/// GIF, and APNG without palette controls.
struct AnimationPanel: View {
    let firstFile: URL
    let isGIF: Bool
    @State var choice: AnimationChoice
    let cancel: () -> Void
    let run: (AnimationChoice) -> Void

    @State private var preview: MediaPreview?

    private static let widthRange = 16...3840
    private static let frameRateRange = 1...50
    private static let colorRange = 2...256
    /// Typical LZW output for dithered palette frames.
    private static let gifCompressionRatio = 0.5
    /// Typical deflate output for full-color frames.
    private static let pngCompressionRatio = 0.6
    private static let pngBitsPerPixel = 32.0
    private static let bitsPerByte = 8.0

    var body: some View {
        PanelForm(
            actionTitle: String(localized: "Create", comment: "Animation panel action"), canRun: rangeIsValid,
            cancel: cancel
        ) {
            run(choice)
        } content: {
            Section {
                Toggle("Only part of the video", isOn: $choice.usesRange)
                if choice.usesRange {
                    SecondsField(
                        title: String(localized: "Start (seconds)", comment: "Trim field"), value: $choice.start)
                    SecondsField(title: String(localized: "End (seconds)", comment: "Trim field"), value: $choice.end)
                }
            }
            Section {
                NumberField(title: Text("Width (pixels)"), value: $choice.width, range: Self.widthRange)
                NumberField(title: Text("Frame rate (fps)"), value: $choice.framesPerSecond, range: Self.frameRateRange)
                if isGIF {
                    NumberField(title: Text("Colors"), value: $choice.colors, range: Self.colorRange)
                    Picker("Dithering", selection: $choice.dithering) {
                        ForEach(Dithering.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Toggle("Loop", isOn: $choice.loops)
            }
            LabeledContent("Estimated size") {
                Text(estimate.map { String(localized: "About \($0.fileSize)", comment: "Estimated file size") } ?? "—")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            do {
                preview = try await MediaPreview(videoAt: firstFile)
            } catch {
                Logger(category: "panels").error("No video preview: \(error, privacy: .public)")
            }
        }
    }

    private var rangeIsValid: Bool {
        guard choice.usesRange else { return true }
        let duration = preview?.durationSeconds ?? .infinity
        return 0 <= choice.start && choice.start < choice.end && choice.end <= duration
    }

    /// Rough, but enough to pick settings.
    private var estimate: Int64? {
        guard let preview, preview.displayWidth > 0 else { return nil }
        let width = Double(min(choice.width, preview.displayWidth))
        let height = width * Double(preview.displayHeight) / Double(preview.displayWidth)
        let seconds = choice.usesRange ? max(choice.end - choice.start, 0) : preview.durationSeconds
        let frames = (seconds * Double(choice.framesPerSecond)).rounded(.up)
        let bitsPerPixel = isGIF ? log2(Double(choice.colors)) : Self.pngBitsPerPixel
        let ratio = isGIF ? Self.gifCompressionRatio : Self.pngCompressionRatio
        return Int64(frames * width * height * bitsPerPixel / Self.bitsPerByte * ratio)
    }
}
