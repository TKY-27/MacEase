import AppKit
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
        if type?.conforms(to: .svg) == true || suffix == "svg" { return .quickLook }
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

    // Folders and packages use the system preview.
    static func inspect(_ url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .contentTypeKey])
        if values.isDirectory == true { return .quickLook }
        guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        return resolve(type: values.contentType, extension: url.pathExtension)
    }
}

enum PreviewLayout {
    static let margin: CGFloat = 16
    // Matches the height of Finder's toolbar.
    static let barHeight: CGFloat = 52
}

struct PreviewContent: View {
    let url: URL
    let kind: PreviewKind

    var body: some View {
        switch kind {
        case .text, .html, .markdown, .json, .propertyList:
            PreviewTextViewer(url: url, kind: kind)
        case .image: PreviewImageViewer(url: url)
        case .media, .audio: PreviewMediaViewer(url: url, audioOnly: kind == .audio)
        case .pdf: PreviewPDFViewer(url: url)
        case .quickLook:
            VStack(spacing: 0) {
                PreviewToolbar {}
                QuickLookPreview(url: url)
            }
        }
    }
}

struct PreviewFailure: View {
    var message = Text("This preview could not be displayed.")

    var body: some View {
        message.font(.callout).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).padding(PreviewLayout.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EnvironmentValues {
    @Entry var previewBarTrailingInset: CGFloat = 0
}

// Leaves room for the panel's trailing controls.
struct PreviewToolbar<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.previewBarTrailingInset) private var trailingInset

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                content
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(.leading, PreviewLayout.margin)
            .padding(.trailing, PreviewLayout.margin + trailingInset)
            .frame(maxWidth: .infinity, minHeight: PreviewLayout.barHeight)
            Divider()
        }
    }
}
