import CoreText
import Foundation

enum PreviewFontError: Error, Equatable, Sendable {
    case unreadable
}

// CTFontDescriptor is immutable.
struct PreviewFontFace: @unchecked Sendable {
    static let specimenSizes: [CGFloat] = [12, 16, 20, 28, 40, 64]

    let displayName: String
    let faceCount: Int
    private let descriptor: CTFontDescriptor

    static func load(_ url: URL) throws(PreviewFontError) -> Self {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
            let first = descriptors.first
        else {
            throw .unreadable
        }
        let sample = CTFontCreateWithFontDescriptor(first, specimenSizes[0], nil)
        let name = resolvedName(for: sample, fallbackURL: url)
        return Self(displayName: name, faceCount: descriptors.count, descriptor: first)
    }

    func font(size: CGFloat) -> CTFont {
        CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    private static func resolvedName(for font: CTFont, fallbackURL: URL) -> String {
        let display = CTFontCopyDisplayName(font) as String
        if !display.isEmpty { return display }
        let full = CTFontCopyFullName(font) as String
        if !full.isEmpty { return full }
        let postScript = CTFontCopyPostScriptName(font) as String
        if !postScript.isEmpty { return postScript }
        return fallbackURL.deletingPathExtension().lastPathComponent
    }
}
