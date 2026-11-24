import AppKit
import Engine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum PreviewKind: Equatable, Hashable, Sendable {
    case text, html, markdown, json, propertyList, svg, font, image, media, audio, pdf, quickLook

    private static let htmlExtensions: Set<String> = ["html", "htm", "xhtml"]
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdx"]
    private static let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "otc", "woff", "woff2"]
    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "webm", "mkv", "mov", "avi", "wmv", "flv", "ogv", "mpg", "mpeg", "m2ts", "3gp",
    ]
    private static let audioExtensions: Set<String> = [
        "mp3", "wav", "flac", "ogg", "oga", "opus", "m4a", "aac", "wma", "aif", "aiff", "aifc", "caf",
    ]
    private static let typeScriptExtensions: Set<String> = ["ts", "mts", "cts"]
    private static let textExtensions: Set<String> = [
        "txt", "text", "log", "csv", "tsv", "nfo", "srt", "vtt", "ass", "lrc", "diff", "patch", "tex", "rst",
        "ini", "cfg", "conf", "properties", "toml", "reg", "inf", "env", "editorconfig", "gitignore",
        "gitattributes", "gitmodules",
        "jsonc", "json5", "yaml", "yml",
        "xml", "xaml", "csproj", "vcxproj", "fsproj", "vbproj", "props", "targets", "manifest", "sln",
        "css", "scss", "sass", "less",
        "js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx", "vue", "svelte", "astro",
        "py", "pyw", "pyi", "rb", "php", "java", "kt", "kts", "gradle", "groovy", "scala", "go", "rs",
        "c", "h", "cc", "cpp", "cxx", "hh", "hpp", "hxx", "inl",
        "cs", "csx", "fs", "fsx", "vb", "vbs", "swift", "m", "mm",
        "lua", "pl", "pm", "r", "jl", "dart", "ex", "exs", "clj", "sql",
        "sh", "bash", "zsh", "fish", "ps1", "psm1", "psd1", "bat", "cmd",
        "dockerfile", "cmake", "mk", "proto", "graphql", "gql", "hcl", "tf", "sol",
    ]
    private static let textDotfiles: Set<String> = [
        ".env", ".editorconfig", ".gitignore", ".gitattributes", ".gitmodules", ".dockerfile",
    ]

    var fileType: FinderPreviewFileType? {
        switch self {
        case .text, .json, .propertyList: .text
        case .html: .html
        case .markdown: .markdown
        case .svg: .svg
        case .pdf: .pdf
        case .font: .font
        case .image: .image
        case .media: .video
        case .audio: .audio
        case .quickLook: nil
        }
    }

    static func resolve(
        type: UTType?, extension suffix: String, fileName: String? = nil,
        disabled: Set<FinderPreviewFileType> = []
    ) -> Self {
        let resolved = resolveUnfiltered(type: type, extension: suffix, fileName: fileName)
        if let fileType = resolved.fileType, disabled.contains(fileType) {
            return .quickLook
        }
        return resolved
    }

    private static func resolveUnfiltered(type: UTType?, extension suffix: String, fileName: String?) -> Self {
        let suffix = suffix.lowercased()
        if type?.conforms(to: .pdf) == true || suffix == "pdf" { return .pdf }
        if type?.conforms(to: .html) == true || htmlExtensions.contains(suffix) { return .html }
        if type?.conforms(to: .propertyList) == true || suffix == "plist" { return .propertyList }
        if type?.conforms(to: .json) == true || suffix == "json" { return .json }
        if let markdown = UTType("net.daringfireball.markdown"), type?.conforms(to: markdown) == true {
            return .markdown
        }
        if markdownExtensions.contains(suffix) { return .markdown }
        if type?.conforms(to: .svg) == true || suffix == "svg" { return .svg }
        if type?.conforms(to: .font) == true || fontExtensions.contains(suffix) { return .font }
        if type?.conforms(to: .image) == true { return .image }
        // macOS maps .ts/.mts to MPEG-2 transport streams.
        if typeScriptExtensions.contains(suffix) { return .text }
        if type?.conforms(to: .audio) == true || audioExtensions.contains(suffix) { return .audio }
        if type?.conforms(to: .audiovisualContent) == true || videoExtensions.contains(suffix) { return .media }
        if type?.conforms(to: .sourceCode) == true || type?.conforms(to: .plainText) == true
            || type?.conforms(to: .xml) == true || textExtensions.contains(suffix)
            || fileName.map({ textDotfiles.contains($0.lowercased()) }) == true
        {
            return .text
        }
        return .quickLook
    }

    // Folders and packages use the system preview.
    static func inspect(_ url: URL, disabled: Set<FinderPreviewFileType> = []) throws -> Self {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .contentTypeKey])
        if values.isDirectory == true { return .quickLook }
        guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        return resolve(
            type: values.contentType, extension: url.pathExtension, fileName: url.lastPathComponent, disabled: disabled)
    }
}

