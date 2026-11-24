import AVKit
import Engine
import SwiftUI

struct MediaEditorView: View {
    @Bindable var model: MediaEditorModel
    let close: () -> Void
    let save: (Batch, Engine.Settings) -> Task<BatchOutcome?, Never>
    let runFrame: (Batch, Engine.Settings) -> Task<BatchOutcome?, Never>
    let progress: (UUID) -> JobCenter.ActiveBatch?

    private var editable: Bool { model.ready && !model.editingLocked }
    @State private var showsPreparing = false
    @GestureState private var pinch = 1.0
    @Environment(\.displayScale) private var displayScale

    private var preparing: Bool { model.preparingPreview }

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
            } else if model.streamConsent == nil {
                ProgressView("Opening…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(.background)
        .preferredColorScheme(.dark)
        .toolbar { toolbar }
        .task { model.load() }
        .streamConsentAlert($model.streamConsent, accept: model.continueWithoutStreams) { declined in
            if declined.purpose == .open { close() }
        }
        .background(
            EditorKeyboardShortcuts(
                model: model, save: { save(replacingOriginal: false) },
                saveFrame: { Task { await model.saveFrame(run: runFrame) } }, close: close
            ).frame(width: 0, height: 0)
        )
        .onChange(of: model.category) { _, _ in
            model.pause(); model.refresh()
        }
        .onChange(of: model.original) { _, _ in
            model.pause(); model.refresh()
        }
        .onChange(of: model.zoom) { _, _ in model.refresh() }
        .task(id: preparing) {
            showsPreparing = false
            guard preparing else { return }
            // Quick rebuilds would otherwise flash the indicator.
            do { try await Task.sleep(for: Self.preparingDelay) } catch { return }
            showsPreparing = true
        }
    }

    private static let preparingDelay = Duration.milliseconds(300)
    private static let previewInset = CGSize(width: 48, height: 40)

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
                    if model.isVideo {
                        EditorTransportBar(model: model) { Task { await model.saveFrame(run: runFrame) } }
                    } else {
                        photoBar
                    }
                }
                Divider()
                inspector.frame(width: 300)
            }
            if model.isVideo {
                Divider()
                EditorTimeline(model: model)
            }
        }
        .disabled(model.savingBatchID != nil)
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
            .disabled(!editable)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.original) {
                Label("Compare Original", systemImage: "square.split.2x1")
            }
            .toggleStyle(.button)
            .help("Show Original (M)")
            .accessibilityValue(model.original ? Text("Original") : Text("Edited"))
            .disabled(!editable)
            ControlGroup {
                Menu {
                    Button("Reset All Edits") { model.reset() }
                } label: {
                    Label("Undo Edit", systemImage: "arrow.uturn.backward")
                } primaryAction: {
                    model.undo()
                }
                .help("Undo (⌘Z)")
                .disabled(!model.canUndo || !editable)
                Button {
                    model.redo()
                } label: {
                    Label("Redo Edit", systemImage: "arrow.uturn.forward")
                }
                .help("Redo (⇧⌘Z)")
                .disabled(!model.canRedo || !editable)
            }
            Button("Cancel", action: close)
        }
        ToolbarItem(placement: .confirmationAction) {
            Menu {
                Button {
                    save(replacingOriginal: true)
                } label: {
                    Text("Replace Original")
                    Text("The original goes to the Trash and can be undone.")
                }
                .disabled(model.forcesNewFile)
                .help(model.newFileReason ?? "")
            } label: {
                Text("Save")
            } primaryAction: {
                save(replacingOriginal: false)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSave)
        }
    }

    private func save(replacingOriginal: Bool) {
        Task {
            if await model.save(replacingOriginal: replacingOriginal, run: save) { close() }
        }
    }

    private var photoList: some View {
        VStack(spacing: 8) {
            List(model.photoURLs, id: \.self, selection: $model.selectedPhotos) { url in
                HStack {
                    PhotoListThumbnail(url: url)
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
                Button {
                    model.applyPhotoEdits(toAll: false)
                } label: {
                    Text("Copy Edits to Selected").frame(maxWidth: .infinity)
                }
                .help("Copy this photo’s edits to the selected photos")
                .disabled(model.selectedPhotos.isEmpty)
                Button {
                    model.applyPhotoEdits(toAll: true)
                } label: {
                    Text("Copy Edits to All Photos").frame(maxWidth: .infinity)
                }
                .help("Copy this photo’s edits to every photo in the list")
            }
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    private var photoBar: some View {
        PhotoZoomControl(model: model, pinch: pinch)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .frame(height: 44)
    }

    private var preview: some View {
        GeometryReader { proxy in
            let fitScale = min(
                (proxy.size.width - Self.previewInset.width) * displayScale / model.previewSize.width,
                (proxy.size.height - Self.previewInset.height) * displayScale / model.previewSize.height)
            ZStack {
                Color.black.opacity(0.55)
                if model.isVideo || model.image != nil {
                    let imageSize =
                        model.isVideo
                        ? model.previewSize
                        : CGSize(
                            width: model.image?.width ?? 1, height: model.image?.height ?? 1)
                    let scale = min(
                        (proxy.size.width - Self.previewInset.width) / imageSize.width,
                        (proxy.size.height - Self.previewInset.height) / imageSize.height)
                    let zoom = model.category == .crop || model.isVideo ? 1 : model.livePhotoZoom(pinch: pinch)
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
                                EditorCropOverlay(model: model).disabled(model.editingLocked)
                                    .allowsHitTesting(!model.editingLocked)
                            }
                            if model.category == .markup && !model.original {
                                EditorMarkupOverlay(model: model).disabled(model.editingLocked)
                                    .allowsHitTesting(!model.editingLocked)
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                    }
                    .scrollIndicators(zoom > 1 ? .automatic : .never)
                    .gesture(
                        MagnifyGesture()
                            .updating($pinch) { value, pinch, _ in pinch = value.magnification }
                            .onEnded { value in model.setPhotoZoom(model.zoom * value.magnification) },
                        isEnabled: !model.isVideo && model.category != .crop)
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
                        if showsPreparing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Preparing preview…").font(.callout)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Spacer()
                }.padding(12)
            }
            .onChange(of: fitScale, initial: true) { _, fit in
                if !model.isVideo { model.updatePhotoFitScale(fit) }
            }
        }
    }

    private var inspector: some View {
        let needsSegment =
            model.isVideo && !model.hasSelection && model.category != .crop && model.category != .markup
        return VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if needsSegment {
                            Label("Select a segment in the timeline to adjust it.", systemImage: "info.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Group {
                            switch model.category {
                            case .video: videoControls
                            case .adjust: adjustmentControls
                            case .styles: styleControls
                            case .crop: cropControls
                            case .markup: EditorMarkupInspector(model: model)
                            }
                        }
                        .disabled(needsSegment && model.category != .video)
                    }
                    .id(model.isVideo ? model.values.selectedID : nil)
                    .disabled(model.loadingPhoto)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(model.reverseProgress != nil)
                .onChange(of: model.musicRevealRequest) { _, _ in reader.scrollTo(Self.musicSectionID) }
            }
            if model.isVideo {
                Divider()
                exportSettings.disabled(model.editingLocked)
            }
            Divider()
            outputSummary
        }
        .background(.background.secondary)
    }

    private var exportSettings: some View {
        InspectorSection(String(localized: "Export")) {
            LabeledContent("Resolution") {
                Picker("Resolution", selection: model.binding(\.resolution)) {
                    Text("Original resolution").tag(0)
                    ForEach([2160, 1080, 720, 480, 360], id: \.self) { Text(verbatim: "\($0)p").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func saveProgress(_ id: UUID, title: Text) -> some View {
        let batch = progress(id)
        let fraction = batch.flatMap { $0.itemCount > 1 ? $0.progress : $0.currentFileFraction }
        return HStack(spacing: 8) {
            ProgressView(value: fraction).controlSize(.small)
            title.font(.callout).foregroundStyle(.secondary).fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var reverseStatus: some View {
        if let fraction = model.reverseProgress {
            HStack(spacing: 8) {
                ProgressView(value: fraction).controlSize(.small)
                Text("Reversing…").font(.callout).foregroundStyle(.secondary).fixedSize()
                Button("Cancel", action: model.cancelReverse).controlSize(.small)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Reversing segment"))
        }
        if let failure = model.reverseFailure { ProblemLabel(text: failure) }
    }

    @ViewBuilder private var frameNote: some View {
        switch model.frameNote {
        case .saved(let output):
            HStack(spacing: 6) {
                Label("Saved “\(output.lastPathComponent)”", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                    .buttonStyle(.link)
                    .fixedSize()
            }
            .font(.callout)
        case .failed(let message): ProblemLabel(text: message)
        case nil: EmptyView()
        }
    }

    private var outputSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let id = model.savingBatchID { saveProgress(id, title: Text("Saving…")) }
            if let id = model.frameBatchID { saveProgress(id, title: Text("Saving Frame…")) }
            frameNote
            reverseStatus
            if let failure = model.saveFailure ?? model.failure {
                ProblemLabel(text: failure)
            }
            if model.invalidFields.contains(where: { $0 != MediaEditorModel.overlayTextField }) {
                ProblemLabel(text: String(localized: "Enter a valid number within the allowed range."))
            }
            if let note = model.omittedStreamsNote {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text("\(Int(model.outputSize.width)) × \(Int(model.outputSize.height))")
                if model.isVideo {
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                    Text(Timecode.string(model.outputDuration))
                }
            }
            .font(.callout.monospacedDigit())
            if let reason = model.newFileReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private func applyToAllSegments(styleOnly: Bool) -> some View {
        if model.isVideo, model.values.segments.count > 1 {
            Button {
                model.applyToAllSegments(styleOnly: styleOnly)
            } label: {
                Text(styleOnly ? "Apply Style to All Segments" : "Apply Adjustments to All Segments")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!model.canApplyToAllSegments(styleOnly: styleOnly))
            .help(
                model.applyToAllUnavailableReason(styleOnly: styleOnly)
                    ?? (styleOnly
                        ? String(localized: "Give every segment this segment’s style")
                        : String(localized: "Give every segment this segment’s adjustments")))
        }
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
            applyToAllSegments(styleOnly: false)
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
                title: String(localized: "Intensity"), value: model.adjustments.styleIntensity, range: 0...1,
                display: "\(Int((model.adjustments.styleIntensity * 100).rounded()))%", model: model
            ) { amount, interaction in
                model.adjustmentBinding(\.styleIntensity, in: interaction).wrappedValue = amount
            }
            .disabled(model.adjustments.style == .original)
            applyToAllSegments(styleOnly: true)
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
                .disabled(model.swapCropSidesUnavailableReason != nil)
                .help(model.swapCropSidesUnavailableReason ?? "")
            }
            InspectorSection(String(localized: "Straighten")) {
                LabeledSlider(
                    title: String(localized: "Angle"), value: model.values.photo.geometry.straighten,
                    range: -45...45,
                    display: model.values.photo.geometry.straighten.formatted(.number.precision(.fractionLength(1)))
                        + "°", model: model
                ) { angle, interaction in
                    model.change(in: interaction) { $0.photo.geometry.straighten = angle }
                }
            }
            DisclosureGroup("Exact Selection (%)") {
                VStack(spacing: 8) {
                    cropField(String(localized: "Left"), keyPath: \.x)
                    cropField(String(localized: "Top"), keyPath: \.y)
                    cropField(String(localized: "Width"), keyPath: \.width)
                    cropField(String(localized: "Height"), keyPath: \.height)
                }
                .padding(.top, 6)
            }
            Button("Reset Crop and Rotation") {
                model.change { $0.photo.geometry = EditGeometry() }; model.cropAspect = 0
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func cropField(_ title: String, keyPath: WritableKeyPath<EditCrop, Double>) -> some View {
        LabeledContent(title) {
            EditorNumberField(
                model: model, title: title, id: "crop-\(keyPath)",
                value: model.values.photo.geometry.crop[keyPath: keyPath] * 100, range: 0...100, precision: 1
            ) { percent, interaction in
                model.setCropPercentage(percent, keyPath: keyPath, in: interaction)
            }
            .frame(width: 70)
        }
    }

}

/// Original-photo thumbnail beside a file name.
private struct PhotoListThumbnail: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
        .task(id: url) {
            let thumbnail = await Self.thumbnail(url)
            guard !Task.isCancelled else { return }
            image = thumbnail
        }
    }

    /// Unreadable files keep the placeholder.
    @concurrent private static func thumbnail(_ url: URL) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.pixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static let side: CGFloat = 36
    private nonisolated static let pixels = 96
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

/// Common editor fade lengths.
struct FadePicker: View {
    static let presets: [Double] = [0, 0.25, 0.5, 1, 2, 3, 5]

    let title: Text
    @Binding var value: Double

    var body: some View {
        Picker(selection: $value) {
            ForEach(Self.presets + (Self.presets.contains(value) ? [] : [value]), id: \.self) { seconds in
                Text(Self.title(seconds)).tag(seconds)
            }
        } label: {
            title
        }
        .labelsHidden()
        .fixedSize()
    }

    static func title(_ seconds: Double) -> String {
        seconds == 0
            ? String(localized: "None")
            : String(localized: "\(seconds.formatted(.number.precision(.fractionLength(0...2)))) sec")
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

struct ToolTileLabelStyle: LabelStyle {
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

struct EditorSlider: View {
    @Bindable var model: MediaEditorModel
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    /// Spoken instead of the raw number.
    var spokenValue: String?
    let commit: (Double, EditorInteraction?) -> Void
    @State private var interaction: EditorInteraction?

    var body: some View {
        Slider(
            value: Binding(get: { value }, set: { commit($0, interaction) }),
            in: range
        ) {
            Text(title)
        } onEditingChanged: { active in
            if active {
                interaction = model.beginInteraction()
            } else if let token = interaction {
                interaction = nil
                model.endInteraction(token)
            }
        }
        .labelsHidden()
        .accessibilityValue(Text(spokenValue ?? value.formatted(.number.precision(.fractionLength(0...2)))))
        .onDisappear {
            if let token = interaction {
                interaction = nil
                model.endInteraction(token)
            }
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let display: String
    @Bindable var model: MediaEditorModel
    let commit: (Double, EditorInteraction?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(display).monospacedDigit().foregroundStyle(.secondary)
            }
            EditorSlider(model: model, title: title, value: value, range: range, spokenValue: display, commit: commit)
        }
    }
}

struct EditorNumberField: View {
    @Bindable var model: MediaEditorModel
    let title: String
    let id: String
    let value: Double
    let range: ClosedRange<Double>
    let precision: Int
    var timecode = false
    let commit: (Double, EditorInteraction) -> Void

    init(
        model: MediaEditorModel, title: String, id: String, value: Double, range: ClosedRange<Double>, precision: Int,
        timecode: Bool = false, commit: @escaping (Double, EditorInteraction) -> Void
    ) {
        self.model = model
        self.title = title
        self.id = id
        self.value = value
        self.range = range
        self.precision = precision
        self.timecode = timecode
        self.commit = commit
    }

    init(
        model: MediaEditorModel, title: String, id: String, keyPath: WritableKeyPath<EditorValues, Double>,
        range: ClosedRange<Double>, precision: Int, timecode: Bool = false
    ) {
        self.init(
            model: model, title: title, id: id, value: model.values[keyPath: keyPath], range: range,
            precision: precision, timecode: timecode
        ) { amount, interaction in
            model.change(in: interaction) { $0[keyPath: keyPath] = amount }
        }
    }

    var body: some View {
        EditorNumberControl(
            model: model, title: title, id: id, value: value, commit: commit,
            range: range, precision: precision, timecode: timecode)
    }
}

// AppKit delegate avoids delayed SwiftUI FocusState updates.
private struct EditorNumberControl: NSViewRepresentable {
    let model: MediaEditorModel
    let title: String
    let id: String
    let value: Double
    let commit: (Double, EditorInteraction) -> Void
    let range: ClosedRange<Double>
    let precision: Int
    let timecode: Bool

    var formattedValue: String {
        timecode
            ? Timecode.string(value, fractionDigits: precision)
            : value.formatted(.number.grouping(.never).precision(.fractionLength(precision)))
    }

    func parse(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        guard let amount = timecode ? TimecodeField.parse(normalized) : Double(normalized), amount.isFinite,
            range.contains(amount)
        else { return nil }
        return amount
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        let controlSize = Self.controlSize(context.environment.controlSize)
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.alignment = .right
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.controlSize = controlSize
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: controlSize), weight: .regular)
        field.isEnabled = context.environment.isEnabled
        field.setAccessibilityLabel(title)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.stringValue = formattedValue
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ view: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let controlSize = Self.controlSize(context.environment.controlSize)
        if view.controlSize != controlSize {
            view.controlSize = controlSize
            view.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: controlSize), weight: .regular)
        }
        if view.isEnabled != context.environment.isEnabled { view.isEnabled = context.environment.isEnabled }
        if view.accessibilityLabel() != title { view.setAccessibilityLabel(title) }
        guard !coordinator.editing, view.currentEditor() == nil else { return }
        let formatted = formattedValue
        if view.stringValue != formatted { view.stringValue = formatted }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let fitting = nsView.fittingSize
        let width = proposal.width ?? max(Self.minimumIdealWidth, fitting.width)
        let height = nsView.controlSize == .small ? Self.smallHeight : fitting.height
        return CGSize(width: width, height: height)
    }

    static func dismantleNSView(_ view: NSTextField, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.teardown()
    }

    private static let minimumIdealWidth: CGFloat = 52
    // Matches SwiftUI's small text field.
    private static let smallHeight: CGFloat = 21

    private static func controlSize(_ size: ControlSize) -> NSControl.ControlSize {
        switch size {
        case .mini: .mini
        case .small: .small
        case .regular: .regular
        case .large: .large
        case .extraLarge: .extraLarge
        @unknown default: .regular
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: EditorNumberControl
        var editing = false
        private var interaction: EditorInteraction?

        init(parent: EditorNumberControl) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) { beginEditing() }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            editing = true
            // Input methods apply only committed text.
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
            if let amount = parent.parse(field.stringValue) {
                parent.model.invalidFields.remove(parent.id)
                if amount != parent.value { parent.commit(amount, ensureInteraction()) }
            } else {
                parent.model.invalidFields.insert(parent.id)
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard editing else { return }
            finishEditing(notification.object as? NSTextField)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            control.window?.makeFirstResponder(nil)
            return true
        }

        func teardown() {
            let model = parent.model
            let id = parent.id
            let token = interaction
            interaction = nil
            let wasEditing = editing
            editing = false
            guard wasEditing || token != nil || model.invalidFields.contains(id) else { return }
            guard !model.closed else { return }
            model.invalidFields.remove(id)
            if let token { model.endInteraction(token) }
        }

        private func beginEditing() {
            editing = true
            _ = ensureInteraction()
        }

        private func ensureInteraction() -> EditorInteraction {
            if let interaction, parent.model.isActiveInteraction(interaction) { return interaction }
            let token = parent.model.beginInteraction()
            interaction = token
            return token
        }

        private func finishEditing(_ field: NSTextField?) {
            editing = false
            let token = interaction
            interaction = nil
            if let field {
                let formatted = parent.formattedValue
                if field.stringValue != formatted { field.stringValue = formatted }
            }
            parent.model.invalidFields.remove(parent.id)
            if let token { parent.model.endInteraction(token) }
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

    private var currentValue: Double { model.adjustments[adjustment] }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(adjustment.editorTitle)
                Spacer()
                Button {
                    model.setAdjustment(adjustment, to: 0)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset adjustment")
                .opacity(currentValue == 0 ? 0 : 1)
                .disabled(currentValue == 0)
                .accessibilityLabel(Text("Reset \(adjustment.editorTitle)"))
                EditorNumberField(
                    model: model, title: adjustment.editorTitle, id: adjustment.rawValue,
                    value: currentValue, range: adjustment.range, precision: 2
                ) { amount, interaction in
                    model.setAdjustment(adjustment, to: amount, in: interaction)
                }
                .controlSize(.small)
                .frame(width: 52)
            }
            EditorSlider(model: model, title: adjustment.editorTitle, value: currentValue, range: adjustment.range) {
                amount, interaction in
                model.setAdjustment(adjustment, to: amount, in: interaction)
            }
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
        case .markup: "pencil.tip.crop.circle"
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
