import Foundation
import MenuCatalog

public struct TextEditDocument: Sendable {
    public let text: String
    public let encoding: String.Encoding
    public let byteOrderMark: Data
    public let lineEnding: String

    public init(bytes: Data, encoding chosen: String.Encoding? = nil) throws {
        let mark = TextEncoding.byteOrderMark(of: bytes)
        let encoding = mark?.0.foundation ?? (chosen == .utf16 ? .utf16BigEndian : chosen)
        if let encoding {
            guard let decoded = String(data: bytes.dropFirst(mark?.1 ?? 0), encoding: encoding) else {
                throw EngineError.invalidInput(.textEncodingUndetected)
            }
            text = decoded
            self.encoding = encoding
        } else {
            let decoded = try TextEncoding.decode(bytes)
            text = decoded.text
            self.encoding = decoded.source.foundation
        }
        byteOrderMark = Data(bytes.prefix(mark?.1 ?? 0))
        lineEnding = text.first(where: \.isNewline).map(String.init) ?? "\n"
    }

    public func encoded(_ buffer: String, asUTF8: Bool = false) throws -> Data {
        guard !buffer.isEmpty else { throw EngineError.invalidInput(.emptyTextEdit) }
        let target = asUTF8 ? String.Encoding.utf8 : encoding
        guard let body = buffer.data(using: target, allowLossyConversion: false),
            let decoded = String(data: body, encoding: target), decoded.utf8.elementsEqual(buffer.utf8)
        else { throw EngineError.invalidInput(.textEditUnrepresentable) }
        return (asUTF8 ? Data() : byteOrderMark) + body
    }
}

public enum TextReplacement {
    public static func batch(
        original: URL, stamp: FileStamp, text: String, document: TextEditDocument, asUTF8: Bool = false
    ) -> Batch {
        var work = WorkItem(inputs: [original]) { context in
            context.phase(.encoding)
            let bytes = try document.encoded(text, asUTF8: asUTF8)
            try Task.checkCancellation()
            let staged = try context.stagingURL(for: original, name: original.lastPathComponent)
            try bytes.write(to: staged)
            return .replace(
                original: original,
                output: StagedFile(
                    url: staged, name: original.lastPathComponent,
                    check: .textReplacement(
                        encoding: asUTF8 ? .utf8 : document.encoding,
                        byteOrderMark: asUTF8 ? Data() : document.byteOrderMark, text: text)))
        }
        work.replacementInputStamps = [original: stamp]
        return Batch(operation: .textEdit, items: [work])
    }
}
