import Formats
import Foundation

enum StreamingText {
    static let chunkBytes = 64 * 1024
    private static let maximumIncompleteBytes = 3
    static let maximumGraphemeBytes = 1024 * 1024

    private struct Source {
        let encoding: SourceTextEncoding
        let prefix: Data
    }

    static func transcode(
        _ input: URL, to output: URL, target: TextEncodingTarget, source: SourceTextEncoding?, settings: TextSettings
    ) throws -> (encoding: String.Encoding, replaced: Bool) {
        let detected = try identify(input, assuming: source, allowingAmbiguity: false)
        let header = try TextEncoding.encode(
            "", as: target, unmappable: settings.unmappable, substitute: settings.shiftJISSubstitute)
        try header.data.write(to: output, options: .withoutOverwriting)
        let writer = try FileHandle(forWritingTo: output)
        try writer.seekToEnd()
        var pending = ""
        var replaced = false
        var line = 1
        func append(_ text: String) throws {
            let encoded = try TextEncoding.encode(
                text, as: target, unmappable: settings.unmappable, substitute: settings.shiftJISSubstitute,
                startingLine: line)
            try writer.write(contentsOf: encoded.data.dropFirst(header.data.count))
            replaced = replaced || encoded.replaced
            if target == .shiftJIS { line += text.lazy.filter(\.isNewline).count }
        }
        try chunks(input, encoding: detected.encoding.foundation, skipping: detected.prefix.count) { _, text in
            if target == .shiftJIS {
                pending += text
                if pending.utf8.count > maximumGraphemeBytes,
                    pending.contains(where: { $0.utf8.count > maximumGraphemeBytes })
                {
                    throw EngineError.invalidInput(.malformed("A text character exceeds 1 MiB"))
                }
                guard let last = pending.indices.last else { return }
                try append(String(pending[..<last]))
                pending = String(pending[last...])
            } else {
                try append(text)
            }
        }
        try append(pending)
        try writer.close()
        return (header.encoding, replaced)
    }

    static func normalize(_ input: URL, to output: URL, ending: LineEnding) throws -> String.Encoding {
        let detected = try identify(input, assuming: nil, allowingAmbiguity: true)
        try detected.prefix.write(to: output, options: .withoutOverwriting)
        let writer = try FileHandle(forWritingTo: output)
        try writer.seekToEnd()
        var afterCarriageReturn = false
        let wide = detected.encoding == .utf16LittleEndian || detected.encoding == .utf16BigEndian
        let bigEndian = detected.encoding == .utf16BigEndian
        let carriageReturn = UInt8(ascii: "\r")
        let lineFeed = UInt8(ascii: "\n")
        let endingBytes = ending == .crlf ? [carriageReturn, lineFeed] : [lineFeed]
        try chunks(input, encoding: detected.encoding.foundation, skipping: detected.prefix.count) { bytes, text in
            if wide {
                let normalized: [UInt16] = TextEncoding.normalized(
                    text.utf16, ending: endingBytes.map(UInt16.init), afterCarriageReturn: &afterCarriageReturn)
                let encoded = TextEncoding.utf16Data(normalized, bigEndian: bigEndian)
                try writer.write(contentsOf: encoded.dropFirst(detected.prefix.count))
            } else {
                let normalized: [UInt8] = TextEncoding.normalized(
                    Array(bytes), ending: endingBytes, afterCarriageReturn: &afterCarriageReturn)
                try writer.write(contentsOf: normalized)
            }
        }
        try writer.close()
        return detected.encoding.foundation
    }

    static func validate(_ url: URL, encoding: String.Encoding) throws {
        if encoding == .utf16 {
            let prefix = try prefix(of: url)
            if let (source, count) = TextEncoding.byteOrderMark(of: prefix),
                source == .utf16LittleEndian || source == .utf16BigEndian
            {
                try chunks(url, encoding: source.foundation, skipping: count) { _, _ in }
                return
            }
        }
        try chunks(url, encoding: encoding) { _, _ in }
    }

    static func equalContents(_ first: URL, _ second: URL) throws -> Bool {
        let left = try FileHandle(forReadingFrom: first)
        let right = try FileHandle(forReadingFrom: second)
        while true {
            try Task.checkCancellation()
            let leftBytes = try left.readChunk(upToCount: chunkBytes)
            let rightBytes = try right.readChunk(upToCount: chunkBytes)
            if leftBytes != rightBytes { return false }
            if leftBytes?.isEmpty != false { break }
        }
        try left.close()
        try right.close()
        return true
    }

    private static func prefix(of url: URL) throws -> Data {
        let reader = try FileHandle(forReadingFrom: url)
        let prefix = try reader.readChunk(upToCount: maximumIncompleteBytes) ?? Data()
        try reader.close()
        return prefix
    }

    private static func identify(
        _ url: URL, assuming chosen: SourceTextEncoding?, allowingAmbiguity: Bool
    ) throws -> Source {
        let prefix = try prefix(of: url)
        if let (source, count) = TextEncoding.byteOrderMark(of: prefix) {
            return Source(encoding: source, prefix: prefix.prefix(count))
        }
        if let chosen { return Source(encoding: chosen, prefix: Data()) }
        if try accepts(url, as: .utf8) { return Source(encoding: .utf8, prefix: Data()) }
        let cp932 = try accepts(url, as: .cp932)
        let eucJP = try accepts(url, as: .eucJP)
        if cp932, !eucJP || allowingAmbiguity { return Source(encoding: .cp932, prefix: Data()) }
        if eucJP, !cp932 { return Source(encoding: .eucJP, prefix: Data()) }
        throw EngineError.invalidInput(.textEncodingUndetected)
    }

    private static func accepts(_ url: URL, as source: SourceTextEncoding) throws -> Bool {
        do {
            try chunks(url, encoding: source.foundation) { _, _ in }
            return true
        } catch EngineError.invalidInput(.textEncodingUndetected) {
            return false
        }
    }

    private static func chunks(
        _ url: URL, encoding: String.Encoding, skipping: Int = 0, consume: (Data, String) throws -> Void
    ) throws {
        try Task.checkCancellation()
        let reader = try FileHandle(forReadingFrom: url)
        try reader.seek(toOffset: UInt64(skipping))
        let wide = encoding == .utf16 || encoding == .utf16LittleEndian || encoding == .utf16BigEndian
        var pending = Data()
        while let bytes = try reader.readChunk(upToCount: chunkBytes), !bytes.isEmpty {
            try Task.checkCancellation()
            try autoreleasepool {
                pending.append(bytes)
                for suffix in 0...min(maximumIncompleteBytes, pending.count) {
                    let prefix = pending.prefix(pending.count - suffix)
                    if wide, !prefix.count.isMultiple(of: MemoryLayout<UInt16>.size) { continue }
                    let decoded =
                        encoding == .utf8
                        ? String(validating: prefix, as: UTF8.self) : String(data: prefix, encoding: encoding)
                    if let text = decoded {
                        try consume(prefix, text)
                        pending = Data(pending.suffix(suffix))
                        return
                    }
                }
                throw EngineError.invalidInput(.textEncodingUndetected)
            }
        }
        guard pending.isEmpty else { throw EngineError.invalidInput(.textEncodingUndetected) }
        try reader.close()
        try Task.checkCancellation()
    }
}
