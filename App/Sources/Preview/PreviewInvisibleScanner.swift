import Foundation

struct PreviewInvisibleCharacter: Equatable, Sendable {
    let range: NSRange
    let scalar: Unicode.Scalar

    var codePointLabel: String {
        String(format: "U+%04X", scalar.value)
    }

    // Unicode names controls "<control>".
    var unicodeLabel: String {
        let properties = scalar.properties
        let name =
            properties.name ?? properties.nameAlias ?? (properties.generalCategory == .control ? "<control>" : nil)
        return name.map { "\(codePointLabel) \($0)" } ?? codePointLabel
    }
}

enum PreviewInvisibleScanner {
    private static let cancellationStride = 4096

    // Prose permits soft hyphens inside words.
    private static let proseLanguages: Set<PreviewLanguage> = [
        .plain, .markdown, .restructuredText, .asciiDoc, .latex, .markup,
    ]

    private static let tabValue: UInt32 = 0x09
    private static let lineFeedValue: UInt32 = 0x0A
    private static let carriageReturnValue: UInt32 = 0x0D
    private static let spaceValue: UInt32 = 0x20
    private static let deleteValue: UInt32 = 0x7F
    private static let c1EndValue: UInt32 = 0x9F
    private static let softHyphenValue: UInt32 = 0x00AD
    private static let combiningGraphemeJoinerValue: UInt32 = 0x034F
    private static let arabicLetterMarkValue: UInt32 = 0x061C
    private static let hangulChoseongFillerValue: UInt32 = 0x115F
    private static let hangulJungseongFillerValue: UInt32 = 0x1160
    private static let khmerInvisibleStart: UInt32 = 0x17B4
    private static let khmerInvisibleEnd: UInt32 = 0x17B5
    private static let mongolianVowelSeparatorValue: UInt32 = 0x180E
    private static let zeroWidthSpaceValue: UInt32 = 0x200B
    private static let zeroWidthNonJoinerValue: UInt32 = 0x200C
    private static let zeroWidthJoinerValue: UInt32 = 0x200D
    private static let leftToRightMarkValue: UInt32 = 0x200E
    private static let rightToLeftMarkValue: UInt32 = 0x200F
    private static let lineSeparatorValue: UInt32 = 0x2028
    private static let paragraphSeparatorValue: UInt32 = 0x2029
    private static let bidiEmbedStart: UInt32 = 0x202A
    private static let bidiOverrideEnd: UInt32 = 0x202E
    private static let wordJoinerValue: UInt32 = 0x2060
    private static let invisibleOperatorEnd: UInt32 = 0x2064
    private static let bidiIsolateStart: UInt32 = 0x2066
    private static let bidiIsolateEnd: UInt32 = 0x2069
    private static let brailleBlankValue: UInt32 = 0x2800
    private static let hangulFillerValue: UInt32 = 0x3164
    private static let variationSelectorStart: UInt32 = 0xFE00
    private static let variationSelectorEnd: UInt32 = 0xFE0F
    private static let byteOrderMarkValue: UInt32 = 0xFEFF
    private static let halfwidthHangulFillerValue: UInt32 = 0xFFA0
    private static let interlinearStart: UInt32 = 0xFFF9
    private static let interlinearEnd: UInt32 = 0xFFFB
    private static let blackFlagValue: UInt32 = 0x1F3F4
    private static let tagStartValue: UInt32 = 0xE0000
    private static let tagPrintableStart: UInt32 = 0xE0020
    private static let tagPrintableEnd: UInt32 = 0xE007E
    private static let tagCancelValue: UInt32 = 0xE007F
    private static let ideographicVSStart: UInt32 = 0xE0100
    private static let ideographicVSEnd: UInt32 = 0xE01EF

    static func scan(_ text: String, language: PreviewLanguage = .plain) throws -> [PreviewInvisibleCharacter] {
        try scan(prefix: PreviewTokenizer.cappedPrefix(of: text), language: language)
    }

