import AppKit
import CArchive
import Darwin
import Foundation

enum AttributedDocument {
    private static let maximumFileBytes: Int64 = 8 * 1_024 * 1_024
    private static let maximumExpandedBytes: Int64 = 32 * 1_024 * 1_024
    private static let maximumEntries = 1_024
    private static let maximumPackageDepth = 64
    private static let maximumCharacters = 1_000_000
    private static let maximumPages = 256
    private static let archiveBlockBytes = 64 * 1_024
    private static let pageBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let pageMargin: CGFloat = 54

    static func convert(_ url: URL, toPDF: Bool) throws -> Data {
        let extensionName = url.pathExtension.lowercased()
        let documentType: NSAttributedString.DocumentType
        switch extensionName {
        case "docx": documentType = .officeOpenXML
        case "odt": documentType = .openDocument
        case "rtf": documentType = .rtf
        case "rtfd": documentType = .rtfd
        default: throw EngineError.invalidInput(.unsupportedFileType)
        }

        var attributes: NSDictionary?
        let document: NSAttributedString
        if extensionName == "rtfd" {
            let wrapper = try validatedPackage(at: url)
            guard let imported = NSAttributedString(rtfdFileWrapper: wrapper, documentAttributes: &attributes) else {
                throw EngineError.decodeFailed("RTFD document cannot be opened")
            }
            document = imported
        } else {
            let source = try ConversionInput.read(url, limit: maximumFileBytes)
            if extensionName == "docx" || extensionName == "odt" {
                try validateArchive(source)
            }
            document = try NSAttributedString(
                data: source, options: [.documentType: documentType], documentAttributes: &attributes)
        }
        guard document.length <= maximumCharacters else {
            throw EngineError.invalidInput(.malformed("Document has too many characters"))
        }
        if !toPDF { return Data(document.string.utf8) }
        return try pdf(for: document)
    }

