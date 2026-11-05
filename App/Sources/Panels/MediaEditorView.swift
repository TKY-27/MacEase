import AVKit
import Engine
import SwiftUI

struct MediaEditorView: View {
    @Bindable var model: MediaEditorModel
    let close: () -> Void
    let save: (Batch, Engine.Settings) -> Void

    var body: some View {
        Group {
            if model.ready {
                workspace
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
        .frame(minWidth: 960, minHeight: 600)
        .background(.background)
        .preferredColorScheme(.dark)
        .toolbar { toolbar }
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

    private var workspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !model.isVideo, model.photoURLs.count > 1 {
                    photoList.frame(width: 200)
                    Divider()
                }
                VStack(spacing: 0) {
                    preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    if model.isVideo { EditorTransportBar(model: model) } else { photoBar }
                }
                Divider()
                inspector.frame(width: 300)
            }
            if model.isVideo {
                Divider()
                EditorTimeline(model: model)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Editing tool", selection: $model.category) {
                ForEach(EditorCategory.allCases.filter { model.isVideo || $0 != .video }, id: \.self) {
                    Label($0.title, systemImage: $0.symbol).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .labelsHidden()
            .disabled(!model.ready)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.original) {
                Label("Compare Original", systemImage: "square.split.2x1")
            }
            .toggleStyle(.button)
            .help("Show Original (M)")
            .accessibilityValue(model.original ? Text("Original") : Text("Edited"))
            .disabled(!model.ready)
            ControlGroup {
                Button {
                    model.undo()
                } label: {
                    Label("Undo Edit", systemImage: "arrow.uturn.backward")
                }
                .help("Undo (⌘Z)")
                .disabled(!model.canUndo).keyboardShortcut("z", modifiers: .command)
                Button {
                    model.redo()
                } label: {
                    Label("Redo Edit", systemImage: "arrow.uturn.forward")
                }
                .help("Redo (⇧⌘Z)")
                .disabled(!model.canRedo).keyboardShortcut("z", modifiers: [.command, .shift])
            }
            Menu {
                Button("Reset All Edits") { model.reset() }.disabled(!model.canUndo)
            } label: {
                Label("More Editing Actions", systemImage: "ellipsis.circle")
            }
            .help("More Editing Actions")
        }
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: close).keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
                do {
                    try model.validateForSave()
                    var settings = model.settings
                    if model.isVideo, model.savesNewFile { settings.outputMode = .newFile }
                    save(try model.makeBatch(), settings)
                    close()
                } catch { model.report(error) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSave)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var photoList: some View {
        VStack(spacing: 8) {
            List(model.photoURLs, id: \.self, selection: $model.selectedPhotos) { url in
                HStack {
                    Text(url.lastPathComponent).lineLimit(2)
                    Spacer()
                    if model.values.photoEdits[url]?.isIdentity == false {
                        Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Edited"))
                    }
                }
                .tag(url)
                .contentShape(Rectangle())
            }
            .onChange(of: model.selectedPhotos) { _, selected in
                if let url = selected.first, !selected.contains(model.url) { model.selectPhoto(url) }
            }
            VStack(spacing: 6) {
                Button("Apply to Selected") { model.applyPhotoEdits(toAll: false) }
                    .disabled(model.selectedPhotos.isEmpty)
                Button("Apply to All Photos") { model.applyPhotoEdits(toAll: true) }
            }
            .controlSize(.small)
            .padding(.bottom, 10)
        }
    }

    private var photoBar: some View {
        HStack {
            Picker("Zoom", selection: $model.zoom) {
                Text("Fit").tag(1.0)
                Text(verbatim: "200%").tag(2.0)
                Text(verbatim: "400%").tag(4.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.category == .crop)
            .help(model.category == .crop ? "Zoom is unavailable while cropping" : "Preview Zoom")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var preview: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.55)
                if model.isVideo || model.image != nil {
                    let imageSize =
                        model.isVideo
                        ? model.previewSize
                        : CGSize(
                            width: model.image?.width ?? 1, height: model.image?.height ?? 1)
                    let scale = min(
                        (proxy.size.width - 48) / imageSize.width, (proxy.size.height - 40) / imageSize.height)
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
                    .scrollIndicators(zoom > 1 ? .automatic : .never)
                } else {
                    ProgressView()
                }
                VStack {
                    HStack {
                        if model.original {
                            Text("Original").font(.callout.weight(.semibold)).padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.regularMaterial, in: Capsule())
                        }
                        Spacer()
                        if model.preparingPlayback || model.splitting || model.loadingPhoto
                            || model.isVideo && !model.playerReady && !model.values.segments.isEmpty
                        {
                            ProgressView("Preparing preview…").controlSize(.small).padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.regularMaterial, in: Capsule())
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
                VStack(alignment: .leading, spacing: 20) {
                    switch model.category {
                    case .video: videoControls
                    case .adjust: adjustmentControls
                    case .styles: styleControls
                    case .crop: cropControls
                    }
                }
                .id(model.isVideo ? model.values.selectedID : nil)
                .disabled(model.isVideo && !model.hasSelection && model.category != .crop && model.category != .video)
                .disabled(model.loadingPhoto)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            outputSummary
        }
        .background(.background.secondary)
    }

    private var outputSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let failure = model.failure { ProblemLabel(text: failure) }
            if !model.invalidFields.isEmpty {
                ProblemLabel(text: String(localized: "Enter a valid number within the allowed range."))
            }
            HStack(spacing: 6) {
                Text("\(Int(model.outputSize.width)) × \(Int(model.outputSize.height))")
                if model.isVideo {
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    Text(Timecode.string(model.outputDuration))
                }
            }
            .font(.callout.monospacedDigit())
            Group {
                if model.convertsToSDR {
                    Label("SDR · Save as new file", systemImage: "sun.max")
                } else if !model.isVideo, model.photoURLs.count > 1 {
                    Text("Save policy is applied separately to every photo.")
                } else {
                    Text(
                        model.savesNewFile
                            ? String(localized: "Save as new file")
                            : String(localized: "Replace original (Trash and Undo)"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var adjustmentControls: some View {
        Group {
            if !model.isVideo {
                Toggle(isOn: model.binding(\.photo.autoEnhance)) {
                    Label("Auto Enhance", systemImage: "wand.and.stars")
                }
                .toggleStyle(.button)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            ForEach(AdjustmentGroup.allCases, id: \.self) { group in
                let adjustments = group.adjustments.filter { !model.isVideo || !$0.photoOnly }
                if !adjustments.isEmpty {
                    InspectorSection(group.title) {
                        ForEach(adjustments, id: \.self) { adjustment in
                            EditorAdjustmentRow(model: model, adjustment: adjustment)
                        }
                    }
                }
            }
        }
    }

    private var styleControls: some View {
        InspectorSection(String(localized: "Style")) {
            VStack(spacing: 2) {
                ForEach(MediaStyle.allCases, id: \.self) { style in
                    let selected = model.adjustments.style == style
                    Button {
                        model.adjustmentBinding(\.style).wrappedValue = style
                    } label: {
                        HStack {
                            Text(style.editorTitle)
                            Spacer()
                            if selected { Image(systemName: "checkmark").fontWeight(.semibold) }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                        .background(
                            selected ? Color.accentColor.opacity(0.28) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            LabeledSlider(
                title: String(localized: "Intensity"), value: model.adjustmentBinding(\.styleIntensity), range: 0...1,
                display: "\(Int((model.adjustments.styleIntensity * 100).rounded()))%", model: model
            )
            .disabled(model.adjustments.style == .original)
        }
    }

    private var cropControls: some View {
        Group {
            InspectorSection(String(localized: "Rotate and Flip")) {
                HStack(spacing: 8) {
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
                        Label(
                            "Flip Horizontal",
                            systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    Button {
                        model.change { $0.photo.geometry.flipVertical.toggle() }
                    } label: {
                        Label("Flip Vertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                    }
                }
                .labelStyle(ToolTileLabelStyle())
                .buttonStyle(.bordered)
            }
            InspectorSection(String(localized: "Aspect Ratio")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(CropAspectOption.all, id: \.value) { option in
                        let selected = model.cropAspect == option.value
                        Button {
                            model.cropAspect = option.value
                        } label: {
                            Text(option.title).font(.callout).lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(selected ? .accentColor : nil)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .onChange(of: model.cropAspect) { _, _ in model.fitCropAspect() }
                Toggle(
                    isOn: Binding(
                        get: { model.cropPortrait },
                        set: {
                            model.cropPortrait = $0
                            model.fitCropAspect()
                        })
                ) {
                    Label("Swap Width and Height", systemImage: "rectangle.portrait.rotate")
                        .frame(maxWidth: .infinity)
                }
                .toggleStyle(.button)
                .disabled(model.cropAspect == 0 || model.cropAspect == 1)
            }
            InspectorSection(String(localized: "Straighten")) {
                LabeledSlider(
                    title: String(localized: "Angle"), value: model.binding(\.photo.geometry.straighten),
                    range: -45...45,
                    display: model.values.photo.geometry.straighten.formatted(.number.precision(.fractionLength(1)))
                        + "°", model: model)
            }
            DisclosureGroup("Exact Selection (%)") {
                VStack(spacing: 8) {
                    cropField("Left", keyPath: \.x)
                    cropField("Top", keyPath: \.y)
                    cropField("Width", keyPath: \.width)
                    cropField("Height", keyPath: \.height)
                }
                .padding(.top, 6)
            }
            Button("Reset Crop and Rotation") {
                model.change { $0.photo.geometry = EditGeometry() }; model.cropAspect = 0
            }
            .frame(maxWidth: .infinity)
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
            InspectorSection(String(localized: "Selected Segment")) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Start").foregroundStyle(.secondary)
                        EditorNumberField(
                            model: model, title: Text("Start (seconds)"), id: "start",
                            value: model.videoBoundaryBinding(start: true),
                            range: 0...max(0, model.values.end - model.sourceFrameDuration),
                            precision: 3
                        )
                        Text("sec").foregroundStyle(.tertiary)
                    }
                    GridRow {
                        Text("End").foregroundStyle(.secondary)
                        EditorNumberField(
                            model: model, title: Text("End (seconds)"), id: "end",
                            value: model.videoBoundaryBinding(start: false),
                            range: min(
                                model.sourceDuration, model.values.start + model.sourceFrameDuration)...model
                                .sourceDuration,
                            precision: 3
                        )
                        Text("sec").foregroundStyle(.tertiary)
                    }
                    GridRow {
                        Text("Length").foregroundStyle(.secondary)
                        Text(Timecode.string((model.values.end - model.values.start) / model.values.speed))
                            .monospacedDigit()
                            .gridCellColumns(2)
                    }
                }
                .disabled(!model.hasSelection)
            }
            InspectorSection(String(localized: "Speed")) {
                Picker(
                    "Playback speed",
                    selection: Binding(
                        get: { Self.speedPresets.contains(model.values.speed) ? model.values.speed : nil },
                        set: { speed in if let speed { model.change { $0.speed = speed } } })
                ) {
                    ForEach(Self.speedPresets, id: \.self) { speed in
                        Text(speed.formatted(.number.precision(.fractionLength(0...2))) + "×").tag(Optional(speed))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack {
                    Slider(value: model.binding(\.speed), in: 0.5...4) {
                        Text("Playback speed")
                    } onEditingChanged: { active in
                        active ? model.beginInteraction() : model.endInteraction()
                    }
                    .labelsHidden()
                    EditorNumberField(
                        model: model, title: Text("Playback speed"), id: "speed",
                        value: model.binding(\.speed), range: VideoEdit.speedRange, precision: 2
                    ).frame(width: 58)
                    Text(verbatim: "×").foregroundStyle(.secondary).accessibilityHidden(true)
                }
                Text("Pitch is preserved.").font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!model.hasSelection)
            InspectorSection(String(localized: "Volume")) {
                HStack(spacing: 10) {
                    Button {
                        model.change { $0.volume = $0.volume == 0 ? 1 : 0 }
                    } label: {
                        Label(
                            model.values.volume == 0 ? "Unmute" : "Mute",
                            systemImage: model.values.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .frame(width: 22)
                    Slider(value: model.binding(\.volume), in: 0...1) {
                        Text("Volume")
                    } onEditingChanged: { active in
                        active ? model.beginInteraction() : model.endInteraction()
                    }
                    .labelsHidden()
                    Text("\(Int((model.values.volume * 100).rounded()))%")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
            .disabled(!model.selectedHasAudio)
            InspectorSection(String(localized: "Export")) {
                Picker("Resolution", selection: model.binding(\.resolution)) {
                    Text("Original resolution").tag(0)
                    ForEach([2160, 1080, 720, 480, 360], id: \.self) { Text(verbatim: "\($0)p").tag($0) }
                }
            }
            InspectorSection(String(localized: "Source Videos")) {
                if model.values.sources.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.values.sources.enumerated()), id: \.offset) { index, source in
                            Text("\(index + 1). \(source.url.lastPathComponent)").font(.callout).lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Text(
                        "Joined videos use the first video's canvas and frame rate. Other sizes fit with black borders. HDR becomes SDR; transparency is flattened. Originals are kept. Metadata may be removed."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = true
                    panel.canChooseDirectories = false
                    panel.allowedContentTypes = [.movie, .video]
                    if panel.runModal() == .OK { model.importVideos(panel.urls) }
                } label: {
                    Label("Add Videos…", systemImage: "plus")
                }
                .disabled(model.importing)
            }
        }
    }

    private static let speedPresets: [Double] = [0.5, 1, 1.5, 2]
}

private enum AdjustmentGroup: CaseIterable {
    case light, color, detail

    var title: String {
        switch self {
        case .light: String(localized: "Light")
        case .color: String(localized: "Color")
        case .detail: String(localized: "Detail")
        }
    }

    var adjustments: [MediaAdjustment] {
        switch self {
        case .light: [.exposure, .brightness, .contrast, .highlights, .shadows, .blackPoint]
        case .color: [.saturation, .vibrance, .warmth, .tint]
        case .detail: [.sharpness, .noiseReduction, .vignette]
        }
    }
}

private struct CropAspectOption {
    let title: String
    let value: Double

    static let all = [
        CropAspectOption(title: String(localized: "Freeform"), value: 0),
        CropAspectOption(title: String(localized: "Original Ratio"), value: -1),
        CropAspectOption(title: "1:1", value: 1),
        CropAspectOption(title: "4:3", value: 4.0 / 3),
        CropAspectOption(title: "3:2", value: 1.5),
        CropAspectOption(title: "4:5", value: 0.8),
        CropAspectOption(title: "16:9", value: 16.0 / 9),
    ]
}

private struct ToolTileLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            configuration.icon.font(.title3)
            configuration.title.font(.caption).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String
    @Bindable var model: MediaEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(display).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range) {
                Text(title)
            } onEditingChanged: { active in
                active ? model.beginInteraction() : model.endInteraction()
            }
            .labelsHidden()
        }
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
            .multilineTextAlignment(.trailing).monospacedDigit().focused($focused)
            .onAppear { synchronize() }
            .onDisappear {
                model.invalidFields.remove(id); if focused { model.endInteraction() }
            }
            .onChange(of: value) { _, _ in
                if !focused, parsed != value { synchronize() }
            }
            .onChange(of: focused) { _, focused in
                if focused {
                    model.beginInteraction()
                } else {
                    Task { @MainActor in
                        await model.finishBoundaryInput()
                        guard !self.focused else { return }
                        synchronize()
                        model.endInteraction()
                    }
                }
            }
            .onSubmit { focused = false }
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(adjustment.editorTitle)
                Spacer()
                Button {
                    value.wrappedValue = 0
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset adjustment")
                .opacity(value.wrappedValue == 0 ? 0 : 1)
                .disabled(value.wrappedValue == 0)
                .accessibilityLabel(Text("Reset \(adjustment.editorTitle)"))
                EditorNumberField(
                    model: model, title: Text(adjustment.editorTitle), id: adjustment.rawValue,
                    value: value, range: adjustment.range, precision: 2
                )
                .controlSize(.small)
                .frame(width: 52)
            }
            Slider(value: value, in: adjustment.range) {
                Text(adjustment.editorTitle)
            } onEditingChanged: { active in
                active ? model.beginInteraction() : model.endInteraction()
            }
            .labelsHidden()
            .controlSize(.small)
            .tint(adjustment.range.lowerBound < 0 ? .secondary : nil)
        }
    }
}

extension EditorCategory {
    var symbol: String {
        switch self {
        case .video: "film"
        case .adjust: "slider.horizontal.3"
        case .styles: "camera.filters"
        case .crop: "crop.rotate"
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
