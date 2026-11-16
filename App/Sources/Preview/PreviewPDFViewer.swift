import PDFKit
import SwiftUI
import os

struct PreviewPDFViewer: View {
    let url: URL
    @State private var document: PDFDocument?
    @State private var thumbnails = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            PreviewToolbar {
                Toggle(isOn: $thumbnails) { Label("Page Thumbnails", systemImage: "sidebar.left") }
                    .toggleStyle(.button).labelStyle(.iconOnly).help(Text("Page Thumbnails"))
                    .disabled(document == nil)
                Spacer(minLength: 0)
            }
            if failed {
                PreviewFailure()
            } else if let document {
                PreviewPDFDocument(document: document, thumbnails: thumbnails)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            do {
                let loaded = try await Self.read(url)
                try Task.checkCancellation()
                document = loaded
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
                Logger(category: "finder-preview").error(
                    "Preview PDF failed: \(error.localizedDescription, privacy: .private)")
            }
        }
        .onDisappear { document = nil }
    }

    nonisolated private static func read(_ url: URL) async throws -> sending PDFDocument {
        try Task.checkCancellation()
        guard let document = PDFDocument(url: url), !document.isLocked else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        return document
    }
}

private struct PreviewPDFDocument: NSViewRepresentable {
    let document: PDFDocument
    let thumbnails: Bool

    func makeNSView(context: Context) -> NSStackView {
        let pages = PDFThumbnailView()
        pages.thumbnailSize = NSSize(width: 56, height: 72)
        pages.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let viewer = PDFView()
        viewer.autoScales = true
        viewer.displayMode = .singlePageContinuous
        viewer.backgroundColor = .underPageBackgroundColor
        viewer.document = document
        pages.pdfView = viewer
        let stack = NSStackView(views: [pages, viewer])
        stack.orientation = .horizontal
        stack.alignment = .height
        stack.spacing = 0
        stack.detachesHiddenViews = true
        return stack
    }

    func updateNSView(_ stack: NSStackView, context: Context) {
        stack.arrangedSubviews.first?.isHidden = !thumbnails
    }

    static func dismantleNSView(_ stack: NSStackView, coordinator: ()) {
        for view in stack.arrangedSubviews {
            if let thumbnails = view as? PDFThumbnailView { thumbnails.pdfView = nil }
            if let viewer = view as? PDFView { viewer.document = nil }
        }
    }
}
