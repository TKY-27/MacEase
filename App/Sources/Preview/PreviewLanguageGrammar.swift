import Foundation

enum UTF16Code {
    static let tab: UInt16 = 9
    static let lineFeed: UInt16 = 10
    static let carriageReturn: UInt16 = 13
    static let space: UInt16 = 32
    static let exclamation: UInt16 = 33
    static let doubleQuote: UInt16 = 34
    static let hash: UInt16 = 35
    static let dollar: UInt16 = 36
    static let percent: UInt16 = 37
    static let singleQuote: UInt16 = 39
    static let leftParen: UInt16 = 40
    static let rightParen: UInt16 = 41
    static let plus: UInt16 = 43
    static let comma: UInt16 = 44
    static let minus: UInt16 = 45
    static let dot: UInt16 = 46
    static let slash: UInt16 = 47
    static let digitZero: UInt16 = 48
    static let digitNine: UInt16 = 57
    static let colon: UInt16 = 58
    static let semicolon: UInt16 = 59
    static let lessThan: UInt16 = 60
    static let equals: UInt16 = 61
    static let greaterThan: UInt16 = 62
    static let question: UInt16 = 63
    static let atSign: UInt16 = 64
    static let upperA: UInt16 = 65
    static let upperB: UInt16 = 66
    static let upperE: UInt16 = 69
    static let upperF: UInt16 = 70
    static let upperO: UInt16 = 79
    static let upperR: UInt16 = 82
    static let upperU: UInt16 = 85
    static let upperX: UInt16 = 88
    static let upperZ: UInt16 = 90
    static let asciiCaseOffset: UInt16 = 32
    static let leftBracket: UInt16 = 91
    static let backslash: UInt16 = 92
    static let rightBracket: UInt16 = 93
    static let underscore: UInt16 = 95
    static let backtick: UInt16 = 96
    static let lowerA: UInt16 = 97
    static let lowerB: UInt16 = 98
    static let lowerC: UInt16 = 99
    static let lowerE: UInt16 = 101
    static let lowerF: UInt16 = 102
    static let lowerO: UInt16 = 111
    static let lowerR: UInt16 = 114
    static let lowerU: UInt16 = 117
    static let lowerX: UInt16 = 120
    static let lowerZ: UInt16 = 122
    static let leftBrace: UInt16 = 123
    static let rightBrace: UInt16 = 125
    static let tilde: UInt16 = 126
    static let delete: UInt16 = 127
    static let c1End: UInt16 = 0x009F
    static let softHyphen: UInt16 = 0x00AD
    static let arabicLetterMark: UInt16 = 0x061C
    static let zeroWidthSpace: UInt16 = 0x200B
    static let zeroWidthNonJoiner: UInt16 = 0x200C
    static let zeroWidthJoiner: UInt16 = 0x200D
    static let leftToRightMark: UInt16 = 0x200E
    static let rightToLeftMark: UInt16 = 0x200F
    static let combiningEnclosingKeycap: UInt32 = 0x20E3
    static let variationSelector16: UInt32 = 0xFE0F
    static let lineSeparator: UInt16 = 0x2028
    static let paragraphSeparator: UInt16 = 0x2029
    static let bidiEmbedStart: UInt16 = 0x202A
    static let bidiOverrideEnd: UInt16 = 0x202E
    static let wordJoiner: UInt16 = 0x2060
    static let invisibleOperatorEnd: UInt16 = 0x2064
    static let bidiIsolateStart: UInt16 = 0x2066
    static let bidiIsolateEnd: UInt16 = 0x2069
    static let byteOrderMark: UInt16 = 0xFEFF
    static let leadSurrogateStart: UInt16 = 0xD800
    static let leadSurrogateEnd: UInt16 = 0xDBFF
    static let trailSurrogateStart: UInt16 = 0xDC00
    static let trailSurrogateEnd: UInt16 = 0xDFFF
}

// Reference type avoids ARC copies per token.
final class PreviewLanguageGrammar: Sendable {
    struct BlockComment: Sendable {
        let open: [UInt16]
        let close: [UInt16]
        let openFirst: UInt16
        let nested: Bool

        init(_ open: String, _ close: String, nested: Bool = false) {
            let openUnits = Array(open.utf16)
            self.open = openUnits
            self.close = Array(close.utf16)
            self.openFirst = openUnits[0]
            self.nested = nested
        }
    }

    struct StringRule: Sendable {
        enum Escape: Sendable {
            case none
            case backslash
            case doubled
            case backtick
        }

        enum Scope: Sendable {
            case anywhere
            case notAfterDigit
            case markupTag
            case scalarStart
            case charLiteral
        }

        let open: [UInt16]
        let close: [UInt16]
        let openFirst: UInt16
        let openLength: Int
        let closeFirst: UInt16
        let closeLength: Int
        let escape: Escape
        let multiline: Bool
        let scope: Scope

        init(
            _ open: String,
            close: String? = nil,
            escape: Escape = .backslash,
            multiline: Bool = false,
            scope: Scope = .anywhere
        ) {
            let openUnits = Array(open.utf16)
            let closeUnits = Array((close ?? open).utf16)
            self.open = openUnits
            self.close = closeUnits
            self.openFirst = openUnits[0]
            self.openLength = openUnits.count
            self.closeFirst = closeUnits[0]
            self.closeLength = closeUnits.count
            self.escape = escape
            self.multiline = multiline
            self.scope = scope
        }
    }

    enum NumberStyle: Sendable {
        case standard
        case cDigitQuote
        case cssUnit
        case none
    }

