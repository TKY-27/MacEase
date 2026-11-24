import Darwin
import Engine
import Foundation
import os

enum PreviewMarkdownRenderer {
    static let maximumImageBytes = 8 * 1024 * 1024
    static let maximumTotalImageBytes = 32 * 1024 * 1024

    static func html(_ markdown: String, markdownURL: URL, directory: Int32? = nil, restricted: Bool) throws -> String {
        let rendered = try MarkdownConversion.html(markdown, title: markdownURL.lastPathComponent)
        guard !restricted else { return rendered }
        if let directory {
            var embedder = PreviewImageEmbedder(directory: directory)
            return try embedLocalImages(in: rendered, embedder: &embedder)
        }
        let folder = markdownURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let opened = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard opened >= 0 else {
            Logger(category: "finder-preview").error(
                "Markdown folder could not be opened (errno \(errno, privacy: .public)); images stay linked")
            return rendered
        }
        defer { close(opened) }
        var embedder = PreviewImageEmbedder(directory: opened)
        return try embedLocalImages(in: rendered, embedder: &embedder)
    }

    private static func embedLocalImages(in html: String, embedder: inout PreviewImageEmbedder) throws -> String {
        var output = ""
        output.reserveCapacity(html.count)
        var cursor = html.startIndex

        while let tagStart = findImageTag(in: html, from: cursor) {
            try Task.checkCancellation()
            output.append(contentsOf: html[cursor..<tagStart])
            guard let tagEnd = findTagEnd(in: html, from: tagStart) else {
                output.append(contentsOf: html[tagStart...])
                return output
            }
            let tag = String(html[tagStart...tagEnd])
            output.append(rewriteImageTag(tag, embedder: &embedder))
            cursor = html.index(after: tagEnd)
        }
        output.append(contentsOf: html[cursor...])
        return output
    }

    private static func findImageTag(in html: String, from start: String.Index) -> String.Index? {
        var cursor = start
        while let open = html[cursor...].firstIndex(of: "<") {
            let afterOpen = html.index(after: open)
            guard let nameEnd = html.index(afterOpen, offsetBy: 3, limitedBy: html.endIndex) else { return nil }
            if html[afterOpen..<nameEnd].lowercased() == "img", nameEnd < html.endIndex {
                let delimiter = html[nameEnd]
                if delimiter == " " || delimiter == "\t" || delimiter == "\n" || delimiter == "\r" || delimiter == "/" {
                    return open
                }
            }
            cursor = afterOpen
        }
        return nil
    }

    private static func findTagEnd(in html: String, from start: String.Index) -> String.Index? {
        var quote: Character?
        var cursor = start
        while cursor < html.endIndex {
            let character = html[cursor]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return cursor
            }
            cursor = html.index(after: cursor)
        }
        return nil
    }

    private static func rewriteImageTag(_ tag: String, embedder: inout PreviewImageEmbedder) -> String {
        guard let valueRange = findSrcAttributeValueRange(in: tag),
            let relativePath = localRelativePath(from: unescapeHTML(String(tag[valueRange]))),
            let embedded = embedder.dataURL(for: relativePath)
        else { return tag }
        return String(tag[..<valueRange.lowerBound]) + embedded + String(tag[valueRange.upperBound...])
    }

    private static func findSrcAttributeValueRange(in tag: String) -> Range<String.Index>? {
        var cursor = tag.index(tag.startIndex, offsetBy: min(4, tag.count))
        while cursor < tag.endIndex {
            while cursor < tag.endIndex, tag[cursor].isWhitespace || tag[cursor] == "/" {
                cursor = tag.index(after: cursor)
            }
            guard cursor < tag.endIndex, tag[cursor] != ">" else { return nil }
            let nameStart = cursor
            while cursor < tag.endIndex, !tag[cursor].isWhitespace, tag[cursor] != "=",
                tag[cursor] != ">", tag[cursor] != "/"
            {
                cursor = tag.index(after: cursor)
            }
            let attributeName = tag[nameStart..<cursor].lowercased()
            while cursor < tag.endIndex, tag[cursor].isWhitespace { cursor = tag.index(after: cursor) }
            guard cursor < tag.endIndex, tag[cursor] == "=" else { continue }
            cursor = tag.index(after: cursor)
            while cursor < tag.endIndex, tag[cursor].isWhitespace { cursor = tag.index(after: cursor) }
            guard cursor < tag.endIndex else { return nil }
            let valueRange: Range<String.Index>
            if tag[cursor] == "\"" || tag[cursor] == "'" {
                let quote = tag[cursor]
                let valueStart = tag.index(after: cursor)
                guard let valueEnd = tag[valueStart...].firstIndex(of: quote) else { return nil }
                valueRange = valueStart..<valueEnd
                cursor = tag.index(after: valueEnd)
            } else {
                let valueStart = cursor
                while cursor < tag.endIndex, !tag[cursor].isWhitespace, tag[cursor] != ">" {
                    cursor = tag.index(after: cursor)
                }
                valueRange = valueStart..<cursor
            }
            if attributeName == "src" { return valueRange }
        }
        return nil
    }

    private static func localRelativePath(from source: String) -> String? {
        guard !source.isEmpty, !source.contains("\0"), !source.contains("\\") else { return nil }
        guard !source.hasPrefix("/"), !source.hasPrefix("#"), !source.hasPrefix("?") else { return nil }
        if let components = URLComponents(string: source) {
            guard components.scheme == nil, components.host == nil else { return nil }
            return validatedRelativePath(components.path)
        }
        guard !source.contains(":"), let decoded = source.removingPercentEncoding else { return nil }
        return validatedRelativePath(decoded)
    }

    private static func validatedRelativePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains("\\") else { return nil }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains("..") else { return nil }
        return path
    }

    private static func unescapeHTML(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        var cursor = text.startIndex
        while let amp = text[cursor...].firstIndex(of: "&") {
            output.append(contentsOf: text[cursor..<amp])
            guard let semi = text[amp...].firstIndex(of: ";") else {
                output.append(contentsOf: text[amp...])
                return output
            }
            let entity = text[text.index(after: amp)..<semi]
            if let replacement = decodeHTMLEntity(entity) {
                output.append(replacement)
            } else {
                output.append(contentsOf: text[amp...semi])
            }
            cursor = text.index(after: semi)
        }
        output.append(contentsOf: text[cursor...])
        return output
    }

    private static func decodeHTMLEntity(_ entity: Substring) -> String? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default:
            if entity.hasPrefix("#x") || entity.hasPrefix("#X"),
                let scalar = UInt32(entity.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init)
            {
                return String(scalar)
            }
            if entity.hasPrefix("#"),
                let scalar = UInt32(entity.dropFirst(), radix: 10).flatMap(UnicodeScalar.init)
            {
                return String(scalar)
            }
            return nil
        }
    }
}

