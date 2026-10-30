import AVKit
import Engine
import SwiftUI

struct MediaEditorView: View {
    @Bindable var model: MediaEditorModel
    let close: () -> Void
    let save: (OperationOptions, Engine.Settings) -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if model.ready {
                HStack(spacing: 0) {
                    preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    inspector.frame(width: 290)
                }
                if model.isVideo { EditorTimeline(model: model).padding(.horizontal, 20).padding(.vertical, 12) }
                footer
            } else if let failure = model.failure {
                ContentUnavailableView {
                    Label("Unable to Open", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Close", action: close)
                }
            } else {
                ProgressView("Opening…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 960, minHeight: 540)
        .background(.background)
        .task { model.load() }
        .background(EditorKeyboardShortcuts(model: model).frame(width: 0, height: 0))
        .onChange(of: model.category) { _, _ in
            model.pause(); model.refresh()
        }
        .onChange(of: model.original) { _, _ in
            model.pause(); model.refresh()
        }
        .onChange(of: model.zoom) { _, _ in model.refresh() }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button(action: close) { Label("Cancel", systemImage: "xmark") }.labelStyle(.iconOnly)
                .help("Cancel editing").keyboardShortcut(.cancelAction)
            Picker("Editing tool", selection: $model.category) {
                ForEach(EditorCategory.allCases.filter { model.isVideo || $0 != .video }, id: \.self) {
                    Text($0.title).tag($0)
                }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: model.isVideo ? 320 : 250).disabled(!model.ready)
            Spacer()
            Button {
                model.original.toggle()
            } label: {
                Label("Compare Original", systemImage: "square.on.square")
            }
            .labelStyle(.iconOnly).help("Compare with original (M)")
            .tint(model.original ? .accentColor : nil).disabled(!model.ready)
            HStack(spacing: 6) {
                Button {
                    model.undo()
                } label: {
                    Label("Undo Edit", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.canUndo).keyboardShortcut("z", modifiers: .command)
                Button {
                    model.redo()
                } label: {
                    Label("Redo Edit", systemImage: "arrow.uturn.forward")
                }
                .disabled(!model.canRedo).keyboardShortcut("z", modifiers: [.command, .shift])
            }.labelStyle(.iconOnly)
            GlassEffectContainer {
                HStack(spacing: 10) {
                    Menu {
                        Button("Reset All Edits") { model.reset() }.disabled(!model.ready)
                    } label: {
                        Image(systemName: "ellipsis")
                    }.menuStyle(.borderlessButton)
                        .frame(width: 32, height: 32).glassEffect().help("More editing actions")
                    Button {
                        do {
                            try model.validateForSave()
                            var settings = model.settings
                            if model.savesNewFile { settings.outputMode = .newFile }
                            save(
                                model.isVideo ? .video(.edit(model.values.video)) : .image(.edit(model.values.photo)),
                                settings)
                            close()
                        } catch { model.report(error) }
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .disabled(!model.canSave).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var preview: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if model.isVideo || model.image != nil {
                    let imageSize =
                        model.isVideo
                        ? model.previewSize
                        : CGSize(
                            width: model.image?.width ?? 1, height: model.image?.height ?? 1)
                    let scale = min(
                        (proxy.size.width - 40) / imageSize.width, (proxy.size.height - 32) / imageSize.height)
                    let zoom = model.category == .crop || model.isVideo ? 1 : model.zoom
                    let size = CGSize(width: imageSize.width * scale * zoom, height: imageSize.height * scale * zoom)
                    ScrollView([.horizontal, .vertical]) {
                        ZStack {
                            if model.isVideo {
                                EditorPlayer(player: model.player, ready: $model.playerReady).opacity(
                                    model.playerReady ? 1 : 0)
                                if model.values.segments.isEmpty {
                                    ContentUnavailableView("No Segments", systemImage: "film")
                                }
                            } else if let image = model.image {
                                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                            }
                            if model.category == .crop && !model.original {
                                EditorCropOverlay(model: model)
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                    }
                } else {
                    ProgressView()
                }
                VStack {
                    HStack {
                        if model.original { Text("Original").padding(8).background(.regularMaterial, in: Capsule()) }
                        Spacer()
                        if model.preparingPlayback || model.splitting
                            || model.isVideo && !model.playerReady && !model.values.segments.isEmpty
                        {
                            ProgressView("Preparing preview…").padding(8).background(.regularMaterial, in: Capsule())
                        }
                    }
                    Spacer()
                }.padding(12)
            }
        }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.category {
                    case .video: videoControls
                    case .adjust: adjustmentControls
                    case .styles: styleControls
                    case .crop: cropControls
                    }
                }
                .id(model.isVideo ? model.values.selectedID : nil)
                .disabled(model.isVideo && !model.hasSelection && model.category != .crop)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var adjustmentControls: some View {
        Group {
            if !model.isVideo {
                Toggle("Auto Enhance", isOn: model.binding(\.photo.autoEnhance))
            }
            ForEach(MediaAdjustment.allCases.filter { !model.isVideo || !$0.photoOnly }, id: \.self) { adjustment in
                EditorAdjustmentRow(model: model, adjustment: adjustment)
            }
        }
    }

    private var styleControls: some View {
        Group {
            Picker("Style", selection: model.adjustmentBinding(\.style)) {
                ForEach(MediaStyle.allCases, id: \.self) { Text($0.editorTitle).tag($0) }
            }.pickerStyle(.radioGroup)
            Slider(value: model.adjustmentBinding(\.styleIntensity), in: 0...1) {
                Text("Intensity")
            } onEditingChanged: { active in
                active ? model.beginInteraction() : model.endInteraction()
            }
            .disabled(model.adjustments.style == .original)
        }
    }

    private var cropControls: some View {
        Group {
            HStack {
                Button {
                    model.change {
                        let crop = $0.photo.geometry.crop
                        $0.photo.geometry.quarterTurns = ($0.photo.geometry.quarterTurns + 1) % 4
                        $0.photo.geometry.crop = EditCrop(
                            x: 1 - crop.y - crop.height, y: crop.x,
                            width: crop.height, height: crop.width)
                    }
                    model.synchronizeCropAspect()
                } label: {
                    Label("Rotate Right", systemImage: "rotate.right")
                }
                Button {
                    model.change { $0.photo.geometry.flipHorizontal.toggle() }
                } label: {
                    Label("Flip Horizontal", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                Button {
                    model.change { $0.photo.geometry.flipVertical.toggle() }
                } label: {
                    Label("Flip Vertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                }
            }
            .labelStyle(.iconOnly)
            .help("Rotate and flip the entire image")
            Picker("Aspect Ratio", selection: $model.cropAspect) {
                Text("Freeform").tag(0.0)
                Text("Original Ratio").tag(-1.0)
                Text("1:1").tag(1.0)
                Text("4:3").tag(4.0 / 3)
                Text("3:2").tag(1.5)
                Text("4:5").tag(0.8)
                Text("16:9").tag(16.0 / 9)
            }.onChange(of: model.cropAspect) { _, _ in model.fitCropAspect() }
            Toggle(
                "Swap Width and Height",
                isOn: Binding(
                    get: { model.cropPortrait },
                    set: {
                        model.cropPortrait = $0
                        model.fitCropAspect()
                    })
            ).disabled(model.cropAspect == 0 || model.cropAspect == 1)
            VStack(alignment: .leading) {
                HStack {
                    Text("Straighten")
                    Spacer()
                    Text(model.values.photo.geometry.straighten, format: .number.precision(.fractionLength(1)))
                    Text("°").accessibilityHidden(true)
                }
                Slider(value: model.binding(\.photo.geometry.straighten), in: -45...45) {
                    Text("Straighten")
                } onEditingChanged: { active in
                    active ? model.beginInteraction() : model.endInteraction()
                }
                .labelsHidden()
            }
            DisclosureGroup("Selection (%)") {
                cropField("Left", keyPath: \.x)
                cropField("Top", keyPath: \.y)
                cropField("Width", keyPath: \.width)
                cropField("Height", keyPath: \.height)
            }
            Button("Reset Crop and Rotation") {
                model.change { $0.photo.geometry = EditGeometry() }; model.cropAspect = 0
            }
        }
    }

    private func cropField(_ title: LocalizedStringKey, keyPath: WritableKeyPath<EditCrop, Double>) -> some View {
        LabeledContent(title) {
            EditorNumberField(
                model: model, title: Text(title), id: "crop-\(keyPath)",
                value: Binding(
                    get: { model.values.photo.geometry.crop[keyPath: keyPath] * 100 },
                    set: { model.setCropPercentage($0, keyPath: keyPath) }), range: 0...100, precision: 1
            )
            .frame(width: 70)
        }
    }

    private var videoControls: some View {
        Group {
            Text("Selected Segment").font(.headline)
            LabeledContent("Start") {
                EditorNumberField(
                    model: model, title: Text("Start (seconds)"), id: "start",
                    value: model.binding(\.start), range: 0...max(0, model.values.end - model.frameDuration),
                    precision: 3
                )
                .frame(width: 90)
            }
            LabeledContent("End") {
                EditorNumberField(
                    model: model, title: Text("End (seconds)"), id: "end",
                    value: model.binding(\.end),
                    range: min(model.duration, model.values.start + model.frameDuration)...model.duration,
                    precision: 3
                ).frame(width: 90)
            }
            LabeledContent("Playback speed") {
                EditorNumberField(
                    model: model, title: Text("Playback speed"), id: "speed",
                    value: model.binding(\.speed), range: VideoEdit.speedRange, precision: 2
                ).frame(width: 70)
                Text("×").accessibilityHidden(true)
            }
            Slider(value: model.binding(\.speed), in: 0.5...4) {
                Text("Playback speed")
            } onEditingChanged: { active in
                active ? model.beginInteraction() : model.endInteraction()
            }
            .labelsHidden()
            Divider()
            Picker("Resolution", selection: model.binding(\.resolution)) {
                Text("Original resolution").tag(0)
                ForEach([2160, 1080, 720, 480, 360], id: \.self) { Text(verbatim: "\($0)p").tag($0) }
            }
            VStack(alignment: .leading) {
                HStack {
                    Text("Volume")
                    Spacer()
                    Button {
                        model.change { $0.volume = $0.volume == 0 ? 1 : 0 }
                    } label: {
                        Label("Mute", systemImage: model.values.volume == 0 ? "speaker.slash" : "speaker.wave.2")
                    }.labelStyle(.iconOnly)
                }
                Slider(value: model.binding(\.volume), in: 0...1) {
                    Text("Volume")
                } onEditingChanged: { active in
                    active ? model.beginInteraction() : model.endInteraction()
                }
                .labelsHidden()
            }.disabled(!model.hasAudio)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let failure = model.failure { ProblemLabel(text: failure) }
            if !model.invalidFields.isEmpty {
                ProblemLabel(text: String(localized: "Enter a valid number within the allowed range."))
            }
            HStack {
                Text("\(Int(model.outputSize.width)) × \(Int(model.outputSize.height))")
                    .monospacedDigit().foregroundStyle(.secondary)
                if model.isVideo {
                    Text(
                        "\(model.outputDuration, format: .number.precision(.fractionLength(2))) seconds"
                    )
                    .monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Picker("Zoom", selection: $model.zoom) {
                        Text("Fit").tag(1.0)
                        Text("2×").tag(2.0)
                        Text("4×").tag(4.0)
                    }.frame(width: 160).disabled(model.category == .crop)
                }
                Spacer()
                if model.convertsToSDR {
                    Label("SDR · Save as new file", systemImage: "sun.max")
                } else {
                    Text(
                        model.savesNewFile
                            ? String(localized: "Save as new file")
                            : String(localized: "Replace original (Trash and Undo)"))
                }
            }.font(.callout)
        }.padding(.horizontal, 20).padding(.vertical, 10)
    }
}

private struct EditorNumberField: View {
    @Bindable var model: MediaEditorModel
    let title: Text
    let id: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let precision: Int
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var parsed: Double? {
        let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        guard let amount = Double(normalized), amount.isFinite, range.contains(amount) else { return nil }
        return amount
    }

    private func synchronize() {
        draft = value.formatted(.number.grouping(.never).precision(.fractionLength(precision)))
        model.invalidFields.remove(id)
    }

    var body: some View {
        TextField(
            text: Binding(
                get: { draft },
                set: { entered in
                    draft = entered
                    if let amount = parsed {
                        model.invalidFields.remove(id)
                        if amount != value { value = amount }
                    } else {
                        model.invalidFields.insert(id)
                    }
                })
        ) { title }.labelsHidden().textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing).focused($focused)
            .onAppear { synchronize() }
            .onDisappear {
                model.invalidFields.remove(id); if focused { model.endInteraction() }
            }
            .onChange(of: value) { _, _ in
                if parsed != value { synchronize() }
            }
            .onChange(of: focused) { _, focused in
                if focused { model.beginInteraction() } else { synchronize(); model.endInteraction() }
            }
    }
}

private struct EditorPlayer: NSViewRepresentable {
    let player: AVPlayer?
    @Binding var ready: Bool

    func makeCoordinator() -> Coordinator { Coordinator(ready: $ready) }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        let coordinator = context.coordinator
        coordinator.observation = view.observe(\.isReadyForDisplay, options: [.initial, .new]) {
            [weak coordinator] _, change in
            let ready = change.newValue ?? false
            Task { @MainActor in coordinator?.ready.wrappedValue = ready }
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        context.coordinator.ready = $ready
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.observation = nil
        view.player = nil
    }

    @MainActor final class Coordinator {
        var observation: NSKeyValueObservation?
        var ready: Binding<Bool>
        init(ready: Binding<Bool>) { self.ready = ready }
    }
}

private struct EditorAdjustmentRow: View {
    @Bindable var model: MediaEditorModel
    let adjustment: MediaAdjustment

    private var value: Binding<Double> {
        Binding(
            get: { model.adjustments[adjustment] },
            set: { amount in
                guard amount.isFinite else { return }
                model.change {
                    let bounded = min(max(adjustment.range.lowerBound, amount), adjustment.range.upperBound)
                    if model.isVideo {
                        $0.videoAdjustments[adjustment] = bounded
                    } else {
                        $0.photo.adjustments[adjustment] = bounded
                    }
                }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(adjustment.editorTitle)
                Spacer()
                EditorNumberField(
                    model: model, title: Text(adjustment.editorTitle), id: adjustment.rawValue,
                    value: value, range: adjustment.range, precision: 2
                ).frame(width: 58)
                Button {
                    value.wrappedValue = 0
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless).help("Reset adjustment").disabled(value.wrappedValue == 0)
                .accessibilityLabel(Text("Reset \(adjustment.editorTitle)"))
            }
            Slider(value: value, in: adjustment.range) {
                Text(adjustment.editorTitle)
            } onEditingChanged: { active in
                active ? model.beginInteraction() : model.endInteraction()
            }
            .labelsHidden()
        }
    }
}

extension MediaStyle {
    var editorTitle: String {
        switch self {
        case .original: String(localized: "Original")
        case .vivid: String(localized: "Vivid")
        case .warm: String(localized: "Warm")
        case .cool: String(localized: "Cool")
        case .dramatic: String(localized: "Dramatic")
        case .monochrome: String(localized: "Monochrome")
        }
    }
}

extension MediaAdjustment {
    var editorTitle: String {
        switch self {
        case .exposure: String(localized: "Exposure")
        case .brightness: String(localized: "Brightness")
        case .contrast: String(localized: "Contrast")
        case .highlights: String(localized: "Highlights")
        case .shadows: String(localized: "Shadows")
        case .saturation: String(localized: "Saturation")
        case .vibrance: String(localized: "Vibrance")
        case .warmth: String(localized: "Warmth")
        case .tint: String(localized: "Tint")
        case .blackPoint: String(localized: "Black Point")
        case .sharpness: String(localized: "Sharpness")
        case .noiseReduction: String(localized: "Noise Reduction")
        case .vignette: String(localized: "Vignette")
        }
    }
}
