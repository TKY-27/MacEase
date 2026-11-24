import SwiftUI
import os

struct PreviewFontViewer: View {
    let url: URL
    let sample: String
    @State private var face: PreviewFontFace?
    @State private var unreadable = false
    private static let specimenSpacing: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            PreviewToolbar {}
            if unreadable {
                QuickLookPreview(url: url)
            } else if let face {
                specimen(face)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    private func specimen(_ face: PreviewFontFace) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.specimenSpacing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: face.displayName).font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    if face.faceCount > 1 {
                        Text("First of \(face.faceCount) faces").font(.callout).foregroundStyle(.secondary)
                    }
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
        let result = await Task.detached(priority: .userInitiated) { [url] in
            Result { () throws(PreviewFontError) in try PreviewFontFace.load(url) }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let loaded): face = loaded
        case .failure(.unreadable):
            Logger(category: "finder-preview").notice("Core Text could not load the font; using Quick Look")
            unreadable = true
        }
    }
}