    static func scan(prefix: Substring, language: PreviewLanguage) throws -> [PreviewInvisibleCharacter] {
        try scan(prefix, language: language, checkpoint: Task.checkCancellation)
    }

    // Short strings finish before any checkpoint.
    static func flagged(in text: Substring) -> [PreviewInvisibleCharacter] {
        scan(text, language: .plain) {}
    }

    // Reorders text or hides readable text.
    static func altersReading(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (bidiEmbedStart...bidiOverrideEnd).contains(value)
            || (bidiIsolateStart...bidiIsolateEnd).contains(value)
            || (tagStartValue...tagCancelValue).contains(value)
    }

    private static func scan(
        _ prefix: Substring, language: PreviewLanguage, checkpoint: () throws -> Void
    ) rethrows -> [PreviewInvisibleCharacter] {
        let scalars = prefix.unicodeScalars
        guard !scalars.isEmpty else { return [] }
        let isProse = proseLanguages.contains(language)
        var results: [PreviewInvisibleCharacter] = []
        var index = scalars.startIndex
        var utf16Offset = 0
        var previous: Unicode.Scalar?
        var lineStart = scalars.startIndex
        var cachedLineHasRTL: Bool?
        var exemptTagEnd = scalars.startIndex
        var step = 0

        while index < scalars.endIndex {
            step &+= 1
            if (step & (cancellationStride - 1)) == 0 { try checkpoint() }

            let scalar = scalars[index]
            let nextIndex = scalars.index(after: index)
            let width = scalar.utf16.count
            let value = scalar.value

            if value == lineFeedValue || value == carriageReturnValue {
                lineStart = nextIndex
                cachedLineHasRTL = nil
            } else if value == blackFlagValue, let tagEnd = emojiTagSequenceEnd(in: scalars, from: nextIndex) {
                exemptTagEnd = tagEnd
            } else if index >= exemptTagEnd, value < spaceValue || value >= deleteValue {
                let nextScalar: Unicode.Scalar? = nextIndex < scalars.endIndex ? scalars[nextIndex] : nil
                let flagged = shouldFlag(
                    scalar,
                    utf16Offset: utf16Offset,
                    previous: previous,
                    next: nextScalar,
                    isProse: isProse,
                    lineHasRTL: {
                        if let cached = cachedLineHasRTL { return cached }
                        let computed = lineContainsRTL(in: scalars, from: lineStart)
                        cachedLineHasRTL = computed
                        return computed
                    })
                if flagged {
                    results.append(
                        PreviewInvisibleCharacter(
                            range: NSRange(location: utf16Offset, length: width),
                            scalar: scalar))
                }
            }

            previous = scalar
            utf16Offset += width
            index = nextIndex
        }
        return results
    }

    private static func shouldFlag(
        _ scalar: Unicode.Scalar,
        utf16Offset: Int,
        previous: Unicode.Scalar?,
        next: Unicode.Scalar?,
        isProse: Bool,
        lineHasRTL: () -> Bool
    ) -> Bool {
        let value = scalar.value
        if isAlwaysFlagged(value) { return true }
        if value == byteOrderMarkValue { return utf16Offset > 0 }
        if (variationSelectorStart...variationSelectorEnd).contains(value) {
            return !canCarryStandardVariation(previous)
        }
        if (ideographicVSStart...ideographicVSEnd).contains(value) {
            return !(previous?.properties.isIdeographic ?? false)
        }
        if value == zeroWidthJoinerValue || value == zeroWidthNonJoinerValue {
            if (previous.map(isASCIIWordScalar) ?? false) || (next.map(isASCIIWordScalar) ?? false) {
                return true
            }
            return !(previous.map(isNonASCIIGraphic) ?? false) && !(next.map(isNonASCIIGraphic) ?? false)
        }
        if value == leftToRightMarkValue || value == rightToLeftMarkValue || value == arabicLetterMarkValue {
            if (previous.map(isASCIILetterScalar) ?? false) || (next.map(isASCIILetterScalar) ?? false) {
                return true
            }
            return !lineHasRTL()
        }
        if value == softHyphenValue {
            if isProse {
                return !(previous?.properties.isAlphabetic ?? false) || !(next?.properties.isAlphabetic ?? false)
            }
            return (previous.map(isASCIIScalar) ?? false) || (next.map(isASCIIScalar) ?? false)
                || !(previous?.properties.isAlphabetic ?? false) || !(next?.properties.isAlphabetic ?? false)
        }
        return false
    }

