import Foundation
import Testing

@testable import Engine

private func formattedJSON(_ text: String, _ formatting: JSONFormatting, settings: TextSettings) throws -> String {
    let output = FileManager.default.temporaryDirectory.appending(path: "MacEaseJSON-\(UUID().uuidString)")
    defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: output) } }
    let source = output.appendingPathExtension("source")
    try Data(text.utf8).write(to: source)
    defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: source) } }
    try JSONFormatter.write(source, formatting, settings: settings, to: output)
    #expect(try Data(contentsOf: source) == Data(text.utf8))
    return try String(contentsOf: output, encoding: .utf8)
}

@Suite struct JSONSortTests {
    @Test func ordinalOrderUsesUnicodeScalars() throws {
        let source = "{\"😀\":4,\"\u{E000}\":3,\"é\":2,\"e\u{301}\":1}"
        let output = try formattedJSON(source, .sortKeys, settings: TextSettings())
        #expect(output == "{\n  \"e\u{301}\": 1,\n  \"é\": 2,\n  \"\u{E000}\": 3,\n  \"😀\": 4\n}\n")
    }

    @Test func prettyAndMinifyIgnoreSortOptionsAndPreserveNumbers() throws {
        var settings = TextSettings()
        settings.jsonDescending = true
        settings.jsonPinnedKeys = ["a"]
        settings.jsonSortPrimitiveArrays = true
        let source = #"{"z":9007199254740993,"a":[2,1e+003]}"#
        #expect(try formattedJSON(source, .minify, settings: settings) == source)
        #expect(
            try formattedJSON(source, .pretty, settings: settings)
                == "{\n  \"z\": 9007199254740993,\n  \"a\": [\n    2,\n    1e+003\n  ]\n}\n")
    }

    @Test func caseInsensitiveOrderBreaksTiesByUnicodeScalar() throws {
        var settings = TextSettings()
        settings.jsonKeyComparison = .caseInsensitive

        let output = try formattedJSON(#"{"b":0,"A":1,"a":2,"B":3}"#, .sortKeys, settings: settings)

        #expect(output == "{\n  \"A\": 1,\n  \"a\": 2,\n  \"B\": 3,\n  \"b\": 0\n}\n")
    }

    @Test func caseFoldingPreservesScalarTieBreaksAndCombiningSequences() throws {
        var settings = TextSettings()
        settings.jsonKeyComparison = .caseInsensitive
        let source = "{\"ß\":1,\"ss\":2,\"SS\":3,\"İ\":4,\"i\u{307}\":5,\"é\":6,\"e\u{301}\":7}"
        let expected =
            "{\n  \"e\u{301}\": 7,\n  \"i\u{307}\": 5,\n  \"İ\": 4,\n  \"SS\": 3,\n  \"ss\": 2,\n  \"ß\": 1,\n  \"é\": 6\n}\n"
        #expect(try formattedJSON(source, .sortKeys, settings: settings) == expected)
    }

    @Test func naturalOrderUsesNumericRuns() throws {
        var settings = TextSettings()
        settings.jsonKeyComparison = .natural

        let output = try formattedJSON(#"{"file10":10,"File2":2,"file1":1}"#, .sortKeys, settings: settings)

        #expect(output == "{\n  \"file1\": 1,\n  \"File2\": 2,\n  \"file10\": 10\n}\n")
    }

    @Test(arguments: [
        ("a18446744073709551616", "a2"),
        ("a0002", "a02"),
        ("a02", "a2"),
        ("a١", "a2"),
        ("a２", "a10"),
        ("e\u{301}", "é"),
        ("a\u{301}\u{327}", "a\u{327}\u{301}"),
        ("ab", "a\u{34F}b"),
        ("ss", "ß"),
        ("i\u{307}", "İ"),
        ("a𐐀", "a𐐨"),
    ])
    func naturalOrderingRetainsPlatformNumericAndCanonicalRules(_ first: String, _ second: String) throws {
        var settings = TextSettings()
        settings.jsonKeyComparison = .natural
        let source = JSONValue.object([(second, .number("2")), (first, .number("1"))]).serialized(indent: nil)
        let expected =
            JSONValue.object([(first, .number("1")), (second, .number("2"))]).serialized(indent: "  ") + "\n"
        #expect(try formattedJSON(source, .sortKeys, settings: settings) == expected)
    }

    @Test(arguments: ["unicode", "numeric", "tie", "secondary", "nonstarter", "icuNumeric"])
    func naturalGiantKeysMatchWholeFoundationComparison(_ variant: String) throws {
        let prefix = String(repeating: "a", count: 4 * 65_536 - 4)
        let left: String
        let right: String
        switch variant {
        case "unicode":
            left = "É" + prefix + "2"
            right = "F" + prefix + "10"
        case "numeric":
            left = prefix + "2"
            right = prefix + "100000"
        case "secondary":
            left = "a\u{301}" + prefix
            right = "a\u{300}" + prefix
        case "nonstarter":
            let marks = String(repeating: "\u{315}", count: 40_000)
            left = "a" + marks + "\u{300}"
            right = "a\u{300}" + marks
        case "icuNumeric":
            let digits = String(repeating: "2", count: 80_000)
            left = "é" + digits + "1"
            right = "e\u{301}" + digits + "2"
        default:
            left = prefix + "000002"
            right = prefix + "2"
        }
        let locale = Locale(identifier: "en_US_POSIX")
        let foldedLeft = left.folding(options: .caseInsensitive, locale: locale)
        let foldedRight = right.folding(options: .caseInsensitive, locale: locale)
        #expect(Array(foldedLeft.utf8) != Array(foldedRight.utf8))
        let primary = foldedLeft.compare(foldedRight, options: [.literal, .numeric], locale: locale)
        let leftFirst =
            primary == .orderedSame
            ? left.unicodeScalars.lexicographicallyPrecedes(right.unicodeScalars) : primary == .orderedAscending
        let leftMember = (key: left, value: JSONValue.number("1"))
        let rightMember = (key: right, value: JSONValue.number("2"))
        let expected =
            JSONValue.object(leftFirst ? [leftMember, rightMember] : [rightMember, leftMember])
            .serialized(indent: "  ") + "\n"
        let source = JSONValue.object([rightMember, leftMember]).serialized(indent: nil)
        var settings = TextSettings()
        settings.jsonKeyComparison = .natural
        #expect(try formattedJSON(source, .sortKeys, settings: settings) == expected)
    }

    @Test func naturalLongCombiningPrefixesKeepContentBasedOrder() throws {
        let prefix = "a" + String(repeating: "\u{315}", count: 40_000)
        let acute = (prefix + "\u{301}", JSONValue.number("1"))
        let grave = (prefix + "\u{300}", JSONValue.number("2"))
        var settings = TextSettings()
        settings.jsonKeyComparison = .natural
        for descending in [false, true] {
            settings.jsonDescending = descending
            let expected =
                JSONValue.object(descending ? [grave, acute] : [acute, grave]).serialized(indent: "  ") + "\n"
            for members in [[acute, grave], [grave, acute]] {
                let source = JSONValue.object(members).serialized(indent: nil)
                #expect(try formattedJSON(source, .sortKeys, settings: settings) == expected)
            }
        }
    }

    @Test(arguments: [
        ("\u{1D165}a", "\u{1D165}b"),
        ("\u{10100}a", "\u{10100}b"),
        ("\u{11131}\u{11127}", "\u{11131}a"),
        ("\u{10940}", "中"),
        ("\u{1FAEA}", "a"),
    ])
    func naturalOrderingPreservesFoundationContextAndDataGeneration(_ left: String, _ right: String) throws {
        let locale = Locale(identifier: "en_US_POSIX")
        let primary = left.compare(right, options: [.literal, .numeric], locale: locale)
        let leftMember = (key: left, value: JSONValue.number("1"))
        let rightMember = (key: right, value: JSONValue.number("2"))
        let expected =
            JSONValue.object(primary == .orderedAscending ? [leftMember, rightMember] : [rightMember, leftMember])
            .serialized(indent: "  ") + "\n"
        var settings = TextSettings()
        settings.jsonKeyComparison = .natural
        let source = JSONValue.object([rightMember, leftMember]).serialized(indent: nil)
        #expect(try formattedJSON(source, .sortKeys, settings: settings) == expected)
    }

    @Test(arguments: [JSONKeyComparison.ordinal, .caseInsensitive, .natural])
    func giantCombiningKeysAndPinsRetainCaseFoldTies(_ comparison: JSONKeyComparison) throws {
        let marks = String(repeating: "\u{301}", count: 600_000)
        let upper = "A" + marks + "Z"
        let lower = "a" + marks + "z"
        var settings = TextSettings()
        settings.jsonKeyComparison = comparison
        settings.jsonDescending = true
        settings.jsonPinnedKeys = [lower, upper]
        let source = JSONValue.object([
            ("z", .number("0")), (upper, .number("1")), (lower, .number("2")), (upper, .number("3")),
        ]).serialized(indent: nil)
        let expected =
            JSONValue.object([
                (lower, .number("2")), (upper, .number("1")), (upper, .number("3")), ("z", .number("0")),
            ]).serialized(indent: "  ") + "\n"
        #expect(try formattedJSON(source, .sortKeys, settings: settings) == expected)
    }

    @Test(arguments: Array(65_532...65_538))
    func caseFoldExpansionsAndSupplementaryScalarsCrossChunkBoundaries(_ boundary: Int) throws {
        let prefix = String(repeating: "A", count: boundary)
        let upper = prefix + "İß𐐀Σ\u{345}\u{301}Z"
        let folded = String(repeating: "a", count: boundary) + "i\u{307}ss𐐨σ\u{3B9}\u{301}z"
        var settings = TextSettings()
        settings.jsonKeyComparison = .caseInsensitive
        settings.jsonPinnedKeys = [folded]
        let source = JSONValue.object([("!", .number("0")), (folded, .number("2")), (upper, .number("1"))]).serialized(
            indent: nil)
        let expected =
            JSONValue.object([(upper, .number("1")), (folded, .number("2")), ("!", .number("0"))]).serialized(
                indent: "  ") + "\n"
        #expect(try formattedJSON(source, .sortKeys, settings: settings) == expected)
    }

    @Test func diskCaseFoldingMatchesWholeFoundationForEveryUnicodeScalar() throws {
        var key = ""
        for code in UInt32(0)...0x10FFFF {
            if let scalar = Unicode.Scalar(code) { key.unicodeScalars.append(scalar) }
        }
        let folded = key.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        var settings = TextSettings()
        settings.jsonKeyComparison = .caseInsensitive
        settings.jsonPinnedKeys = [folded]
        let source = JSONValue.object([("!", .number("0")), (key, .number("1")), (folded, .number("2"))]).serialized(
            indent: nil)
        let expected =
            JSONValue.object([(key, .number("1")), (folded, .number("2")), ("!", .number("0"))]).serialized(
                indent: "  ") + "\n"
        #expect(try formattedJSON(source, .sortKeys, settings: settings) == expected)
    }

    @Test func pinnedKeysKeepTheirOrderWhenDescending() throws {
        var settings = TextSettings()
        settings.jsonKeyComparison = .caseInsensitive
        settings.jsonDescending = true
        settings.jsonPinnedKeys = ["B", "Z"]

        let output = try formattedJSON(#"{"a":1,"z":2,"b":3,"c":4}"#, .sortKeys, settings: settings)

        #expect(output == "{\n  \"b\": 3,\n  \"z\": 2,\n  \"c\": 4,\n  \"a\": 1\n}\n")
    }

    @Test func primitiveArraysSortLexicallyOnlyWhenEnabled() throws {
        let source = #"{"values":[2,10,1e3,"x",null],"records":[{"z":1,"a":2},{"y":3,"b":4}]}"#
        var settings = TextSettings()
        let unchanged = try formattedJSON(source, .sortKeys, settings: settings)
        settings.jsonSortPrimitiveArrays = true

        let output = try formattedJSON(source, .sortKeys, settings: settings)

        #expect(unchanged.contains("\"values\": [\n    2,\n    10,\n    1e3,\n    \"x\",\n    null\n  ]"))
        #expect(output.contains("\"values\": [\n    \"x\",\n    10,\n    1e3,\n    2,\n    null\n  ]"))
        #expect(
            output.contains(
                "\"records\": [\n    {\n      \"a\": 2,\n      \"z\": 1\n    },\n    {\n      \"b\": 4,\n      \"y\": 3\n    }\n  ]"
            ))
    }

    @Test func rootOnlyLeavesNestedObjectsAndArraysUntouched() throws {
        let source = #"{"z":{"b":1,"a":2},"a":[10,2]}"#
        var settings = TextSettings()
        settings.keySortScope = .topLevel
        settings.jsonSortPrimitiveArrays = true

        let output = try formattedJSON(source, .sortKeys, settings: settings)

        #expect(output == "{\n  \"a\": [\n    10,\n    2\n  ],\n  \"z\": {\n    \"b\": 1,\n    \"a\": 2\n  }\n}\n")
    }

    @Test func rootArraySortsOnlyItsPrimitiveElements() throws {
        var settings = TextSettings()
        settings.keySortScope = .topLevel
        settings.jsonSortPrimitiveArrays = true

        let output = try formattedJSON("[2,10,1e3]", .sortKeys, settings: settings)

        #expect(output == "[\n  10,\n  1e3,\n  2\n]\n")
    }

    @Test func duplicateKeysRetainTheirSourceOrder() throws {
        var settings = TextSettings()
        settings.jsonKeyComparison = .caseInsensitive

        let output = try formattedJSON(#"{"a":1,"A":2,"a":3}"#, .sortKeys, settings: settings)

        #expect(output == "{\n  \"A\": 2,\n  \"a\": 1,\n  \"a\": 3\n}\n")
    }

    @Test func unicodePinnedKeyMatchesCaseInsensitively() throws {
        var settings = TextSettings()
        settings.jsonPinnedKeys = ["é"]

        let output = try formattedJSON(#"{"a":1,"É":2}"#, .sortKeys, settings: settings)

        #expect(output == "{\n  \"É\": 2,\n  \"a\": 1\n}\n")
    }
}
