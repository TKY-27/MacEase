import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Text, PDF, icon and data URI outputs.
enum ImageExports {
    static let base64Limit: Int64 = 10_000_000
    static let smallestIconEdge = 16
    static let appIconEdge = 1024
    static let appIconFile = "AppIcon.png"

    static func recognizeText(_ url: URL, output: TextOutput, context: ItemContext) async throws -> ItemResult {
        let document = try await ImageDocument.load(url)
        let text = try await TextRecognition.text(
            in: document.first, languages: context.settings.intelligence.ocrLanguages)
        guard !text.isEmpty else { return .skipped(.noTextFound) }
        switch output {
        case .clipboard: return .text(text, .clipboard)
        case .panel: return .text(text, .report)
        case .file:
            let name = (url.lastPathComponent as NSString).deletingPathExtension + ".txt"
            let staged = try context.stagingURL(for: url, name: name)
            try Data(text.utf8).write(to: staged)
            return .derived(nextTo: url, outputs: [StagedFile(url: staged, name: name, check: .text(.utf8))])
        }
    }

    /// One page per input, in order.
    static func pdf(from inputs: [URL], context: ItemContext) async throws -> ItemResult {
        guard let first = inputs.first else { return .skipped(.nothingToRemove) }
        var pages: [(image: CGImage, pixelsPerInch: Double)] = []
        var budget = FrameMemoryBudget.retainedImages
        for (index, url) in inputs.enumerated() {
            try Task.checkCancellation()
            guard try ContentSniffer.matches(url, kind: .image) else {
                throw EngineError.decodeFailed(url.lastPathComponent)
            }
            let document = try await ImageDocument.load(url, budget: &budget)
            let images = document.isMultiPage ? document.frames.map(\.image) : [document.first]
            pages += images.map { ($0, document.pixelsPerInch) }
            context.progress(Double(index + 1) / Double(inputs.count + 1))
        }
        let name = (first.lastPathComponent as NSString).deletingPathExtension + ".pdf"
        let staged = try context.stagingURL(for: first, name: name)
        try ImageEncoder.pdf(pages).write(to: staged)
        return .derived(nextTo: first, outputs: [StagedFile(url: staged, name: name, check: .pdf)])
    }

    static func iconSet(_ url: URL, kind: IconSetKind, context: ItemContext) async throws -> ItemResult {
        let document = try await ImageDocument.load(url)
        let square = try ImageEncoder.square(document.first)
        guard square.width >= smallestIconEdge else { throw EngineError.invalidInput(.notSquareEnough) }
        let base = (url.lastPathComponent as NSString).deletingPathExtension
        let frame = [ImageFrame(image: square, duration: 0)]
        let options = EncodeOptions(quality: ImageEncoder.maximumQuality)
        let file: StagedFile
        switch kind {
        case .icns, .ico:
            let format: ImageFormat = kind == .icns ? .icns : .ico
            let name = base + "." + format.fileExtension
            let staged = try context.stagingURL(for: url, name: name)
            try ImageEncoder.encode(frame, as: format, options: options).write(to: staged)
            file = StagedFile(url: staged, name: name, check: .image)
        case .appIconSet:
            let name = base + ".appiconset"
            let folder = try context.stagingURL(for: url, name: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let icon = try ImagePixels.scaled(square, width: appIconEdge, height: appIconEdge)
            try ImageEncoder.png(icon).write(to: folder.appending(path: appIconFile))
            try appIconContents().write(to: folder.appending(path: "Contents.json"))
            file = StagedFile(url: folder, name: name, check: .folder)
        }
        return .derived(nextTo: url, outputs: [file])
    }

    /// Single size; Xcode derives the rest.
    static func appIconContents() throws -> Data {
        let contents: [String: Any] = [
            "images": [
                [
                    "filename": appIconFile, "idiom": "universal", "platform": "ios",
                    "size": "\(appIconEdge)x\(appIconEdge)",
                ]
            ],
            "info": ["author": "xcode", "version": 1],
        ]
        return try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    }

    static func base64(_ url: URL) throws -> ItemResult {
        let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard size <= base64Limit else { throw EngineError.invalidInput(.tooLarge(limitBytes: base64Limit)) }
        let data = try Data(contentsOf: url)
        guard let mime = mimeType(of: data) else { throw EngineError.decodeFailed(url.lastPathComponent) }
        return .text("data:\(mime);base64,\(data.base64EncodedString())", .clipboard)
    }

    private static func mimeType(of data: Data) -> String? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
            let identifier = CGImageSourceGetType(source),
            let mime = UTType(identifier as String)?.preferredMIMEType
        {
            return mime
        }
        return SVGRenderer.isSVG(data) ? UTType.svg.preferredMIMEType : nil
    }
}
