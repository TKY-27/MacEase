import Engine
import SwiftUI

/// Valid edits save immediately, like other settings.
struct PresetSettingsView: View {
    @State private var library: PresetLibrary?
    @State private var presets: [PlatformPreset] = []
    @State private var editedIDs: Set<String> = []
    @State private var selectedID = ""
    @State private var draft: PlatformPreset?
    @State private var confirmsReset = false
    @State private var failure: String?

    private let supportDirectory: URL

    init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    var body: some View {
        Form {
            Section {
                Picker("Preset", selection: $selectedID) {
                    ForEach(presets) { preset in
                        Text(Self.name(of: preset)).tag(preset.id)
                    }
                }
            } footer: {
                HStack {
                    Text(
                        editedIDs.contains(selectedID)
                            ? "Edited. MacEase uses your values for this preset."
                            : "Default values. Platform limits change, so you can edit them."
                    )
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults…") { confirmsReset = true }
                        .disabled(!editedIDs.contains(selectedID))
                }
            }
            if let draft {
                PresetEditor(preset: $draft.unwrapped(or: draft))
                    .id(selectedID)
            }
            if let failure {
                ProblemLabel(text: failure)
            }
        }
        .onAppear(perform: load)
        .onChange(of: selectedID) { draft = presets.first { $0.id == selectedID } }
        .onChange(of: draft) { save() }
        .confirmationDialog(
            "Restore the default values for this preset?", isPresented: $confirmsReset
        ) {
            Button("Restore Defaults", role: .destructive, action: reset)
        } message: {
            Text("Your edits to this preset are removed.")
        }
    }

    private func load() {
        do {
            let library = self.library ?? PresetLibrary(supportDirectory: supportDirectory)
            self.library = library
            presets = try library.presets()
            editedIDs = Set(try library.overrides().map(\.id))
            if selectedID.isEmpty, let first = presets.first { selectedID = first.id }
            draft = presets.first { $0.id == selectedID }
            failure = nil
        } catch {
            failure = String(localized: "Presets could not be loaded: \(error.localizedDescription)")
        }
    }

    private func save() {
        guard let library, let draft, draft != presets.first(where: { $0.id == draft.id }),
            PresetValidation.problems(in: draft).isEmpty
        else { return }
        do {
            try library.save(draft)
            presets = try library.presets()
            editedIDs = Set(try library.overrides().map(\.id))
            failure = nil
        } catch {
            failure = String(localized: "The preset could not be saved: \(error.localizedDescription)")
        }
    }

    private func reset() {
        do {
            try library?.reset(id: selectedID)
        } catch {
            failure = String(localized: "The preset could not be restored: \(error.localizedDescription)")
            return
        }
        load()
    }

    static func name(of preset: PlatformPreset) -> String {
        preset.name.localized(languageCode: Bundle.main.preferredLocalizations.first)
    }
}

private struct PresetEditor: View {
    @Binding var preset: PlatformPreset
    @State private var switchedOff: [MediaSlot: MediaLimits] = [:]

    var body: some View {
        Section {
            TextField(text: $preset.name.en) { Text(verbatim: "English") }
            TextField(text: $preset.name.ja) { Text(verbatim: "日本語") }
        } header: {
            Text("Name")
        } footer: {
            if let problem = PresetValidation.nameProblem(in: preset) {
                ProblemLabel(text: problem)
            }
        }
        ForEach(MediaSlot.allCases, id: \.self) { slot in
            Section {
                Toggle(slot.toggleTitle, isOn: enabled(slot))
                if let limits = preset[keyPath: slot.keyPath] {
                    MediaLimitsEditor(
                        limits: $preset[dynamicMember: slot.keyPath].unwrapped(or: limits),
                        usualFields: slot.usualFields)
                }
            } header: {
                Text(slot.title)
            } footer: {
                ForEach(PresetValidation.problems(in: preset[keyPath: slot.keyPath]), id: \.self) {
                    ProblemLabel(text: $0)
                }
            }
        }
    }

