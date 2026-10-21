import CoreFoundation
import Foundation

public enum TextEncoding {
    static let cp932 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let utf16LittleEndianBOM: [UInt8] = [0xFF, 0xFE]
    private static let utf16BigEndianBOM: [UInt8] = [0xFE, 0xFF]
    private static let carriageReturn: UInt8 = 0x0D
    private static let lineFeed: UInt8 = 0x0A
    private static let legacyCandidates: [SourceTextEncoding] = [.cp932, .eucJP]

    struct Decoded {
        let text: String
        let source: SourceTextEncoding
    }

    /// Legacy encodings must be unambiguous.
    static func decode(_ data: Data, assuming chosen: SourceTextEncoding? = nil) throws -> Decoded {
        if let (source, bomLength) = byteOrderMark(of: data) {
            return try decode(data.dropFirst(bomLength), as: source)
        }
        if let chosen { return try decode(data, as: chosen) }
        if let text = String(data: data, encoding: .utf8) { return Decoded(text: text, source: .utf8) }
        let matches = legacyCandidates.compactMap { candidate in
            String(data: data, encoding: candidate.foundation).map { Decoded(text: $0, source: candidate) }
        }
        guard matches.count == 1, let match = matches.first else {
            throw EngineError.invalidInput(.textEncodingUndetected)
        }
        return match
    }

    static func encode(
        _ text: String,
        as target: TextEncodingTarget,
        unmappable: UnmappablePolicy,
        substitute: String = "?"
    ) throws -> (data: Data, encoding: String.Encoding, replaced: Bool) {
        switch target {
        case .utf8: return (Data(text.utf8), .utf8, false)
        case .utf8BOM: return (Data(utf8BOM + text.utf8), .utf8, false)
        case .utf16: return (utf16Data(text.utf16, bigEndian: false), .utf16, false)
        case .shiftJIS:
            let result = try cp932Data(text, unmappable: unmappable, substitute: substitute)
            return (result.data, cp932, result.replaced)
        }
    }

    /// Multibyte units never contain CR or LF.
    static func normalizingLineEndings(
        _ data: Data,
        to ending: LineEnding
    ) throws -> (data: Data, encoding: String.Encoding) {
        let decoded = try decodingAmbiguous(data)
        let encoding = decoded.source.foundation
        let endingBytes = ending == .crlf ? [carriageReturn, lineFeed] : [lineFeed]
        switch decoded.source {
        case .utf16LittleEndian, .utf16BigEndian:
            let units: [UInt16] = normalized(decoded.text.utf16, ending: endingBytes.map(UInt16.init))
            return (utf16Data(units, bigEndian: decoded.source == .utf16BigEndian), encoding)
        case .utf8, .cp932, .eucJP:
            // Frees the decoded text before copying.
            _ = consume decoded
            let bytes: [UInt8] = normalized(data, ending: endingBytes)
            return (Data(bytes), encoding)
        }
    }

    /// Kept bytes make ambiguity harmless.
    private static func decodingAmbiguous(_ data: Data) throws -> Decoded {
        do {
            return try decode(data)
        } catch EngineError.invalidInput(.textEncodingUndetected) {
            return try decode(data, assuming: legacyCandidates[0])
        }
    }

    private static func decode(_ data: Data, as source: SourceTextEncoding) throws -> Decoded {
        guard let text = String(data: data, encoding: source.foundation) else {
            throw EngineError.invalidInput(.textEncodingUndetected)
        }
        return Decoded(text: text, source: source)
    }

    private static func byteOrderMark(of data: Data) -> (SourceTextEncoding, Int)? {
        if data.starts(with: utf8BOM) { return (.utf8, utf8BOM.count) }
        if data.starts(with: utf16LittleEndianBOM) { return (.utf16LittleEndian, utf16LittleEndianBOM.count) }
        if data.starts(with: utf16BigEndianBOM) { return (.utf16BigEndian, utf16BigEndianBOM.count) }
        return nil
    }

    public static func isValidShiftJISSubstitute(_ substitute: String) -> Bool {
        substitute.unicodeScalars.count == 1 && substitute.data(using: cp932) != nil
    }

    private static func cp932Data(
        _ text: String, unmappable: UnmappablePolicy, substitute: String
    ) throws -> (data: Data, replaced: Bool) {
        let replacement: Data?
        if unmappable == .custom {
            guard isValidShiftJISSubstitute(substitute), let encoded = substitute.data(using: cp932) else {
                throw EngineError.invalidInput(.malformed("Shift_JIS substitute must be one encodable character"))
            }
            replacement = encoded
        } else {
            replacement = nil
        }
        if let data = text.data(using: cp932) { return (data, false) }
        var data = Data()
        var replaced = false
        var line = 1
        for character in text {
            if let bytes = String(character).data(using: cp932) {
                data.append(bytes)
            } else {
                replaced = true
                switch unmappable {
                case .fail:
                    throw EngineError.invalidInput(.unmappableCharacter(line: line))
                case .questionMark:
                    data.append(UInt8(ascii: "?"))
                case .numericReference:
                    for scalar in character.unicodeScalars { data.append(contentsOf: "&#\(scalar.value);".utf8) }
                case .custom:
                    guard let replacement else { throw EngineError.unexpected("validated substitute missing") }
                    data.append(replacement)
                }
            }
            if character.isNewline { line += 1 }
        }
        return (data, replaced)
    }

    private static func normalized<Output: RangeReplaceableCollection>(
        _ units: some Collection<Output.Element>, ending: [Output.Element]
    ) -> Output where Output.Element: FixedWidthInteger {
        let carriageReturn = Output.Element(Self.carriageReturn)
        let lineFeed = Output.Element(Self.lineFeed)
        var result = Output()
        // Untouched capacity stays virtual; regrowth copies everything.
        result.reserveCapacity(units.count * ending.count)
        var afterCarriageReturn = false
        for unit in units {
            defer { afterCarriageReturn = unit == carriageReturn }
            if unit == lineFeed, afterCarriageReturn { continue }
            if unit == carriageReturn || unit == lineFeed {
                result.append(contentsOf: ending)
            } else {
                result.append(unit)
            }
        }
        return result
    }

    private static func utf16Data(_ units: some Collection<UInt16>, bigEndian: Bool) -> Data {
        let bom = bigEndian ? utf16BigEndianBOM : utf16LittleEndianBOM
        let unitBytes = MemoryLayout<UInt16>.size
        var output = Data(count: bom.count + units.count * unitBytes)
        output.withUnsafeMutableBytes { buffer in
            buffer.copyBytes(from: bom)
            var offset = bom.count
            for unit in units {
                buffer.storeBytes(
                    of: bigEndian ? unit.bigEndian : unit.littleEndian, toByteOffset: offset, as: UInt16.self)
                offset += unitBytes
            }
        }
        return output
    }
}

extension SourceTextEncoding {
    var foundation: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .utf16LittleEndian: .utf16LittleEndian
        case .utf16BigEndian: .utf16BigEndian
        case .cp932: TextEncoding.cp932
        case .eucJP: .japaneseEUC
        }
    }
}
