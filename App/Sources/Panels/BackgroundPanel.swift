import AppKit
import Engine
import SwiftUI

struct BackgroundChoice: Codable, Equatable {
    enum Mask: String, Codable, CaseIterable {
        case subject
        case person
        case colorKey
    }

    enum Output: String, Codable, CaseIterable {
        case transparent
        case green
        case blue
        case custom
        case blur
    }

    var mask = Mask.subject
    var keyColor = Engine.RGBColor.white
    var tolerance = 0.12
    var output = Output.transparent
    var customColor = Engine.RGBColor.white
    var blurRadius = BackgroundOptions.defaultBlurRadius
    var videoFormat = TransparentVideoFormat.hevcAlpha

    func imageOptions(green: Engine.RGBColor, blue: Engine.RGBColor) -> BackgroundOptions {
        let source: MaskSource =
            switch mask {
            case .subject: .subject
            case .person: .person
            case .colorKey: .colorKey(keyColor, tolerance: tolerance)
            }
        let fill: BackgroundFill =
            switch output {
            case .transparent: .transparent
            case .green: .color(green)
            case .blue: .color(blue)
            case .custom: .color(customColor)
            case .blur: .blur(radius: blurRadius)
            }
        return BackgroundOptions(mask: source, fill: fill)
    }
}

/// Shared by image and video background removal.
struct BackgroundPanel: View {
    let isVideo: Bool
    @State var choice: BackgroundChoice
    let cancel: () -> Void
    let run: (BackgroundChoice) -> Void

    private static let toleranceRange = 0.0...1.0
    private static let blurRange = 1.0...100.0

    var body: some View {
        PanelForm(
            actionTitle: String(localized: "Replace Background", comment: "Background panel action"), cancel: cancel
        ) {
            run(choice)
        } content: {
            Section {
                Picker("Find", selection: $choice.mask) {
                    ForEach(masks, id: \.self) { Text($0.title).tag($0) }
                }
                if choice.mask == .colorKey {
                    LabeledContent("Key color") {
                        HStack {
                            ColorPicker("Key color", selection: $choice.keyColor.color, supportsOpacity: false)
                                .labelsHidden()
                            Button("Pick from Screen", systemImage: "eyedropper", action: sampleKeyColor)
                                .labelStyle(.iconOnly)
                                .help(Text("Pick from Screen"))
                        }
                    }
                    LabeledContent {
                        Slider(value: $choice.tolerance, in: Self.toleranceRange) { Text("Tolerance") }
                            .labelsHidden()
                    } label: {
                        Text("Tolerance")
                        Text(choice.tolerance, format: .percent.precision(.fractionLength(0)))
                    }
                }
            }
            Section {
                Picker("Background", selection: $choice.output) {
                    ForEach(BackgroundChoice.Output.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if choice.output == .custom {
                    ColorPicker("Color", selection: $choice.customColor.color, supportsOpacity: false)
                }
                if choice.output == .blur {
                    LabeledContent {
                        Slider(value: $choice.blurRadius, in: Self.blurRange) { Text("Blur radius") }
                            .labelsHidden()
                    } label: {
                        Text("Blur radius")
                        Text(choice.blurRadius, format: .number.precision(.fractionLength(0)))
                    }
                }
                if isVideo, choice.output == .transparent {
                    Picker("Video format", selection: $choice.videoFormat) {
                        ForEach(TransparentVideoFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
        }
    }

    /// The video matte uses Vision masks only.
    private var masks: [BackgroundChoice.Mask] {
        isVideo ? [.person, .subject] : BackgroundChoice.Mask.allCases
    }

    private func sampleKeyColor() {
        NSColorSampler().show { picked in
            guard let rgb = picked.flatMap({ Engine.RGBColor(Color(nsColor: $0)) }) else { return }
            Task { @MainActor in choice.keyColor = rgb }
        }
    }
}

extension BackgroundChoice.Mask {
    var title: String {
        switch self {
        case .subject: String(localized: "Main subject", comment: "Background mask source")
        case .person: String(localized: "People", comment: "Background mask source")
        case .colorKey: String(localized: "Color key", comment: "Background mask source")
        }
    }
}

extension BackgroundChoice.Output {
    var title: String {
        switch self {
        case .transparent: String(localized: "Transparent", comment: "Background output")
        case .green: String(localized: "Green", comment: "Background output")
        case .blue: String(localized: "Blue", comment: "Background output")
        case .custom: String(localized: "Custom color", comment: "Background output")
        case .blur: String(localized: "Blurred", comment: "Background output")
        }
    }
}