    private func enabled(_ slot: MediaSlot) -> Binding<Bool> {
        Binding {
            preset[keyPath: slot.keyPath] != nil
        } set: { isOn in
            if isOn {
                preset[keyPath: slot.keyPath] = switchedOff.removeValue(forKey: slot) ?? MediaLimits()
            } else {
                switchedOff[slot] = preset[keyPath: slot.keyPath]
                preset[keyPath: slot.keyPath] = nil
            }
        }
    }
}

/// Set fields stay visible to remain editable.
private struct MediaLimitsEditor: View {
    @Binding var limits: MediaLimits
    let usualFields: Set<LimitField>

    private static let bytesPerMegabyte = 1_000_000.0
    private static let defaultAspect = AspectRange(
        min: AspectRatio(width: 1, height: 1), max: AspectRatio(width: 1, height: 1), fit: .crop)

    var body: some View {
        if shows(.size) {
            TextField("Max size (MB)", value: megabytes, format: .number, prompt: Text("No limit"))
        }
        if shows(.width) {
            TextField(
                "Max width (pixels)", value: $limits.maxWidth, format: .number.grouping(.never),
                prompt: Text("No limit"))
        }
        if shows(.height) {
            TextField(
                "Max height (pixels)", value: $limits.maxHeight, format: .number.grouping(.never),
                prompt: Text("No limit"))
        }
        if shows(.frames) {
            TextField("Max frames", value: $limits.maxFrames, format: .number, prompt: Text("No limit"))
        }
        if shows(.duration) {
            TextField(
                "Max duration (seconds)", value: $limits.maxDurationSeconds, format: .number, prompt: Text("No limit"))
        }
        if shows(.formats) {
            TextField("Formats", value: $limits.formats, format: FormatListStyle(), prompt: Text("Any"))
        }
        if shows(.videoCodec) {
            TextField("Video codec", text: text($limits.videoCodec), prompt: Text("Automatic"))
        }
        if shows(.audioCodec) {
            TextField("Audio codec", text: text($limits.audioCodec), prompt: Text("Automatic"))
        }
        if shows(.quality) {
            TextField("Quality (0–100)", value: $limits.quality, format: .number, prompt: Text("Automatic"))
        }
        if shows(.aspect) {
            Toggle("Limit aspect ratio", isOn: aspectEnabled)
            if let range = limits.aspect {
                let aspect = $limits.aspect.unwrapped(or: range)
                TextField("Narrowest ratio", value: aspect.min, format: AspectRatioStyle())
                TextField("Widest ratio", value: aspect.max, format: AspectRatioStyle())
                Picker("Outside the range", selection: aspect.fit) {
                    Text("Crop").tag(AspectFit.crop)
                    Text("Letterbox").tag(AspectFit.letterbox)
                }
            }
        }
    }

    private func shows(_ field: LimitField) -> Bool {
        usualFields.contains(field) || isSet(field)
    }

    private func isSet(_ field: LimitField) -> Bool {
        switch field {
        case .size: limits.maxBytes != nil
        case .width: limits.maxWidth != nil
        case .height: limits.maxHeight != nil
        case .frames: limits.maxFrames != nil
        case .duration: limits.maxDurationSeconds != nil
        case .formats: limits.formats != nil
        case .videoCodec: limits.videoCodec != nil
        case .audioCodec: limits.audioCodec != nil
        case .quality: limits.quality != nil
        case .aspect: limits.aspect != nil
        }
    }

    private var megabytes: Binding<Double?> {
        Binding {
            limits.maxBytes.map { Double($0) / Self.bytesPerMegabyte }
        } set: {
            limits.maxBytes = $0.map(Self.bytes(megabytes:))
        }
    }

    /// Saturates huge entries instead of trapping.
    private static func bytes(megabytes: Double) -> Int64 {
        let bytes = (megabytes * bytesPerMegabyte).rounded()
        return Int64(exactly: bytes) ?? (bytes > 0 ? .max : .min)
    }

    private var aspectEnabled: Binding<Bool> {
        Binding {
            limits.aspect != nil
        } set: {
            limits.aspect = $0 ? Self.defaultAspect : nil
        }
    }

