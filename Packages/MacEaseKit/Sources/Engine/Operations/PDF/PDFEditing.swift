import Foundation
import MenuCatalog
import PDFKit

enum PDFEditing {
    static func merge(_ inputs: [URL], pages: [PDFPageReference]?, context: ItemContext) throws -> ItemResult {
        let minimum = OperationID.pdfMerge.minimumSelection
        guard inputs.count >= minimum, let first = inputs.first else {
            throw EngineError.invalidInput(.tooFewFiles(minimum: minimum))
        }
        let documents = try inputs.map { ($0, try open($0)) }
        let byFile = Dictionary(documents) { earlier, _ in earlier }
        let order =
            pages
            ?? documents.flatMap { url, document in
                (0..<document.pageCount).map { PDFPageReference(file: url, pageIndex: $0) }
            }
        guard !order.isEmpty else { throw EngineError.invalidInput(.noPages) }
        let merged = PDFDocument()
        for (position, reference) in order.enumerated() {
            try Task.checkCancellation()
            guard let document = byFile[reference.file] else {
                throw EngineError.unexpected("merge page from an unselected file")
            }
            merged.insert(try copy(of: reference.pageIndex, in: document), at: merged.pageCount)
            context.progress(Double(position + 1) / Double(order.count))
        }
        let name = "\(baseName(of: first)) (merged).pdf"
        let staged = try context.stagingURL(for: first, name: name)
        try write(merged, to: staged)
        return .derived(nextTo: first, outputs: [StagedFile(url: staged, name: name, check: .pdf)])
    }

    static func compress(_ url: URL, context: ItemContext) throws -> ItemResult {
        let document = try open(url)
        // PDFKit otherwise copies untouched documents verbatim.
        let first = try page(0, in: document)
        document.removePage(at: 0)
        document.insert(first, at: 0)
        let staged = try context.stagingURL(for: url, name: url.lastPathComponent)
        try write(document, to: staged, options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
        let sizes = try [url, staged].map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
        guard sizes[1] < sizes[0] else { return .skipped(.outputNotSmaller) }
        return .replace(original: url, output: StagedFile(url: staged, name: url.lastPathComponent, check: .pdf))
    }

    static func rotate(_ url: URL, degrees: Int, context: ItemContext) throws -> ItemResult {
        let document = try open(url)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            try page(index, in: document).rotation += degrees
        }
        let staged = try context.stagingURL(for: url, name: url.lastPathComponent)
        try write(document, to: staged)
        return .replace(original: url, output: StagedFile(url: staged, name: url.lastPathComponent, check: .pdf))
    }

    static func extract(_ pages: IndexSet, from url: URL, context: ItemContext) throws -> ItemResult {
        let document = try open(url)
        let chosen = pages.filter { $0 < document.pageCount }
        guard !chosen.isEmpty else { throw EngineError.invalidInput(.noPages) }
        let extracted = PDFDocument()
        for index in chosen {
            extracted.insert(try copy(of: index, in: document), at: extracted.pageCount)
        }
        let name = "\(baseName(of: url)) (extracted).pdf"
        let staged = try context.stagingURL(for: url, name: name)
        try write(extracted, to: staged)
        return .derived(nextTo: url, outputs: [StagedFile(url: staged, name: name, check: .pdf)])
    }

    static func split(_ url: URL, context: ItemContext) throws -> ItemResult {
        let document = try open(url)
        let folder = try stagingFolder(for: url, context: context)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let single = PDFDocument()
            single.insert(try copy(of: index, in: document), at: 0)
            let name = pageFileName(base: baseName(of: url), index: index, count: document.pageCount, extension: "pdf")
            try write(single, to: folder.appending(path: name))
            context.progress(Double(index + 1) / Double(document.pageCount))
        }
        return .derived(nextTo: url, outputs: [StagedFile(url: folder, name: baseName(of: url), check: .folder)])
    }

    /// Rewriting would drop owner-password protection.
    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw EngineError.decodeFailed("PDF does not open") }
        guard !document.isEncrypted else { throw EngineError.invalidInput(.encrypted) }
        return document
    }

    static func page(_ index: Int, in document: PDFDocument) throws -> PDFPage {
        guard (0..<document.pageCount).contains(index), let page = document.page(at: index) else {
            throw EngineError.unexpected("page index out of range")
        }
        return page
    }

    static func baseName(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    static func stagingFolder(for url: URL, context: ItemContext) throws -> URL {
        let folder = try context.stagingDirectory(for: url).appending(
            path: baseName(of: url), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    /// Zero-padded so every app sorts them.
    static func pageFileName(base: String, index: Int, count: Int, extension pathExtension: String) -> String {
        let number = String(index + 1)
        let padding = String(repeating: "0", count: max(0, String(count).count - number.count))
        return "\(base) \(padding)\(number).\(pathExtension)"
    }

    private static func copy(of index: Int, in document: PDFDocument) throws -> PDFPage {
        guard let copy = try page(index, in: document).copy() as? PDFPage else {
            throw EngineError.unexpected("PDF page copy failed")
        }
        return copy
    }

    private static func write(
        _ document: PDFDocument,
        to url: URL,
        options: [PDFDocumentWriteOption: Any] = [:]
    ) throws {
        guard document.write(to: url, withOptions: options) else { throw EngineError.encodeFailed("PDF write failed") }
    }
}
