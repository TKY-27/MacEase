import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import PDFKit
import Vision

@Generable
struct SuggestedName {
    @Guide(description: "A short descriptive file name without an extension")
    var name: String
}

/// Nothing renames until the panel confirms.
public enum AINaming {
    static let maximumLength = 60
    private static let previewEdge = 1024
    private static let minimumLabelConfidence: Float = 0.3
    /// About 2,000 tokens of context.
    private static let contextCharacterLimit = 6_000

    public static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// Image and PDF children, in Finder order.
    public static func candidates(in folder: URL) throws -> [URL] {
        let children = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return
            try children
            .filter { try ContentSniffer.matches($0, kind: .image) || ContentSniffer.matches($0, kind: .pdf) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// A base name without extension, in `language`.
    public static func suggestedName(for url: URL, languageCode: String) async throws -> String {
        guard isAvailable else { throw EngineError.missingCapability(.appleIntelligence) }
        let picture = try preview(of: url)
        let created = try url.resourceValues(forKeys: [.creationDateKey]).creationDate
        let facts =
            "Current name: \(url.deletingPathExtension().lastPathComponent)"
            + (created.map { "\nCreated: \($0.formatted(date: .long, time: .omitted))" } ?? "")
        let instructions = Instructions(
            """
            You name files. Reply with a short descriptive name in \(languageName(languageCode)), \
            at most \(maximumLength) characters, using letters, digits, spaces and hyphens only.
            """)
        let session = LanguageModelSession(instructions: instructions)
        var raw: String?
        #if compiler(>=6.4)
            if #available(macOS 27, *), SystemLanguageModel.default.capabilities.contains(.vision) {
                raw = try await AINamingVision.name(of: picture, facts: facts, session: session)
            }
        #endif
        if raw == nil {
            let context = try await textContext(of: picture, url: url)
            raw = try await session.respond(to: facts + "\n" + context, generating: SuggestedName.self).content.name
        }
        guard let name = raw.flatMap(sanitized) else { throw EngineError.unexpected("no usable name suggested") }
        return name
    }

    private static func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// Letters, digits, spaces, hyphens; at most 60.
    static func sanitized(_ raw: String) -> String? {
        let allowed = raw.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" ? Character(scalar) : " "
        }
        let words = String(allowed).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = String(words.prefix(maximumLength)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func preview(of url: URL) throws -> CGImage {
        if try ContentSniffer.matches(url, kind: .pdf) {
            guard let page = PDFDocument(url: url)?.page(at: 0) else { throw EngineError.invalidInput(.noPages) }
            let bounds = page.bounds(for: .cropBox)
            let edge = max(bounds.width, bounds.height)
            guard edge.isFinite, edge > 0,
                let dpi = Int(exactly: (Double(previewEdge) / edge * PDFExport.pointsPerInch).rounded(.towardZero)),
                dpi > 0
            else { throw EngineError.invalidInput(.invalidNumericParameter) }
            return try PDFExport.render(page, dpi: dpi)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: previewEdge,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw EngineError.decodeFailed("image does not decode") }
        return image
    }

    /// macOS 26 models read only text.
    private static func textContext(of picture: CGImage, url: URL) async throws -> String {
        let text = try await TextRecognition.text(in: picture, languages: [])
        let labels = try await ClassifyImageRequest().perform(on: picture)
            .filter { $0.confidence >= minimumLabelConfidence }.map(\.identifier)
        var lines = ["Labels: \(labels.joined(separator: ", "))"]
        if let exif = CGImageSourceCreateWithURL(url as CFURL, nil)
            .flatMap({ CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] })
        {
            let date = (exif[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal]
            let camera = (exif[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel]
            if let date { lines.append("Taken: \(date)") }
            if let camera { lines.append("Camera: \(camera)") }
        }
        lines.append("Text in the image:\n\(text)")
        return String(lines.joined(separator: "\n").prefix(contextCharacterLimit))
    }
}
