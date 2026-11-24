import Foundation

extension PreviewTokenizer {
    private static let maximumDelimiterLength = 16
    private static let maximumHeredocTagLength = 32
    private static let maximumUnicodeEscapeDigits = 6
    private static let maximumMarkdownHeadingLevel = 6
    private static let maximumAsciiDocHeadingLevel = 6
    private static let minimumMarkdownFenceLength = 3
    private static let minimumRstAdornmentLength = 3
    private static let minimumAsciiDocFenceLength = 4
    private static let rstAdornments: Set<UInt16> = Set("=-~^+*#\"`:.'_".utf16)

    static func scanLetterPrefixedString(
        _ buffer: UnsafeBufferPointer<UInt16>,
        from start: Int,
        previous: UInt16?,
        grammar: PreviewLanguageGrammar
    ) -> Int? {
        guard !(previous.map(isPlainIdentifier) ?? false) else { return nil }
        let count = buffer.count
        let unit = buffer[start]

        if grammar.rawLiteralStyle == .rustHash, unit == UTF16Code.lowerR || unit == UTF16Code.lowerB,
            let end = scanRustRawString(buffer, from: start)
        {
            return end
        }
        if grammar.rawLiteralStyle == .cppDelim, unit == UTF16Code.upperR,
            let end = scanCPPRawString(buffer, from: start)
        {
            return end
        }
        switch grammar.prefixedStringStyle {
        case .python:
            guard isPythonPrefixChar(unit) else { return nil }
            var quotePos = start + 1
            if quotePos < count, isPythonPrefixChar(buffer[quotePos]) { quotePos += 1 }
            guard quotePos < count,
                buffer[quotePos] == UTF16Code.doubleQuote || buffer[quotePos] == UTF16Code.singleQuote
            else { return nil }
            for rule in grammar.strings where matches(buffer, at: quotePos, rule.open) {
                return scanDelimited(buffer, from: quotePos, rule: rule)
            }
        case .dartRaw:
            guard unit == UTF16Code.lowerR, start + 1 < count else { return nil }
            let next = buffer[start + 1]
            guard next == UTF16Code.doubleQuote || next == UTF16Code.singleQuote else { return nil }
            for rule in [
                rawTripleDoubleQuoteRule, rawTripleSingleQuoteRule, rawDoubleQuoteRule, rawSingleQuoteRule,
            ] where matches(buffer, at: start + 1, rule.open) {
                return scanDelimited(buffer, from: start + 1, rule: rule)
            }
        case .rustBytes:
            guard unit == UTF16Code.lowerB || unit == UTF16Code.lowerC, start + 1 < count else { return nil }
            if buffer[start + 1] == UTF16Code.doubleQuote {
                return scanDelimited(buffer, from: start + 1, rule: multilineDoubleQuoteRule)
            }
            if unit == UTF16Code.lowerB, buffer[start + 1] == UTF16Code.singleQuote,
                let end = scanCharLiteral(buffer, from: start + 1)
            {
                return end
            }
        case .none, .csharpInterpolated:
            break
        }
        return nil
    }

    static func scanCSharpInterpolatedPrefix(
        _ buffer: UnsafeBufferPointer<UInt16>, from start: Int
    ) -> Int? {
        let count = buffer.count
        let unit = buffer[start]
        if unit == UTF16Code.dollar, start + 2 < count,
            buffer[start + 1] == UTF16Code.atSign, buffer[start + 2] == UTF16Code.doubleQuote
        {
            return scanDelimited(buffer, from: start + 2, rule: verbatimDoubleQuoteRule)
        }
        if unit == UTF16Code.atSign, start + 2 < count,
            buffer[start + 1] == UTF16Code.dollar, buffer[start + 2] == UTF16Code.doubleQuote
        {
            return scanDelimited(buffer, from: start + 2, rule: verbatimDoubleQuoteRule)
        }
        if unit == UTF16Code.dollar, start + 1 < count, buffer[start + 1] == UTF16Code.doubleQuote {
            return scanDelimited(buffer, from: start + 1, rule: doubleQuoteRule)
        }
        return nil
    }

