import Foundation

struct PreviewToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case keyword, type, string, comment, number, diffAdded, diffRemoved, invisible
    }
    let range: NSRange
    let kind: Kind
    let invisibleScalar: Unicode.Scalar?

    init(range: NSRange, kind: Kind, invisibleScalar: Unicode.Scalar? = nil) {
        self.range = range
        self.kind = kind
        self.invisibleScalar = invisibleScalar
    }
}

enum PreviewTokenizer {
    static let cancellationStride = 4096
    // Bounds unterminated single-character multiline quotes.
    private static let maximumSingleQuoteUnits = 16_384
    private static let maximumSingleQuoteLines = 256
    private static let maximumCSSDeclarationLookahead = 128

    static let doubleQuoteRule = PreviewLanguageGrammar.StringRule("\"")
    static let multilineDoubleQuoteRule = PreviewLanguageGrammar.StringRule("\"", multiline: true)
    static let verbatimDoubleQuoteRule = PreviewLanguageGrammar.StringRule(
        "\"", escape: .doubled, multiline: true)
    static let rawDoubleQuoteRule = PreviewLanguageGrammar.StringRule("\"", escape: .none)
    static let rawSingleQuoteRule = PreviewLanguageGrammar.StringRule("'", escape: .none)
    static let rawTripleDoubleQuoteRule = PreviewLanguageGrammar.StringRule(
        "\"\"\"", escape: .none, multiline: true)
    static let rawTripleSingleQuoteRule = PreviewLanguageGrammar.StringRule(
        "'''", escape: .none, multiline: true)

    private static let markupDirectiveLeaders: Set<UInt16> = [UTF16Code.exclamation, UTF16Code.question]
    private static let scalarPreceders: Set<UInt16> = [
        UTF16Code.tab, UTF16Code.lineFeed, UTF16Code.carriageReturn, UTF16Code.space,
        UTF16Code.comma, UTF16Code.colon, UTF16Code.equals, UTF16Code.leftBracket, UTF16Code.leftBrace,
    ]
    private static let objcAtKeywords: Set<String> = [
        "autoreleasepool", "available", "catch", "class", "compatibility_alias", "defs", "dynamic",
        "encode", "end", "finally", "implementation", "import", "interface", "NO", "optional",
        "package", "private", "property", "protected", "protocol", "public", "required", "selector",
        "synchronized", "synthesize", "throw", "try", "YES",
    ]
    private static let cssUnitSuffixes: Set<String> = [
        "px", "em", "rem", "vh", "vw", "vmin", "vmax", "svh", "dvh", "lvh",
        "ch", "ex", "pt", "pc", "cm", "mm", "in", "s", "ms", "deg", "rad", "turn", "fr",
    ]

    private struct MarkupState {
        let baseGrammar: PreviewLanguageGrammar
        let phpTemplate: Bool
        var activeGrammar: PreviewLanguageGrammar
        var inTag = false
        var tagSelfClosing = false
        var pendingEmbedded: PreviewLanguage?
        var embeddedLanguage: PreviewLanguage?

        init(baseGrammar: PreviewLanguageGrammar, phpTemplate: Bool) {
            self.baseGrammar = baseGrammar
            self.phpTemplate = phpTemplate
            self.activeGrammar = baseGrammar
        }
    }

    static func cappedPrefix(of text: String) -> Substring {
        let limit = PreviewTextSource.highlightBytes
        guard text.utf8.count > limit else { return text[...] }
        let utf8 = text.utf8
        var end = utf8.index(utf8.startIndex, offsetBy: limit)
        // Walk back to avoid splitting UTF-8 scalars.
        while end > utf8.startIndex, (utf8[end] & 0xC0) == 0x80 {
            end = utf8.index(before: end)
        }
        return text[..<end]
    }

    static func invisibleCharacters(
        _ text: String, language: PreviewLanguage = .plain
    ) throws -> [PreviewInvisibleCharacter] {
        try PreviewInvisibleScanner.scan(prefix: cappedPrefix(of: text), language: language)
    }

