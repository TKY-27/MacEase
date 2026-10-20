import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum PDFExport {
    static let pointsPerInch = 72.0
    private static let ocrDPI = 300
    private static let pageSeparator = "\u{0C}"
    private static let textExtension = "txt"
    private static let percent = 100.0
    /// Keeps one page bitmap near 400 MB.
    private static let maximumPixels = 100_000_000

    static func images(of url: URL, format: StillFormat, dpi: Int, context: ItemContext) throws -> ItemResult {
        let document = try PDFEditing.open(url)
        let folder = try PDFEditing.stagingFolder(for: url, context: context)
        let (type, pathExtension) = format == .png ? (UTType.png, "png") : (UTType.jpeg, "jpg")
        var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] =
                Double(context.settings.image.jpegQuality) / percent
        }
        let base = PDFEditing.baseName(of: url)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let image = try render(try PDFEditing.page(index, in: document), dpi: dpi)
            let name = PDFEditing.pageFileName(
                base: base, index: index, count: document.pageCount, extension: pathExtension)
            let target = folder.appending(path: name)
            guard
                let destination = CGImageDestinationCreateWithURL(target as CFURL, type.identifier as CFString, 1, nil)
            else { throw EngineError.encodeFailed("image destination unavailable") }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw EngineError.encodeFailed("page image write failed")
            }
            context.progress(Double(index + 1) / Double(document.pageCount))
        }
        return .derived(nextTo: url, outputs: [StagedFile(url: folder, name: base, check: .folder)])
    }

    static func text(of url: URL, context: ItemContext) async throws -> ItemResult {
        let document = try PDFEditing.open(url)
        var pages: [String] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let page = try PDFEditing.page(index, in: document)
            let embedded = page.string ?? ""
            if embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages.append(try await recognizedText(on: page, languages: context.settings.intelligence.ocrLanguages))
            } else {
                pages.append(embedded)
            }
            context.progress(Double(index + 1) / Double(document.pageCount))
        }
        guard pages.contains(where: { !$0.isEmpty }) else { throw EngineError.invalidInput(.emptyInput) }
        let name = "\(PDFEditing.baseName(of: url)).\(textExtension)"
        let staged = try context.stagingURL(for: url, name: name)
        try Data(pages.joined(separator: pageSeparator).utf8).write(to: staged)
        return .derived(nextTo: url, outputs: [StagedFile(url: staged, name: name, check: .text(.utf8))])
    }

    /// On white, as PDF pages assume paper.
    static func render(_ page: PDFPage, dpi: Int) throws -> CGImage {
        let bounds = page.bounds(for: .cropBox)
        let isQuarterTurned = page.rotation % 180 != 0
        let scale = Double(dpi) / pointsPerInch
        let scaledWidth = ((isQuarterTurned ? bounds.height : bounds.width) * scale).rounded()
        let scaledHeight = ((isQuarterTurned ? bounds.width : bounds.height) * scale).rounded()
        guard scaledWidth * scaledHeight <= Double(maximumPixels) else {
            throw EngineError.invalidInput(.malformed("page is too large to render at \(dpi) dpi"))
        }
        let width = Int(scaledWidth)
        let height = Int(scaledHeight)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
            let canvas = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw EngineError.encodeFailed("page canvas unavailable") }
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: canvas)
        guard let image = canvas.makeImage() else { throw EngineError.encodeFailed("page render failed") }
        return image
    }

    private static func recognizedText(on page: PDFPage, languages: [String]) async throws -> String {
        try await TextRecognition.text(in: try render(page, dpi: ocrDPI), languages: languages)
    }
}