    static func scanCharLiteral(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let count = buffer.count
        var pos = start + 1
        guard pos < count else { return nil }
        let first = buffer[pos]
        guard first != UTF16Code.singleQuote, first != UTF16Code.lineFeed, first != UTF16Code.carriageReturn else {
            return nil
        }
        if first == UTF16Code.backslash {
            pos += 1
            guard pos < count else { return nil }
            let escaped = buffer[pos]
            if UTF16.isLeadSurrogate(escaped), pos + 1 < count, UTF16.isTrailSurrogate(buffer[pos + 1]) {
                pos += 2
            } else {
                pos += 1
            }
            if escaped == UTF16Code.lowerX {
                guard pos + 1 < count, isHexDigit(buffer[pos]), isHexDigit(buffer[pos + 1]) else { return nil }
                pos += 2
            } else if escaped == UTF16Code.lowerU, pos < count, buffer[pos] == UTF16Code.leftBrace {
                pos += 1
                var digits = 0
                while pos < count, digits < maximumUnicodeEscapeDigits, isHexDigit(buffer[pos]) {
                    pos += 1
                    digits += 1
                }
                guard digits > 0, pos < count, buffer[pos] == UTF16Code.rightBrace else { return nil }
                pos += 1
            }
        } else if UTF16.isLeadSurrogate(first), pos + 1 < count, UTF16.isTrailSurrogate(buffer[pos + 1]) {
            pos += 2
        } else {
            pos += 1
        }
        guard pos < count, buffer[pos] == UTF16Code.singleQuote else { return nil }
        return pos + 1
    }

    static func scanSwiftRawString(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let count = buffer.count
        var pos = start
        var hashes = 0
        while pos < count, hashes < maximumDelimiterLength, buffer[pos] == UTF16Code.hash {
            pos += 1
            hashes += 1
        }
        guard hashes > 0, pos < count, buffer[pos] == UTF16Code.doubleQuote else { return nil }
        let isTriple =
            pos + 2 < count
            && buffer[pos + 1] == UTF16Code.doubleQuote
            && buffer[pos + 2] == UTF16Code.doubleQuote
        pos += isTriple ? 3 : 1
        while pos < count {
            let unit = buffer[pos]
            if !isTriple, unit == UTF16Code.lineFeed || unit == UTF16Code.carriageReturn {
                return pos
            }
            if unit == UTF16Code.backslash, hasConsecutiveHashes(buffer, at: pos + 1, count: hashes) {
                pos = advanceEscaped(buffer, from: pos + hashes, limit: count)
                continue
            }
            if unit == UTF16Code.doubleQuote {
                if isTriple {
                    if pos + 2 < count, buffer[pos + 1] == UTF16Code.doubleQuote,
                        buffer[pos + 2] == UTF16Code.doubleQuote,
                        hasConsecutiveHashes(buffer, at: pos + 3, count: hashes)
                    {
                        return pos + 3 + hashes
                    }
                } else if hasConsecutiveHashes(buffer, at: pos + 1, count: hashes) {
                    return pos + 1 + hashes
                }
            }
            pos += 1
        }
        return count
    }

    private static func scanRustRawString(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let count = buffer.count
        var pos = start
        if buffer[pos] == UTF16Code.lowerB {
            pos += 1
            guard pos < count, buffer[pos] == UTF16Code.lowerR else { return nil }
        }
        pos += 1
        var hashes = 0
        while pos < count, hashes < maximumDelimiterLength, buffer[pos] == UTF16Code.hash {
            pos += 1
            hashes += 1
        }
        guard pos < count, buffer[pos] == UTF16Code.doubleQuote else { return nil }
        pos += 1
        while pos < count {
            if buffer[pos] == UTF16Code.doubleQuote, hasConsecutiveHashes(buffer, at: pos + 1, count: hashes) {
                return pos + 1 + hashes
            }
            pos += 1
        }
        return count
    }

    private static func hasConsecutiveHashes(
        _ buffer: UnsafeBufferPointer<UInt16>, at start: Int, count hashes: Int
    ) -> Bool {
        guard start + hashes <= buffer.count else { return false }
        for offset in 0..<hashes where buffer[start + offset] != UTF16Code.hash { return false }
        return true
    }