    private static func validatedPackage(at url: URL) throws -> FileWrapper {
        var totalBytes: Int64 = 0
        var entryCount = 0

        func visit(_ location: URL, depth: Int) throws -> FileWrapper {
            try Task.checkCancellation()
            guard depth <= maximumPackageDepth else {
                throw EngineError.invalidInput(.malformed("Document package is too deeply nested"))
            }
            var status = stat()
            guard lstat(location.path, &status) == 0 else {
                throw EngineError.decodeFailed("Document package is unavailable")
            }
            let kind = status.st_mode & S_IFMT
            if kind == S_IFDIR {
                var children: [String: FileWrapper] = [:]
                var traversalFailure: (any Error)?
                guard
                    let entries = FileManager.default.enumerator(
                        at: location, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants],
                        errorHandler: { _, failure in
                            traversalFailure = failure
                            return false
                        })
                else { throw EngineError.decodeFailed("Document package cannot be enumerated") }
                while let entry = entries.nextObject() {
                    guard let child = entry as? URL else {
                        throw EngineError.decodeFailed("Document package entry is invalid")
                    }
                    entryCount += 1
                    guard entryCount <= maximumEntries else {
                        throw EngineError.invalidInput(.malformed("Document package has too many entries"))
                    }
                    children[child.lastPathComponent] = try visit(child, depth: depth + 1)
                }
                if let traversalFailure { throw traversalFailure }
                let wrapper = FileWrapper(directoryWithFileWrappers: children)
                wrapper.preferredFilename = location.lastPathComponent
                return wrapper
            } else if kind == S_IFREG {
                guard status.st_size >= 0, status.st_size <= maximumExpandedBytes - totalBytes else {
                    throw EngineError.invalidInput(.tooLarge(limitBytes: maximumExpandedBytes))
                }
                let bytes = try ConversionInput.read(location, limit: maximumExpandedBytes - totalBytes)
                totalBytes += Int64(bytes.count)
                let wrapper = FileWrapper(regularFileWithContents: bytes)
                wrapper.preferredFilename = location.lastPathComponent
                return wrapper
            } else {
                throw EngineError.invalidInput(.malformed("Document package contains a link or special file"))
            }
        }

        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw EngineError.invalidInput(.malformed("RTFD is not a directory"))
        }
        return try visit(url, depth: 0)
    }

    private static func validateArchive(_ source: Data) throws {
        try source.withUnsafeBytes { rawBytes in
            guard let archive = archive_read_new() else {
                throw EngineError.decodeFailed("Archive reader allocation failed")
            }
            defer { archive_read_free(archive) }
            archive_read_support_filter_all(archive)
            archive_read_support_format_zip(archive)
            guard archive_read_open_memory(archive, rawBytes.baseAddress, rawBytes.count) == ARCHIVE_OK else {
                throw EngineError.decodeFailed("Document archive cannot be opened")
            }

            var entry: OpaquePointer?
            var entryCount = 0
            var totalBytes: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: archiveBlockBytes)
            while true {
                try Task.checkCancellation()
                let result = archive_read_next_header(archive, &entry)
                if result == ARCHIVE_EOF { break }
                guard result == ARCHIVE_OK, let entry else {
                    throw EngineError.decodeFailed("Document archive is malformed")
                }
                guard let pathname = archive_entry_pathname(entry), let path = String(validatingCString: pathname),
                    !path.hasPrefix("/"), !path.contains("\\"),
                    !path.split(separator: "/").contains("..")
                else {
                    throw EngineError.invalidInput(.malformed("Document archive contains an unsafe path"))
                }
                entryCount += 1
                guard entryCount <= maximumEntries else {
                    throw EngineError.invalidInput(.malformed("Document archive has too many entries"))
                }
                let kind = archive_entry_filetype(entry)
                guard kind == S_IFREG || kind == S_IFDIR,
                    archive_entry_symlink(entry) == nil,
                    archive_entry_hardlink(entry) == nil
                else {
                    throw EngineError.invalidInput(.malformed("Document archive contains a link or special file"))
                }
                if archive_entry_size_is_set(entry) != 0 {
                    let claimedBytes = archive_entry_size(entry)
                    guard claimedBytes >= 0, claimedBytes <= maximumExpandedBytes - totalBytes else {
                        throw EngineError.invalidInput(.tooLarge(limitBytes: maximumExpandedBytes))
                    }
                }
                while true {
                    try Task.checkCancellation()
                    let bytes = buffer.withUnsafeMutableBytes { archive_read_data(archive, $0.baseAddress, $0.count) }
                    guard bytes >= 0 else { throw EngineError.decodeFailed("Document archive is malformed") }
                    if bytes == 0 { break }
                    guard Int64(bytes) <= maximumExpandedBytes - totalBytes else {
                        throw EngineError.invalidInput(.tooLarge(limitBytes: maximumExpandedBytes))
                    }
                    totalBytes += Int64(bytes)
                }
            }
            guard entryCount > 0 else { throw EngineError.invalidInput(.emptyInput) }
        }
    }

    private static func pdf(for document: NSAttributedString) throws -> Data {
        guard document.length > 0 else { throw EngineError.invalidInput(.emptyInput) }
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw EngineError.encodeFailed("PDF output allocation failed")
        }
        var mediaBox = pageBox
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw EngineError.encodeFailed("PDF context allocation failed")
        }
        var closed = false
        defer { if !closed { context.closePDF() } }

        let storage = NSTextStorage(attributedString: document)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let contentBox = pageBox.insetBy(dx: pageMargin, dy: pageMargin)
        let totalGlyphs = layout.numberOfGlyphs
        var offset = 0
        var pages = 0
        while offset < totalGlyphs {
            try Task.checkCancellation()
            guard pages < maximumPages else {
                throw EngineError.invalidInput(.malformed("Document exceeds PDF page limit"))
            }
            let container = NSTextContainer(size: contentBox.size)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            let visible = layout.glyphRange(for: container)
            guard visible.length > 0 else { throw EngineError.encodeFailed("Text cannot fit on a PDF page") }
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: pageMargin, y: pageBox.height - pageMargin)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            layout.drawBackground(forGlyphRange: visible, at: .zero)
            layout.drawGlyphs(forGlyphRange: visible, at: .zero)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
            offset = NSMaxRange(visible)
            pages += 1
        }
        context.closePDF()
        closed = true
        return output as Data
    }
}
