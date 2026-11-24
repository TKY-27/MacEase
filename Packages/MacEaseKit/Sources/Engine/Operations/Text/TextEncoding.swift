import CoreFoundation
import Foundation

public enum TextEncoding {
    public static func detectedString(from bytes: Data, truncated: Bool = false) throws -> String {
        if bytes.isEmpty { return "" }
        if let text = plausibleDecodedText(from: [UInt8](bytes), truncated: truncated) {
            return text
        }
        throw EngineError.invalidInput(.textEncodingUndetected)
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
        if hasByteOrderMark(bytes) {
            return decodeBOMText(bytes, truncated: truncated)
        }
        if bytes.contains(0) {
            if let text = chooseUTF32(bytes, truncated: truncated) { return text }
            let le = decodeUTF16Candidate(bytes, littleEndian: true, truncated: truncated, checkLowControls: true)
            let be = decodeUTF16Candidate(bytes, littleEndian: false, truncated: truncated, checkLowControls: true)
            return chooseUTF16(le, be)?.text
        }
        let le = decodeUTF16Candidate(bytes, littleEndian: true, truncated: truncated, checkLowControls: true)
        let be = decodeUTF16Candidate(bytes, littleEndian: false, truncated: truncated, checkLowControls: true)
        if !bytes.contains(where: isRawControl) {
            // Alternating 0x09 lane indicates BOM-less Devanagari UTF-16.
            if bytes.count >= 6, bytes.count.isMultiple(of: 2) {
                let evenTabs = stride(from: 0, to: bytes.count, by: 2).allSatisfy { bytes[$0] == tabByte }
                let oddTabs = stride(from: 1, to: bytes.count, by: 2).allSatisfy { bytes[$0] == tabByte }
                if oddTabs, !evenTabs, let candidate = le { return candidate.text }
                if evenTabs, !oddTabs, let candidate = be { return candidate.text }
            }
            if bytes.contains(escapeByte),
                let text = decodeWithSuffixTrim(bytes, encoding: .iso2022JP, maxTrim: truncated ? 3 : 0),
                isPlausibleText(text)
            {
                return text
            }
            if let text = decodeUTF8(bytes, truncated: truncated), isPlausibleText(text) {
                return text
            }
            if let candidate = le, candidate.hasSurrogatePairs, !(be?.hasSurrogatePairs ?? false) {
                return candidate.text
            }
            if let candidate = be, candidate.hasSurrogatePairs, !(le?.hasSurrogatePairs ?? false) {
                return candidate.text
            }
            let cp932Text = decodeWithSuffixTrim(bytes, encoding: cp932, maxTrim: truncated ? 1 : 0)
                .flatMap { isPlausibleText($0) ? $0 : nil }
            let eucText = decodeWithSuffixTrim(bytes, encoding: .japaneseEUC, maxTrim: truncated ? 2 : 0)
                .flatMap { isPlausibleText($0) ? $0 : nil }
            if let cp932Text, eucText == nil {
                // Reject halfwidth-katakana CP932 artifacts when UTF-16 matches.
                if cp932Text.unicodeScalars.contains(where: { (0xFF61...0xFF9F).contains($0.value) }),
                    let chosen = chooseUTF16(le, be),
                    chosen.distinctHighBytes * 2 <= chosen.distinctLowBytes
                {
                    return chosen.text
                }
                return cp932Text
            }
            if let eucText, cp932Text == nil { return eucText }
            if let cp932Text { return cp932Text }
            if let text = try? strictString(from: Data(bytes), encoding: .windowsCP1252), isPlausibleText(text) {
                return text
            }
            if let text = try? strictString(from: Data(bytes), encoding: .isoLatin1), isPlausibleText(text) {
                return text
            }
        }
        return chooseUTF16(le, be)?.text
    }