enum PreviewLayout {
    static let margin: CGFloat = 16
    // Matches the height of Finder's toolbar.
    static let barHeight: CGFloat = 52
    static let noteHeight: CGFloat = 24
}

struct PreviewContent: View {
    let url: URL
    let kind: PreviewKind
    let trust: PreviewTrust
    let detected: DetectedContent?
    let settings: FinderPreviewSettings
    @Binding var scriptConsent: Set<String>

    var body: some View {
        switch detected.map({ PreviewContentMatch.evaluate(kind: kind, detected: $0) }) ?? .matches {
        case .empty:
            refused(Text("This file is empty."))
        case .binaryWithTextExtension(let name):
            refused(Text("This file doesn't look like text, so it isn't shown."))
                .environment(\.previewMismatch, Self.localized(name))
        case .mismatch(let name):
            viewer.environment(\.previewMismatch, Self.localized(name))
        case .matches:
            viewer
        }
    }

    // Engine format names are English.
    private static func localized(_ name: String) -> String {
        Bundle.main.localizedString(forKey: name, value: name, table: nil)
    }

    private func refused(_ message: Text) -> some View {
        VStack(spacing: 0) {
            PreviewToolbar {}
            PreviewFailure(message: message)
        }
    }

    @ViewBuilder private var viewer: some View {
        switch kind {
        case .text, .html, .markdown, .json, .propertyList:
            PreviewTextViewer(url: url, kind: kind, trust: trust, settings: settings, scriptConsent: $scriptConsent)
        case .image: PreviewImageViewer(url: url)
        case .media, .audio: PreviewMediaViewer(url: url, audioOnly: kind == .audio)
        case .pdf: PreviewPDFViewer(url: url)
        case .svg, .font, .quickLook:
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

// Single line; full text in the tooltip.
struct PreviewNote: View {
    let symbol: String
    let text: Text
    var shortText: Text?
    var tint: Color = .secondary

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
                ViewThatFits(in: .horizontal) {
                    text.fixedSize()
                    (shortText ?? text).lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, PreviewLayout.margin)
            .frame(maxWidth: .infinity, minHeight: PreviewLayout.noteHeight, alignment: .leading)
            .help(text)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            Divider()
        }
    }
}

extension EnvironmentValues {
    @Entry var previewBarTrailingInset: CGFloat = 0
    @Entry var previewMismatch: String?
}

// Leaves room for the panel's trailing controls.
struct PreviewToolbar<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.previewBarTrailingInset) private var trailingInset
    @Environment(\.previewMismatch) private var mismatch

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
            if let mismatch {
                PreviewNote(
                    symbol: "exclamationmark.triangle.fill",
                    text: Text("The content looks like \(mismatch), which doesn't match the file name."),
                    shortText: Text("Content looks like \(mismatch)"), tint: .yellow)
            }
        }
    }
}