    private static func scanCPPRawString(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let count = buffer.count
        guard start + 2 < count, buffer[start + 1] == UTF16Code.doubleQuote else { return nil }
        let delimStart = start + 2
        var delimEnd = delimStart
        while delimEnd < count, delimEnd - delimStart <= maximumDelimiterLength {
            let unit = buffer[delimEnd]
            if unit == UTF16Code.leftParen { break }
            if unit == UTF16Code.space || unit == UTF16Code.tab || unit == UTF16Code.lineFeed
                || unit == UTF16Code.carriageReturn || unit == UTF16Code.rightParen || unit == UTF16Code.backslash
            {
                return nil
            }
            delimEnd += 1
        }
        guard delimEnd < count, buffer[delimEnd] == UTF16Code.leftParen else { return nil }
        let delimLength = delimEnd - delimStart
        var pos = delimEnd + 1
        while pos < count {
            if buffer[pos] == UTF16Code.rightParen, pos + delimLength + 1 < count,
                buffer[pos + delimLength + 1] == UTF16Code.doubleQuote
            {
                var matched = true
                for offset in 0..<delimLength where buffer[pos + 1 + offset] != buffer[delimStart + offset] {
                    matched = false
                    break
                }
                if matched { return pos + delimLength + 2 }
            }
            pos += 1
        }
        return count
    }

    static func scanLuaLongBracket(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let count = buffer.count
        guard start + 1 < count, buffer[start] == UTF16Code.leftBracket else { return nil }
        var pos = start + 1
        var equals = 0
        while pos < count, equals < maximumDelimiterLength, buffer[pos] == UTF16Code.equals {
            pos += 1
            equals += 1
        }
        guard pos < count, buffer[pos] == UTF16Code.leftBracket else { return nil }
        pos += 1
        while pos < count {
            if buffer[pos] == UTF16Code.rightBracket, pos + equals + 1 < count,
                buffer[pos + equals + 1] == UTF16Code.rightBracket
            {
                var matched = true
                for offset in 0..<equals where buffer[pos + 1 + offset] != UTF16Code.equals {
                    matched = false
                    break
                }
                if matched { return pos + equals + 2 }
            }
            pos += 1
        }
        return count
    }

    static func scanPowerShellHereString(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let count = buffer.count
        guard start + 2 < count else { return nil }
        let quote = buffer[start + 1]
        guard quote == UTF16Code.doubleQuote || quote == UTF16Code.singleQuote else { return nil }
        var pos = start + 2
        while pos < count, buffer[pos] == UTF16Code.space || buffer[pos] == UTF16Code.tab { pos += 1 }
        guard pos < count, buffer[pos] == UTF16Code.lineFeed || buffer[pos] == UTF16Code.carriageReturn else {
            return nil
        }
        while pos < count {
            if buffer[pos] == UTF16Code.lineFeed,
                pos + 2 < count, buffer[pos + 1] == quote, buffer[pos + 2] == UTF16Code.atSign
            {
                return pos + 3
            }
            pos += 1
        }
        return count
    }