    private func text(_ value: Binding<String?>) -> Binding<String> {
        Binding {
            value.wrappedValue ?? ""
        } set: {
            value.wrappedValue = $0.isEmpty ? nil : $0
        }
    }
}

private enum LimitField {
    case size
    case width
    case height
    case frames
    case duration
    case formats
    case videoCodec
    case audioCodec
    case quality
    case aspect
}

private enum MediaSlot: CaseIterable {
    case image
    case gif
    case video
    case audio

    var keyPath: WritableKeyPath<PlatformPreset, MediaLimits?> {
        switch self {
        case .image: \.image
        case .gif: \.gif
        case .video: \.video
        case .audio: \.audio
        }
    }

    var usualFields: Set<LimitField> {
        switch self {
        case .image: [.size, .width, .height, .aspect, .formats, .quality]
        case .gif: [.size, .width, .height, .frames, .duration]
        case .video: [.size, .width, .height, .duration, .aspect, .formats, .videoCodec, .audioCodec, .quality]
        case .audio: [.size, .duration, .formats, .audioCodec, .quality]
        }
    }

    var title: String {
        switch self {
        case .image: String(localized: "Images", comment: "Preset section")
        case .gif: String(localized: "GIF", comment: "Preset section")
        case .video: String(localized: "Video", comment: "Preset section")
        case .audio: String(localized: "Audio", comment: "Preset section")
        }
    }

    var toggleTitle: String {
        switch self {
        case .image: String(localized: "Applies to images", comment: "Preset section toggle")
        case .gif: String(localized: "Applies to GIFs", comment: "Preset section toggle")
        case .video: String(localized: "Applies to videos", comment: "Preset section toggle")
        case .audio: String(localized: "Applies to audio", comment: "Preset section toggle")
        }
    }
}

private enum PresetValidation {
    private static let qualityRange = 0...100

    static func problems(in preset: PlatformPreset) -> [String] {
        [nameProblem(in: preset)].compactMap { $0 }
            + [preset.image, preset.gif, preset.video, preset.audio].flatMap(problems(in:))
    }

    static func nameProblem(in preset: PlatformPreset) -> String? {
        let names = [preset.name.en, preset.name.ja].map { $0.trimmingCharacters(in: .whitespaces) }
        return names.contains(where: \.isEmpty) ? String(localized: "Enter a name in both languages.") : nil
    }

    static func problems(in limits: MediaLimits?) -> [String] {
        guard let limits else { return [] }
        var problems: [String] = []
        let sizes: [Double?] = [
            limits.maxBytes.map(Double.init), limits.maxWidth.map(Double.init), limits.maxHeight.map(Double.init),
            limits.maxFrames.map(Double.init), limits.maxDurationSeconds,
        ]
        if sizes.contains(where: { $0.map { $0 <= 0 } ?? false }) {
            problems.append(String(localized: "Limits must be greater than zero."))
        }
        if let quality = limits.quality, !qualityRange.contains(quality) {
            problems.append(String(localized: "Quality must be between 0 and 100."))
        }
        if let aspect = limits.aspect, aspect.min.value > aspect.max.value {
            problems.append(String(localized: "The narrowest ratio must not be wider than the widest."))
        }
        return problems
    }
}

private struct ProblemLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
    }
}

/// Reuses the engine's decoder for identical rules.
private struct AspectRatioStyle: ParseableFormatStyle, ParseStrategy {
    var parseStrategy: Self { self }

    func format(_ ratio: AspectRatio) -> String {
        "\(ratio.width.formatted(.number.grouping(.never))):\(ratio.height.formatted(.number.grouping(.never)))"
    }

    func parse(_ text: String) throws -> AspectRatio {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return try JSONDecoder().decode(AspectRatio.self, from: JSONEncoder().encode(trimmed))
    }
}

private struct FormatListStyle: ParseableFormatStyle, ParseStrategy {
    var parseStrategy: Self { self }

    func format(_ formats: [String]) -> String {
        formats.joined(separator: ", ")
    }

    func parse(_ text: String) throws -> [String] {
        let formats = text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !formats.isEmpty else { throw CocoaError(.formatting) }
        return formats
    }
}
