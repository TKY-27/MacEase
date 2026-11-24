import Darwin
import Engine
import Foundation

enum PreviewMarkdownRenderer {
    static let maximumImageBytes = 8 * 1024 * 1024
    static let maximumTotalImageBytes = 32 * 1024 * 1024
    private static let readChunkBytes = 64 * 1024
    private static let bmpHeaderSizes: Set<UInt32> = [12, 40, 52, 56, 64, 108, 124]

    static func html(_ markdown: String, markdownURL: URL, restricted: Bool) throws -> String {
        let rendered = try MarkdownConversion.html(markdown, title: markdownURL.lastPathComponent)
        guard !restricted else { return rendered }
        let baseDirectory = markdownURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        return embedLocalImages(in: rendered, baseDirectory: baseDirectory)
    }

    private static func embedLocalImages(in html: String, baseDirectory: URL) -> String {
        let baseComponents = baseDirectory.pathComponents
        var remainingBudget = maximumTotalImageBytes
        var output = ""
        output.reserveCapacity(html.count)
        var cursor = html.startIndex

        while let tagStart = findImageTag(in: html, from: cursor) {
            output.append(contentsOf: html[cursor..<tagStart])
            guard let tagEnd = findTagEnd(in: html, from: tagStart) else {
                output.append(contentsOf: html[tagStart...])
                return output
            }
            let tag = String(html[tagStart...tagEnd])
            output.append(
                rewriteImageTag(
                    tag, baseDirectory: baseDirectory, baseComponents: baseComponents,
                    remainingBudget: &remainingBudget))
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

    private static func rewriteImageTag(
        _ tag: String,
        baseDirectory: URL,
        baseComponents: [String],
        remainingBudget: inout Int
    ) -> String {
        guard let valueRange = findSrcAttributeValueRange(in: tag) else { return tag }
        let rawSource = unescapeHTML(String(tag[valueRange]))
        let limit = min(maximumImageBytes, remainingBudget)
        guard limit > 0,
            let relativePath = localRelativePath(from: rawSource),
            let resolvedURL = containedFileURL(
                relativePath: relativePath, baseDirectory: baseDirectory, baseComponents: baseComponents),
            let bytes = readBoundedRegularFile(at: resolvedURL, limit: limit),
            let mimeType = imageMIMEType(for: bytes)
        else { return tag }
        remainingBudget -= bytes.count
        let embedded = "data:\(mimeType);base64,\(bytes.base64EncodedString())"
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

    private static func containedFileURL(
        relativePath: String, baseDirectory: URL, baseComponents: [String]
    ) -> URL? {
        let candidate = baseDirectory.appendingPathComponent(relativePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > baseComponents.count,
            Array(candidateComponents.prefix(baseComponents.count)) == baseComponents
        else { return nil }
        return candidate
    }

    private static func readBoundedRegularFile(at url: URL, limit: Int) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        guard status.st_size > 0, status.st_size <= Int64(limit) else { return nil }
        var bytes = Data()
        bytes.reserveCapacity(Int(status.st_size))
        var chunk = [UInt8](repeating: 0, count: readChunkBytes)
        while true {
            let count = chunk.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return read(descriptor, base, readChunkBytes)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            guard count <= limit - bytes.count else { return nil }
            bytes.append(contentsOf: chunk[..<count])
        }
        return bytes.isEmpty ? nil : bytes
    }

    private static func imageMIMEType(for payload: Data) -> String? {
        let header = [UInt8](payload.prefix(64))
        if header.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if header.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if header.starts(with: Array("GIF87a".utf8)) || header.starts(with: Array("GIF89a".utf8)) {
            return "image/gif"
        }
        if header.count >= 12, header.starts(with: Array("RIFF".utf8)),
            header[8..<12].elementsEqual("WEBP".utf8)
        {
            return "image/webp"
        }
        if header.count >= 18, header.starts(with: Array("BM".utf8)),
            header[6..<10].allSatisfy({ $0 == 0 })
        {
            let dibSize =
                UInt32(header[14]) | (UInt32(header[15]) << 8)
                | (UInt32(header[16]) << 16) | (UInt32(header[17]) << 24)
            if bmpHeaderSizes.contains(dibSize) { return "image/bmp" }
        }
        if header.starts(with: [0x00, 0x00, 0x01, 0x00]) { return "image/x-icon" }
        if header.starts(with: [0x49, 0x49, 0x2A, 0x00]) || header.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return "image/tiff"
        }
        if header.count >= 12, header[4..<8].elementsEqual("ftyp".utf8) {
            let brand = String(decoding: header[8..<12], as: UTF8.self)
            if ["avif", "avis"].contains(brand) { return "image/avif" }
            if ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"].contains(brand) {
                return "image/heic"
            }
        }
        let svgPrefix = [UInt8](payload.prefix(4096))
        if !svgPrefix.contains(0), isSVGRoot(svgPrefix) { return "image/svg+xml" }
        return nil
    }

    private static func isSVGRoot(_ header: [UInt8]) -> Bool {
        var text = String(decoding: header, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var cursor = text.startIndex
        while cursor < text.endIndex {
            while cursor < text.endIndex, text[cursor].isWhitespace { cursor = text.index(after: cursor) }
            let remaining = text[cursor...]
            if remaining.hasPrefix("<?") {
                guard let end = remaining.range(of: "?>") else { return false }
                cursor = end.upperBound
            } else if remaining.hasPrefix("<!--") {
                guard let end = remaining.range(of: "-->") else { return false }
                cursor = end.upperBound
            } else if remaining.lowercased().hasPrefix("<!doctype") {
                guard let end = remaining.firstIndex(of: ">") else { return false }
                cursor = text.index(after: end)
            } else {
                let lowered = remaining.lowercased()
                guard lowered.hasPrefix("<svg") else { return false }
                let after = lowered.index(lowered.startIndex, offsetBy: 4)
                guard after == lowered.endIndex else {
                    let next = lowered[after]
                    return next.isWhitespace || next == ">" || next == "/"
                }
                return true
            }
        }
        return false
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