    static func scanHeredoc(
        _ buffer: UnsafeBufferPointer<UInt16>, from start: Int, lastLineBreak: Int, quoteMayFollowSpace: Bool
    ) -> Int? {
        let count = buffer.count
        guard start + 2 < count, buffer[start + 1] == UTF16Code.lessThan else { return nil }
        var pos = start + 2
        var isTriple = false
        var stripIndent = false
        if pos < count, buffer[pos] == UTF16Code.lessThan {
            isTriple = true
            pos += 1
        } else if pos < count, buffer[pos] == UTF16Code.minus || buffer[pos] == UTF16Code.tilde {
            stripIndent = true
            pos += 1
        }
        let hadSpace = pos < count && (buffer[pos] == UTF16Code.space || buffer[pos] == UTF16Code.tab)
        while pos < count, buffer[pos] == UTF16Code.space || buffer[pos] == UTF16Code.tab { pos += 1 }
        guard pos < count else { return nil }
        let quote: UInt16?
        if buffer[pos] == UTF16Code.singleQuote || buffer[pos] == UTF16Code.doubleQuote {
            if hadSpace && !quoteMayFollowSpace { return nil }
            quote = buffer[pos]
            pos += 1
        } else {
            // Skip bitshift operators like `a << b`.
            if hadSpace && !isTriple && !stripIndent { return nil }
            quote = nil
        }
        let tagStart = pos
        var hasUpper = false
        while pos < count, pos - tagStart < maximumHeredocTagLength, isASCIIIdentifier(buffer[pos]) {
            if (UTF16Code.upperA...UTF16Code.upperZ).contains(buffer[pos]) { hasUpper = true }
            pos += 1
        }
        let tagLength = pos - tagStart
        guard tagLength > 0, isASCIILetter(buffer[tagStart]) || buffer[tagStart] == UTF16Code.underscore else {
            return nil
        }
        if let quote {
            guard pos < count, buffer[pos] == quote else { return nil }
            pos += 1
        } else if !isTriple && !stripIndent && !hasUpper {
            return nil
        }
        // Fail in O(1) on lines without newline.
        guard pos <= lastLineBreak else { return nil }
        let firstLineEnd = lineEnd(buffer, from: pos)
        guard firstLineEnd < count else { return nil }
        var lineCursor = nextLineStart(buffer, after: firstLineEnd)
        while lineCursor < count {
            let currentEnd = lineEnd(buffer, from: lineCursor)
            var checkStart = lineCursor
            if stripIndent {
                while checkStart < currentEnd,
                    buffer[checkStart] == UTF16Code.space || buffer[checkStart] == UTF16Code.tab
                {
                    checkStart += 1
                }
            }
            var checkEnd = currentEnd
            if isTriple, checkEnd > checkStart, buffer[checkEnd - 1] == UTF16Code.semicolon {
                checkEnd -= 1
            }
            if checkEnd - checkStart == tagLength {
                var matched = true
                for offset in 0..<tagLength where buffer[checkStart + offset] != buffer[tagStart + offset] {
                    matched = false
                    break
                }
                if matched { return currentEnd }
            }
            lineCursor = nextLineStart(buffer, after: currentEnd)
        }
        return count
    }

    static func isMarkdownHeading(_ buffer: UnsafeBufferPointer<UInt16>, at start: Int) -> Bool {
        let count = buffer.count
        var pos = start
        while pos < count, pos - start < maximumMarkdownHeadingLevel, buffer[pos] == UTF16Code.hash {
            pos += 1
        }
        return pos > start && (pos == count || isSpaceOrLineBreak(buffer[pos]))
    }

    static func scanMarkdownFence(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let count = buffer.count
        let fenceUnit = buffer[start]
        var pos = start
        while pos < count, buffer[pos] == fenceUnit { pos += 1 }
        let fenceLength = pos - start
        guard fenceLength >= minimumMarkdownFenceLength else { return nil }
        let openingLineEnd = lineEnd(buffer, from: pos)
        if fenceUnit == UTF16Code.backtick {
            for index in pos..<openingLineEnd where buffer[index] == UTF16Code.backtick {
                return nil
            }
        }
        var lineCursor = nextLineStart(buffer, after: openingLineEnd)
        while lineCursor < count {
            let currentEnd = lineEnd(buffer, from: lineCursor)
            var probe = lineCursor
            while probe < currentEnd, buffer[probe] == UTF16Code.space || buffer[probe] == UTF16Code.tab {
                probe += 1
            }
            var run = 0
            while probe < currentEnd, buffer[probe] == fenceUnit {
                run += 1
                probe += 1
            }
            if run >= fenceLength {
                while probe < currentEnd, buffer[probe] == UTF16Code.space || buffer[probe] == UTF16Code.tab {
                    probe += 1
                }
                if probe == currentEnd { return currentEnd }
            }
            lineCursor = nextLineStart(buffer, after: currentEnd)
        }
        return count
    }

    static func scanSectionHeader(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let count = buffer.count
        var pos = start + 1
        while pos < count, buffer[pos] != UTF16Code.lineFeed, buffer[pos] != UTF16Code.carriageReturn {
            if buffer[pos] == UTF16Code.rightBracket {
                pos += 1
                if pos < count, buffer[pos] == UTF16Code.rightBracket { pos += 1 }
                return pos
            }
            pos += 1
        }
        return nil
    }

