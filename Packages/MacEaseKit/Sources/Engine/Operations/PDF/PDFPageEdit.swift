import Foundation
import PDFKit

public struct PDFPageEditSession: Sendable {
    public let sourceStamp: FileStamp
    public let pageCount: Int

    public static func open(_ url: URL) throws -> PDFPageEditSession {
        try OperationPlanner.validateInput(url)
        let stamp = try FileStamp(of: url, includingIdentity: true)
        let document = try PDFEditing.openForPageEditing(url)
        try validate(stamp, at: url)
        return PDFPageEditSession(sourceStamp: stamp, pageCount: document.pageCount)
    }

    static func validate(_ stamp: FileStamp, at url: URL) throws {
        guard stamp.matchesIdentity(url.path) else {
            throw EngineError.invalidInput(
                .malformed(String(localized: "The PDF changed. Reopen the page editor.", comment: "PDF source changed"))
            )
        }
    }
}

extension PDFEditing {
    static func openForPageEditing(_ url: URL) throws -> PDFDocument {
        let document = try openForCopying(url)
        guard !document.isEncrypted else { throw EngineError.invalidInput(.encrypted) }
        return document
    }

    static func editPages(_ order: [Int], sourceStamp: FileStamp, url: URL, context: ItemContext) throws -> ItemResult {
        try PDFPageEditSession.validate(sourceStamp, at: url)
        let document = try openForPageEditing(url)
        guard !order.isEmpty else { throw EngineError.invalidInput(.noPages) }
        guard Set(order).count == order.count, order.allSatisfy({ (0..<document.pageCount).contains($0) }) else {
            throw EngineError.invalidInput(
                .malformed(String(localized: "Invalid PDF page order.", comment: "PDF page order validation")))
        }
        guard order != Array(0..<document.pageCount) else { return .skipped(.alreadyDone) }
        let originalPages = try (0..<document.pageCount).map { try page($0, in: document) }
        let retained = Set(order)
        let navigation = PDFPageNavigation(document: document, pages: originalPages)
        for index in originalPages.indices.reversed() where !retained.contains(index) {
            document.removePage(at: index)
        }
        for (position, sourceIndex) in order.enumerated() {
            try Task.checkCancellation()
            let currentIndex = document.index(for: originalPages[sourceIndex])
            if currentIndex != position { document.exchangePage(at: position, withPageAt: currentIndex) }
            context.progress(Double(position + 1) / Double(order.count))
        }
        navigation.restore(in: document)
        let expected = PDFEditSnapshot(document)
        let staged = try context.stagingURL(for: url, name: url.lastPathComponent)
        try PDFPageEditSession.validate(sourceStamp, at: url)
        guard document.write(to: staged) else { throw EngineError.encodeFailed("PDF write failed") }
        let exported = try openForPageEditing(staged)
        guard PDFEditSnapshot(exported) == expected else {
            throw EngineError.encodeFailed("PDF page content or navigation changed during export")
        }
        try PDFPageEditSession.validate(sourceStamp, at: url)
        return .replace(original: url, output: StagedFile(url: staged, name: url.lastPathComponent, check: .pdf))
    }

}

private struct PDFPageNavigation {
    let root: PDFOutline?
    let outlines: [(PDFOutline, Target)]
    let links: [(PDFAnnotation, Target)]

    struct Target {
        let page: PDFPage
        let point: CGPoint
        let zoom: CGFloat

        init?(_ destination: PDFDestination?) {
            guard let destination, let page = destination.page else { return nil }
            self.page = page
            point = destination.point
            zoom = destination.zoom
        }
    }

    init(document: PDFDocument, pages: [PDFPage]) {
        root = document.outlineRoot
        outlines = Self.destinations(in: root)
        links = pages.flatMap { page in
            page.annotations.compactMap { annotation -> (PDFAnnotation, Target)? in
                guard
                    let destination = Target(
                        (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination)
                else {
                    return nil
                }
                return (annotation, destination)
            }
        }
    }

    func restore(in document: PDFDocument) {
        document.outlineRoot = root
        for (outline, destination) in outlines {
            outline.destination = retained(destination, in: document)
        }
        for (annotation, destination) in links {
            let target = retained(destination, in: document)
            annotation.destination = target
            annotation.action = target.map { PDFActionGoTo(destination: $0) }
        }
    }

    private func retained(_ destination: Target, in document: PDFDocument) -> PDFDestination? {
        guard document.index(for: destination.page) != NSNotFound else { return nil }
        let restored = PDFDestination(page: destination.page, at: destination.point)
        restored.zoom = destination.zoom
        return restored
    }

    private static func destinations(in outline: PDFOutline?) -> [(PDFOutline, Target)] {
        guard let outline else { return [] }
        let current = Target(outline.destination).map { [(outline, $0)] } ?? []
        return current + (0..<outline.numberOfChildren).flatMap { destinations(in: outline.child(at: $0)) }
    }
}

private struct PDFEditSnapshot: Equatable {
    let pages: [Page]
    let outline: [String]

    struct Page: Equatable {
        let text: String?
        let rotation: Int
        let boxes: [CGRect]
        let annotations: [String]
    }

    init(_ document: PDFDocument) {
        pages = (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            return Page(
                text: page.string, rotation: page.rotation,
                boxes: [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox].map { page.bounds(for: $0) },
                annotations: page.annotations.map { annotation in
                    [
                        annotation.type ?? "", NSStringFromRect(annotation.bounds), annotation.contents ?? "",
                        annotation.fieldName ?? "", annotation.widgetStringValue ?? "",
                        Self.destination(
                            (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination, in: document),
                        (annotation.action as? PDFActionURL)?.url?.absoluteString ?? "",
                    ].joined(separator: "\u{0}")
                })
        }
        outline = Self.outline(document.outlineRoot, in: document)
    }

    private static func destination(_ destination: PDFDestination?, in document: PDFDocument) -> String {
        guard let destination, let page = destination.page else { return "" }
        return "\(document.index(for: page)):\(destination.point.x):\(destination.point.y)"
    }

    private static func outline(_ entry: PDFOutline?, in document: PDFDocument) -> [String] {
        guard let entry else { return [] }
        return ["\(entry.label ?? ""):\(destination(entry.destination, in: document)):\(entry.numberOfChildren)"]
            + (0..<entry.numberOfChildren).flatMap { outline(entry.child(at: $0), in: document) }
    }
}
