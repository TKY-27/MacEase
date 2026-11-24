import Engine
import SwiftUI

struct EditorMarkupInspector: View {
    @Bindable var model: MediaEditorModel

    private var selected: EditOverlay? { model.selectedOverlay }
    private var shownTool: MarkupTool { selected?.mark.tool ?? model.markupTool }

    var body: some View {
        Group {
            InspectorSection(String(localized: "Tool")) {
                tools
                if model.markupTool != .select {
                    Button(addTitle(model.markupTool)) { model.addDefaultOverlay(model.markupTool) }
                        .frame(maxWidth: .infinity)
                        .disabled(!model.canAddOverlay)
                    Text(hint(model.markupTool)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            switch shownTool {
            case .redact: redactionStyle
            case .box, .arrow, .text: annotationStyle
            case .select: EmptyView()
            }
            if let selected {
                if case .text(let text, _, _, _) = selected.mark {
                    InspectorSection(String(localized: "Text")) {
                        MarkupTextField(model: model, id: selected.id, text: text).id(selected.id)
                    }
                }
                EditorMarkupPosition(model: model, overlay: selected)
                if let timed = model.selectedTimedOverlay { visibleRange(timed) }
            }
            overlayList
        }
    }

    private var tools: some View {
        HStack(spacing: 6) {
            ForEach(MarkupTool.allCases, id: \.self) { tool in
                let active = model.markupTool == tool
                Button {
                    model.markupTool = tool
                } label: {
                    Label(tool.title, systemImage: tool.symbol)
                        .padding(.vertical, 4)
                        .foregroundStyle(active ? Color.white : .primary)
                        .background(
                            active ? Color.accentColor : Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
                .help(hint(tool))
            }
        }
        .labelStyle(ToolTileLabelStyle())
    }

    private func addTitle(_ tool: MarkupTool) -> String {
        switch tool {
        case .select: ""
        case .redact: String(localized: "Add \(model.redactionStyle.title) Region")
        case .box: String(localized: "Add Box")
        case .arrow: String(localized: "Add Arrow")
        case .text: String(localized: "Add Text")
        }
    }

    private func hint(_ tool: MarkupTool) -> String {
        switch tool {
        case .select: String(localized: "Select, move and resize markup.")
        case .redact: String(localized: "Drag over the area to hide.")
        case .box, .arrow: String(localized: "Drag in the preview to draw.")
        case .text: String(localized: "Click in the preview to add text.")
        }
    }

    private var redactionStyle: some View {
        InspectorSection(String(localized: "Redaction")) {
            Picker(
                "Redaction style",
                selection: Binding(
                    get: {
                        if case .redaction(_, let style) = selected?.mark { return style }
                        return model.redactionStyle
                    },
                    set: { style in
                        model.redactionStyle = style
                        if let selected, case .redaction(let rect, _) = selected.mark {
                            model.updateOverlay(selected.id, .redaction(rect: rect, style: style))
                        }
                    })
            ) {
                ForEach(RedactionStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Mosaic and blur can sometimes be partly reversed. Solid can’t.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var annotationStyle: some View {
        InspectorSection(String(localized: "Style")) {
            HStack(spacing: 8) {
                ForEach(MarkColor.allCases, id: \.self) { color in
                    let active = (selected?.mark.color ?? model.markColor) == color
                    Button {
                        model.markColor = color
                        if let selected, let mark = selected.mark.with(color: color) {
                            model.updateOverlay(selected.id, mark)
                        }
                    } label: {
                        Circle().fill(Color(cgColor: color.cgColor))
                            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                            .frame(width: 20, height: 20)
                            .padding(3)
                            .overlay(Circle().strokeBorder(active ? Color.accentColor : .clear, lineWidth: 2))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(color.title))
                    .accessibilityAddTraits(active ? .isSelected : [])
                    .help(color.title)
                }
            }
            Picker(
                "Size",
                selection: Binding(
                    get: { selected?.mark.size ?? model.markSize },
                    set: { size in
                        model.markSize = size
                        if let selected, let mark = selected.mark.with(size: size) {
                            model.updateOverlay(selected.id, mark)
                        }
                    })
            ) {
                ForEach(MarkSize.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private func visibleRange(_ timed: TimedOverlay) -> some View {
        let duration =
            model.values.sources.indices.contains(timed.sourceIndex)
            ? model.values.sources[timed.sourceIndex].duration : model.duration
        let ranges = model.timeline?.outputRanges(of: timed) ?? []
        return InspectorSection(String(localized: "Visible Range")) {
            if model.values.sources.count > 1, model.values.sources.indices.contains(timed.sourceIndex) {
                Text(model.values.sources[timed.sourceIndex].url.lastPathComponent)
                    .font(.callout).lineLimit(1).truncationMode(.middle)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Start").foregroundStyle(.secondary)
                    EditorNumberField(
                        model: model, title: String(localized: "Start"), id: "overlay-start",
                        value: Binding(
                            get: { timed.start },
                            set: { model.setOverlayRange(timed.id, start: $0, end: timed.end) }),
                        range: 0...max(0, timed.end - model.frameDuration), precision: Self.timecodeDigits,
                        timecode: true)
                }
                GridRow {
                    Text("End").foregroundStyle(.secondary)
                    EditorNumberField(
                        model: model, title: String(localized: "End"), id: "overlay-end",
                        value: Binding(
                            get: { timed.end },
                            set: { model.setOverlayRange(timed.id, start: timed.start, end: $0) }),
                        range: min(duration, timed.start + model.frameDuration)...duration,
                        precision: Self.timecodeDigits, timecode: true)
                }
            }
            HStack(spacing: 8) {
                Button("Start at Playhead") { Task { await model.setOverlayBoundaryAtPlayhead(start: true) } }
                    .help("Show from the playhead (I)")
                Button("End at Playhead") { Task { await model.setOverlayBoundaryAtPlayhead(start: false) } }
                    .help("Show through the playhead (O)")
            }
            .disabled(!model.canSetOverlayBoundary)
            .frame(maxWidth: .infinity)
            Button("Show for Whole Video") { model.setOverlayRange(timed.id, start: 0, end: duration) }
                .frame(maxWidth: .infinity)
                .disabled(timed.start == 0 && timed.end == duration)
            if ranges.isEmpty {
                ProblemLabel(
                    text: String(localized: "Not shown in the edited video. Its range is outside every segment."))
            } else if !model.canSetOverlayBoundary {
                Text("Move the playhead into this video to set the range from it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var overlayList: some View {
        InspectorSection(String(localized: "Markup")) {
            if model.markupOverlays.isEmpty {
                Text("No markup yet.").font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                ForEach(model.markupOverlays, id: \.id) { overlay in
                    overlayRow(overlay)
                }
            }
            if !model.canAddOverlay, model.markupOverlays.count >= EditOverlay.maximumCount {
                Text("Up to \(EditOverlay.maximumCount) items.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func overlayRow(_ overlay: EditOverlay) -> some View {
        let active = model.values.selectedOverlayID == overlay.id
        let name = model.overlayName(overlay)
        return HStack(spacing: 8) {
            Button {
                model.selectOverlay(overlay.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: overlay.mark.symbol).frame(width: 18).foregroundStyle(.secondary)
                    Text(name).lineLimit(1)
                    Spacer(minLength: 4)
                    if case .text(let text, _, _, _) = overlay.mark {
                        Text(text).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                            .frame(maxWidth: 90, alignment: .trailing)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(name))
            .accessibilityValue(Text(model.overlayDescription(overlay)))
            .accessibilityAddTraits(active ? .isSelected : [])
            Button {
                model.deleteOverlay(overlay.id)
            } label: {
                Label("Delete \(name)", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Delete (⌫)")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(active ? Color.accentColor.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private static let timecodeDigits = 3
}

/// The accessible, precise placement path.
private struct EditorMarkupPosition: View {
    @Bindable var model: MediaEditorModel
    let overlay: EditOverlay

    var body: some View {
        InspectorSection(String(localized: "Position (%)")) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                switch overlay.mark {
                case .redaction(let rect, _), .box(let rect, _, _):
                    row(String(localized: "Left"), "left", rect.x) {
                        rectMark(
                            EditCrop(x: min($0, 1 - rect.width), y: rect.y, width: rect.width, height: rect.height))
                    }
                    row(String(localized: "Top"), "top", rect.y) {
                        rectMark(
                            EditCrop(x: rect.x, y: min($0, 1 - rect.height), width: rect.width, height: rect.height))
                    }
                    row(String(localized: "Width"), "width", rect.width, minimum: MediaEditorModel.minimumOverlaySide) {
                        rectMark(EditCrop(x: rect.x, y: rect.y, width: min($0, 1 - rect.x), height: rect.height))
                    }
                    row(
                        String(localized: "Height"), "height", rect.height, minimum: MediaEditorModel.minimumOverlaySide
                    ) {
                        rectMark(EditCrop(x: rect.x, y: rect.y, width: rect.width, height: min($0, 1 - rect.y)))
                    }
                case .arrow(let from, let to, let color, let size):
                    row(String(localized: "Start X"), "start-x", from.x) {
                        .arrow(from: EditPoint(x: $0, y: from.y), to: to, color: color, size: size)
                    }
                    row(String(localized: "Start Y"), "start-y", from.y) {
                        .arrow(from: EditPoint(x: from.x, y: $0), to: to, color: color, size: size)
                    }
                    row(String(localized: "End X"), "end-x", to.x) {
                        .arrow(from: from, to: EditPoint(x: $0, y: to.y), color: color, size: size)
                    }
                    row(String(localized: "End Y"), "end-y", to.y) {
                        .arrow(from: from, to: EditPoint(x: to.x, y: $0), color: color, size: size)
                    }
                case .text(let text, let at, let color, let size):
                    row(String(localized: "X"), "x", at.x) {
                        .text(text, at: EditPoint(x: $0, y: at.y), color: color, size: size)
                    }
                    row(String(localized: "Y"), "y", at.y) {
                        .text(text, at: EditPoint(x: at.x, y: $0), color: color, size: size)
                    }
                }
            }
            if !model.values.photo.geometry.isIdentity {
                Text("Measured on the original frame, before crop and rotation.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .id(overlay.id)
    }

    private func rectMark(_ rect: EditCrop) -> EditMark {
        switch overlay.mark {
        case .redaction(_, let style): .redaction(rect: rect, style: style)
        case .box(_, let color, let size): .box(rect: rect, color: color, size: size)
        case .arrow, .text: overlay.mark
        }
    }

    private func row(
        _ title: String, _ key: String, _ value: Double, minimum: Double = 0,
        mark: @escaping (Double) -> EditMark
    ) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            EditorNumberField(
                model: model, title: title, id: "overlay-\(key)",
                value: Binding(
                    get: { value * 100 },
                    set: { model.updateOverlay(overlay.id, mark($0 / 100)) }),
                range: minimum * 100...100, precision: 1
            )
            .frame(width: 70)
        }
    }
}

private struct MarkupTextField: View {
    @Bindable var model: MediaEditorModel
    let id: UUID
    let text: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(
                "Text",
                text: Binding(
                    get: { draft },
                    set: { entered in
                        draft = entered.replacing(/\R/, with: " ")
                        guard let selected = model.selectedOverlay, selected.id == id,
                            case .text(_, let at, let color, let size) = selected.mark
                        else { return }
                        let mark = EditMark.text(draft, at: at, color: color, size: size)
                        if (try? mark.validate()) != nil {
                            model.invalidFields.remove(MediaEditorModel.overlayTextField)
                            model.updateOverlay(id, mark)
                        } else {
                            model.invalidFields.insert(MediaEditorModel.overlayTextField)
                        }
                    })
            )
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { focused = false }
            if model.invalidFields.contains(MediaEditorModel.overlayTextField) {
                ProblemLabel(
                    text: String(localized: "Enter 1 to \(EditOverlay.maximumTextLength) characters on one line."))
            }
        }
        .onAppear {
            draft = text
            if model.overlayTextFocusRequest == id { focused = true }
        }
        .onChange(of: model.overlayTextFocusRequest) { _, request in if request == id { focused = true } }
        .onChange(of: text) { _, text in if !focused { draft = text } }
        .onChange(of: focused) { _, focused in
            if focused {
                model.beginInteraction()
            } else {
                model.overlayTextFocusRequest = nil
                draft = text
                model.invalidFields.remove(MediaEditorModel.overlayTextField)
                model.endInteraction()
            }
        }
        .onDisappear {
            model.invalidFields.remove(MediaEditorModel.overlayTextField)
            if focused { model.endInteraction() }
        }
    }
}

extension EditMark {
    var color: MarkColor? {
        switch self {
        case .redaction: nil
        case .box(_, let color, _), .arrow(_, _, let color, _), .text(_, _, let color, _): color
        }
    }

    var size: MarkSize? {
        switch self {
        case .redaction: nil
        case .box(_, _, let size), .arrow(_, _, _, let size), .text(_, _, _, let size): size
        }
    }

    func with(color: MarkColor) -> EditMark? {
        switch self {
        case .redaction: nil
        case .box(let rect, _, let size): .box(rect: rect, color: color, size: size)
        case .arrow(let from, let to, _, let size): .arrow(from: from, to: to, color: color, size: size)
        case .text(let text, let at, _, let size): .text(text, at: at, color: color, size: size)
        }
    }

    func with(size: MarkSize) -> EditMark? {
        switch self {
        case .redaction: nil
        case .box(let rect, let color, _): .box(rect: rect, color: color, size: size)
        case .arrow(let from, let to, let color, _): .arrow(from: from, to: to, color: color, size: size)
        case .text(let text, let at, let color, _): .text(text, at: at, color: color, size: size)
        }
    }
}

extension MarkColor {
    var title: String {
        switch self {
        case .red: String(localized: "Red")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .blue: String(localized: "Blue")
        case .white: String(localized: "White")
        case .black: String(localized: "Black")
        }
    }
}

extension MarkSize {
    var title: String {
        switch self {
        case .small: String(localized: "Small")
        case .medium: String(localized: "Medium")
        case .large: String(localized: "Large")
        }
    }
}