    static func scanLaTeXCommand(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int {
        let count = buffer.count
        guard start + 1 < count else { return start + 1 }
        var pos = start + 1
        if isASCIILetter(buffer[pos]) {
            while pos < count, isASCIILetter(buffer[pos]) { pos += 1 }
            return pos
        }
        if buffer[pos] != UTF16Code.lineFeed && buffer[pos] != UTF16Code.carriageReturn {
            if UTF16.isLeadSurrogate(buffer[pos]), pos + 1 < count, UTF16.isTrailSurrogate(buffer[pos + 1]) {
                return pos + 2
            }
            return pos + 1
        }
        return pos
    }

    static func scanKeyAssignment(
        _ buffer: UnsafeBufferPointer<UInt16>, from start: Int, allowColon: Bool
    ) -> Int? {
        let count = buffer.count
        guard isASCIILetter(buffer[start]) || buffer[start] == UTF16Code.underscore else { return nil }
        var keyEnd = start + 1
        while keyEnd < count,
            isASCIIIdentifier(buffer[keyEnd]) || buffer[keyEnd] == UTF16Code.dot || buffer[keyEnd] == UTF16Code.minus
        {
            keyEnd += 1
        }
        var probe = keyEnd
        while probe < count, buffer[probe] == UTF16Code.space || buffer[probe] == UTF16Code.tab { probe += 1 }
        guard probe < count else { return nil }
        if buffer[probe] == UTF16Code.equals || (allowColon && buffer[probe] == UTF16Code.colon) {
            return keyEnd
        }
        return nil
    }

    static func scanMakefileTarget(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let count = buffer.count
        let first = buffer[start]
        guard isASCIILetter(first) || first == UTF16Code.dot || first == UTF16Code.underscore else { return nil }
        var pos = start + 1
        while pos < count {
            let unit = buffer[pos]
            if unit == UTF16Code.colon {
                if pos + 1 < count, buffer[pos + 1] == UTF16Code.equals { return nil }
                return pos
            }
            if unit == UTF16Code.equals || unit == UTF16Code.lineFeed || unit == UTF16Code.carriageReturn
                || unit == UTF16Code.hash || unit == UTF16Code.space || unit == UTF16Code.tab
            {
                return nil
            }
            pos += 1
        }
        return nil
    }

    static func tokenizeDiff(
        _ buffer: UnsafeBufferPointer<UInt16>, into result: inout [PreviewToken]
    ) throws {
        let count = buffer.count
        var cursor = 0
        var lineIndex = 0
        var inHunk = false
        while cursor < count {
            lineIndex &+= 1
            if (lineIndex & (cancellationStride - 1)) == 0 { try Task.checkCancellation() }
            let end = lineEnd(buffer, from: cursor)
            let nextStart = nextLineStart(buffer, after: end)
            if end > cursor {
                if matchesASCII(buffer, at: cursor, end: end, "diff ") {
                    inHunk = false
                    result.append(PreviewToken(range: NSRange(location: cursor, length: end - cursor), kind: .keyword))
                } else if matchesASCII(buffer, at: cursor, end: end, "@@") {
                    inHunk = true
                    result.append(PreviewToken(range: NSRange(location: cursor, length: end - cursor), kind: .number))
                } else if let kind = diffLineKind(
                    buffer, start: cursor, end: end, nextStart: nextStart, inHunk: &inHunk)
                {
                    result.append(PreviewToken(range: NSRange(location: cursor, length: end - cursor), kind: kind))
                }
            }
            cursor = nextStart
        }
    }

    private static func diffLineKind(
        _ buffer: UnsafeBufferPointer<UInt16>,
        start: Int,
        end: Int,
        nextStart: Int,
        inHunk: inout Bool
    ) -> PreviewToken.Kind? {
        if matchesASCII(buffer, at: start, end: end, "\\ No newline") { return .keyword }
        let first = buffer[start]
        if inHunk {
            if isDiffFileHeaderStart(buffer, start: start, end: end, nextStart: nextStart) {
                inHunk = false
                return .keyword
            }
            if first == UTF16Code.plus { return .diffAdded }
            if first == UTF16Code.minus { return .diffRemoved }
            return nil
        }
        if matchesASCII(buffer, at: start, end: end, "+++ ")
            || matchesASCII(buffer, at: start, end: end, "+++\t")
            || matchesASCII(buffer, at: start, end: end, "--- ")
            || matchesASCII(buffer, at: start, end: end, "---\t")
            || (end - start == 3
                && (matchesASCII(buffer, at: start, end: end, "+++")
                    || matchesASCII(buffer, at: start, end: end, "---")))
            || matchesASCII(buffer, at: start, end: end, "index ")
            || matchesASCII(buffer, at: start, end: end, "===")
            || matchesASCII(buffer, at: start, end: end, "new file mode ")
            || matchesASCII(buffer, at: start, end: end, "deleted file mode ")
            || matchesASCII(buffer, at: start, end: end, "old mode ")
            || matchesASCII(buffer, at: start, end: end, "new mode ")
            || matchesASCII(buffer, at: start, end: end, "rename from ")
            || matchesASCII(buffer, at: start, end: end, "rename to ")
            || matchesASCII(buffer, at: start, end: end, "similarity index ")
            || matchesASCII(buffer, at: start, end: end, "Binary files ")
        {
            return .keyword
        }
        if first == UTF16Code.plus { return .diffAdded }
        if first == UTF16Code.minus { return .diffRemoved }
        return nil
    }

    private static func isDiffFileHeaderStart(
        _ buffer: UnsafeBufferPointer<UInt16>, start: Int, end: Int, nextStart: Int
    ) -> Bool {
        guard matchesASCII(buffer, at: start, end: end, "--- ") || matchesASCII(buffer, at: start, end: end, "---\t"),
            nextStart < buffer.count
        else { return false }
        let nextEnd = lineEnd(buffer, from: nextStart)
        guard
            matchesASCII(buffer, at: nextStart, end: nextEnd, "+++ ")
                || matchesASCII(buffer, at: nextStart, end: nextEnd, "+++\t")
        else { return false }
        let thirdStart = nextLineStart(buffer, after: nextEnd)
        guard thirdStart < buffer.count else { return false }
        let thirdEnd = lineEnd(buffer, from: thirdStart)
        return matchesASCII(buffer, at: thirdStart, end: thirdEnd, "@@")
    }

    static func tokenizeRestructuredText(
        _ buffer: UnsafeBufferPointer<UInt16>, into result: inout [PreviewToken]
    ) throws {
        let count = buffer.count
        var cursor = 0
        var lineIndex = 0
        var prevStart = 0
        var prevEnd = 0
        var prevHadText = false
        var prevWasAdornment = false
        var prevTokenBaseline = 0
        var pendingOverline: (Int, Int)?
        while cursor < count {
            lineIndex &+= 1
            if (lineIndex & (cancellationStride - 1)) == 0 { try Task.checkCancellation() }
            let end = lineEnd(buffer, from: cursor)
            if isRstAdornment(buffer, start: cursor, end: end) {
                if prevHadText && !prevWasAdornment {
                    result.removeSubrange(prevTokenBaseline..<result.count)
                    if let overline = pendingOverline {
                        result.append(
                            PreviewToken(
                                range: NSRange(location: overline.0, length: overline.1 - overline.0), kind: .keyword))
                    }
                    result.append(
                        PreviewToken(range: NSRange(location: prevStart, length: prevEnd - prevStart), kind: .keyword))
                    result.append(
                        PreviewToken(range: NSRange(location: cursor, length: end - cursor), kind: .keyword))
                    pendingOverline = nil
                } else {
                    pendingOverline = (cursor, end)
                }
                prevHadText = false
                prevWasAdornment = true
            } else {
                prevTokenBaseline = result.count
                let hasText = lineHasNonSpace(buffer, start: cursor, end: end)
                if hasText {
                    scanInlineBackticks(buffer, start: cursor, end: end, doubleFirst: true, into: &result)
                } else {
                    pendingOverline = nil
                }
                prevStart = cursor
                prevEnd = end
                prevHadText = hasText
                prevWasAdornment = false
            }
            cursor = nextLineStart(buffer, after: end)
        }
    }

    static func tokenizeAsciiDoc(
        _ buffer: UnsafeBufferPointer<UInt16>, into result: inout [PreviewToken]
    ) throws {
        let count = buffer.count
        var cursor = 0
        var lineIndex = 0
        while cursor < count {
            lineIndex &+= 1
            if (lineIndex & (cancellationStride - 1)) == 0 { try Task.checkCancellation() }
            let end = lineEnd(buffer, from: cursor)
            if let fenceChar = asciiDocFenceChar(buffer, start: cursor, end: end) {
                let blockStart = cursor
                var scan = nextLineStart(buffer, after: end)
                var blockEnd = end
                while scan < count {
                    let scanEnd = lineEnd(buffer, from: scan)
                    blockEnd = scanEnd
                    let next = nextLineStart(buffer, after: scanEnd)
                    if asciiDocFenceChar(buffer, start: scan, end: scanEnd) == fenceChar {
                        scan = next
                        break
                    }
                    scan = next
                }
                result.append(
                    PreviewToken(range: NSRange(location: blockStart, length: blockEnd - blockStart), kind: .string))
                cursor = scan
                continue
            }
            if isAsciiDocHeading(buffer, start: cursor, end: end) {
                result.append(PreviewToken(range: NSRange(location: cursor, length: end - cursor), kind: .keyword))
            } else {
                scanInlineBackticks(buffer, start: cursor, end: end, doubleFirst: false, into: &result)
            }
            cursor = nextLineStart(buffer, after: end)
        }
    }

    private static func scanInlineBackticks(
        _ buffer: UnsafeBufferPointer<UInt16>,
        start: Int,
        end: Int,
        doubleFirst: Bool,
        into result: inout [PreviewToken]
    ) {
        var pos = start
        while pos < end {
            if buffer[pos] == UTF16Code.backtick {
                var delimLength = 1
                let maxDelim = doubleFirst ? 2 : 3
                while delimLength < maxDelim, pos + delimLength < end,
                    buffer[pos + delimLength] == UTF16Code.backtick
                {
                    delimLength += 1
                }
                var scan = pos + delimLength
                var closed: Int?
                while scan + delimLength <= end {
                    var matched = true
                    for offset in 0..<delimLength where buffer[scan + offset] != UTF16Code.backtick {
                        matched = false
                        break
                    }
                    if matched {
                        closed = scan + delimLength
                        break
                    }
                    scan += 1
                }
                if let closed, closed > pos + delimLength * 2 {
                    result.append(PreviewToken(range: NSRange(location: pos, length: closed - pos), kind: .string))
                    pos = closed
                    continue
                }
            }
            pos += 1
        }
    }

    private static func isRstAdornment(_ buffer: UnsafeBufferPointer<UInt16>, start: Int, end: Int) -> Bool {
        var trimmedEnd = end
        while trimmedEnd > start,
            buffer[trimmedEnd - 1] == UTF16Code.space || buffer[trimmedEnd - 1] == UTF16Code.tab
        {
            trimmedEnd -= 1
        }
        guard trimmedEnd - start >= minimumRstAdornmentLength else { return false }
        let marker = buffer[start]
        guard rstAdornments.contains(marker) else { return false }
        for index in (start + 1)..<trimmedEnd where buffer[index] != marker { return false }
        return true
    }

    private static func asciiDocFenceChar(_ buffer: UnsafeBufferPointer<UInt16>, start: Int, end: Int) -> UInt16? {
        var trimmedEnd = end
        while trimmedEnd > start,
            buffer[trimmedEnd - 1] == UTF16Code.space || buffer[trimmedEnd - 1] == UTF16Code.tab
        {
            trimmedEnd -= 1
        }
        guard trimmedEnd - start >= minimumAsciiDocFenceLength else { return nil }
        let marker = buffer[start]
        guard marker == UTF16Code.minus || marker == UTF16Code.dot else { return nil }
        for index in (start + 1)..<trimmedEnd where buffer[index] != marker { return nil }
        return marker
    }

    private static func isAsciiDocHeading(_ buffer: UnsafeBufferPointer<UInt16>, start: Int, end: Int) -> Bool {
        var pos = start
        while pos < end, pos - start < maximumAsciiDocHeadingLevel, buffer[pos] == UTF16Code.equals {
            pos += 1
        }
        return pos > start && pos < end && (buffer[pos] == UTF16Code.space || buffer[pos] == UTF16Code.tab)
    }

    private static func lineHasNonSpace(_ buffer: UnsafeBufferPointer<UInt16>, start: Int, end: Int) -> Bool {
        for index in start..<end where buffer[index] != UTF16Code.space && buffer[index] != UTF16Code.tab {
            return true
        }
        return false
    }

    @inline(__always)
    private static func isPythonPrefixChar(_ unit: UInt16) -> Bool {
        switch unit {
        case UTF16Code.lowerR, UTF16Code.lowerF, UTF16Code.lowerB, UTF16Code.lowerU,
            UTF16Code.upperR, UTF16Code.upperF, UTF16Code.upperB, UTF16Code.upperU:
            true
        default:
            false
        }
    }
}