    static let cp932 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let utf16LittleEndianBOM: [UInt8] = [0xFF, 0xFE]
    private static let utf16BigEndianBOM: [UInt8] = [0xFE, 0xFF]
    private static let utf32LittleEndianBOM: [UInt8] = [0xFF, 0xFE, 0x00, 0x00]
    private static let utf32BigEndianBOM: [UInt8] = [0x00, 0x00, 0xFE, 0xFF]
    private static let tabByte: UInt8 = 0x09
    private static let carriageReturn: UInt8 = 0x0D
    private static let lineFeed: UInt8 = 0x0A
    private static let escapeByte: UInt8 = 0x1B
    private static let firstPrintableByte: UInt8 = 0x20
    private static let allowedByteControls: Set<UInt8> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1B]
    private static let allowedTextControls: Set<UInt32> = [0x09, 0x0A, 0x0B, 0x0C, 0x0D]
    private static let disallowedCategories: Set<Unicode.GeneralCategory> = [
        .control, .privateUse, .surrogate, .unassigned,
    ]
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

    private struct UTF16Candidate {
        let text: String
        let hasSurrogatePairs: Bool
        let highNuls: Int
        let distinctHighBytes: Int
        let distinctLowBytes: Int
    }

    private static func hasByteOrderMark(_ bytes: [UInt8]) -> Bool {
        bytes.starts(with: utf32LittleEndianBOM) || bytes.starts(with: utf32BigEndianBOM)
            || bytes.starts(with: utf16LittleEndianBOM) || bytes.starts(with: utf16BigEndianBOM)
            || bytes.starts(with: utf8BOM)
    }

    private static func isRawControl(_ byte: UInt8) -> Bool {
        byte < firstPrintableByte && !allowedByteControls.contains(byte)
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
                ? ""
                : decodeUTF16Candidate(body, littleEndian: true, truncated: truncated, checkLowControls: false)?.text
        }
        if bytes.starts(with: utf16BigEndianBOM) {
            let body = Array(bytes.dropFirst(utf16BigEndianBOM.count))
            return body.isEmpty
                ? ""
                : decodeUTF16Candidate(body, littleEndian: false, truncated: truncated, checkLowControls: false)?.text
        }
        if bytes.starts(with: utf8BOM) {
            let body = Array(bytes.dropFirst(utf8BOM.count))
            guard !body.isEmpty else { return "" }
            guard let text = decodeUTF8(body, truncated: truncated), isPlausibleText(text) else { return nil }
            return text
        }
        return nil
    }

    private static func decodeUTF8(_ bytes: [UInt8], truncated: Bool) -> String? {
        let trim = truncated ? incompleteUTF8SuffixLength(bytes) : 0
        let slice = trim == 0 ? Data(bytes) : Data(bytes.dropLast(trim))
        return String(data: slice, encoding: .utf8)
    }

    private static func incompleteUTF8SuffixLength(_ bytes: [UInt8]) -> Int {
        let tail = Array(bytes.suffix(4))
        guard let start = tail.lastIndex(where: { $0 & 0xC0 != 0x80 }) else { return 0 }
        let lead = tail[start]
        let required: Int
        switch lead {
        case 0xC2...0xDF: required = 2
        case 0xE0...0xEF: required = 3
        case 0xF0...0xF4: required = 4
        default: return 0
        }
        let count = tail.count - start
        guard count < required else { return 0 }
        if count > 1 {
            let second = tail[start + 1]
            if (lead == 0xE0 && second < 0xA0) || (lead == 0xED && second > 0x9F)
                || (lead == 0xF0 && second < 0x90) || (lead == 0xF4 && second > 0x8F)
            {
                return 0
            }
        }
        return count
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

    private static func chooseUTF32(_ bytes: [UInt8], truncated: Bool) -> String? {
        let le = decodeUTF32Body(bytes, littleEndian: true, truncated: truncated)
        let be = decodeUTF32Body(bytes, littleEndian: false, truncated: truncated)
        if let le, be == nil { return le }
        if let be, le == nil { return be }
        return le
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

    private static func chooseUTF16(_ le: UTF16Candidate?, _ be: UTF16Candidate?) -> UTF16Candidate? {
        switch (le, be) {
        case (let candidate?, nil): return candidate
        case (nil, let candidate?): return candidate
        case (nil, nil): return nil
        case (let left?, let right?):
            if left.hasSurrogatePairs != right.hasSurrogatePairs {
                return left.hasSurrogatePairs ? left : right
            }
            if left.highNuls != right.highNuls {
                return left.highNuls > right.highNuls ? left : right
            }
            if left.distinctHighBytes != right.distinctHighBytes {
                return left.distinctHighBytes < right.distinctHighBytes ? left : right
            }
            return nil
        }
    }

    private static func decodeUTF16Candidate(
        _ bytes: [UInt8], littleEndian: Bool, truncated: Bool, checkLowControls: Bool
    ) -> UTF16Candidate? {
        guard bytes.count >= 2 else { return nil }
        guard truncated || bytes.count.isMultiple(of: 2) else { return nil }
        let usable = bytes.count - (bytes.count % 2)
        let unitCount = usable / 2
        var units: [UInt16] = []
        units.reserveCapacity(unitCount)
        var lowControls = 0
        var highNuls = 0
        var distinctHigh: Set<UInt8> = []
        var distinctLow: Set<UInt8> = []
        for offset in stride(from: 0, to: usable, by: 2) {
            let low = littleEndian ? bytes[offset] : bytes[offset + 1]
            let high = littleEndian ? bytes[offset + 1] : bytes[offset]
            if isRawControl(low) { lowControls += 1 }
            if high == 0 { highNuls += 1 }
            distinctHigh.insert(high)
            distinctLow.insert(low)
            units.append(UInt16(low) | (UInt16(high) << 8))
        }
        if checkLowControls, lowControls * 2 >= unitCount { return nil }
        if truncated, let last = units.last, UTF16.isLeadSurrogate(last) { units.removeLast() }
        guard !units.isEmpty else { return nil }
        var iterator = units.makeIterator()
        var decoder = UTF16()
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(units.count)
        var hasSurrogatePairs = false
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                guard isPlausibleScalar(scalar) else { return nil }
                if scalar.value > 0xFFFF { hasSurrogatePairs = true }
                scalars.append(scalar)
            case .emptyInput:
                guard !scalars.isEmpty else { return nil }
                return UTF16Candidate(
                    text: String(String.UnicodeScalarView(scalars)),
                    hasSurrogatePairs: hasSurrogatePairs,
                    highNuls: highNuls,
                    distinctHighBytes: distinctHigh.count,
                    distinctLowBytes: distinctLow.count)
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
