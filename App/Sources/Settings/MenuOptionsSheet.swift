import Engine
import MenuCatalog
import SwiftUI
import os

/// Menu groups whose items take editable values.
enum MenuGroupOptions: String, Identifiable {
    case imageResize = "image.resize"
    case videoResize = "video.resize"
    case imageCompress = "image.compress"
    case videoCompress = "video.compress"
    case imageRotate = "image.rotate"
    case videoRotate = "video.rotate"
    case frameRate = "video.fps"
    case loudness = "audio.normalize"

    var id: String { rawValue }

    init?(_ group: MenuGroupID) {
        self.init(rawValue: group.rawValue)
    }

    fileprivate var operation: OperationID {
        switch self {
        case .imageResize: .imageResize
        case .videoResize: .videoResize
        case .imageCompress: .imageCompress
        case .videoCompress: .videoCompress
        case .imageRotate: .imageRotate
        case .videoRotate: .videoRotate
        case .frameRate: .videoFPS
        case .loudness: .audioNormalize
        }
    }

    /// Adjacent slots sharing a unit.
    fileprivate var slotRows: [[MenuValueSlot]] {
        MenuValues.slots.filter { $0.operation == operation }.reduce(into: []) { rows, slot in
            if let last = rows.last?.last, last.unit == slot.unit {
                rows[rows.count - 1].append(slot)
            } else {
                rows.append([slot])
            }
        }
    }
}

struct MenuOptionsSheet: View {
    @Bindable var store: SettingsStore
    let options: MenuGroupOptions
    let supportDirectory: URL

    /// Recreates the fields, dropping invalid drafts.
    @State private var resets = 0
    @State private var invalidFields: Set<String> = []
    @State private var editsPresets = false

    var body: some View {
        ChecklistSheet(resetTitle: "Reset", canReset: !isDefault) {
            reset()
            invalidFields = []
            resets += 1
        } content: {
            Section {
                fields
            } header: {
                Text(
                    "\(MenuStrings.kind(options.operation.kind)) ▸ \(MenuStrings.operationName(options.operation))",
                    comment: "Menu value row: kind and operation")
            } footer: {
                if let footer {
                    Text(footer).foregroundStyle(.secondary)
                }
            }
            .id(resets)
        }
        .sheet(isPresented: $editsPresets) {
            PresetSheet(store: store, supportDirectory: supportDirectory)
        }
    }

    @ViewBuilder private var fields: some View {
        ForEach(options.slotRows, id: \.first?.id) { slots in
            MenuValueRow(store: store, slots: slots, invalidFields: $invalidFields)
        }
        switch options {
        case .imageCompress, .videoCompress:
            LabeledContent {
                Button("Edit Presets…") { editsPresets = true }
            } label: {
                Text("Platform presets")
                Text("Size limits for Discord, X, Instagram and other Compress items.")
            }
        case .imageRotate, .videoRotate:
            Toggle(isOn: $store.settings.extraRotationEnabled) {
                Text("Extra angle")
                Text("Adds one more angle to Rotate.")
            }
            .accessibilityLabel(Text("Extra angle"))
            .accessibilityHint(Text("Adds one more angle to Rotate."))
            if store.settings.extraRotationEnabled {
                ExtraAngleRow(store: store, invalidFields: $invalidFields)
            }
        case .frameRate:
            FrameRateFields(store: store, invalidFields: $invalidFields)
        case .loudness:
            LoudnessFields(store: store, invalidFields: $invalidFields)
        case .imageResize, .videoResize:
            EmptyView()
        }
    }

    private var footer: String? {
        switch options {
        case .videoCompress:
            String(
                localized: "Edited values replace the menu items in place. Sizes use 1 MB = 1,000,000 bytes.",
                comment: "Editable Finder menu values footer")
        case .imageResize, .videoResize:
            String(localized: "Edited values replace the menu items in place.", comment: "Menu options footer")
        case .imageRotate, .videoRotate:
            String(localized: "Applies to images and videos.", comment: "Extra rotation angle scope")
        case .imageCompress, .frameRate, .loudness: nil
        }
    }

