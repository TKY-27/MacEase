import AppKit
import Engine
import SwiftUI

struct ActivityComparisonPanel: View {
    let session: ActivitySession
    @State private var selected: Int?
    @State private var scale = 0.0
    @State private var center = CGPoint(x: 0.5, y: 0.5)

    private var selection: Int? { selected ?? session.comparisonIndices.first }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if session.comparisonIndices.count > 1 {
                    Picker(
                        String(localized: "File"),
                        selection: Binding(
                            get: { selection ?? 0 },
                            set: {
                                selected = $0; reset()
                            }
                        )
                    ) {
                        ForEach(session.comparisonIndices, id: \.self) { index in
                            Text(verbatim: session.outcome.inputs[index].first?.lastPathComponent ?? "").tag(index)
                        }
                    }
                    .frame(maxWidth: 360)
                } else if let selection {
                    Text(verbatim: session.outcome.inputs[selection].first?.lastPathComponent ?? "")
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button(String(localized: "Fit")) { reset() }
                    .accessibilityLabel(String(localized: "Fit Both Images"))
                Button("100%") {
                    scale = 1; center = CGPoint(x: 0.5, y: 0.5)
                }
                .accessibilityLabel(String(localized: "View Both Images at Actual Pixels"))
                Button {
                    scale = max(0.125, scale == 0 ? 0.5 : scale / 2)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help(String(localized: "Zoom Out"))
                .accessibilityLabel(String(localized: "Zoom Out"))
                Button {
                    scale = min(8, scale == 0 ? 1 : scale * 2)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help(String(localized: "Zoom In"))
                .accessibilityLabel(String(localized: "Zoom In"))
            }
            .padding()
            Divider()
            if let selection {
                ComparisonPair(session: session, index: selection, scale: scale, center: $center)
                    .id(selection)
            }
            Divider()
            HStack {
                Text("Pan Both Images").foregroundStyle(.secondary)
                Spacer()
                Button {
                    pan(x: -0.05, y: 0)
                } label: {
                    Label("Pan Left", systemImage: "arrow.left")
                }
                .keyboardShortcut(.leftArrow, modifiers: .option)
                Button {
                    pan(x: 0.05, y: 0)
                } label: {
                    Label("Pan Right", systemImage: "arrow.right")
                }
                .keyboardShortcut(.rightArrow, modifiers: .option)
                Button {
                    pan(x: 0, y: -0.05)
                } label: {
                    Label("Pan Up", systemImage: "arrow.up")
                }
                .keyboardShortcut(.upArrow, modifiers: .option)
                Button {
                    pan(x: 0, y: 0.05)
                } label: {
                    Label("Pan Down", systemImage: "arrow.down")
                }
                .keyboardShortcut(.downArrow, modifiers: .option)
            }
            .labelStyle(.iconOnly)
            .disabled(scale == 0)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 850, minHeight: 560)
    }

    private func pan(x: Double, y: Double) {
        center = CGPoint(x: max(0, min(1, center.x + x)), y: max(0, min(1, center.y + y)))
    }

    private func reset() {
        scale = 0
        center = CGPoint(x: 0.5, y: 0.5)
    }
}

private struct ComparisonPair: View {
    let session: ActivitySession
    let index: Int
    let scale: Double
    @Binding var center: CGPoint
    @State private var comparison: ActivityComparison?
    @State private var problem: String?

    var body: some View {
        Group {
            if let comparison {
                HStack(spacing: 0) {
                    ComparisonImage(
                        title: String(localized: "Original"), comparison: comparison,
                        original: true, scale: scale, center: $center)
                    Divider()
                    ComparisonImage(
                        title: String(localized: "Output"), comparison: comparison,
                        original: false, scale: scale, center: $center)
                }
            } else if let problem {
                ContentUnavailableView(
                    String(localized: "Comparison Unavailable"),
                    systemImage: "photo", description: Text(problem))
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                let capturedSession = session
                let capturedIndex = index
                let resolved = try await Task.detached { try capturedSession.comparison(at: capturedIndex) }.value
                comparison = resolved
            } catch { problem = UserMessages.describeActivity(error) }
        }
    }
}

