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
    private static let textPresentationValue: UInt32 = 0xFE0E
    private static let emojiPresentationValue: UInt32 = 0xFE0F
    private static let byteOrderMarkValue: UInt32 = 0xFEFF
    private static let halfwidthHangulFillerValue: UInt32 = 0xFFA0
    private static let interlinearStart: UInt32 = 0xFFF9
    private static let interlinearEnd: UInt32 = 0xFFFB
    private static let blackFlagValue: UInt32 = 0x1F3F4
    private static let tagStartValue: UInt32 = 0xE0000
    private static let tagDigits: ClosedRange<UInt32> = 0xE0030...0xE0039
    private static let tagLowercaseLetters: ClosedRange<UInt32> = 0xE0061...0xE007A
    private static let tagCancelValue: UInt32 = 0xE007F
    private static let ideographicVSStart: UInt32 = 0xE0100
    private static let ideographicVSEnd: UInt32 = 0xE01EF
    // Subdivision flags: two letters, then 1–4 more.
    private static let subdivisionRegionTags = 2
    private static let subdivisionSuffixTags = 1...4
    private static let keycapBases = Set("0123456789#*".unicodeScalars)

    static func scan(prefix: Substring, language: PreviewLanguage) throws -> [PreviewInvisibleCharacter] {
        try scan(prefix, language: language, startsFile: true, checkpoint: Task.checkCancellation)
    }

    // Short strings finish before any checkpoint.
    static func flagged(in text: Substring, startsFile: Bool) -> [PreviewInvisibleCharacter] {
        scan(text, language: .plain, startsFile: startsFile) {}
    }

    // Reorders text or hides readable text.
    static func altersReading(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (bidiEmbedStart...bidiOverrideEnd).contains(value)
            || (bidiIsolateStart...bidiIsolateEnd).contains(value)
            || (tagStartValue...tagCancelValue).contains(value)
    }

    private static func scan(
        _ prefix: Substring, language: PreviewLanguage, startsFile: Bool, checkpoint: () throws -> Void
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
        var strongBeforeIsRTL: Bool?
        var strongAfter: (index: String.UnicodeScalarView.Index, isRTL: Bool?) = (scalars.startIndex, nil)
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
                strongBeforeIsRTL = nil
            } else if value == blackFlagValue, let tagEnd = subdivisionFlagEnd(in: scalars, from: nextIndex) {
                exemptTagEnd = tagEnd
            } else if index >= exemptTagEnd, value < spaceValue || value >= deleteValue {
                let nextScalar: Unicode.Scalar? = nextIndex < scalars.endIndex ? scalars[nextIndex] : nil
                let flagged = shouldFlag(
                    scalar,
                    atFileStart: startsFile && utf16Offset == 0,
                    previous: previous,
                    next: nextScalar,
                    isProse: isProse,
                    lineHasRTL: {
                        if let cached = cachedLineHasRTL { return cached }
                        let computed = lineContainsRTL(in: scalars, from: lineStart)
                        cachedLineHasRTL = computed
                        return computed
                    },
                    strongNeighborsAreRTL: {
                        // The forward search never moves back.
                        if strongAfter.index <= index {
                            strongAfter = nextStrongDirection(in: scalars, after: index)
                        }
                        return strongBeforeIsRTL == true && strongAfter.isRTL == true
                    })
                if flagged {
                    results.append(
                        PreviewInvisibleCharacter(
                            range: NSRange(location: utf16Offset, length: width),
                            scalar: scalar))
                }
            }

            if !isProse, let isRTL = strongDirectionIsRTL(scalar) { strongBeforeIsRTL = isRTL }
            previous = scalar
            utf16Offset += width
            index = nextIndex
        }
        return results
    }

    // The one place deciding context-dependent characters.
    private static func shouldFlag(
        _ scalar: Unicode.Scalar,
        atFileStart: Bool,
        previous: Unicode.Scalar?,
        next: Unicode.Scalar?,
        isProse: Bool,
        lineHasRTL: () -> Bool,
        strongNeighborsAreRTL: () -> Bool
    ) -> Bool {
        let value = scalar.value
        if isAlwaysFlagged(value) { return true }
        if value == byteOrderMarkValue { return !atFileStart }
        if (variationSelectorStart...emojiPresentationValue).contains(value) {
            return !canCarryStandardVariation(value, after: previous)
        }
        if (ideographicVSStart...ideographicVSEnd).contains(value) {
            return !(previous?.properties.isIdeographic ?? false)
        }
        if value == zeroWidthSpaceValue {
            // Thai, Khmer, Japanese prose uses it.
            return !(isProse && isNonASCIILetterOrMark(previous) && isNonASCIILetterOrMark(next))
        }
        if value == zeroWidthJoinerValue || value == zeroWidthNonJoinerValue {
            return !isOrthographicJoin(previous, next)
        }
        if value == leftToRightMarkValue || value == rightToLeftMarkValue || value == arabicLetterMarkValue {
            guard isProse else { return !strongNeighborsAreRTL() }
            if isASCIILetter(previous) || isASCIILetter(next) { return true }
            return !lineHasRTL()
        }
        if value == softHyphenValue {
            if isProse {
                return !(previous?.properties.isAlphabetic ?? false) || !(next?.properties.isAlphabetic ?? false)
            }
            return (previous?.isASCII ?? false) || (next?.isASCII ?? false)
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

    private static func subdivisionFlagEnd(
        in scalars: Substring.UnicodeScalarView, from start: String.UnicodeScalarView.Index
    ) -> String.UnicodeScalarView.Index? {
        var cursor = start
        var tagCount = 0
        while cursor < scalars.endIndex, tagCount < subdivisionRegionTags + subdivisionSuffixTags.upperBound {
            let value = scalars[cursor].value
            let isRegionTag = tagCount < subdivisionRegionTags
            guard tagLowercaseLetters.contains(value) || (!isRegionTag && tagDigits.contains(value)) else { break }
            tagCount += 1
            cursor = scalars.index(after: cursor)
        }
        guard subdivisionSuffixTags.contains(tagCount - subdivisionRegionTags), cursor < scalars.endIndex,
            scalars[cursor].value == tagCancelValue
        else { return nil }
        return scalars.index(after: cursor)
    }

    // ASCII bases take only keycap presentation selectors.
    private static func canCarryStandardVariation(_ selector: UInt32, after previous: Unicode.Scalar?) -> Bool {
        guard let previous else { return false }
        if previous.isASCII {
            return keycapBases.contains(previous)
                && (selector == textPresentationValue || selector == emojiPresentationValue)
        }
        let properties = previous.properties
        return !properties.isWhitespace && !properties.isDefaultIgnorableCodePoint
            && !isAlwaysFlagged(previous.value)
    }

    // Viramas, right-to-left letters and emoji sequences.
    private static func isOrthographicJoin(_ previous: Unicode.Scalar?, _ next: Unicode.Scalar?) -> Bool {
        func isVirama(_ scalar: Unicode.Scalar?) -> Bool { scalar?.properties.canonicalCombiningClass == .virama }
        func isRTLLetter(_ scalar: Unicode.Scalar?) -> Bool { scalar.flatMap(strongDirectionIsRTL) == true }
        func isEmojiPart(_ scalar: Unicode.Scalar?) -> Bool {
            guard let scalar, !scalar.isASCII else { return false }
            return scalar.properties.isEmoji || scalar.value == emojiPresentationValue
        }
        return isVirama(previous) || isVirama(next) || isRTLLetter(previous) || isRTLLetter(next)
            || (isEmojiPart(previous) && isEmojiPart(next))
    }

    private static func isNonASCIILetterOrMark(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar, !scalar.isASCII else { return false }
        let properties = scalar.properties
        return properties.isAlphabetic || properties.generalCategory == .spacingMark
            || properties.generalCategory == .nonspacingMark
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        return scalar.isASCII && scalar.properties.isAlphabetic
    }

    // Letters are strong; nil for weak characters.
    private static func strongDirectionIsRTL(_ scalar: Unicode.Scalar) -> Bool? {
        guard scalar.properties.isAlphabetic else { return nil }
        return isRTLScriptScalar(scalar.value)
    }

    private static func nextStrongDirection(
        in scalars: Substring.UnicodeScalarView, after index: String.UnicodeScalarView.Index
    ) -> (index: String.UnicodeScalarView.Index, isRTL: Bool?) {
        var cursor = scalars.index(after: index)
        while cursor < scalars.endIndex {
            let scalar = scalars[cursor]
            if scalar.value == lineFeedValue || scalar.value == carriageReturnValue { break }
            if let isRTL = strongDirectionIsRTL(scalar) { return (cursor, isRTL) }
            cursor = scalars.index(after: cursor)
        }
        return (cursor, nil)
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
            0xFE70...0xFEFE,
            0x10800...0x10FFF,
            0x1E800...0x1EFFF:
            return true
        default:
            return false
        }
    }
}