    private var isDefault: Bool {
        guard invalidFields.isEmpty else { return false }
        let defaults = Settings()
        let slots = options.slotRows.joined()
        switch options {
        case .imageResize, .videoResize, .imageCompress, .videoCompress:
            return slots.allSatisfy { store.settings.menuValues.value(for: $0.id) == $0.defaultValue }
        case .imageRotate, .videoRotate:
            return store.settings.extraRotationEnabled == defaults.extraRotationEnabled
                && store.settings.extraRotationDegrees == defaults.extraRotationDegrees
        case .frameRate:
            return store.settings.video.frameRateFilm == defaults.video.frameRateFilm
                && store.settings.video.frameRateStandard == defaults.video.frameRateStandard
                && store.settings.video.frameRateSmooth == defaults.video.frameRateSmooth
        case .loudness:
            return store.settings.audio.loudnessTarget == defaults.audio.loudnessTarget
                && store.settings.audio.loudnessStreaming == defaults.audio.loudnessStreaming
                && store.settings.audio.loudnessBroadcast == defaults.audio.loudnessBroadcast
        }
    }

    private func reset() {
        let defaults = Settings()
        for slot in options.slotRows.joined() { store.settings.menuValues.reset(slot.id) }
        switch options {
        case .imageResize, .videoResize, .imageCompress, .videoCompress: break
        case .imageRotate, .videoRotate:
            store.settings.extraRotationEnabled = defaults.extraRotationEnabled
            store.settings.extraRotationDegrees = defaults.extraRotationDegrees
        case .frameRate:
            store.settings.video.frameRateFilm = defaults.video.frameRateFilm
            store.settings.video.frameRateStandard = defaults.video.frameRateStandard
            store.settings.video.frameRateSmooth = defaults.video.frameRateSmooth
        case .loudness:
            store.settings.audio.loudnessTarget = defaults.audio.loudnessTarget
            store.settings.audio.loudnessStreaming = defaults.audio.loudnessStreaming
            store.settings.audio.loudnessBroadcast = defaults.audio.loudnessBroadcast
        }
    }
}

private struct FrameRateFields: View {
    private static let field = MenuGroupOptions.frameRate.rawValue

    @Bindable var store: SettingsStore
    @Binding var invalidFields: Set<String>

    var body: some View {
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
        if invalidFields.contains(Self.field)
            || !VideoSettings.frameRateRange.contains(store.settings.video.frameRateFilm)
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

    private func frameRate(_ keyPath: WritableKeyPath<VideoSettings, Int>) -> Binding<Int> {
        Binding {
            store.settings.video[keyPath: keyPath]
        } set: { rate in
            let isValid = VideoSettings.frameRateRange.contains(rate)
            invalidFields.mark(Self.field, valid: isValid)
            if isValid { store.settings.video[keyPath: keyPath] = rate }
        }
    }
}

private struct LoudnessFields: View {
    private static let field = MenuGroupOptions.loudness.rawValue

    @Bindable var store: SettingsStore
    @Binding var invalidFields: Set<String>

    var body: some View {
        TextField(
            String(localized: "Standard (LUFS)", comment: "Standard loudness preset"),
            value: loudness(\.loudnessTarget), format: .number)
        TextField(
            String(localized: "Streaming (LUFS)", comment: "Streaming loudness preset"),
            value: loudness(\.loudnessStreaming), format: .number)
        TextField(
            String(localized: "Broadcast (LUFS)", comment: "Broadcast loudness preset"),
            value: loudness(\.loudnessBroadcast), format: .number)
        if invalidFields.contains(Self.field)
            || !AudioSettings.loudnessRange.contains(store.settings.audio.loudnessTarget)
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
    }

    private func loudness(_ keyPath: WritableKeyPath<AudioSettings, Double>) -> Binding<Double> {
        Binding {
            store.settings.audio[keyPath: keyPath]
        } set: { target in
            let isValid = AudioSettings.loudnessRange.contains(target)
            invalidFields.mark(Self.field, valid: isValid)
            if isValid { store.settings.audio[keyPath: keyPath] = target }
        }
    }
}

private struct PresetSheet: View {
    let store: SettingsStore
    let supportDirectory: URL
    @Environment(\.dismiss) private var dismiss

    private static let width: CGFloat = 520
    private static let height: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            PresetSettingsView(store: store, supportDirectory: supportDirectory)
                .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: Self.width, height: Self.height)
    }
}

