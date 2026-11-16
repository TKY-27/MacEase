import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum PreviewKind: Sendable {
    case text, html, markdown, json, propertyList, image, media, audio, pdf, quickLook

    static func resolve(type: UTType?, extension suffix: String) -> Self {
        let suffix = suffix.lowercased()
        if type?.conforms(to: .pdf) == true { return .pdf }
        if type?.conforms(to: .html) == true { return .html }
        if type?.conforms(to: .propertyList) == true || suffix == "plist" { return .propertyList }
        if type?.conforms(to: .json) == true || suffix == "json" { return .json }
        if let markdown = UTType("net.daringfireball.markdown"), type?.conforms(to: markdown) == true {
            return .markdown
        }
        if ["md", "markdown"].contains(suffix) { return .markdown }
        if type?.conforms(to: .image) == true { return .image }
        if type?.conforms(to: .audio) == true { return .audio }
        if type?.conforms(to: .audiovisualContent) == true { return .media }
        if type?.conforms(to: .sourceCode) == true || type?.conforms(to: .plainText) == true
            || type?.conforms(to: .xml) == true
            || ["yaml", "yml", "toml", "csv", "log"].contains(suffix)
        {
            return .text
        }
        return .quickLook
    }

    var fillsPane: Bool {
        switch self {
        case .image, .media, .audio: false
        case .text, .html, .markdown, .json, .propertyList, .pdf, .quickLook: true
        }
    }
}

struct PreviewContent: View {
    let url: URL
    let kind: PreviewKind
    let previewHeight: CGFloat?
    let textEditor: PreviewTextEditor
    let jobs: JobCenter

    var body: some View {
        switch kind {
        case .text, .html, .markdown, .json, .propertyList:
            PreviewTextViewer(url: url, kind: kind, editor: textEditor, jobs: jobs)
        case .image: PreviewImageViewer(url: url, height: previewHeight)
        case .media, .audio: PreviewMediaViewer(url: url, audioOnly: kind == .audio, height: previewHeight)
        case .pdf: PreviewPDFViewer(url: url)
        case .quickLook: QuickLookPreview(url: url)
        }
    }
}

struct PreviewFailure: View {
    var body: some View {
        Text("This preview could not be displayed.").font(.callout).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).padding(PreviewLayout.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PreviewToolbar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) { content }
                .controlSize(.small)
                .padding(.horizontal, PreviewLayout.margin)
                .frame(maxWidth: .infinity, minHeight: PreviewLayout.toolbarHeight)
            Divider()
        }
    }
}