    struct Features: OptionSet, Sendable {
        let rawValue: UInt32
        static let markupTags = Self(rawValue: 1 << 0)
        static let markdownHeadings = Self(rawValue: 1 << 1)
        static let hashPreprocessor = Self(rawValue: 1 << 2)
        static let keyBeforeColon = Self(rawValue: 1 << 3)
        static let keyBeforeEquals = Self(rawValue: 1 << 4)
        static let keyBeforeColonOrEquals = Self(rawValue: 1 << 5)
        static let iniSectionHeaders = Self(rawValue: 1 << 6)
        static let dockerfileInstructions = Self(rawValue: 1 << 7)
        static let makefileTargets = Self(rawValue: 1 << 8)
        static let latexCommands = Self(rawValue: 1 << 9)
        static let rstSyntax = Self(rawValue: 1 << 10)
        static let asciiDocSyntax = Self(rawValue: 1 << 11)
        static let diffSyntax = Self(rawValue: 1 << 12)
        static let rustRawStrings = Self(rawValue: 1 << 13)
        static let cppRawStrings = Self(rawValue: 1 << 14)
        static let luaLongBrackets = Self(rawValue: 1 << 15)
        static let heredoc = Self(rawValue: 1 << 16)
        static let objcAtKeywords = Self(rawValue: 1 << 17)
        static let slashCommentSkipsURL = Self(rawValue: 1 << 18)
        static let batchRemComment = Self(rawValue: 1 << 19)
        static let powershellHereString = Self(rawValue: 1 << 20)
        static let pythonStringPrefixes = Self(rawValue: 1 << 21)
        static let dartRawStringPrefix = Self(rawValue: 1 << 22)
        static let rustByteStringPrefix = Self(rawValue: 1 << 23)
        static let allowDollarIdentifier = Self(rawValue: 1 << 24)
        static let allowHyphenIdentifier = Self(rawValue: 1 << 25)
        static let allowAtIdentifier = Self(rawValue: 1 << 26)
        static let escapedPercentSkipsComment = Self(rawValue: 1 << 27)
        static let yamlKeyColonRequiresSpace = Self(rawValue: 1 << 28)
        static let csharpInterpolatedPrefix = Self(rawValue: 1 << 29)
    }

    private struct WordSlot: Sendable {
        let hash: UInt64
        let offset: Int
        let length: Int
        let kind: PreviewToken.Kind
    }

    let lineComments: [[UInt16]]
    let blockComments: [BlockComment]
    let strings: [StringRule]
    private let wordPool: [UInt8]
    private let wordSlots: [WordSlot?]
    private let wordMask: Int
    let caseInsensitiveKeywords: Bool
    let numberStyle: NumberStyle
    let features: Features

    // ASCII masks skip non-matching scanner branches.
    let commentLow: UInt64
    let commentHigh: UInt64
    let specialLow: UInt64
    let specialHigh: UInt64
    let stringLow: UInt64
    let stringHigh: UInt64
    let triggerLow: UInt64
    let triggerHigh: UInt64
    let minWordLength: Int
    let maxWordLength: Int

    private static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037
    private static let fnvPrime: UInt64 = 1_099_511_628_211

    init(
        lineComments: [String] = [],
        blockComments: [BlockComment] = [],
        strings: [StringRule] = [],
        keywords: String = "",
        types: String = "",
        literals: String = "",
        caseInsensitiveKeywords: Bool = false,
        numberStyle: NumberStyle = .standard,
        features: Features = []
    ) {
        self.lineComments = lineComments.map { Array($0.utf16) }
        self.blockComments = blockComments
        self.strings = strings
        let normalize: (Substring) -> String =
            caseInsensitiveKeywords ? { $0.lowercased() } : { String($0) }
        var map: [String: PreviewToken.Kind] = [:]
        for word in types.split(separator: " ") { map[normalize(word)] = .type }
        for word in keywords.split(separator: " ") { map[normalize(word)] = .keyword }
        for word in literals.split(separator: " ") { map[normalize(word)] = .keyword }
        var pool: [UInt8] = []
        var capacity = 16
        while capacity < map.count * 4 { capacity <<= 1 }
        var slots = [WordSlot?](repeating: nil, count: capacity)
        let mask = capacity - 1
        for (word, kind) in map {
            let bytes = Array(word.utf8)
            let offset = pool.count
            pool.append(contentsOf: bytes)
            var hash = Self.fnvOffsetBasis
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= Self.fnvPrime
            }
            var index = Int(truncatingIfNeeded: hash) & mask
            while slots[index] != nil { index = (index + 1) & mask }
            slots[index] = WordSlot(hash: hash, offset: offset, length: bytes.count, kind: kind)
        }
        self.wordPool = pool
        self.wordSlots = slots
        self.wordMask = mask
        self.caseInsensitiveKeywords = caseInsensitiveKeywords
        self.numberStyle = numberStyle
        self.features = features

