import CoreFoundation
import Foundation

public enum TextEncoding {
    public static func detectedString(from bytes: Data) throws -> String {
        if let text = decodeUTF32BOM(bytes) { return text }
        do {
            return try decode(bytes).text
        } catch EngineError.invalidInput(.textEncodingUndetected) {
            if let text = detectPreviewFallback(bytes) { return text }
            throw EngineError.invalidInput(.textEncodingUndetected)
        }
    }

    public static func strictString(from bytes: Data, encoding: String.Encoding) throws -> String {
        switch encoding {
        case .utf16, .utf16LittleEndian, .utf16BigEndian:
            // Foundation ignores a trailing UTF-16 byte.
            guard bytes.count.isMultiple(of: MemoryLayout<UInt16>.size) else {
                throw EngineError.invalidInput(.textEncodingUndetected)
            }
        case .utf32, .utf32LittleEndian, .utf32BigEndian:
            guard bytes.count.isMultiple(of: MemoryLayout<UInt32>.size) else {
                throw EngineError.invalidInput(.textEncodingUndetected)
            }
        default: break
        }
        guard let text = String(data: bytes, encoding: encoding) else {
            throw EngineError.invalidInput(.textEncodingUndetected)
        }
        return text
    }

    /// True if a viewer encoding decodes text.
    public static func hasPlausibleTextDecoding(_ bytes: [UInt8], truncated: Bool = false) -> Bool {
        plausibleDecodedText(from: bytes, truncated: truncated) != nil
    }

    static func plausibleBOMText(from bytes: [UInt8], truncated: Bool = false) -> String? {
        decodeBOMText(bytes, truncated: truncated)
    }

    static func plausibleDecodedText(from bytes: [UInt8], truncated: Bool = false) -> String? {
        guard !bytes.isEmpty else { return nil }
        if let text = decodeBOMText(bytes, truncated: truncated) { return text }
        if !bytes.contains(where: { $0 < firstPrintableByte && !allowedByteControls.contains($0) }) {
            if bytes.contains(escapeByte) {
                if let text = decodeWithSuffixTrim(bytes, encoding: .iso2022JP, maxTrim: truncated ? 3 : 0),
                    isPlausibleText(text)
                {
                    return text
                }
            }
            for (encoding, maxTrim) in byteOrientedCandidates {
                if let text = decodeWithSuffixTrim(bytes, encoding: encoding, maxTrim: truncated ? maxTrim : 0),
                    isPlausibleText(text)
                {
                    return text
                }
            }
        }
        if let text = decodeBOMLessUTF32(bytes, littleEndian: true, truncated: truncated) { return text }
        if let text = decodeBOMLessUTF32(bytes, littleEndian: false, truncated: truncated) { return text }
        if let text = decodeBOMLessUTF16(bytes, littleEndian: true, truncated: truncated) { return text }
        if let text = decodeBOMLessUTF16(bytes, littleEndian: false, truncated: truncated) { return text }
        return nil
    }

