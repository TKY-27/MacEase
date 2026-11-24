import SwiftUI
import os

struct PreviewFontViewer: View {
    let url: URL
    let sample: String
    @State private var face: PreviewFontFace?
    @State private var unreadable = false
    @State private var refusalMessage: String?
    private static let specimenSpacing: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            PreviewToolbar { faceControls }
            if let refusalMessage {
                PreviewFailure(message: Text(refusalMessage))
            } else if unreadable {
                QuickLookPreview(url: url)
            } else if let face {
                specimen(face)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    @ViewBuilder private var faceControls: some View {
        if let face, face.faceCount > 1 {
            Picker("Face", selection: Binding(get: { face.index }, set: select)) {
                ForEach(face.faceNames.indices, id: \.self) { index in
                    Text(verbatim: face.faceNames[index]).tag(index)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .help(Text("Face"))
            ControlGroup {
                Button {
                    step(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(face.index == 0)
                .help(Text("Previous Face"))
                .accessibilityLabel(Text("Previous Face"))
                Button {
                    step(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(face.index == face.faceCount - 1)
                .help(Text("Next Face"))
                .accessibilityLabel(Text("Next Face"))
            }
            .fixedSize()
        }
    }

    private func select(_ index: Int) {
        guard let chosen = face?.selecting(index) else { return }
        face = chosen
    }

    // Reads current state; quick clicks outrun rendering.
    private func step(by offset: Int) {
        guard let face else { return }
        select(face.index + offset)
    }

    private func specimen(_ face: PreviewFontFace) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.specimenSpacing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: face.displayName).font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Group {
                        if let style = face.styleName {
                            Text("\(style) · \(face.glyphCount) glyphs")
                        } else {
                            Text("\(face.glyphCount) glyphs")
                        }
                        if face.faceCount > 1 {
                            Text("Face \(face.index + 1) of \(face.faceCount)")
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(PreviewFontFace.specimenSizes, id: \.self) { size in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Int(size)) pt").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Text(verbatim: sample).font(Font(face.font(size: size)))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PreviewLayout.margin)
            .textSelection(.enabled)
        }
    }

    private func load() async {
        do {
            let loaded = try await offMain { [url] in try PreviewFontFace.load(url) }
            guard !Task.isCancelled else { return }
            face = loaded
        } catch is CancellationError {
        } catch PreviewFontError.tooLarge {
            guard !Task.isCancelled else { return }
            refusalMessage = String(localized: "This font file is too large to preview.")
        } catch PreviewFontError.tooManyFaces {
            guard !Task.isCancelled else { return }
            refusalMessage = String(localized: "This font collection has too many faces to preview.")
        } catch {
            guard !Task.isCancelled else { return }
            Logger(category: "finder-preview").notice("Core Text could not load the font; using Quick Look")
            unreadable = true
        }
    }
}