        var cLow: UInt64 = 0
        var cHigh: UInt64 = 0
        var spLow: UInt64 = 0
        var spHigh: UInt64 = 0
        var stLow: UInt64 = 0
        var stHigh: UInt64 = 0
        func mark(_ unit: UInt16, low: inout UInt64, high: inout UInt64) {
            if unit < 64 {
                low |= 1 << UInt64(unit)
            } else if unit < 128 {
                high |= 1 << UInt64(unit - 64)
            }
        }
        for marker in self.lineComments {
            if let first = marker.first { mark(first, low: &cLow, high: &cHigh) }
        }
        for block in blockComments {
            mark(block.openFirst, low: &cLow, high: &cHigh)
        }
        if features.contains(.luaLongBrackets) {
            mark(UTF16Code.minus, low: &cLow, high: &cHigh)
            mark(UTF16Code.leftBracket, low: &spLow, high: &spHigh)
        }
        if features.contains(.markdownHeadings) || features.contains(.hashPreprocessor) {
            mark(UTF16Code.hash, low: &cLow, high: &cHigh)
        }
        if features.contains(.iniSectionHeaders) { mark(UTF16Code.leftBracket, low: &cLow, high: &cHigh) }
        if features.contains(.latexCommands) { mark(UTF16Code.backslash, low: &cLow, high: &cHigh) }
        if features.contains(.rustRawStrings) {
            mark(UTF16Code.lowerR, low: &spLow, high: &spHigh)
            mark(UTF16Code.lowerB, low: &spLow, high: &spHigh)
        }
        if features.contains(.cppRawStrings) { mark(UTF16Code.upperR, low: &spLow, high: &spHigh) }
        if features.contains(.heredoc) { mark(UTF16Code.lessThan, low: &spLow, high: &spHigh) }
        if features.contains(.objcAtKeywords) || features.contains(.powershellHereString) {
            mark(UTF16Code.atSign, low: &spLow, high: &spHigh)
        }
        if features.contains(.pythonStringPrefixes) {
            for unit in "rfbuRFBU".utf16 { mark(unit, low: &spLow, high: &spHigh) }
        }
        if features.contains(.dartRawStringPrefix) { mark(UTF16Code.lowerR, low: &spLow, high: &spHigh) }
        if features.contains(.rustByteStringPrefix) {
            mark(UTF16Code.lowerB, low: &spLow, high: &spHigh)
            mark(UTF16Code.lowerC, low: &spLow, high: &spHigh)
        }
        if features.contains(.csharpInterpolatedPrefix) {
            mark(UTF16Code.dollar, low: &spLow, high: &spHigh)
            mark(UTF16Code.atSign, low: &spLow, high: &spHigh)
        }
        for rule in strings {
            mark(rule.openFirst, low: &stLow, high: &stHigh)
        }
        if features.contains(.markupTags) {
            mark(UTF16Code.lessThan, low: &stLow, high: &stHigh)
            mark(UTF16Code.greaterThan, low: &stLow, high: &stHigh)
            mark(UTF16Code.slash, low: &stLow, high: &stHigh)
        }
        if numberStyle == .cssUnit { mark(UTF16Code.hash, low: &stLow, high: &stHigh) }

        self.commentLow = cLow
        self.commentHigh = cHigh
        self.specialLow = spLow
        self.specialHigh = spHigh
        self.stringLow = stLow
        self.stringHigh = stHigh
        self.triggerLow = cLow | spLow | stLow
        self.triggerHigh = cHigh | spHigh | stHigh