    static let cp932 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let utf16LittleEndianBOM: [UInt8] = [0xFF, 0xFE]
    private static let utf16BigEndianBOM: [UInt8] = [0xFE, 0xFF]
    private static let utf32LittleEndianBOM: [UInt8] = [0xFF, 0xFE, 0x00, 0x00]
    private static let utf32BigEndianBOM: [UInt8] = [0x00, 0x00, 0xFE, 0xFF]
    private static let carriageReturn: UInt8 = 0x0D
    private static let lineFeed: UInt8 = 0x0A
    private static let escapeByte: UInt8 = 0x1B
    private static let firstPrintableByte: UInt8 = 0x20
    private static let allowedByteControls: Set<UInt8> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1B]
    private static let allowedTextControls: Set<UInt32> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D]
    private static let disallowedCategories: Set<Unicode.GeneralCategory> = [
        .control, .privateUse, .surrogate, .unassigned,
    ]
    private static let minimumCoherentScriptShare = 0.85
    private static let multiBucketScalarThreshold = 4
    private static let legacyCandidates: [SourceTextEncoding] = [.cp932, .eucJP]
    private static let byteOrientedCandidates: [(String.Encoding, Int)] = [
        (.utf8, 3), (cp932, 1), (.japaneseEUC, 2), (.windowsCP1252, 0), (.isoLatin1, 0),
    ]

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
        substitute: String = "?",
        startingLine: Int = 1
    ) throws -> (data: Data, encoding: String.Encoding, replaced: Bool) {
        switch target {
        case .utf8: return (Data(text.utf8), .utf8, false)
        case .utf8BOM: return (Data(utf8BOM + text.utf8), .utf8, false)
        case .utf16: return (utf16Data(text.utf16, bigEndian: false), .utf16, false)
        case .shiftJIS:
            let result = try cp932Data(text, unmappable: unmappable, substitute: substitute, startingLine: startingLine)
            return (result.data, cp932, result.replaced)
        }
    }

    private static func decode(_ data: Data, as source: SourceTextEncoding) throws -> Decoded {
        try Decoded(text: strictString(from: data, encoding: source.foundation), source: source)
    }

    static func byteOrderMark(of data: Data) -> (SourceTextEncoding, Int)? {
        if data.starts(with: utf8BOM) { return (.utf8, utf8BOM.count) }
        if data.starts(with: utf16LittleEndianBOM) { return (.utf16LittleEndian, utf16LittleEndianBOM.count) }
        if data.starts(with: utf16BigEndianBOM) { return (.utf16BigEndian, utf16BigEndianBOM.count) }
        return nil
    }

    public static func isValidShiftJISSubstitute(_ substitute: String) -> Bool {
        substitute.unicodeScalars.count == 1 && substitute.data(using: cp932) != nil
    }

    private static func cp932Data(
        _ text: String, unmappable: UnmappablePolicy, substitute: String, startingLine: Int
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
        var line = startingLine
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

    @inline(__always)
    static func normalized<Output: RangeReplaceableCollection>(
        _ units: some Collection<Output.Element>, ending: [Output.Element], afterCarriageReturn: inout Bool
    ) -> Output where Output.Element: FixedWidthInteger {
        let carriageReturn = Output.Element(Self.carriageReturn)
        let lineFeed = Output.Element(Self.lineFeed)
        var result = Output()
        // Untouched capacity stays virtual; regrowth copies everything.
        result.reserveCapacity(units.count * ending.count)
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

    static func utf16Data(_ units: some Collection<UInt16>, bigEndian: Bool) -> Data {
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

    private static func decodeUTF32BOM(_ data: Data) -> String? {
        if data.starts(with: utf32LittleEndianBOM) {
            return try? strictString(
                from: Data(data.dropFirst(utf32LittleEndianBOM.count)), encoding: .utf32LittleEndian)
        }
        if data.starts(with: utf32BigEndianBOM) {
            return try? strictString(from: Data(data.dropFirst(utf32BigEndianBOM.count)), encoding: .utf32BigEndian)
        }
        return nil
    }

    private static func detectPreviewFallback(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        if bytes.contains(escapeByte),
            !bytes.contains(where: { $0 < firstPrintableByte && !allowedByteControls.contains($0) }),
            let text = try? strictString(from: data, encoding: .iso2022JP),
            isPlausibleText(text)
        {
            return text
        }
        let utf32LE = decodeBOMLessUTF32(bytes, littleEndian: true, truncated: false)
        let utf32BE = decodeBOMLessUTF32(bytes, littleEndian: false, truncated: false)
        if let text = utf32LE, utf32BE == nil { return text }
        if let text = utf32BE, utf32LE == nil { return text }
        let utf16LE = decodeBOMLessUTF16(bytes, littleEndian: true, truncated: false)
        let utf16BE = decodeBOMLessUTF16(bytes, littleEndian: false, truncated: false)
        if let text = utf16LE, utf16BE == nil { return text }
        if let text = utf16BE, utf16LE == nil { return text }
        return nil
    }

    private static func decodeBOMText(_ bytes: [UInt8], truncated: Bool) -> String? {
        if bytes.starts(with: utf32LittleEndianBOM) {
            let body = Array(bytes.dropFirst(utf32LittleEndianBOM.count))
            return body.isEmpty ? "" : decodeUTF32Body(body, littleEndian: true, truncated: truncated)
        }
        if bytes.starts(with: utf32BigEndianBOM) {
            let body = Array(bytes.dropFirst(utf32BigEndianBOM.count))
            return body.isEmpty ? "" : decodeUTF32Body(body, littleEndian: false, truncated: truncated)
        }
        if bytes.starts(with: utf16LittleEndianBOM) {
            let body = Array(bytes.dropFirst(utf16LittleEndianBOM.count))
            return body.isEmpty
                ? "" : decodeUTF16Body(body, littleEndian: true, truncated: truncated, requireCoherence: false)
        }
        if bytes.starts(with: utf16BigEndianBOM) {
            let body = Array(bytes.dropFirst(utf16BigEndianBOM.count))
            return body.isEmpty
                ? "" : decodeUTF16Body(body, littleEndian: false, truncated: truncated, requireCoherence: false)
        }
        if bytes.starts(with: utf8BOM) {
            let body = Array(bytes.dropFirst(utf8BOM.count))
            guard !body.isEmpty else { return "" }
            guard let text = decodeWithSuffixTrim(body, encoding: .utf8, maxTrim: truncated ? 3 : 0),
                isPlausibleText(text)
            else { return nil }
            return text
        }
        return nil
    }

    private static func decodeWithSuffixTrim(_ bytes: [UInt8], encoding: String.Encoding, maxTrim: Int) -> String? {
        for trim in 0...min(maxTrim, max(0, bytes.count - 1)) {
            let slice = trim == 0 ? Data(bytes) : Data(bytes.dropLast(trim))
            if let text = try? strictString(from: slice, encoding: encoding) {
                return text
            }
        }
        return nil
    }

    private static func decodeBOMLessUTF32(_ bytes: [UInt8], littleEndian: Bool, truncated: Bool) -> String? {
        decodeUTF32Body(bytes, littleEndian: littleEndian, truncated: truncated)
    }

    private static func decodeUTF32Body(_ bytes: [UInt8], littleEndian: Bool, truncated: Bool) -> String? {
        guard bytes.count >= 4 else { return nil }
        guard truncated || bytes.count.isMultiple(of: 4) else { return nil }
        let usable = bytes.count - (bytes.count % 4)
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(usable / 4)
        for offset in stride(from: 0, to: usable, by: 4) {
            let raw: UInt32 =
                littleEndian
                ? UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                    | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
                : UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                    | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
            guard let scalar = Unicode.Scalar(raw), isPlausibleScalar(scalar) else { return nil }
            scalars.append(scalar)
        }
        guard !scalars.isEmpty else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func decodeBOMLessUTF16(_ bytes: [UInt8], littleEndian: Bool, truncated: Bool) -> String? {
        decodeUTF16Body(bytes, littleEndian: littleEndian, truncated: truncated, requireCoherence: true)
    }

    private static func decodeUTF16Body(
        _ bytes: [UInt8], littleEndian: Bool, truncated: Bool, requireCoherence: Bool
    ) -> String? {
        guard bytes.count >= 2 else { return nil }
        guard truncated || bytes.count.isMultiple(of: 2) else { return nil }
        let usable = bytes.count - (bytes.count % 2)
        var units = stride(from: 0, to: usable, by: 2).map { offset in
            littleEndian
                ? UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                : UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }
        if truncated, let last = units.last, UTF16.isLeadSurrogate(last) { units.removeLast() }
        guard !units.isEmpty else { return nil }
        var iterator = units.makeIterator()
        var decoder = UTF16()
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(units.count)
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                guard isPlausibleScalar(scalar) else { return nil }
                scalars.append(scalar)
            case .emptyInput:
                guard !scalars.isEmpty else { return nil }
                if requireCoherence, !hasCoherentScripts(scalars) { return nil }
                return String(String.UnicodeScalarView(scalars))
            case .error:
                return nil
            }
        }
    }

    private static func isPlausibleText(_ text: String) -> Bool {
        !text.unicodeScalars.isEmpty && text.unicodeScalars.allSatisfy(isPlausibleScalar)
    }

    private static func isPlausibleScalar(_ scalar: Unicode.Scalar) -> Bool {
        if allowedTextControls.contains(scalar.value) { return true }
        if scalar.value == 0xFFFD { return false }
        return !disallowedCategories.contains(scalar.properties.generalCategory)
    }

    // Separates BOM-less UTF-16 scripts from random bytes.
    private static func hasCoherentScripts(_ scalars: [Unicode.Scalar]) -> Bool {
        var neutral = 0
        var buckets: [UInt32: Int] = [:]
        for scalar in scalars {
            if isScriptNeutral(scalar) {
                neutral += 1
            } else {
                buckets[scriptBucket(for: scalar), default: 0] += 1
            }
        }
        guard !buckets.isEmpty else { return true }
        let allowedBuckets = scalars.count < multiBucketScalarThreshold ? 1 : 2
        let top = buckets.values.sorted(by: >).prefix(allowedBuckets).reduce(0, +)
        return Double(neutral + top) >= Double(scalars.count) * minimumCoherentScriptShare
    }

    private static func isScriptNeutral(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x80 || scalar.properties.isWhitespace || scalar.properties.isEmoji { return true }
        if (0x2000...0x206F).contains(value) || (0x3000...0x303F).contains(value)
            || (0xFE00...0xFE0F).contains(value) || (0xFF00...0xFFEF).contains(value)
        {
            return true
        }
        return scalar.properties.generalCategory == .format
    }

    private static func scriptBucket(for scalar: Unicode.Scalar) -> UInt32 {
        let value = scalar.value
        if (0x0080...0x024F).contains(value) || (0x1E00...0x1EFF).contains(value) { return 0x0080 }
        if (0x3040...0x30FF).contains(value) || (0x31F0...0x31FF).contains(value)
            || (0x3400...0x4DBF).contains(value) || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value) || (0x20000...0x2FA1F).contains(value)
        {
            return 0x4E00
        }
        if (0x1100...0x11FF).contains(value) || (0x3130...0x318F).contains(value)
            || (0xAC00...0xD7AF).contains(value)
        {
            return 0xAC00
        }
        return value >> 8
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
