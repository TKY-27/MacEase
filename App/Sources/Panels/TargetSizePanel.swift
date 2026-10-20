import Engine
import SwiftUI

struct TargetSizeChoice: Codable, Equatable {
    enum Goal: String, Codable, CaseIterable {
        case size
        case quality
        case preset
    }

    var goal = Goal.size
    var megabytes = 10.0
    var quality = 75
    var presetID = ""
    var allowsDownscale = true
    var allowsFrameRateReduction = true
    var stripsGPS = true
}

/// Other families plug in here.
struct TargetSizeFamily {
    /// The quality slider snaps to these.
    let qualityLevels: [Int]
    let qualityText: (Int) -> String
    let limits: (PlatformPreset) -> MediaLimits?
    var offersDownscale = false
    var offersFrameRateReduction = false
    var offersGPS = false
    /// `nil` when the preset vanished.
    let options: (TargetSizeChoice, PlatformPreset?) -> OperationOptions?

    private static let bytesPerMegabyte = 1_000_000.0
    private static let percent = 100.0

    static func bytes(_ megabytes: Double) -> Int64 {
        Int64((megabytes * bytesPerMegabyte).rounded(.down))
    }

    static var image: TargetSizeFamily {
        TargetSizeFamily(
            qualityLevels: Array(0...100), qualityText: { "\($0)" }, limits: \.image, offersDownscale: true,
            offersFrameRateReduction: true, offersGPS: true
        ) { choice, preset in
            let goal: CompressionGoal
            switch choice.goal {
            case .size: goal = .bytes(bytes(choice.megabytes))
            case .quality: goal = .quality(choice.quality)
            case .preset:
                guard let preset else { return nil }
                goal = .platform(preset)
            }
            return .image(
                .compress(
                    ImageCompression(
                        goal: goal, allowsDownscale: choice.allowsDownscale,
                        allowsFrameRateReduction: choice.allowsFrameRateReduction, stripsGPS: choice.stripsGPS)))
        }
    }

    /// Video output never carries location metadata.
    static var video: TargetSizeFamily {
        TargetSizeFamily(
            qualityLevels: Array(0...100), qualityText: { "\($0)" }, limits: \.video, offersDownscale: true,
            offersFrameRateReduction: true
        ) { choice, preset in
            let goal: VideoCompression.Goal
            switch choice.goal {
            case .size: goal = .bytes(bytes(choice.megabytes))
            case .quality: goal = .quality(Double(choice.quality) / percent)
            case .preset:
                guard let preset else { return nil }
                goal = .platform(preset)
            }
            return .video(
                .compress(
                    VideoCompression(
                        goal: goal, allowsDownscale: choice.allowsDownscale,
                        allowsFrameRateReduction: choice.allowsFrameRateReduction)))
        }
    }

    static var audio: TargetSizeFamily {
        TargetSizeFamily(
            qualityLevels: [64, 96, 128, 160, 192, 256, 320],
            qualityText: { String(localized: "\($0) kbps", comment: "Audio bitrate") }, limits: \.audio
        ) { choice, preset in
            switch choice.goal {
            case .size: .audio(.compress(.targetBytes(bytes(choice.megabytes))))
            case .quality: .audio(.compress(.kilobits(choice.quality)))
            case .preset: preset?.audio?.targetBytes.map { .audio(.compress(.targetBytes($0))) }
            }
        }
    }
}

struct TargetSizePanel: View {
    let family: TargetSizeFamily
    /// Already filtered to this family.
    let presets: [PlatformPreset]
    @State var choice: TargetSizeChoice
    let cancel: () -> Void
    let run: (TargetSizeChoice, OperationOptions) -> Void

    private static let smallestMegabytes = 0.01

    var body: some View {
        PanelForm(
            actionTitle: String(localized: "Compress", comment: "Target size panel action"), canRun: options != nil,
            cancel: cancel
        ) {
            if let options { run(choice, options) }
        } content: {
            Picker("Goal", selection: $choice.goal) {
                Text("File size").tag(TargetSizeChoice.Goal.size)
                Text("Quality").tag(TargetSizeChoice.Goal.quality)
                if !presets.isEmpty {
                    Text("Platform").tag(TargetSizeChoice.Goal.preset)
                }
            }
            .pickerStyle(.segmented)
            goalControls
            if family.offersDownscale || family.offersFrameRateReduction || family.offersGPS {
                Section {
                    if family.offersDownscale {
                        Toggle("Allow lower resolution", isOn: $choice.allowsDownscale)
                    }
                    if family.offersFrameRateReduction {
                        Toggle("Allow lower frame rate", isOn: $choice.allowsFrameRateReduction)
                    }
                    if family.offersGPS {
                        Toggle("Remove location (GPS)", isOn: $choice.stripsGPS)
                    }
                }
            }
        }
        .onAppear {
            if choice.presetID.isEmpty || preset == nil { choice.presetID = presets.first?.id ?? "" }
            if !family.qualityLevels.contains(choice.quality) { choice.quality = nearestLevel(to: choice.quality) }
        }
    }

    @ViewBuilder private var goalControls: some View {
        switch choice.goal {
        case .size:
            LabeledContent("Size (MB)") {
                TextField("Size (MB)", value: $choice.megabytes, format: .number.precision(.fractionLength(0...2)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
            }
        case .quality:
            LabeledContent {
                HStack {
                    Slider(value: levelIndex, in: 0...Double(family.qualityLevels.count - 1)) { Text("Quality") }
                        .labelsHidden()
                        .accessibilityValue(family.qualityText(choice.quality))
                    Text(family.qualityText(choice.quality))
                        .monospacedDigit()
                        .accessibilityHidden(true)
                }
            } label: {
                Text("Quality")
            }
        case .preset:
            Picker("Platform", selection: $choice.presetID) {
                ForEach(presets) {
                    Text($0.name.localized(languageCode: Bundle.main.preferredLocalizations.first)).tag($0.id)
                }
            }
        }
    }

    private var preset: PlatformPreset? {
        presets.first { $0.id == choice.presetID }
    }

    private var options: OperationOptions? {
        if choice.goal == .size, choice.megabytes < Self.smallestMegabytes { return nil }
        return family.options(choice, preset)
    }

    private var levelIndex: Binding<Double> {
        Binding {
            Double(family.qualityLevels.firstIndex(of: choice.quality) ?? 0)
        } set: {
            choice.quality = family.qualityLevels[Int($0.rounded())]
        }
    }

    private func nearestLevel(to value: Int) -> Int {
        family.qualityLevels.min { abs($0 - value) < abs($1 - value) } ?? value
    }
}
