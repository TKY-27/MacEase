import Engine
import Formats
import MenuCatalog
import SwiftUI

struct ImageSettingsView: View {
    @Bindable var store: SettingsStore

    private static let toleranceRange = 0.0...1.0

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
                    Text("Applies to Discord, X, Instagram and the other presets.")
                }
            }
            Section("Background") {
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
                    "Rotation fill", selection: $store.settings.video.rotationFill.color, supportsOpacity: false)
            }
            Section("Target-Size Compression") {
                Toggle("Allow lower resolution", isOn: $store.settings.video.allowDownscale)
                Toggle("Allow lower frame rate", isOn: $store.settings.video.allowFrameRateReduction)
            }
            Section("GIF Defaults") {
                NumberField(
                    title: Text("Width (pixels)"), value: $store.settings.video.gifWidth, range: Self.gifWidthRange)
                NumberField(
                    title: Text("Frame rate (fps)"), value: $store.settings.video.gifFrameRate,
                    range: Self.gifFrameRateRange)
                NumberField(title: Text("Colors"), value: $store.settings.video.gifColors, range: Self.gifColorRange)
                Toggle("Loop", isOn: $store.settings.video.gifLoops)
            }
            Section("Output") {
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
}

struct AudioSettingsView: View {
    @Bindable var store: SettingsStore

    private static let mp3Bitrates = [64, 96, 128, 160, 192, 224, 256, 320]
    private static let aacBitrates = [64, 96, 128, 160, 192, 256, 320]
    private static let opusBitrates = [32, 48, 64, 96, 128, 160, 192, 256]
    private static let vorbisBitrates = [64, 96, 128, 160, 192, 256, 320]
    private static let vbrQualities = 0...9
    private static let loudnessTargets = [-14.0, -16.0, -23.0]

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
                Picker("Loudness target", selection: $store.settings.audio.loudnessTarget) {
                    ForEach(Self.loudnessTargets, id: \.self) { target in
                        Text("\(target, format: .number) LUFS", comment: "Loudness target such as -14 LUFS")
                            .tag(target)
                    }
                }
                Picker("Extract audio as", selection: $store.settings.audio.extractFormat) {
                    ForEach(OperationID.videoExtractAudio.presets, id: \.self) { format in
                        Text(MenuStrings.preset(.videoExtractAudio, format)).tag(format)
                    }
                }
            }
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
    fileprivate var title: String {
        switch self {
        case .floydSteinberg: String(localized: "Floyd–Steinberg", comment: "GIF dithering method")
        case .ordered: String(localized: "Ordered", comment: "GIF dithering method")
        case .none: String(localized: "None", comment: "GIF dithering method")
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
    fileprivate var title: String {
        switch self {
        case .keyframe: String(localized: "At keyframes (fast, lossless)", comment: "Video trim mode")
        case .exact: String(localized: "Exact (re-encodes)", comment: "Video trim mode")
        }
    }
}

extension TransparentVideoFormat {
    fileprivate var title: String {
        switch self {
        case .hevcAlpha: String(localized: "HEVC with alpha (MOV)", comment: "Transparent video format")
        case .proRes4444: "ProRes 4444 (MOV)"
        case .vp9AlphaWebM: String(localized: "VP9 with alpha (WebM)", comment: "Transparent video format")
        }
    }
}
