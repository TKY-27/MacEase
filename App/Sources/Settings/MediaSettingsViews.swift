import Engine
import Formats
import MenuCatalog
import SwiftUI

struct ImageSettingsView: View {
    @Bindable var store: SettingsStore

    private static let toleranceRange = 0.0...1.0
    private static let blurRadiusRange = 0...100
    private static let svgColorRange = 1...8

    var body: some View {
        Form {
            Section("Default Quality") {
                QualitySlider(title: Text(verbatim: "JPEG"), value: $store.settings.image.jpegQuality)
                QualitySlider(title: Text(verbatim: "HEIC"), value: $store.settings.image.heicQuality)
                QualitySlider(title: Text(verbatim: "WebP"), value: $store.settings.image.webpQuality)
                QualitySlider(title: Text(verbatim: "AVIF"), value: $store.settings.image.avifQuality)
                QualitySlider(title: Text(verbatim: "JPEG XL"), value: $store.settings.image.jxlQuality)
            }
            Section {
                Toggle(isOn: $store.settings.image.optimizePNGOnConvert) {
                    Text("Optimize PNG files on convert")
                    Text("Lossless; smaller files take a little longer.")
                }
                .accessibilityLabel(Text("Optimize PNG files on convert"))
                .accessibilityHint(Text("Lossless; smaller files take a little longer."))
                Picker("GIF dithering", selection: $store.settings.image.gifDithering) {
                    ForEach(Dithering.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section("Strip Metadata") {
                ForEach(MetadataField.allCases, id: \.self) { field in
                    Toggle(field.title, isOn: stripping(field))
                }
                Toggle(isOn: $store.settings.image.keepGPSOnPlatformPresets) {
                    Text("Keep location for platform presets")
                    Text("Applies to Compress items that target a size.")
                }
                .accessibilityLabel(Text("Keep location for platform presets"))
                .accessibilityHint(Text("Applies to Compress items that target a size."))
            }
            Section("Background") {
                Picker(
                    String(localized: "Foreground mask", comment: "Saved foreground mask"),
                    selection: $store.settings.image.backgroundMask
                ) {
                    ForEach(ForegroundMask.allCases, id: \.self) { mask in Text(mask.title).tag(mask) }
                }
                NumberField(
                    title: Text(String(localized: "Blur radius (pixels)", comment: "Saved background blur radius")),
                    value: $store.settings.image.backgroundBlurRadius,
                    range: Self.blurRadiusRange)
                ColorPicker("Color key", selection: $store.settings.image.colorKey.color, supportsOpacity: false)
                LabeledContent {
                    Slider(value: $store.settings.image.colorKeyTolerance, in: Self.toleranceRange) {
                        Text("Color key tolerance")
                    }
                    .labelsHidden()
                } label: {
                    Text("Color key tolerance")
                    Text(store.settings.image.colorKeyTolerance, format: .percent.precision(.fractionLength(0)))
                }
                ColorPicker(
                    "Green background", selection: $store.settings.image.greenBackground.color, supportsOpacity: false)
                ColorPicker(
                    "Blue background", selection: $store.settings.image.blueBackground.color, supportsOpacity: false)
                ColorPicker(
                    "Custom background", selection: $store.settings.image.customBackground.color,
                    supportsOpacity: false)
            }
            Section(String(localized: "Rotation", comment: "Rotation defaults")) {
                Toggle(
                    String(localized: "Fill empty corners with a color", comment: "Image rotation background policy"),
                    isOn: $store.settings.image.rotationFillsWithColor)
                if store.settings.image.rotationFillsWithColor {
                    ColorPicker(
                        String(localized: "Rotation fill", comment: "Saved rotation background color"),
                        selection: $store.settings.image.rotationFill.color, supportsOpacity: false)
                }
            }
            Section {
                Picker(
                    String(localized: "Convert to SVG by", comment: "SVG mode"),
                    selection: $store.settings.image.svgMode
                ) {
                    Text(String(localized: "Tracing shapes", comment: "SVG mode")).tag(SVGMode.trace)
                    Text(String(localized: "Embedding a PNG", comment: "SVG mode")).tag(SVGMode.embeddedPNG)
                }
                if store.settings.image.svgMode == .trace {
                    NumberField(
                        title: Text(String(localized: "Tracing colors", comment: "Saved SVG palette size")),
                        value: $store.settings.image.svgColors,
                        range: Self.svgColorRange)
                }
            } header: {
                Text(String(localized: "SVG", comment: "SVG export defaults"))
            } footer: {
                Text(svgFooter)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var svgFooter: String {
        switch store.settings.image.svgMode {
        case .trace:
            String(localized: "Draws editable vector shapes with a few colors.", comment: "SVG mode footer")
        case .embeddedPNG:
            String(
                localized: "Keeps every pixel inside the SVG file. The result is not vector art.",
                comment: "SVG mode footer")
        }
    }

    private func stripping(_ field: MetadataField) -> Binding<Bool> {
        Binding {
            store.settings.image.strippedMetadata.contains(field)
        } set: { stripped in
            if stripped {
                store.settings.image.strippedMetadata.insert(field)
            } else {
                store.settings.image.strippedMetadata.remove(field)
            }
        }
    }
}

struct VideoSettingsView: View {
    @Bindable var store: SettingsStore
    @State private var rejectedFrameRate = false
    @State private var rejectedAnimationRange = false

    private static let gifWidthRange = 16...3840
    private static let gifFrameRateRange = 1...50
    private static let gifColorRange = 2...256

    var body: some View {
        Form {
            Section("Encoding") {
                Picker("Codec for re-encoding", selection: $store.settings.video.codec) {
                    ForEach(VideoCodecChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Prefer", selection: $store.settings.video.priority) {
                    ForEach(EncodePriority.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Trim", selection: $store.settings.video.trimMode) {
                    ForEach(TrimMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                ColorPicker(
                    String(localized: "Rotation fill", comment: "Saved rotation background color"),
                    selection: $store.settings.video.rotationFill.color, supportsOpacity: false)
            }
            Section {
                Toggle("Allow lower resolution", isOn: $store.settings.video.allowDownscale)
                Toggle("Allow lower frame rate", isOn: $store.settings.video.allowFrameRateReduction)
            } header: {
                Text("Target-Size Compression")
            } footer: {
                Text("Also applies to images and GIFs compressed to a size.")
                    .foregroundStyle(.secondary)
            }
            Section(String(localized: "Frame Rate Menu", comment: "Editable frame rate presets")) {
                TextField(
                    String(localized: "Film (fps)", comment: "Film frame rate slot"),
                    value: frameRate(\.frameRateFilm),
                    format: .number.grouping(.never))
                TextField(
                    String(localized: "Standard (fps)", comment: "Standard frame rate slot"),
                    value: frameRate(\.frameRateStandard),
                    format: .number.grouping(.never))
                TextField(
                    String(localized: "Smooth (fps)", comment: "Smooth frame rate slot"),
                    value: frameRate(\.frameRateSmooth),
                    format: .number.grouping(.never))
                if rejectedFrameRate || !VideoSettings.frameRateRange.contains(store.settings.video.frameRateFilm)
                    || !VideoSettings.frameRateRange.contains(store.settings.video.frameRateStandard)
                    || !VideoSettings.frameRateRange.contains(store.settings.video.frameRateSmooth)
                {
                    Text(
                        String(
                            localized: "Frame rates must be between 1 and 120 fps.",
                            comment: "Explains invalid frame rate")
                    )
                    .foregroundStyle(.red)
                }
            }
            Section(String(localized: "Animated Images", comment: "Animation export defaults")) {
                NumberField(
                    title: Text("Width (pixels)"), value: $store.settings.video.gifWidth, range: Self.gifWidthRange)
                NumberField(
                    title: Text("Frame rate (fps)"), value: $store.settings.video.gifFrameRate,
                    range: Self.gifFrameRateRange)
                NumberField(title: Text("Colors"), value: $store.settings.video.gifColors, range: Self.gifColorRange)
                Picker(
                    String(localized: "Dithering", comment: "Animation palette dithering"),
                    selection: $store.settings.image.gifDithering
                ) {
                    ForEach(Dithering.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Loop", isOn: $store.settings.video.gifLoops)
                SecondsField(
                    title: String(localized: "Start (seconds)", comment: "Animated image start time"),
                    value: animationTime(\.gifStartSeconds))
                SecondsField(
                    title: String(localized: "End (seconds, 0 for full duration)", comment: "Animated image end time"),
                    value: animationTime(\.gifEndSeconds))
                if rejectedAnimationRange
                    || !VideoSettings.animationTimeRange.contains(store.settings.video.gifStartSeconds)
                    || !VideoSettings.animationTimeRange.contains(store.settings.video.gifEndSeconds)
                    || (store.settings.video.gifEndSeconds > 0
                        && store.settings.video.gifEndSeconds <= store.settings.video.gifStartSeconds)
                {
                    Text(
                        String(
                            localized: "Use times from 0 to 86400 seconds, with the end after the start.",
                            comment: "Explains invalid animation range")
                    )
                    .foregroundStyle(.red)
                }
            }
            Section("Output") {
                Picker(
                    String(localized: "Background mask", comment: "Saved video foreground mask"),
                    selection: $store.settings.video.backgroundMask
                ) {
                    ForEach(ForegroundMask.allCases, id: \.self) { mask in Text(mask.title).tag(mask) }
                }
                Picker("Transparent video format", selection: $store.settings.video.transparentFormat) {
                    ForEach(TransparentVideoFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Thumbnail format", selection: $store.settings.video.thumbnailFormat) {
                    ForEach(StillFormat.allCases, id: \.self) { format in
                        Text(MenuStrings.preset(.pdfToImages, format.rawValue)).tag(format)
                    }
                }
            }
        }
    }
    private func animationTime(_ keyPath: WritableKeyPath<VideoSettings, Double>) -> Binding<Double> {
        Binding {
            store.settings.video[keyPath: keyPath]
        } set: { seconds in
            var candidate = store.settings.video
            candidate[keyPath: keyPath] = seconds
            rejectedAnimationRange =
                !VideoSettings.animationTimeRange.contains(seconds)
                || (candidate.gifEndSeconds > 0 && candidate.gifEndSeconds <= candidate.gifStartSeconds)
            if !rejectedAnimationRange { store.settings.video[keyPath: keyPath] = seconds }
        }
    }

    private func frameRate(_ keyPath: WritableKeyPath<VideoSettings, Int>) -> Binding<Int> {
        Binding {
            store.settings.video[keyPath: keyPath]
        } set: { rate in
            rejectedFrameRate = !VideoSettings.frameRateRange.contains(rate)
            if !rejectedFrameRate { store.settings.video[keyPath: keyPath] = rate }
        }
    }

}

struct AudioSettingsView: View {
    @Bindable var store: SettingsStore
    @State private var rejectedLoudness = false

    nonisolated fileprivate static let mp3Bitrates = [64, 96, 128, 160, 192, 224, 256, 320]
    nonisolated fileprivate static let aacBitrates = [64, 96, 128, 160, 192, 256, 320]
    nonisolated fileprivate static let opusBitrates = [32, 48, 64, 96, 128, 160, 192, 256]
    nonisolated fileprivate static let vorbisBitrates = [64, 96, 128, 160, 192, 256, 320]
    private static let vbrQualities = 0...9
    private static let extractionBitrates = [64, 96, 128, 160, 192, 256]

    var body: some View {
        Form {
            Section("Default Bitrate") {
                bitratePicker("MP3", $store.settings.audio.mp3Bitrate, Self.mp3Bitrates)
                bitratePicker("AAC", $store.settings.audio.aacBitrate, Self.aacBitrates)
                bitratePicker("Opus", $store.settings.audio.opusBitrate, Self.opusBitrates)
                bitratePicker("Ogg Vorbis", $store.settings.audio.vorbisBitrate, Self.vorbisBitrates)
            }
            Section("MP3") {
                Picker("Mode", selection: $store.settings.audio.mp3Mode) {
                    Text("Constant bitrate (CBR)").tag(MP3Mode.cbr)
                    Text("Variable bitrate (VBR)").tag(MP3Mode.vbr)
                }
                if store.settings.audio.mp3Mode == .vbr {
                    Picker("VBR quality", selection: $store.settings.audio.mp3VBRQuality) {
                        ForEach(Self.vbrQualities, id: \.self) { level in
                            Text(vbrTitle(level)).tag(level)
                        }
                    }
                }
            }
            Section {
                TextField(
                    String(localized: "Standard (LUFS)", comment: "Standard loudness preset"),
                    value: loudness(\.loudnessTarget), format: .number)
                TextField(
                    String(localized: "Streaming (LUFS)", comment: "Streaming loudness preset"),
                    value: loudness(\.loudnessStreaming), format: .number)
                TextField(
                    String(localized: "Broadcast (LUFS)", comment: "Broadcast loudness preset"),
                    value: loudness(\.loudnessBroadcast), format: .number)
                if rejectedLoudness || !AudioSettings.loudnessRange.contains(store.settings.audio.loudnessTarget)
                    || !AudioSettings.loudnessRange.contains(store.settings.audio.loudnessStreaming)
                    || !AudioSettings.loudnessRange.contains(store.settings.audio.loudnessBroadcast)
                {
                    Text(
                        String(
                            localized: "Loudness targets must be between −40 and −5 LUFS.",
                            comment: "Explains invalid loudness")
                    )
                    .foregroundStyle(.red)
                }
                Picker("Extract audio as", selection: $store.settings.audio.extractFormat) {
                    ForEach(OperationID.videoExtractAudio.presets, id: \.self) { format in
                        Text(MenuStrings.preset(.videoExtractAudio, format)).tag(format)
                    }
                }
                Picker(
                    String(localized: "Extracted audio bitrate", comment: "Saved audio extraction rate"),
                    selection: $store.settings.audio.extractedAudioBitrate
                ) {
                    Text(
                        String(
                            localized: "Automatic (copy when possible)",
                            comment: "Automatic extraction preserves compatible streams")
                    ).tag(Int?.none)
                    ForEach(Self.extractionBitrates, id: \.self) { rate in
                        Text(
                            "\(rate) kbps",
                            comment: "Extracted audio bitrate"
                        ).tag(Int?.some(rate))
                    }
                }
            }
        }
    }

    private func loudness(_ keyPath: WritableKeyPath<AudioSettings, Double>) -> Binding<Double> {
        Binding {
            store.settings.audio[keyPath: keyPath]
        } set: { target in
            rejectedLoudness = !AudioSettings.loudnessRange.contains(target)
            if !rejectedLoudness { store.settings.audio[keyPath: keyPath] = target }
        }
    }

    private func bitratePicker(_ format: String, _ value: Binding<Int>, _ rates: [Int]) -> some View {
        Picker(selection: value) {
            ForEach(rates, id: \.self) { rate in
                Text("\(rate) kbps", comment: "Audio bitrate").tag(rate)
            }
        } label: {
            Text(verbatim: format)
        }
    }

    private func vbrTitle(_ level: Int) -> String {
        switch level {
        case Self.vbrQualities.lowerBound:
            String(localized: "V\(level) (highest)", comment: "Best MP3 VBR quality level")
        case Self.vbrQualities.upperBound:
            String(localized: "V\(level) (smallest)", comment: "Smallest MP3 VBR quality level")
        default:
            "V\(level)"
        }
    }
}

extension Dithering {
    var title: String {
        switch self {
        case .floydSteinberg: String(localized: "Floyd–Steinberg", comment: "GIF dithering method")
        case .ordered: String(localized: "Ordered", comment: "GIF dithering method")
        case .none: String(localized: "None", comment: "GIF dithering method")
        }
    }
}

extension ForegroundMask {
    fileprivate var title: String {
        switch self {
        case .subject: String(localized: "Subject", comment: "Foreground mask choice")
        case .person: String(localized: "Person", comment: "Foreground mask choice")
        }
    }
}

extension MetadataField {
    fileprivate var title: String {
        switch self {
        case .exif: String(localized: "EXIF (camera and settings)", comment: "Metadata field")
        case .gps: String(localized: "Location (GPS)", comment: "Metadata field")
        case .makerNotes: String(localized: "Maker notes", comment: "Metadata field")
        case .comments: String(localized: "Comments", comment: "Metadata field")
        case .xmp: "XMP"
        case .iptc: "IPTC"
        }
    }
}

extension VideoCodecChoice {
    fileprivate var title: String {
        switch self {
        case .auto: String(localized: "Automatic", comment: "Video codec choice")
        case .h264: "H.264"
        case .hevc: "HEVC (H.265)"
        }
    }
}

extension EncodePriority {
    fileprivate var title: String {
        switch self {
        case .speed: String(localized: "Speed", comment: "Video encoding priority")
        case .quality: String(localized: "Quality", comment: "Video encoding priority")
        }
    }
}

extension TrimMode {
    var title: String {
        switch self {
        case .keyframe: String(localized: "At keyframes (fast, lossless)", comment: "Video trim mode")
        case .exact: String(localized: "Exact (re-encodes)", comment: "Video trim mode")
        }
    }
}

extension AudioFormat {
    /// Empty for lossless formats.
    var bitrateChoices: [Int] {
        switch self {
        case .mp3: AudioSettingsView.mp3Bitrates
        case .m4aAAC, .aac: AudioSettingsView.aacBitrates
        case .opus: AudioSettingsView.opusBitrates
        case .ogg: AudioSettingsView.vorbisBitrates
        default: []
        }
    }
}

extension TransparentVideoFormat {
    var title: String {
        switch self {
        case .hevcAlpha: String(localized: "HEVC with alpha (MOV)", comment: "Transparent video format")
        case .proRes4444: "ProRes 4444 (MOV)"
        case .vp9AlphaWebM: String(localized: "VP9 with alpha (WebM)", comment: "Transparent video format")
        }
    }
}