private struct MenuValueRow: View {
    @Bindable var store: SettingsStore
    let slots: [MenuValueSlot]
    @Binding var invalidFields: Set<String>
    /// Typed text per slot, kept while invalid.
    @State private var drafts: [String: String] = [:]

    private static let fieldWidth: CGFloat = 56
    private static let spacing: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            Text(unitName)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.fieldWidth), spacing: Self.spacing)],
                alignment: .leading, spacing: Self.spacing
            ) {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    TextField(text: text(of: slot)) {
                        Text(verbatim: "\(unitName) \(index + 1)")
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if slots.contains(where: { !isValid(drafts[$0.id], for: $0) }) {
            Text(
                String(
                    localized:
                        "Use whole numbers from \(slots[0].range.lowerBound.formatted()) to \(slots[0].range.upperBound.formatted()).",
                    comment: "Explains an invalid menu value")
            )
            .foregroundStyle(.red)
        }
    }

    private var unitName: String {
        switch slots[0].unit {
        case .percent: String(localized: "Percentages", comment: "Menu value unit")
        case .pixels where slots[0].operation == .imageResize:
            String(localized: "Long edge in pixels", comment: "Menu value unit")
        case .pixels: String(localized: "Height in pixels", comment: "Menu value unit")
        case .megabytes: String(localized: "Target sizes in MB", comment: "Menu value unit")
        }
    }

    private func isValid(_ draft: String?, for slot: MenuValueSlot) -> Bool {
        draft.map { Int($0).map(slot.range.contains) ?? false } ?? true
    }

    private func text(of slot: MenuValueSlot) -> Binding<String> {
        Binding {
            drafts[slot.id] ?? String(store.settings.menuValues.value(for: slot.id) ?? slot.defaultValue)
        } set: { text in
            drafts[slot.id] = text
            invalidFields.mark(slot.id, valid: isValid(text, for: slot))
            guard isValid(text, for: slot), let value = Int(text) else { return }
            var values = store.settings.menuValues
            do {
                try values.set(value, for: slot.id)
                store.settings.menuValues = values
            } catch {
                Logger(category: "settings").error("Validated menu value rejected for \(slot.id, privacy: .public)")
            }
        }
    }
}

private struct ExtraAngleRow: View {
    @Bindable var store: SettingsStore
    @Binding var invalidFields: Set<String>
    @State private var draft: String?

    private static let fieldWidth: CGFloat = 64
    private static let spacing: CGFloat = 6

    var body: some View {
        LabeledContent {
            HStack(spacing: Self.spacing) {
                TextField(text: degrees) { Text("Angle") }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: Self.fieldWidth)
                Text(verbatim: "°")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        } label: {
            Text("Angle")
        }
        if draft.map({ Self.degrees(from: $0) == nil }) ?? false {
            Text(
                String(
                    localized:
                        "Use degrees from \(Settings.extraRotationRange.lowerBound.formatted()) to \(Settings.extraRotationRange.upperBound.formatted()).",
                    comment: "Explains an invalid extra rotation angle")
            )
            .foregroundStyle(.red)
        }
    }

    private var degrees: Binding<String> {
        Binding {
            draft ?? store.settings.extraRotationDegrees.formatted(.number.grouping(.never))
        } set: { text in
            draft = text
            let degrees = Self.degrees(from: text)
            invalidFields.mark(OperationID.extraAnglePreset, valid: degrees != nil)
            if let degrees { store.settings.extraRotationDegrees = degrees }
        }
    }

    private static func degrees(from text: String) -> Double? {
        guard let degrees = try? FloatingPointFormatStyle<Double>.number.parseStrategy.parse(text),
            degrees.isFinite, Settings.extraRotationRange.contains(degrees)
        else { return nil }
        return degrees
    }
}

extension MenuValueSlot {
    fileprivate var operation: OperationID? {
        id.split(separator: "/").first.flatMap { OperationID(rawValue: String($0)) }
    }
}

extension Set<String> {
    /// Tracks fields showing a rejected value.
    fileprivate mutating func mark(_ field: String, valid: Bool) {
        if valid { remove(field) } else { insert(field) }
    }
}