private struct ComparisonImage: View {
    let title: String
    let comparison: ActivityComparison
    let original: Bool
    let scale: Double
    @Binding var center: CGPoint
    @State private var preview: ActivityImagePreview?
    @State private var problem: String?
    @State private var dragOrigin: CGPoint?
    @Environment(\.displayScale) private var displayScale

    private var url: URL { original ? comparison.original : comparison.output }
    private var bytes: Int64 { original ? comparison.details.originalBytes : comparison.details.outputBytes }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text(verbatim: url.pathExtension.uppercased()).foregroundStyle(.secondary)
                }
                Text(verbatim: bytes.fileSize).monospacedDigit()
                if let preview {
                    Text(verbatim: "\(preview.width) × \(preview.height)").foregroundStyle(.secondary)
                }
                if !original, comparison.details.originalBytes > 0 {
                    Text(UserMessages.sizeChange(original: comparison.details.originalBytes, output: bytes))
                        .foregroundStyle(.secondary)
                }
                if !original, let image = comparison.details.image {
                    if image.reducedDimensions { Text("Dimensions reduced").foregroundStyle(.secondary) }
                    if image.quantized {
                        if let colors = image.paletteColors {
                            Text("Palette: up to \(colors) colors").foregroundStyle(.secondary)
                        } else {
                            Text("Colors reduced").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 160, alignment: .topLeading)
            GeometryReader { geometry in
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    if let problem {
                        Text(problem).multilineTextAlignment(.center).padding()
                    } else if let preview {
                        if let size = preview.displaySize {
                            Image(decorative: preview.image, scale: 1)
                                .resizable().interpolation(.none).frame(
                                    width: size.width / displayScale, height: size.height / displayScale)
                        } else {
                            Image(decorative: preview.image, scale: 1).resizable().scaledToFit()
                        }
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture().onChanged { value in
                        guard scale > 0, let preview else { return }
                        if dragOrigin == nil { dragOrigin = center }
                        guard let origin = dragOrigin else { return }
                        center = CGPoint(
                            x: max(
                                0,
                                min(
                                    1,
                                    origin.x - value.translation.width / (Double(preview.width) * scale / displayScale))
                            ),
                            y: max(
                                0,
                                min(
                                    1,
                                    origin.y - value.translation.height
                                        / (Double(preview.height) * scale / displayScale))))
                    }.onEnded { _ in dragOrigin = nil }
                )
                .task(id: PreviewRequest(scale: scale, center: center, viewport: geometry.size)) {
                    await render(viewport: geometry.size)
                }
                .accessibilityLabel(Text("\(title) image preview"))
            }
        }
        .font(.callout)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func render(viewport: CGSize) async {
        do {
            try await Task.sleep(for: .milliseconds(80))
            let capturedURL = url
            let capturedCenter = center
            let capturedComparison = comparison
            let capturedScale = scale
            let pixelViewport = CGSize(width: viewport.width * displayScale, height: viewport.height * displayScale)
            let rendering = Task.detached {
                try capturedComparison.validate()
                let preview = try await ActivityImagePreview.open(
                    capturedURL, viewport: capturedScale > 0 ? pixelViewport : nil,
                    scale: max(capturedScale, 0.125), center: capturedCenter)
                try capturedComparison.validate()
                return preview
            }
            let rendered = try await withTaskCancellationHandler {
                try await rendering.value
            } onCancel: {
                rendering.cancel()
            }
            try Task.checkCancellation()
            preview = rendered
            problem = nil
        } catch is CancellationError {
        } catch {
            preview = nil
            problem = UserMessages.describeActivity(error)
        }
    }
}

private struct PreviewRequest: Equatable {
    let scale: Double
    let center: CGPoint
    let viewport: CGSize
}