    static func tokens(_ text: String, language: PreviewLanguage) throws -> [PreviewToken] {
        let prefix = cappedPrefix(of: text)
        guard !prefix.isEmpty else { return [] }
        let units = Array(prefix.utf16)
        var result: [PreviewToken] = []
        try units.withUnsafeBufferPointer { buffer in
            switch language {
            case .plain:
                break
            case .diff:
                try tokenizeDiff(buffer, into: &result)
            case .restructuredText:
                try tokenizeRestructuredText(buffer, into: &result)
            case .asciiDoc:
                try tokenizeAsciiDoc(buffer, into: &result)
            case .php:
                try tokenizeGeneral(buffer, baseGrammar: .markup, phpTemplate: true, into: &result)
            default:
                if let grammar = PreviewLanguageGrammar.grammar(for: language) {
                    try tokenizeGeneral(buffer, baseGrammar: grammar, phpTemplate: false, into: &result)
                }
            }
        }
        let invisible = try PreviewInvisibleScanner.scan(prefix: prefix, language: language)
        for mark in invisible {
            result.append(PreviewToken(range: mark.range, kind: .invisible, invisibleScalar: mark.scalar))
        }
        return result
    }

    private static func tokenizeGeneral(
        _ buffer: UnsafeBufferPointer<UInt16>,
        baseGrammar: PreviewLanguageGrammar,
        phpTemplate: Bool,
        into result: inout [PreviewToken]
    ) throws {
        let count = buffer.count
        let lastLineBreak = findLastLineBreak(in: buffer)
        var markup = MarkupState(baseGrammar: baseGrammar, phpTemplate: phpTemplate)
        var cursor = 0
        var step = 0
        var atLineStart = true
        var lineStartOffset = 0
        var braceDepth = 0
        var previousNonSpace: UInt16?

        while cursor < count {
            step &+= 1
            if (step & (cancellationStride - 1)) == 0 { try Task.checkCancellation() }

            if let embedded = markup.embeddedLanguage {
                if embedded == .php, matchesPHPEnd(buffer, at: cursor) {
                    result.append(PreviewToken(range: NSRange(location: cursor, length: 2), kind: .keyword))
                    cursor += 2
                    markup.embeddedLanguage = nil
                    markup.activeGrammar = markup.baseGrammar
                    atLineStart = false
                    previousNonSpace = nil
                    continue
                }
                if embedded != .php, matchesEmbeddedClose(buffer, at: cursor, language: embedded) {
                    markup.embeddedLanguage = nil
                    markup.activeGrammar = markup.baseGrammar
                }
            }

            let start = cursor
            let unit = buffer[cursor]
            if unit == UTF16Code.lineFeed || unit == UTF16Code.carriageReturn {
                cursor += 1
                atLineStart = true
                lineStartOffset = cursor
                previousNonSpace = nil
                continue
            }
            if unit == UTF16Code.space || unit == UTF16Code.tab {
                cursor += 1
                continue
            }

            let isFirstOnLine = atLineStart
            atLineStart = false
            let previous: UInt16? = start > 0 ? buffer[start - 1] : nil
            let grammar = markup.activeGrammar

            if grammar.numberStyle != .none, isDigit(unit) {
                cursor = scanNumber(buffer, from: start, style: grammar.numberStyle)
                result.append(PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .number))
                previousNonSpace = nil
                continue
            }

            if isPlainIdentifier(unit) {
                if isFirstOnLine {
                    if grammar.lineSyntax == .batchRem, matchesBatchRem(buffer, at: start) {
                        cursor = lineEnd(buffer, from: start)
                        result.append(
                            PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .comment))
                        previousNonSpace = nil
                        continue
                    }
                    if grammar.keyStyle == .tomlEquals || grammar.keyStyle == .iniColonOrEquals,
                        let keyEnd = scanKeyAssignment(
                            buffer, from: start, allowColon: grammar.keyStyle == .iniColonOrEquals)
                    {
                        cursor = keyEnd
                        result.append(
                            PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .keyword))
                        previousNonSpace = nil
                        continue
                    }
                    if grammar.lineSyntax == .makefile, start == lineStartOffset,
                        let targetEnd = scanMakefileTarget(buffer, from: start)
                    {
                        cursor = targetEnd
                        result.append(
                            PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .type))
                        previousNonSpace = nil
                        continue
                    }
                }
                if grammar.hasLetterPrefixedString,
                    let literalEnd = scanLetterPrefixedString(
                        buffer, from: start, previous: previous, grammar: grammar)
                {
                    cursor = literalEnd
                    result.append(PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .string))
                    previousNonSpace = nil
                    continue
                }
                cursor += 1
                while cursor < count, isIdentifierContinue(buffer[cursor], rules: grammar.identifiers) {
                    cursor += 1
                }
                if let kind = classifyWord(
                    buffer,
                    start: start,
                    end: cursor,
                    isFirstOnLine: isFirstOnLine,
                    previousNonSpace: previousNonSpace,
                    braceDepth: braceDepth,
                    grammar: grammar)
                {
                    result.append(PreviewToken(range: NSRange(location: start, length: cursor - start), kind: kind))
                }
                previousNonSpace = nil
                continue
            }

            if let token = scanPunctuationConstruct(
                buffer,
                at: &cursor,
                previous: previous,
                isFirstOnLine: isFirstOnLine,
                lineStartOffset: lineStartOffset,
                lastLineBreak: lastLineBreak,
                markup: &markup)
            {
                result.append(token)
                previousNonSpace = nil
                continue
            }
            if cursor > start {
                previousNonSpace = nil
                continue
            }

            if isFirstOnLine, start == lineStartOffset, grammar.lineSyntax == .makefile,
                let targetEnd = scanMakefileTarget(buffer, from: start)
            {
                cursor = targetEnd
                result.append(PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .type))
                previousNonSpace = nil
                continue
            }

            if isSpecialIdentifierStart(unit, rules: grammar.identifiers) {
                cursor += 1
                while cursor < count, isIdentifierContinue(buffer[cursor], rules: grammar.identifiers) {
                    cursor += 1
                }
                if let kind = classifyWord(
                    buffer,
                    start: start,
                    end: cursor,
                    isFirstOnLine: isFirstOnLine,
                    previousNonSpace: previousNonSpace,
                    braceDepth: braceDepth,
                    grammar: grammar)
                {
                    result.append(PreviewToken(range: NSRange(location: start, length: cursor - start), kind: kind))
                }
                previousNonSpace = nil
                continue
            }

            if unit == UTF16Code.leftBrace {
                braceDepth += 1
            } else if unit == UTF16Code.rightBrace, braceDepth > 0 {
                braceDepth -= 1
            }
            previousNonSpace = unit
            cursor += 1
        }
    }

    private static func scanPunctuationConstruct(
        _ buffer: UnsafeBufferPointer<UInt16>,
        at cursor: inout Int,
        previous: UInt16?,
        isFirstOnLine: Bool,
        lineStartOffset: Int,
        lastLineBreak: Int,
        markup: inout MarkupState
    ) -> PreviewToken? {
        let grammar = markup.activeGrammar
        if let token = scanCommentOrDirective(
            buffer,
            at: &cursor,
            previous: previous,
            isFirstOnLine: isFirstOnLine,
            lineStartOffset: lineStartOffset,
            grammar: grammar)
        {
            return token
        }
        if let token = scanPunctuationLiteral(
            buffer,
            at: &cursor,
            lastLineBreak: lastLineBreak,
            grammar: grammar)
        {
            return token
        }
        return scanMarkupOrQuotedLiteral(buffer, at: &cursor, previous: previous, markup: &markup)
    }

    private static func scanCommentOrDirective(
        _ buffer: UnsafeBufferPointer<UInt16>,
        at cursor: inout Int,
        previous: UInt16?,
        isFirstOnLine: Bool,
        lineStartOffset: Int,
        grammar: PreviewLanguageGrammar
    ) -> PreviewToken? {
        let start = cursor
        let count = buffer.count
        let unit = buffer[start]

        if grammar.rawLiteralStyle == .luaBracket, unit == UTF16Code.minus,
            start + 3 < count, buffer[start + 1] == UTF16Code.minus, buffer[start + 2] == UTF16Code.leftBracket,
            let end = scanLuaLongBracket(buffer, from: start + 2)
        {
            cursor = end
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .comment)
        }

        for block in grammar.blockComments where block.openFirst == unit && matches(buffer, at: start, block.open) {
            cursor = scanBlockComment(buffer, from: start, block: block)
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .comment)
        }

        for marker in grammar.lineComments where marker.first == unit && matches(buffer, at: start, marker) {
            if grammar.lineCommentRequiresLeadingSpace, !isFirstOnLine,
                previous != UTF16Code.space && previous != UTF16Code.tab
            {
                continue
            }
            if grammar.skipSlashCommentAfterColon, unit == UTF16Code.slash, previous == UTF16Code.colon {
                continue
            }
            if grammar.skipPercentCommentAfterBackslash, unit == UTF16Code.percent,
                previous == UTF16Code.backslash
            {
                continue
            }
            cursor = lineEnd(buffer, from: start)
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .comment)
        }

        if grammar.rawLiteralStyle == .swiftHash, unit == UTF16Code.hash,
            let end = scanSwiftRawString(buffer, from: start)
        {
            cursor = end
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .string)
        }

        if grammar.lineSyntax == .markdown {
            if isFirstOnLine, unit == UTF16Code.backtick || unit == UTF16Code.tilde,
                let end = scanMarkdownFence(buffer, from: start)
            {
                cursor = end
                return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .string)
            }
            if isFirstOnLine, start == lineStartOffset, unit == UTF16Code.hash,
                isMarkdownHeading(buffer, at: start)
            {
                cursor = lineEnd(buffer, from: start)
                return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .keyword)
            }
        }

        if isFirstOnLine, grammar.lineSyntax == .hashPreprocessor, unit == UTF16Code.hash {
            var end = start + 1
            while end < count, buffer[end] == UTF16Code.space || buffer[end] == UTF16Code.tab { end += 1 }
            let wordStart = end
            while end < count, isASCIIIdentifier(buffer[end]) { end += 1 }
            if end > wordStart {
                cursor = end
                return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .keyword)
            }
        }

        if isFirstOnLine, grammar.lineSyntax == .sectionHeaders, unit == UTF16Code.leftBracket,
            let end = scanSectionHeader(buffer, from: start)
        {
            cursor = end
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .keyword)
        }

        if grammar.lineSyntax == .latex, unit == UTF16Code.backslash {
            cursor = scanLaTeXCommand(buffer, from: start)
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .keyword)
        }

        return nil
    }

    private static func scanPunctuationLiteral(
        _ buffer: UnsafeBufferPointer<UInt16>,
        at cursor: inout Int,
        lastLineBreak: Int,
        grammar: PreviewLanguageGrammar
    ) -> PreviewToken? {
        let start = cursor
        let count = buffer.count
        let unit = buffer[start]

        if grammar.supportsObjCAt, unit == UTF16Code.atSign, start + 1 < count {
            let next = buffer[start + 1]
            if next == UTF16Code.doubleQuote {
                cursor = scanDelimited(buffer, from: start + 1, rule: doubleQuoteRule)
                return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .string)
            }
            if isASCIILetter(next) {
                var end = start + 2
                while end < count, isASCIIIdentifier(buffer[end]) { end += 1 }
                let word = String(decoding: buffer[(start + 1)..<end], as: UTF16.self)
                if objcAtKeywords.contains(word) {
                    cursor = end
                    return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .keyword)
                }
            }
        }

        if grammar.rawLiteralStyle == .powershellHereString, unit == UTF16Code.atSign,
            let end = scanPowerShellHereString(buffer, from: start)
        {
            cursor = end
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .string)
        }

        if grammar.rawLiteralStyle == .luaBracket, unit == UTF16Code.leftBracket,
            let end = scanLuaLongBracket(buffer, from: start)
        {
            cursor = end
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .string)
        }

        if grammar.supportsHeredoc, unit == UTF16Code.lessThan,
            let end = scanHeredoc(buffer, from: start, lastLineBreak: lastLineBreak)
        {
            cursor = end
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .string)
        }

        if grammar.prefixedStringStyle == .csharpInterpolated,
            let end = scanCSharpInterpolatedPrefix(buffer, from: start)
        {
            cursor = end
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .string)
        }

        return nil
    }

    private static func scanMarkupOrQuotedLiteral(
        _ buffer: UnsafeBufferPointer<UInt16>,
        at cursor: inout Int,
        previous: UInt16?,
        markup: inout MarkupState
    ) -> PreviewToken? {
        let start = cursor
        let count = buffer.count
        let unit = buffer[start]
        let grammar = markup.activeGrammar

        if grammar.supportsMarkupTags {
            if markup.phpTemplate, unit == UTF16Code.lessThan,
                let phpTagEnd = matchPHPOpen(buffer, at: start)
            {
                cursor = phpTagEnd
                markup.inTag = false
                markup.tagSelfClosing = false
                markup.pendingEmbedded = nil
                markup.embeddedLanguage = .php
                markup.activeGrammar = .php
                return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .keyword)
            }
            if unit == UTF16Code.lessThan {
                return scanMarkupOpen(buffer, at: &cursor, markup: &markup)
            }
            if markup.inTag, unit == UTF16Code.slash, start + 1 < count, buffer[start + 1] == UTF16Code.greaterThan {
                markup.tagSelfClosing = true
                cursor += 1
                return nil
            }
            if unit == UTF16Code.greaterThan {
                let wasInTag = markup.inTag
                markup.inTag = false
                cursor += 1
                if wasInTag, !markup.tagSelfClosing, let next = markup.pendingEmbedded,
                    let nextGrammar = PreviewLanguageGrammar.grammar(for: next)
                {
                    markup.embeddedLanguage = next
                    markup.activeGrammar = nextGrammar
                }
                markup.pendingEmbedded = nil
                markup.tagSelfClosing = false
                return nil
            }
        }

        for rule in grammar.strings
        where rule.openFirst == unit
            && (rule.openLength == 1 || matches(buffer, at: start, rule.open))
        {
            switch rule.scope {
            case .anywhere:
                break
            case .notAfterDigit:
                if let previous, isDigit(previous) { continue }
            case .markupTag:
                guard markup.inTag else { continue }
            case .scalarStart:
                if let previous, !scalarPreceders.contains(previous) { continue }
            case .charLiteral:
                if let end = scanCharLiteral(buffer, from: start) {
                    cursor = end
                    return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .string)
                }
                continue
            }
            cursor = scanDelimited(buffer, from: start, rule: rule)
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .string)
        }

        if grammar.numberStyle == .cssUnit, unit == UTF16Code.hash,
            let end = scanCSSHexColor(buffer, from: start)
        {
            cursor = end
            return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .number)
        }

        return nil
    }

    private static func scanMarkupOpen(
        _ buffer: UnsafeBufferPointer<UInt16>,
        at cursor: inout Int,
        markup: inout MarkupState
    ) -> PreviewToken {
        let start = cursor
        let count = buffer.count
        cursor += 1
        var isClosing = false
        if cursor < count, buffer[cursor] == UTF16Code.slash {
            isClosing = true
            cursor += 1
        }
        let nameStart = cursor
        while cursor < count, isMarkupNameChar(buffer[cursor]) { cursor += 1 }
        if cursor > nameStart
            || (nameStart < count && markupDirectiveLeaders.contains(buffer[nameStart]))
        {
            markup.inTag = true
            markup.tagSelfClosing = false
            markup.pendingEmbedded = nil
            if !isClosing, cursor > nameStart {
                let length = cursor - nameStart
                if length == 6, matchesASCIIFolded(buffer, at: nameStart, "script") {
                    markup.pendingEmbedded = .javascript
                } else if length == 5, matchesASCIIFolded(buffer, at: nameStart, "style") {
                    markup.pendingEmbedded = .css
                }
            }
        }
        return PreviewToken(range: NSRange(location: start, length: cursor - start), kind: .keyword)
    }

    private static func matchPHPOpen(_ buffer: UnsafeBufferPointer<UInt16>, at start: Int) -> Int? {
        let count = buffer.count
        guard start + 1 < count, buffer[start] == UTF16Code.lessThan, buffer[start + 1] == UTF16Code.question else {
            return nil
        }
        if start + 2 < count, buffer[start + 2] == UTF16Code.equals { return start + 3 }
        if start + 5 <= count, matchesASCIIFolded(buffer, at: start + 2, "php") {
            let after = start + 5
            if after == count || isSpaceOrLineBreak(buffer[after]) { return after }
        }
        if start + 2 < count, isSpaceOrLineBreak(buffer[start + 2]) { return start + 2 }
        return nil
    }

    private static func matchesPHPEnd(_ buffer: UnsafeBufferPointer<UInt16>, at index: Int) -> Bool {
        index + 1 < buffer.count
            && buffer[index] == UTF16Code.question
            && buffer[index + 1] == UTF16Code.greaterThan
    }

    private static func matchesEmbeddedClose(
        _ buffer: UnsafeBufferPointer<UInt16>, at index: Int, language: PreviewLanguage
    ) -> Bool {
        let tag = language == .javascript ? "</script" : "</style"
        let length = tag.utf16.count
        guard index + length <= buffer.count, matchesASCIIFolded(buffer, at: index, tag) else { return false }
        if index + length == buffer.count { return true }
        let next = buffer[index + length]
        return next == UTF16Code.greaterThan || next == UTF16Code.space || next == UTF16Code.tab
            || next == UTF16Code.lineFeed || next == UTF16Code.carriageReturn || next == UTF16Code.slash
    }

    private static func scanBlockComment(
        _ buffer: UnsafeBufferPointer<UInt16>, from start: Int, block: PreviewLanguageGrammar.BlockComment
    ) -> Int {
        let count = buffer.count
        var cursor = start + block.open.count
        var depth = 1
        while cursor < count, depth > 0 {
            if matches(buffer, at: cursor, block.close) {
                depth -= 1
                cursor += block.close.count
            } else if block.nested, matches(buffer, at: cursor, block.open) {
                depth += 1
                cursor += block.open.count
            } else {
                cursor += 1
            }
        }
        return min(count, cursor)
    }

    static func scanDelimited(
        _ buffer: UnsafeBufferPointer<UInt16>, from start: Int, rule: PreviewLanguageGrammar.StringRule
    ) -> Int {
        let count = buffer.count
        let capped = rule.capsMultilineScan
        let unitLimit =
            capped
            ? surrogateSafeLimit(buffer, desired: start + maximumSingleQuoteUnits, minimum: start + rule.openLength)
            : count
        var cursor = start + rule.openLength
        var lines = 0
        let closeFirst = rule.closeFirst
        let closeLength = rule.closeLength

        while cursor < unitLimit {
            let unit = buffer[cursor]
            if unit == UTF16Code.lineFeed || unit == UTF16Code.carriageReturn {
                if !rule.multiline { return cursor }
                if capped, unit == UTF16Code.lineFeed {
                    lines += 1
                    if lines >= maximumSingleQuoteLines { return cursor }
                }
                cursor += 1
                continue
            }
            switch rule.escape {
            case .backslash:
                if unit == UTF16Code.backslash {
                    cursor = advanceEscaped(buffer, from: cursor, limit: unitLimit)
                    continue
                }
            case .backtick:
                if unit == UTF16Code.backtick {
                    cursor = advanceEscaped(buffer, from: cursor, limit: unitLimit)
                    continue
                }
            case .doubled:
                if unit == closeFirst,
                    (closeLength == 1 || matches(buffer, at: cursor, rule.close)),
                    cursor + closeLength * 2 <= unitLimit,
                    (closeLength == 1
                        ? buffer[cursor + 1] == closeFirst
                        : matches(buffer, at: cursor + closeLength, rule.close))
                {
                    cursor += closeLength * 2
                    continue
                }
            case .none:
                break
            }
            if unit == closeFirst, closeLength == 1 || matches(buffer, at: cursor, rule.close) {
                return cursor + closeLength
            }
            cursor += 1
        }
        return surrogateSafeLimit(buffer, desired: cursor, minimum: start + rule.openLength)
    }

    static func advanceEscaped(
        _ buffer: UnsafeBufferPointer<UInt16>, from backslashIndex: Int, limit: Int
    ) -> Int {
        let escapedIndex = backslashIndex + 1
        guard escapedIndex < limit else { return limit }
        if UTF16.isLeadSurrogate(buffer[escapedIndex]),
            escapedIndex + 1 < limit,
            UTF16.isTrailSurrogate(buffer[escapedIndex + 1])
        {
            return escapedIndex + 2
        }
        return escapedIndex + 1
    }

    private static func surrogateSafeLimit(
        _ buffer: UnsafeBufferPointer<UInt16>, desired: Int, minimum: Int
    ) -> Int {
        let clamped = min(buffer.count, desired)
        if clamped > minimum, clamped < buffer.count,
            UTF16.isLeadSurrogate(buffer[clamped - 1]),
            UTF16.isTrailSurrogate(buffer[clamped])
        {
            return clamped - 1
        }
        return clamped
    }

    private static func scanNumber(
        _ buffer: UnsafeBufferPointer<UInt16>, from start: Int, style: PreviewLanguageGrammar.NumberStyle
    ) -> Int {
        let count = buffer.count
        var cursor = start + 1
        if buffer[start] == UTF16Code.digitZero, cursor < count {
            let prefix = buffer[cursor]
            if prefix == UTF16Code.lowerX || prefix == UTF16Code.upperX {
                cursor += 1
                while cursor < count,
                    isHexDigit(buffer[cursor]) || buffer[cursor] == UTF16Code.underscore
                        || (style == .cDigitQuote && buffer[cursor] == UTF16Code.singleQuote
                            && cursor + 1 < count && isHexDigit(buffer[cursor + 1]))
                {
                    cursor += 1
                }
                return cursor
            }
            if prefix == UTF16Code.lowerB || prefix == UTF16Code.upperB
                || prefix == UTF16Code.lowerO || prefix == UTF16Code.upperO
            {
                cursor += 1
                while cursor < count,
                    isDigit(buffer[cursor]) || buffer[cursor] == UTF16Code.underscore
                        || (style == .cDigitQuote && buffer[cursor] == UTF16Code.singleQuote
                            && cursor + 1 < count && isDigit(buffer[cursor + 1]))
                {
                    cursor += 1
                }
                return cursor
            }
        }
        while cursor < count {
            let unit = buffer[cursor]
            if isDigit(unit) || unit == UTF16Code.underscore {
                cursor += 1
            } else if style == .cDigitQuote, unit == UTF16Code.singleQuote,
                cursor + 1 < count, isDigit(buffer[cursor + 1])
            {
                cursor += 1
            } else if unit == UTF16Code.dot, cursor + 1 < count, isDigit(buffer[cursor + 1]) {
                cursor += 1
            } else {
                break
            }
        }
        if cursor < count, buffer[cursor] == UTF16Code.lowerE || buffer[cursor] == UTF16Code.upperE {
            var exp = cursor + 1
            if exp < count, buffer[exp] == UTF16Code.plus || buffer[exp] == UTF16Code.minus { exp += 1 }
            if exp < count, isDigit(buffer[exp]) {
                cursor = exp + 1
                while cursor < count, isDigit(buffer[cursor]) || buffer[cursor] == UTF16Code.underscore {
                    cursor += 1
                }
            }
        }
        if style == .cssUnit, cursor < count {
            if buffer[cursor] == UTF16Code.percent {
                cursor += 1
            } else if isASCIILetter(buffer[cursor]) {
                var unitEnd = cursor + 1
                while unitEnd < count, isASCIILetter(buffer[unitEnd]) { unitEnd += 1 }
                let suffix = String(decoding: buffer[cursor..<unitEnd], as: UTF16.self).lowercased()
                if cssUnitSuffixes.contains(suffix) { cursor = unitEnd }
            }
        }
        return cursor
    }

    private static func scanCSSHexColor(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        let count = buffer.count
        var pos = start + 1
        while pos < count, isHexDigit(buffer[pos]) { pos += 1 }
        let length = pos - (start + 1)
        guard length == 3 || length == 4 || length == 6 || length == 8 else { return nil }
        if pos < count, isASCIIIdentifier(buffer[pos]) || buffer[pos] == UTF16Code.minus { return nil }
        return pos
    }

    private static func classifyWord(
        _ buffer: UnsafeBufferPointer<UInt16>,
        start: Int,
        end: Int,
        isFirstOnLine: Bool,
        previousNonSpace: UInt16?,
        braceDepth: Int,
        grammar: PreviewLanguageGrammar
    ) -> PreviewToken.Kind? {
        if end < buffer.count, buffer[end] == UTF16Code.colon {
            switch grammar.keyStyle {
            case .yamlColon:
                if end + 1 == buffer.count || isSpaceOrLineBreak(buffer[end + 1]) { return .keyword }
            case .cssProperty:
                if isCSSPropertyColon(buffer, colonIndex: end, braceDepth: braceDepth) { return .keyword }
            case .none, .tomlEquals, .iniColonOrEquals:
                break
            }
        }
        if previousNonSpace == UTF16Code.dot { return nil }
        let length = end - start
        guard length >= grammar.minWordLength && length <= grammar.maxWordLength else { return nil }
        if grammar.lineSyntax == .dockerfile {
            if isFirstOnLine || (length == 2 && matchesASCIIFolded(buffer, at: start, "as")),
                grammar.lookupWord(buffer, start: start, end: end) == .keyword
            {
                return .keyword
            }
            return nil
        }
        return grammar.lookupWord(buffer, start: start, end: end)
    }

    private static func isCSSPropertyColon(
        _ buffer: UnsafeBufferPointer<UInt16>, colonIndex: Int, braceDepth: Int
    ) -> Bool {
        guard braceDepth > 0 else { return false }
        let next = colonIndex + 1
        guard next < buffer.count, buffer[next] != UTF16Code.colon else { return false }
        if isSpaceOrLineBreak(buffer[next]) { return true }
        let limit = min(buffer.count, next + maximumCSSDeclarationLookahead)
        var probe = next
        while probe < limit {
            let unit = buffer[probe]
            if unit == UTF16Code.semicolon || unit == UTF16Code.rightBrace { return true }
            if unit == UTF16Code.leftBrace || unit == UTF16Code.lineFeed || unit == UTF16Code.carriageReturn {
                return false
            }
            probe += 1
        }
        return false
    }

    private static func findLastLineBreak(in buffer: UnsafeBufferPointer<UInt16>) -> Int {
        for index in stride(from: buffer.count - 1, through: 0, by: -1) {
            let unit = buffer[index]
            if unit == UTF16Code.lineFeed || unit == UTF16Code.carriageReturn { return index }
        }
        return -1
    }

    @inline(__always)
    static func lineEnd(_ buffer: UnsafeBufferPointer<UInt16>, from start: Int) -> Int {
        var pos = start
        let count = buffer.count
        while pos < count, buffer[pos] != UTF16Code.lineFeed, buffer[pos] != UTF16Code.carriageReturn {
            pos += 1
        }
        return pos
    }

    @inline(__always)
    static func nextLineStart(_ buffer: UnsafeBufferPointer<UInt16>, after end: Int) -> Int {
        let count = buffer.count
        guard end < count else { return count }
        if buffer[end] == UTF16Code.carriageReturn, end + 1 < count, buffer[end + 1] == UTF16Code.lineFeed {
            return end + 2
        }
        return end + 1
    }

    @inline(__always)
    static func matches(_ buffer: UnsafeBufferPointer<UInt16>, at index: Int, _ pattern: [UInt16]) -> Bool {
        let length = pattern.count
        guard index + length <= buffer.count else { return false }
        for offset in 0..<length where buffer[index + offset] != pattern[offset] { return false }
        return true
    }

    static func matchesASCII(
        _ buffer: UnsafeBufferPointer<UInt16>, at start: Int, end: Int, _ literal: String
    ) -> Bool {
        let units = literal.utf8
        guard start + units.count <= end else { return false }
        var offset = 0
        for byte in units {
            if buffer[start + offset] != UInt16(byte) { return false }
            offset += 1
        }
        return true
    }

    static func matchesASCIIFolded(
        _ buffer: UnsafeBufferPointer<UInt16>, at start: Int, _ lowerLiteral: String
    ) -> Bool {
        let units = lowerLiteral.utf8
        guard start + units.count <= buffer.count else { return false }
        var offset = 0
        for byte in units {
            var actual = buffer[start + offset]
            if (UTF16Code.upperA...UTF16Code.upperZ).contains(actual) { actual &+= UTF16Code.asciiCaseOffset }
            if actual != UInt16(byte) { return false }
            offset += 1
        }
        return true
    }

    static func matchesBatchRem(_ buffer: UnsafeBufferPointer<UInt16>, at start: Int) -> Bool {
        guard matchesASCIIFolded(buffer, at: start, "rem") else { return false }
        let after = start + 3
        return after == buffer.count || isSpaceOrLineBreak(buffer[after])
    }

    @inline(__always)
    static func isDigit(_ unit: UInt16) -> Bool {
        (UTF16Code.digitZero...UTF16Code.digitNine).contains(unit)
    }

    @inline(__always)
    static func isHexDigit(_ unit: UInt16) -> Bool {
        isDigit(unit) || (UTF16Code.upperA...UTF16Code.upperF).contains(unit)
            || (UTF16Code.lowerA...UTF16Code.lowerF).contains(unit)
    }

    @inline(__always)
    static func isASCIILetter(_ unit: UInt16) -> Bool {
        (UTF16Code.upperA...UTF16Code.upperZ).contains(unit) || (UTF16Code.lowerA...UTF16Code.lowerZ).contains(unit)
    }

    @inline(__always)
    static func isASCIIIdentifier(_ unit: UInt16) -> Bool {
        isASCIILetter(unit) || isDigit(unit) || unit == UTF16Code.underscore
    }

    @inline(__always)
    static func isPlainIdentifier(_ unit: UInt16) -> Bool {
        isASCIILetter(unit) || unit == UTF16Code.underscore || unit > UTF16Code.delete
    }

    @inline(__always)
    private static func isSpecialIdentifierStart(
        _ unit: UInt16, rules: PreviewLanguageGrammar.IdentifierRules
    ) -> Bool {
        if unit == UTF16Code.dollar, rules.contains(.dollarStart) { return true }
        if unit == UTF16Code.atSign, rules.contains(.atStart) { return true }
        return false
    }

    @inline(__always)
    private static func isIdentifierContinue(
        _ unit: UInt16, rules: PreviewLanguageGrammar.IdentifierRules
    ) -> Bool {
        if isPlainIdentifier(unit) || isDigit(unit) { return true }
        if unit == UTF16Code.minus, rules.contains(.hyphenContinue) { return true }
        return false
    }

    @inline(__always)
    private static func isMarkupNameChar(_ unit: UInt16) -> Bool {
        isPlainIdentifier(unit) || isDigit(unit) || unit == UTF16Code.minus || unit == UTF16Code.colon
    }

    @inline(__always)
    static func isSpaceOrLineBreak(_ unit: UInt16) -> Bool {
        unit == UTF16Code.space || unit == UTF16Code.tab
            || unit == UTF16Code.lineFeed || unit == UTF16Code.carriageReturn
    }
}