// Checks and reads share one descriptor.
private struct PreviewImageEmbedder {
    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private struct Image {
        let mimeType: String
        let bytes: Data
    }

    private static let headerBytes = 4096
    private static let readChunkBytes = 64 * 1024
    private static let mimeTypes: [String: String] = [
        "PNG": "image/png", "JPEG": "image/jpeg", "GIF": "image/gif", "WebP": "image/webp", "BMP": "image/bmp",
        "ICO": "image/x-icon", "TIFF": "image/tiff", "AVIF": "image/avif", "HEIF": "image/heic",
        "SVG": "image/svg+xml",
    ]

    let directory: Int32
    // Includes rejected reads.
    private var readBytes = 0
    private var embeddedBytes = 0
    private var seen: [FileIdentity: Image?] = [:]

    init(directory: Int32) {
        self.directory = directory
    }

    mutating func dataURL(for relativePath: String) -> String? {
        guard let descriptor = openContained(relativePath) else { return nil }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        let identity = FileIdentity(device: status.st_dev, inode: status.st_ino)
        let image: Image?
        if let known = seen[identity] {
            image = known
        } else {
            image = read(descriptor, size: status.st_size)
            seen[identity] = image
        }
        guard let image, embeddedBytes + image.bytes.count <= PreviewMarkdownRenderer.maximumTotalImageBytes else {
            return nil
        }
        embeddedBytes += image.bytes.count
        return "data:\(image.mimeType);base64,\(image.bytes.base64EncodedString())"
    }

    // Every component is opened without following symlinks.
    private func openContained(_ relativePath: String) -> Int32? {
        let components = relativePath.split(separator: "/").filter { $0 != "." }.map(String.init)
        guard let name = components.last, !components.contains("..") else { return nil }
        var parent = dup(directory)
        guard parent >= 0 else { return nil }
        for folder in components.dropLast() {
            let next = openat(parent, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(parent)
            guard next >= 0 else { return nil }
            parent = next
        }
        defer { close(parent) }
        // Nonblocking: a FIFO must not hang.
        let file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        return file >= 0 ? file : nil
    }

    private mutating func read(_ descriptor: Int32, size: off_t) -> Image? {
        let limit = min(
            PreviewMarkdownRenderer.maximumImageBytes, PreviewMarkdownRenderer.maximumTotalImageBytes - readBytes)
        guard size > 0, size <= off_t(limit) else { return nil }
        var bytes = Data()
        // The header decides before any body read.
        guard append(descriptor, upTo: min(Int(size), Self.headerBytes), to: &bytes),
            let mimeType = Self.mimeTypes[ContentSniffer.identify(header: [UInt8](bytes)).displayName],
            append(descriptor, upTo: limit + 1 - bytes.count, to: &bytes), bytes.count <= limit
        else { return nil }
        return Image(mimeType: mimeType, bytes: bytes)
    }

    private mutating func append(_ descriptor: Int32, upTo count: Int, to bytes: inout Data) -> Bool {
        var remaining = count
        var chunk = [UInt8](repeating: 0, count: Self.readChunkBytes)
        while remaining > 0 {
            let wanted = min(remaining, Self.readChunkBytes)
            let received = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, wanted) }
            if received == 0 { return true }
            if received < 0 {
                if errno == EINTR { continue }
                return false
            }
            readBytes += received
            bytes.append(contentsOf: chunk[..<received])
            remaining -= received
        }
        return true
    }
}