        var shortest = Int.max
        var longest = 0
        for word in map.keys {
            let count = word.utf16.count
            if count < shortest { shortest = count }
            if count > longest { longest = count }
        }
        self.minWordLength = shortest
        self.maxWordLength = longest
    }

    @inline(__always)
    func triggersSpecial(_ unit: UInt16) -> Bool {
        if unit < 64 { return (triggerLow & (1 << UInt64(unit))) != 0 }
        if unit < 128 { return (triggerHigh & (1 << UInt64(unit - 64))) != 0 }
        return false
    }

    @inline(__always)
    func triggersComment(_ unit: UInt16) -> Bool {
        if unit < 64 { return (commentLow & (1 << UInt64(unit))) != 0 }
        if unit < 128 { return (commentHigh & (1 << UInt64(unit - 64))) != 0 }
        return false
    }

    @inline(__always)
    func triggersSpecialLiteral(_ unit: UInt16) -> Bool {
        if unit < 64 { return (specialLow & (1 << UInt64(unit))) != 0 }
        if unit < 128 { return (specialHigh & (1 << UInt64(unit - 64))) != 0 }
        return false
    }

    @inline(__always)
    func triggersStringOrMarkup(_ unit: UInt16) -> Bool {
        if unit < 64 { return (stringLow & (1 << UInt64(unit))) != 0 }
        if unit < 128 { return (stringHigh & (1 << UInt64(unit - 64))) != 0 }
        return false
    }

    func lookupWord(_ buffer: UnsafeBufferPointer<UInt16>, start: Int, end: Int) -> PreviewToken.Kind? {
        let length = end - start
        guard length >= minWordLength, length <= maxWordLength else { return nil }
        var hash = Self.fnvOffsetBasis
        let fold = caseInsensitiveKeywords
        for index in start..<end {
            var unit = buffer[index]
            if unit >= UTF16Code.delete { return nil }
            if fold, (UTF16Code.upperA...UTF16Code.upperZ).contains(unit) { unit &+= UTF16Code.asciiCaseOffset }
            hash ^= UInt64(unit)
            hash &*= Self.fnvPrime
        }
        var slotIndex = Int(truncatingIfNeeded: hash) & wordMask
        while let slot = wordSlots[slotIndex] {
            if slot.hash == hash, slot.length == length {
                var matched = true
                for offset in 0..<length {
                    var unit = buffer[start + offset]
                    if fold, (UTF16Code.upperA...UTF16Code.upperZ).contains(unit) {
                        unit &+= UTF16Code.asciiCaseOffset
                    }
                    if UInt8(truncatingIfNeeded: unit) != wordPool[slot.offset + offset] {
                        matched = false
                        break
                    }
                }
                if matched { return slot.kind }
            }
            slotIndex = (slotIndex + 1) & wordMask
        }
        return nil
    }

    static func grammar(for language: PreviewLanguage) -> PreviewLanguageGrammar {
        switch language {
        case .plain: plain
        case .swift: swift
        case .javascript: javascript
        case .python: python
        case .c: c
        case .cpp: cpp
        case .objectiveC: objectiveC
        case .objectiveCPP: objectiveCPP
        case .go: go
        case .rust: rust
        case .ruby: ruby
        case .php: php
        case .java: java
        case .kotlin: kotlin
        case .csharp: csharp
        case .scala: scala
        case .dart: dart
        case .lua: lua
        case .perl: perl
        case .r: rLanguage
        case .shell: shell
        case .powershell: powershell
        case .batch: batch
        case .sql: sql
        case .json: json
        case .yaml: yaml
        case .toml: toml
        case .ini: ini
        case .dockerfile: dockerfile
        case .makefile: makefile
        case .cmake: cmake
        case .groovy: groovy
        case .hcl: hcl
        case .protobuf: protobuf
        case .graphql: graphql
        case .css: css
        case .markup: markup
        case .markdown: markdown
        case .latex: latex
        case .restructuredText: restructuredText
        case .asciiDoc: asciiDoc
        case .diff: diff
        case .fsharp: fsharp
        case .vb: vb
        case .julia: julia
        case .elixir: elixir
        case .clojure: clojure
        case .solidity: solidity
        }
    }

    private static let cKeywords =
        "alignas alignof auto break case const constexpr continue default do else enum extern for goto if inline register restrict return sizeof static static_assert struct switch thread_local typedef typeof union unsigned volatile while _Alignas _Alignof _Atomic _Bool _Complex _Generic _Imaginary _Noreturn _Static_assert _Thread_local"
    private static let cTypes =
        "void char short int long float double signed bool size_t ssize_t ptrdiff_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t intptr_t uintptr_t FILE"
    private static let cLiterals = "true false nullptr NULL"
    private static let cppExtraKeywords =
        "and and_eq bitand bitor catch class co_await co_return co_yield compl concept const_cast consteval constinit decltype delete dynamic_cast explicit export final friend mutable namespace new noexcept not not_eq operator or or_eq override private protected public reinterpret_cast requires static_cast template this throw try typeid typename using virtual xor xor_eq"
    private static let cppExtraTypes =
        "wchar_t char8_t char16_t char32_t string string_view vector map unordered_map set unordered_set array span optional variant tuple pair unique_ptr shared_ptr weak_ptr function std"
    private static let objcExtraKeywords =
        "id instancetype self super atomic nonatomic readonly readwrite strong weak copy assign retain unsafe_unretained nullable nonnull null_resettable __weak __strong __block __unsafe_unretained in out inout bycopy byref oneway"
    private static let objcExtraTypes =
        "BOOL NSObject NSString NSMutableString NSArray NSMutableArray NSDictionary NSMutableDictionary NSSet NSNumber NSData NSURL NSError NSInteger NSUInteger CGFloat CGRect CGPoint CGSize SEL IMP Class Protocol"
    private static let objcExtraLiterals = "YES NO nil Nil"

    static let plain = PreviewLanguageGrammar(numberStyle: .none)

    static let swift = PreviewLanguageGrammar(
        lineComments: ["//"],
        blockComments: [BlockComment("/*", "*/", nested: true)],
        strings: [
            StringRule("\"\"\"", multiline: true),
            StringRule("\""),
        ],
        keywords:
            "actor any as async await borrowing break case catch class consuming continue default defer do else enum extension fileprivate for func guard if import in init inout internal is let nonisolated open private protocol public repeat rethrows return self Self some static struct super switch throw throws try typealias var weak where while",
        types:
            "Any AnyObject Array Bool Character Codable Data Date Dictionary Double Error Equatable Float Hashable Int Int8 Int16 Int32 Int64 Never Optional Result Sendable Set String UInt UInt8 UInt16 UInt32 UInt64 URL Void",
        literals: "true false nil",
        features: [.hashPreprocessor]
    )

    static let javascript = PreviewLanguageGrammar(
        lineComments: ["//"],
        blockComments: [BlockComment("/*", "*/")],
        strings: [
            StringRule("`", multiline: true),
            StringRule("\""),
            StringRule("'"),
        ],
        keywords:
            "abstract as async await break case catch class const continue debugger declare default delete do else enum export extends finally for from function get if implements import in instanceof interface keyof let namespace new of override private protected public readonly return satisfies set static super switch this throw try type typeof var void while with yield",
        types:
            "Array BigInt Boolean Date Error Function Map Math Number Object Promise Record RegExp Set String Symbol WeakMap WeakSet any bigint boolean console document globalThis never number object string symbol unknown window",
        literals: "true false null undefined NaN Infinity"
    )

    static let python = PreviewLanguageGrammar(
        lineComments: ["#"],
        strings: [
            StringRule("\"\"\"", multiline: true),
            StringRule("'''", multiline: true),
            StringRule("\""),
            StringRule("'"),
        ],
        keywords:
            "and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try while with yield",
        types:
            "bool bytearray bytes complex dict enumerate Exception filter float frozenset int isinstance issubclass KeyError len list map memoryview object print range reversed RuntimeError set sorted str super tuple type TypeError ValueError zip",
        literals: "True False None",
        features: [.pythonStringPrefixes]
    )

    static let c = PreviewLanguageGrammar(
        lineComments: ["//"],
        blockComments: [BlockComment("/*", "*/")],
        strings: [
            StringRule("\""),
            StringRule("'", scope: .notAfterDigit),
        ],
        keywords: cKeywords,
        types: cTypes,
        literals: cLiterals,
        numberStyle: .cDigitQuote,
        features: [.hashPreprocessor]
    )

    static let cpp = PreviewLanguageGrammar(
        lineComments: ["//"],
        blockComments: [BlockComment("/*", "*/")],
        strings: [
            StringRule("\""),
            StringRule("'", scope: .notAfterDigit),
        ],
        keywords: cKeywords + " " + cppExtraKeywords,
        types: cTypes + " " + cppExtraTypes,
        literals: cLiterals,
        numberStyle: .cDigitQuote,
        features: [.hashPreprocessor, .cppRawStrings]
    )

    static let objectiveC = PreviewLanguageGrammar(
        lineComments: ["//"],
        blockComments: [BlockComment("/*", "*/")],
        strings: [
            StringRule("\""),
            StringRule("'", scope: .notAfterDigit),
        ],
        keywords: cKeywords + " " + objcExtraKeywords,
        types: cTypes + " " + objcExtraTypes,
        literals: cLiterals + " " + objcExtraLiterals,
        numberStyle: .cDigitQuote,
        features: [.hashPreprocessor, .objcAtKeywords]
    )

    static let objectiveCPP = PreviewLanguageGrammar(
        lineComments: ["//"],
        blockComments: [BlockComment("/*", "*/")],
        strings: [
            StringRule("\""),
            StringRule("'", scope: .notAfterDigit),
        ],
        keywords: cKeywords + " " + cppExtraKeywords + " " + objcExtraKeywords,
        types: cTypes + " " + cppExtraTypes + " " + objcExtraTypes,
        literals: cLiterals + " " + objcExtraLiterals,
        numberStyle: .cDigitQuote,
        features: [.hashPreprocessor, .objcAtKeywords, .cppRawStrings]
    )

    static let go = PreviewLanguageGrammar(
        lineComments: ["//"],
        blockComments: [BlockComment("/*", "*/")],
        strings: [
            StringRule("`", escape: .none, multiline: true),
            StringRule("\""),
            StringRule("'"),
        ],
        keywords:
            "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var",
        types:
            "any append bool byte cap clear close comparable complex complex64 complex128 copy delete error float32 float64 imag int int8 int16 int32 int64 len make max min new panic print println real recover rune string uint uint8 uint16 uint32 uint64 uintptr",
        literals: "true false nil iota"
    )

    static let rust = PreviewLanguageGrammar(
        lineComments: ["//"],
        blockComments: [BlockComment("/*", "*/", nested: true)],
        strings: [
            StringRule("\"", multiline: true),
            StringRule("'", scope: .charLiteral),
        ],
        keywords:
            "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while yield",
        types:
            "Arc bool Box char Clone Copy Debug Default Drop Eq Err f32 f64 Fn FnMut FnOnce Hash i8 i16 i32 i64 i128 IntoIterator isize Iterator None Ok Option Ord PartialEq PartialOrd Rc Result Send Sized Some str String Sync u8 u16 u32 u64 u128 usize Vec",
        literals: "true false",
        features: [.rustRawStrings, .rustByteStringPrefix]
    )

    static let ruby = PreviewLanguageGrammar(
        lineComments: ["#"],
        strings: [
            StringRule("\"", multiline: true),
            StringRule("'", multiline: true),
            StringRule("`", multiline: true),
        ],
        keywords:
            "BEGIN END alias and attr_accessor attr_reader attr_writer begin break case class def do else elsif end ensure extend for if in include module next not or private protected public raise redo require require_relative rescue retry return self super then undef unless until when while yield",
        types:
            "Array BasicObject Class Comparable Enumerable Exception FalseClass File Float Hash Integer IO Kernel MatchData Module NilClass Numeric Object p print Proc puts Range Regexp String Struct Symbol Thread Time TrueClass",
        literals: "true false nil",
        features: [.heredoc]
    )

    static let php = PreviewLanguageGrammar(
        lineComments: ["//", "#"],
        blockComments: [BlockComment("/*", "*/")],
        strings: [
            StringRule("\"", multiline: true),
            StringRule("'", multiline: true),
        ],
        keywords:
            "abstract and array as break callable case catch class clone const continue declare default die do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum eval exit extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield",
        types:
            "bool Closure DateTime Exception float int iterable mixed never object parent self stdClass string Throwable void",
        literals: "true false null TRUE FALSE NULL",
        features: [.heredoc, .allowDollarIdentifier]
    )

    static let java = PreviewLanguageGrammar(
        lineComments: ["//"],
        blockComments: [BlockComment("/*", "*/")],
        strings: [
            StringRule("\"\"\"", multiline: true),
            StringRule("\""),
            StringRule("'"),
        ],
        keywords:
            "abstract assert boolean break byte case catch char class const continue default do double else enum exports extends final finally float for goto if implements import instanceof int interface long module native new non-sealed open opens package permits private protected provides public record requires return sealed short static strictfp super switch synchronized this throw throws to transient transitive try uses var void volatile while with yield",
        types:
            "ArrayList Boolean Byte Character Class Double Exception Float HashMap HashSet Integer List Long Map Math Object Optional Override RuntimeException Set Short Stream String StringBuilder System Throwable Void",
        literals: "true false null"
    )

    static let kotlin = PreviewLanguageGrammar(
        lineComments: ["//"],
        blockComments: [BlockComment("/*", "*/", nested: true)],
        strings: [
            StringRule("\"\"\"", escape: .none, multiline: true),
            StringRule("\""),
            StringRule("'"),
        ],
        keywords:
            "abstract actual annotation as break by catch class companion const constructor continue crossinline data delegate do dynamic else enum expect external final finally for fun get if import in infix init inline inner interface internal is lateinit noinline object open operator out override package private protected public reified return sealed set super suspend tailrec this throw try typealias typeof val value var vararg when where while",
        types:
            "Any Array Boolean Byte Char Double Exception Float Int List Long Map MutableList MutableMap MutableSet Nothing Pair print println Result Sequence Set Short String Throwable Triple Unit",
        literals: "true false null"
    )

    static let csharp = PreviewLanguageGrammar(
        lineComments: ["//"],
        blockComments: [BlockComment("/*", "*/")],
        strings: [
            StringRule("\"\"\"", escape: .none, multiline: true),
            StringRule("@\"", close: "\"", escape: .doubled, multiline: true),
            StringRule("\""),
            StringRule("'"),
        ],
        keywords:
            "abstract as async await base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern file finally fixed float for foreach goto if implicit in init int interface internal is lock long namespace new nint nuint object operator out override params private protected public readonly record ref required return sbyte scoped sealed short sizeof stackalloc static string struct switch this throw try typeof uint ulong unchecked unsafe ushort using var virtual void volatile when where while with yield",
        types:
            "Action Boolean Char Console DateTime Decimal Dictionary Double Exception Func Guid HashSet IEnumerable Int32 Int64 IQueryable List Object String Task TimeSpan ValueTask Void",
        literals: "true false null",
        features: [.hashPreprocessor, .csharpInterpolatedPrefix]
    )

    static let scala = PreviewLanguageGrammar(
        lineComments: ["//"],
        blockComments: [BlockComment("/*", "*/", nested: true)],
        strings: [
            StringRule("\"\"\"", escape: .none, multiline: true),
            StringRule("\""),
            StringRule("'", scope: .charLiteral),
        ],
        keywords:
            "abstract case catch class def do else enum export extends final finally for forSome given if implicit import inline lazy match new object opaque open override package private protected return sealed super then this throw trait transparent try type using val var while with yield",
        types:
            "Any AnyRef AnyVal Boolean Byte Char Double Either Failure Float Future Int Left List Long Map None Nothing Null Option println Right Seq Set Short Some String Success Try Unit Vector",
        literals: "true false null"
    )

    static let dart = PreviewLanguageGrammar(
        lineComments: ["//"],
        blockComments: [BlockComment("/*", "*/")],
        strings: [
            StringRule("\"\"\"", multiline: true),
            StringRule("'''", multiline: true),
            StringRule("\""),
            StringRule("'"),
        ],
        keywords:
            "abstract as assert async await base break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory final finally for get hide if implements import in interface is late library mixin new of on operator part required rethrow return sealed set show static super switch sync this throw try typedef var void when while with yield",
        types:
            "bool DateTime double Duration Error Exception Function Future int Iterable List Map Never num Object print RegExp Set Stream String Type Uri",
        literals: "true false null",
        features: [.dartRawStringPrefix]
    )

    static let lua = PreviewLanguageGrammar(
        lineComments: ["--"],
        strings: [
            StringRule("\""),
            StringRule("'"),
        ],
        keywords:
            "and break do else elseif end for function goto if in local not or repeat return then until while",
        types:
            "assert collectgarbage coroutine dofile error getmetatable io ipairs load loadfile math next os package pairs pcall print rawequal rawget rawlen rawset require select setmetatable string table tonumber tostring type utf8 xpcall _G _VERSION",
        literals: "true false nil",
        features: [.luaLongBrackets]
    )

    static let perl = PreviewLanguageGrammar(
        lineComments: ["#"],
        strings: [
            StringRule("\"", multiline: true),
            StringRule("'", multiline: true),
            StringRule("`", multiline: true),
        ],
        keywords:
            "and cmp continue CORE do else elsif eq eval for foreach ge goto gt if last le local lt my ne next no or our package redo ref return say state sub unless until use while xor",
        types:
            "chomp chop close defined delete die each exists grep join keys length map open pop print printf push reverse scalar shift sort split sprintf substr undef unshift values warn",
        features: [.heredoc, .allowDollarIdentifier]
    )

    static let rLanguage = PreviewLanguageGrammar(
        lineComments: ["#"],
        strings: [
            StringRule("\"", multiline: true),
            StringRule("'", multiline: true),
            StringRule("`"),
        ],
        keywords: "break else for function if in library next repeat require return source while",
        types:
            "apply c cat character colnames complex dim factor ifelse integer lapply length list logical matrix max mean median min names ncol nrow numeric paste paste0 print range rep rownames sapply sd seq sprintf sum tapply var vector which",
        literals: "TRUE FALSE NULL Inf NaN NA NA_integer_ NA_real_ NA_complex_ NA_character_"
    )

    static let shell = PreviewLanguageGrammar(
        lineComments: ["#"],
        strings: [
            StringRule("\"", multiline: true),
            StringRule("'", escape: .none, multiline: true),
            StringRule("`", multiline: true),
        ],
        keywords:
            "and begin break case continue coproc declare do done elif else end esac exit export fi for function if in local not or readonly return select set shift switch then time trap typeset unset until while",
        types:
            "alias awk builtin cat cd command cp echo eval exec find grep ls mkdir mv printf pwd read rm rmdir sed source test type unalias which xargs",
        literals: "true false",
        features: [.heredoc, .allowDollarIdentifier]
    )

    static let powershell = PreviewLanguageGrammar(
        lineComments: ["#"],
        blockComments: [BlockComment("<#", "#>")],
        strings: [
            StringRule("\"", escape: .backtick, multiline: true),
            StringRule("'", escape: .doubled, multiline: true),
        ],
        keywords:
            "begin break catch class continue data do dynamicparam else elseif end enum exit filter finally for foreach from function hidden if in inlinescript parallel param process return sequence switch throw trap try until using var while workflow",
        types:
            "array bool byte char datetime decimal double get-content get-item guid hashtable int int32 int64 object pscustomobject set-content set-item string test-path timespan void write-error write-host write-output write-warning",
        literals: "$true $false $null",
        caseInsensitiveKeywords: true,
        features: [.powershellHereString, .allowDollarIdentifier, .allowHyphenIdentifier]
    )

    static let batch = PreviewLanguageGrammar(
        lineComments: ["::"],
        strings: [
            StringRule("\"", escape: .none)
        ],
        keywords:
            "assoc attrib break call cd chdir cls cmdextversion color comp compact copy date defined del dir do echo else endlocal equ erase errorlevel exist exit for ftype geq goto gtr if in leq lss md mkdir mklink move neq not off on path pause popd prompt pushd rd rem ren rename rmdir set setlocal shift start time title type ver verify vol",
        types: "aux con nul prn",
        caseInsensitiveKeywords: true,
        features: [.batchRemComment]
    )

    static let sql = PreviewLanguageGrammar(
        lineComments: ["--"],
        blockComments: [BlockComment("/*", "*/")],
        strings: [
            StringRule("'", escape: .doubled, multiline: true)
        ],
        keywords:
            "add all alter and any as asc between by case cast check column commit constraint create cross current_date current_time current_timestamp default delete desc distinct drop else end escape except exists explain fetch for foreign from full group having ilike in index inner insert intersect into is join key left like limit not null offset on or order outer primary references returning right rollback select set table then to transaction union unique update using values view when where with",
        types:
            "avg bigint binary bit blob boolean char character clob coalesce count date datetime decimal double float int integer json jsonb length lower max min now nullif numeric real smallint substr sum text time timestamp tinyint trim upper uuid varbinary varchar",
        literals: "true false null",
        caseInsensitiveKeywords: true
    )

    static let json = PreviewLanguageGrammar(
        lineComments: ["//"],
        blockComments: [BlockComment("/*", "*/")],
        strings: [
            StringRule("\"")
        ],
        literals: "true false null"
    )

    static let yaml = PreviewLanguageGrammar(
        lineComments: ["#"],
        strings: [
            StringRule("\"", scope: .scalarStart),
            StringRule("'", escape: .doubled, scope: .scalarStart),
        ],
        literals: "true false null yes no on off",
        features: [.keyBeforeColon, .yamlKeyColonRequiresSpace]
    )

    static let toml = PreviewLanguageGrammar(
        lineComments: ["#"],
        strings: [
            StringRule("\"\"\"", multiline: true, scope: .scalarStart),
            StringRule("'''", escape: .none, multiline: true, scope: .scalarStart),
            StringRule("\"", scope: .scalarStart),
            StringRule("'", escape: .none, scope: .scalarStart),
        ],
        literals: "true false inf nan",
        features: [.iniSectionHeaders, .keyBeforeEquals]
    )

    static let ini = PreviewLanguageGrammar(
        lineComments: ["#", ";"],
        strings: [
            StringRule("\"", scope: .scalarStart),
            StringRule("'", escape: .none, scope: .scalarStart),
        ],
        literals: "true false yes no on off null",
        features: [.iniSectionHeaders, .keyBeforeColonOrEquals]
    )

    static let dockerfile = PreviewLanguageGrammar(
        lineComments: ["#"],
        strings: [
            StringRule("\""),
            StringRule("'", escape: .none),
        ],
        keywords:
            "add arg as cmd copy entrypoint env expose from healthcheck label maintainer onbuild run shell stopsignal user volume workdir",
        caseInsensitiveKeywords: true,
        features: [.dockerfileInstructions]
    )

    static let makefile = PreviewLanguageGrammar(
        lineComments: ["#"],
        strings: [
            StringRule("\""),
            StringRule("'", escape: .none),
        ],
        keywords:
            "define else endef endif export ifdef ifeq ifndef ifneq include override private sinclude undefine unexport vpath",
        features: [.makefileTargets]
    )

    static let cmake = PreviewLanguageGrammar(
        lineComments: ["#"],
        blockComments: [BlockComment("#[[", "]]")],
        strings: [
            StringRule("\"", multiline: true)
        ],
        keywords:
            "add_custom_command add_custom_target add_executable add_library add_subdirectory add_test break cmake_minimum_required configure_file continue else elseif enable_testing endforeach endfunction endif endmacro endwhile execute_process file find_library find_package find_path foreach function if include install list macro math message option project return set string target_compile_definitions target_compile_options target_include_directories target_link_libraries unset while",
        types:
            "alias and config defined exists imported interface matches module not or private public quiet required shared static version_equal version_greater version_less",
        literals: "true false on off yes no",
        caseInsensitiveKeywords: true
    )

    static let groovy = PreviewLanguageGrammar(
        lineComments: ["//"],
        blockComments: [BlockComment("/*", "*/")],
        strings: [
            StringRule("\"\"\"", multiline: true),
            StringRule("'''", multiline: true),
            StringRule("\""),
            StringRule("'"),
        ],
        keywords:
            "abstract api as assert break case catch class compileOnly const continue def default dependencies do else enum extends final finally for goto if implementation implements import in instanceof interface native new package plugins private protected public repositories return runtimeOnly static strictfp super switch synchronized tasks testImplementation this throw throws trait transient try var void volatile while",
        types: "Boolean Closure Double File Float Integer List Long Map Object println Set String",
        literals: "true false null"
    )

    static let hcl = PreviewLanguageGrammar(
        lineComments: ["#", "//"],
        blockComments: [BlockComment("/*", "*/")],
        strings: [
            StringRule("\"")
        ],
        keywords:
            "assert backend check content count data depends_on dynamic for for_each if import in lifecycle locals module moved output provider required_providers required_version resource terraform variable",
        types:
            "any bool coalesce concat flatten format join keys length list lookup map merge number object set split string tuple values",
        literals: "true false null",
        features: [.heredoc]
    )

    static let protobuf = PreviewLanguageGrammar(
        lineComments: ["//"],
        blockComments: [BlockComment("/*", "*/")],
        strings: [
            StringRule("\""),
            StringRule("'"),
        ],
        keywords:
            "edition enum extend extensions group import map max message oneof option optional package public repeated required reserved returns rpc service stream syntax to weak",
        types:
            "bool bytes double fixed32 fixed64 float int32 int64 sfixed32 sfixed64 sint32 sint64 string uint32 uint64",
        literals: "true false"
    )

    static let graphql = PreviewLanguageGrammar(
        lineComments: ["#"],
        strings: [
            StringRule("\"\"\"", multiline: true),
            StringRule("\""),
        ],
        keywords:
            "directive enum extend fragment implements input interface mutation on query repeatable scalar schema subscription type union",
        types: "Boolean Float ID Int String",
        literals: "true false null"
    )

    static let css = PreviewLanguageGrammar(
        lineComments: ["//"],
        blockComments: [BlockComment("/*", "*/")],
        strings: [
            StringRule("\""),
            StringRule("'"),
        ],
        keywords:
            "auto calc clamp from important inherit initial keyframes max media min none revert supports to unset var @charset @container @each @else @extend @font-face @for @forward @if @import @include @keyframes @layer @media @mixin @supports @use",
        numberStyle: .cssUnit,
        features: [.keyBeforeColon, .slashCommentSkipsURL, .allowHyphenIdentifier, .allowAtIdentifier]
    )

    static let markup = PreviewLanguageGrammar(
        blockComments: [BlockComment("<!--", "-->")],
        strings: [
            StringRule("\"", escape: .none, scope: .markupTag),
            StringRule("'", escape: .none, scope: .markupTag),
        ],
        numberStyle: .none,
        features: [.markupTags]
    )

    static let markdown = PreviewLanguageGrammar(
        blockComments: [BlockComment("<!--", "-->")],
        strings: [
            StringRule("```", escape: .none, multiline: true),
            StringRule("`", escape: .none),
        ],
        numberStyle: .none,
        features: [.markdownHeadings]
    )

    static let latex = PreviewLanguageGrammar(
        lineComments: ["%"],
        numberStyle: .none,
        features: [.latexCommands, .escapedPercentSkipsComment]
    )

    static let restructuredText = PreviewLanguageGrammar(
        numberStyle: .none,
        features: [.rstSyntax]
    )

    static let asciiDoc = PreviewLanguageGrammar(
        numberStyle: .none,
        features: [.asciiDocSyntax]
    )

    static let diff = PreviewLanguageGrammar(
        numberStyle: .none,
        features: [.diffSyntax]
    )

    static let fsharp = PreviewLanguageGrammar(
        lineComments: ["//"],
        blockComments: [BlockComment("(*", "*)", nested: true)],
        strings: [
            StringRule("\"\"\"", escape: .none, multiline: true),
            StringRule("@\"", close: "\"", escape: .doubled, multiline: true),
            StringRule("\"", multiline: true),
            StringRule("'", scope: .charLiteral),
        ],
        keywords:
            "abstract and as assert base begin class default delegate do done downcast downto elif else end exception extern finally fixed for fun function global if in inherit inline interface internal lazy let match member module mutable namespace new not of open or override private public rec return select static struct then to try type upcast use val void when while with yield",
        types:
            "array bool byte char decimal Error float float32 int int16 int64 list Map None obj Ok option printfn Result sbyte seq Set Some string uint16 uint32 uint64 unit",
        literals: "true false null"
    )

    static let vb = PreviewLanguageGrammar(
        lineComments: ["'"],
        strings: [
            StringRule("\"", escape: .doubled)
        ],
        keywords:
            "addhandler addressof alias and andalso as byref byval call case catch cbool cbyte cchar cdate cdbl cdec cint class clng cobj const continue csbyte cshort csng cstr ctype cuint culng cushort declare default delegate dim directcast do each else elseif end endif enum erase error event exit finally for friend function get gettype global gosub goto handles if implements imports in inherits interface is isnot let lib like loop me mod module mustinherit mustoverride mybase myclass namespace narrowing new next not notinheritable notoverridable of on operator option optional or orelse out overloads overridable overrides paramarray partial private property protected public raiseevent readonly redim rem removehandler resume return select set shadows shared static step stop structure sub synclock then throw to try trycast typeof using variant wend when while widening with withevents writeonly xor",
        types:
            "boolean byte char date decimal double integer long object sbyte short single string uinteger ulong ushort",
        literals: "true false nothing",
        caseInsensitiveKeywords: true,
        features: [.batchRemComment]
    )

    static let julia = PreviewLanguageGrammar(
        lineComments: ["#"],
        blockComments: [BlockComment("#=", "=#", nested: true)],
        strings: [
            StringRule("\"\"\"", multiline: true),
            StringRule("\"", multiline: true),
            StringRule("'", scope: .charLiteral),
        ],
        keywords:
            "baremodule begin break catch const continue do else elseif end export finally for function global if import in isa let local macro module mutable quote return struct try using where while",
        types:
            "Any Array Bool Char Dict Float16 Float32 Float64 Int Int8 Int16 Int32 Int64 Matrix Missing NamedTuple Nothing Pair print println Set String Symbol Tuple UInt UInt8 UInt16 UInt32 UInt64 Vector",
        literals: "true false nothing missing"
    )

    static let elixir = PreviewLanguageGrammar(
        lineComments: ["#"],
        strings: [
            StringRule("\"\"\"", multiline: true),
            StringRule("'''", multiline: true),
            StringRule("\"", multiline: true),
            StringRule("'", multiline: true),
        ],
        keywords:
            "after alias and case catch cond def defdelegate defexception defimpl defmacro defmacrop defmodule defoverridable defp defprotocol defstruct do else end fn for if import in not or quote raise receive require rescue try unless unquote use when with",
        types:
            "Atom Enum File GenServer IO Kernel Keyword List Map MapSet Module Process Range Regex Stream String Supervisor Task Tuple",
        literals: "true false nil"
    )

    static let clojure = PreviewLanguageGrammar(
        lineComments: [";"],
        strings: [
            StringRule("\"", multiline: true)
        ],
        keywords:
            "and case catch cond condp def defmacro defmethod defmulti defn defn- defonce defprotocol defrecord defstruct deftype do doto finally fn if if-let if-not import let letfn loop new not ns or quote recur refer require syntax-quote throw try unquote use var when when-let when-not",
        types:
            "apply assoc assoc-in atom comp conj cons count deref dissoc filter first get get-in hash-map hash-set list map next partial println prn reduce rest seq str update vec",
        literals: "true false nil",
        features: [.allowHyphenIdentifier]
    )

    static let solidity = PreviewLanguageGrammar(
        lineComments: ["//"],
        blockComments: [BlockComment("/*", "*/")],
        strings: [
            StringRule("\""),
            StringRule("'"),
        ],
        keywords:
            "abstract anonymous as assembly break catch constant constructor continue contract delete do else emit enum error event external fallback for function if immutable import indexed interface internal is library mapping memory modifier new override payable pragma private public pure receive return returns revert solidity storage struct try type unchecked using view virtual while",
        types:
            "abi address assert block bool bytes bytes1 bytes4 bytes32 int int8 int32 int64 int128 int256 keccak256 msg require string tx uint uint8 uint16 uint32 uint64 uint128 uint256",
        literals: "true false"
    )
}
