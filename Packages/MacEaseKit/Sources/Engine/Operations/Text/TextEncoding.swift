import CoreFoundation
import Foundation

enum TextEncoding {
    static let cp932 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let utf16LittleEndianBOM: [UInt8] = [0xFF, 0xFE]
    private static let utf16BigEndianBOM: [UInt8] = [0xFE, 0xFF]
    private static let carriageReturn: UInt8 = 0x0D
    private static let lineFeed: UInt8 = 0x0A
    private static let byteWidth: UInt16 = 8
    private static let lowByteMask: UInt16 = 0xFF
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
        unmappable: UnmappablePolicy
    ) throws -> (data: Data, encoding: String.Encoding) {
        switch target {
        case .utf8: (Data(text.utf8), .utf8)
        case .utf8BOM: (Data(utf8BOM + text.utf8), .utf8)
        case .utf16: (Data(utf16LittleEndianBOM + bytes(of: Array(text.utf16), bigEndian: false)), .utf16)
        case .shiftJIS: (try cp932Data(text, unmappable: unmappable), cp932)
        }
    }

    /// Multibyte units never contain CR or LF.
    static func normalizingLineEndings(
        _ data: Data,
        to ending: LineEnding
    ) throws -> (data: Data, encoding: String.Encoding) {
        let decoded = try decodingAmbiguous(data)
        let endingBytes = ending == .crlf ? [carriageReturn, lineFeed] : [lineFeed]
        switch decoded.source {
        case .utf16LittleEndian, .utf16BigEndian:
            let bigEndian = decoded.source == .utf16BigEndian
            let units = Array(decoded.text.utf16)
            let normalizedUnits = normalized(units, ending: endingBytes.map(UInt16.init))
            let bom = bigEndian ? utf16BigEndianBOM : utf16LittleEndianBOM
            return (Data(bom + bytes(of: normalizedUnits, bigEndian: bigEndian)), decoded.source.foundation)
        case .utf8, .cp932, .eucJP:
            return (Data(normalized(Array(data), ending: endingBytes)), decoded.source.foundation)
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

    private static func cp932Data(_ text: String, unmappable: UnmappablePolicy) throws -> Data {
        if let data = text.data(using: cp932) { return data }
        var data = Data()
        var line = 1
        for character in text {
            if let bytes = String(character).data(using: cp932) {
                data.append(bytes)
            } else {
                switch unmappable {
                case .fail:
                    throw EngineError.invalidInput(.unmappableCharacter(line: line))
                case .questionMark:
                    data.append(UInt8(ascii: "?"))
                case .numericReference:
                    for scalar in character.unicodeScalars { data.append(contentsOf: "&#\(scalar.value);".utf8) }
                }
            }
            if character.isNewline { line += 1 }
        }
        return data
    }

    private static func normalized<Unit: FixedWidthInteger>(_ units: [Unit], ending: [Unit]) -> [Unit] {
        let carriageReturn = Unit(Self.carriageReturn)
        let lineFeed = Unit(Self.lineFeed)
        var result: [Unit] = []
        result.reserveCapacity(units.count)
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit == carriageReturn || unit == lineFeed {
                result += ending
                if unit == carriageReturn, index + 1 < units.count, units[index + 1] == lineFeed { index += 1 }
            } else {
                result.append(unit)
            }
            index += 1
        }
        return result
    }

    private static func bytes(of units: [UInt16], bigEndian: Bool) -> [UInt8] {
        units.flatMap { unit in
            let high = UInt8(unit >> byteWidth)
            let low = UInt8(unit & lowByteMask)
            return bigEndian ? [high, low] : [low, high]
        }
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