    private static func isAlwaysFlagged(_ value: UInt32) -> Bool {
        if value < spaceValue {
            return value != tabValue && value != lineFeedValue && value != carriageReturnValue
        }
        if (deleteValue...c1EndValue).contains(value) { return true }
        switch value {
        case combiningGraphemeJoinerValue,
            hangulChoseongFillerValue, hangulJungseongFillerValue,
            khmerInvisibleStart...khmerInvisibleEnd,
            mongolianVowelSeparatorValue,
            zeroWidthSpaceValue,
            lineSeparatorValue, paragraphSeparatorValue,
            bidiEmbedStart...bidiOverrideEnd,
            wordJoinerValue...invisibleOperatorEnd,
            bidiIsolateStart...bidiIsolateEnd,
            brailleBlankValue,
            hangulFillerValue,
            halfwidthHangulFillerValue,
            interlinearStart...interlinearEnd,
            tagStartValue...tagCancelValue:
            return true
        default:
            return false
        }
    }

    private static func emojiTagSequenceEnd(
        in scalars: Substring.UnicodeScalarView, from start: String.UnicodeScalarView.Index
    ) -> String.UnicodeScalarView.Index? {
        var cursor = start
        var tagCount = 0
        while cursor < scalars.endIndex, (tagPrintableStart...tagPrintableEnd).contains(scalars[cursor].value) {
            tagCount += 1
            cursor = scalars.index(after: cursor)
        }
        guard tagCount > 0, cursor < scalars.endIndex, scalars[cursor].value == tagCancelValue else {
            return nil
        }
        return scalars.index(after: cursor)
    }

    private static func canCarryStandardVariation(_ previous: Unicode.Scalar?) -> Bool {
        guard let previous else { return false }
        let value = previous.value
        if previous.properties.isWhitespace || isASCIILetterScalar(previous) { return false }
        if isAlwaysFlagged(value) || value == byteOrderMarkValue { return false }
        if (variationSelectorStart...variationSelectorEnd).contains(value)
            || (ideographicVSStart...ideographicVSEnd).contains(value)
        {
            return false
        }
        return value >= spaceValue
    }

    private static func lineContainsRTL(
        in scalars: Substring.UnicodeScalarView, from lineStart: String.UnicodeScalarView.Index
    ) -> Bool {
        var cursor = lineStart
        while cursor < scalars.endIndex {
            let value = scalars[cursor].value
            if value == lineFeedValue || value == carriageReturnValue { break }
            if isRTLScriptScalar(value) { return true }
            cursor = scalars.index(after: cursor)
        }
        return false
    }

    private static func isRTLScriptScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x0590...0x05FF,
            0x0600...0x061B, 0x061D...0x06FF,
            0x0700...0x085F,
            0x08A0...0x08FF,
            0xFB1D...0xFDFF,
            0xFE70...0xFEFE:
            return true
        default:
            return false
        }
    }

    private static func isASCIIScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x80
    }

    private static func isASCIILetterScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
    }

    private static func isASCIIWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return isASCIILetterScalar(scalar) || (0x30...0x39).contains(value) || value == 0x5F
    }

    private static func isNonASCIIGraphic(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        guard value >= 0x80, !scalar.properties.isWhitespace else { return false }
        if isAlwaysFlagged(value) || value == byteOrderMarkValue { return false }
        switch value {
        case softHyphenValue, arabicLetterMarkValue,
            zeroWidthNonJoinerValue, zeroWidthJoinerValue,
            leftToRightMarkValue, rightToLeftMarkValue:
            return false
        default:
            return true
        }
    }
}
