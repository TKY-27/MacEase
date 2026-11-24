import PDFKit
import SwiftUI
import os

struct PreviewPDFViewer: View {
    let url: URL
    @State private var document: PDFDocument?
    @State private var failure: Failure?

    private enum Failure: Error {
        case locked, unreadable
    }

    var body: some View {
        VStack(spacing: 0) {
            PreviewToolbar {}
            switch failure {
            case .locked: PreviewFailure(message: Text("This PDF is locked with a password."))
            case .unreadable: PreviewFailure()
            case nil:
                if let document {
                    PreviewPDFDocument(document: document)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task {
            do throws(Failure) {
                let loaded = try await Self.read(url)
                guard !Task.isCancelled else { return }
                document = loaded
            } catch {
                guard !Task.isCancelled else { return }
                failure = error
                Logger(category: "finder-preview").error("Preview PDF failed: \(String(describing: error))")
            }
        }
        .onDisappear { document = nil }
    }

    nonisolated private static func read(_ url: URL) async throws(Failure) -> sending PDFDocument {
        guard let document = PDFDocument(url: url) else { throw .unreadable }
        guard !document.isLocked else { throw .locked }
        return document
    }
}

private struct PreviewPDFDocument: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let viewer = PDFView()
        viewer.autoScales = true
        viewer.displayMode = .singlePageContinuous
        viewer.backgroundColor = .underPageBackgroundColor
        viewer.document = document
        return viewer
    }

    func updateNSView(_ viewer: PDFView, context: Context) {}

    static func dismantleNSView(_ viewer: PDFView, coordinator: ()) { viewer.document = nil }
}
