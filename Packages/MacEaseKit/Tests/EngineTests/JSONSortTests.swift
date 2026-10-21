import Foundation
import Testing

@testable import Engine

@Suite struct JSONSortTests {
    @Test func ordinalOrderUsesUnicodeScalars() throws {
        let source = "{\"😀\":4,\"\u{E000}\":3,\"é\":2,\"e\u{301}\":1}"
        let output = try JSONFormatter.format(source, .sortKeys, settings: TextSettings())
        #expect(output == "{\n  \"e\u{301}\": 1,\n  \"é\": 2,\n  \"\u{E000}\": 3,\n  \"😀\": 4\n}\n")
    }

    @Test func prettyAndMinifyIgnoreSortOptionsAndPreserveNumbers() throws {
        var settings = TextSettings()
        settings.jsonDescending = true
        settings.jsonPinnedKeys = ["a"]
        settings.jsonSortPrimitiveArrays = true
        let source = #"{"z":9007199254740993,"a":[2,1e+003]}"#
        #expect(try JSONFormatter.format(source, .minify, settings: settings) == source)
        #expect(
            try JSONFormatter.format(source, .pretty, settings: settings)
                == "{\n  \"z\": 9007199254740993,\n  \"a\": [\n    2,\n    1e+003\n  ]\n}\n")
    }

    @Test func caseInsensitiveOrderBreaksTiesByUnicodeScalar() throws {
        var settings = TextSettings()
        settings.jsonKeyComparison = .caseInsensitive

        let output = try JSONFormatter.format(#"{"b":0,"A":1,"a":2,"B":3}"#, .sortKeys, settings: settings)

        #expect(output == "{\n  \"A\": 1,\n  \"a\": 2,\n  \"B\": 3,\n  \"b\": 0\n}\n")
    }

    @Test func naturalOrderUsesNumericRuns() throws {
        var settings = TextSettings()
        settings.jsonKeyComparison = .natural

        let output = try JSONFormatter.format(#"{"file10":10,"File2":2,"file1":1}"#, .sortKeys, settings: settings)

        #expect(output == "{\n  \"file1\": 1,\n  \"File2\": 2,\n  \"file10\": 10\n}\n")
    }

    @Test func pinnedKeysKeepTheirOrderWhenDescending() throws {
        var settings = TextSettings()
        settings.jsonKeyComparison = .caseInsensitive
        settings.jsonDescending = true
        settings.jsonPinnedKeys = ["B", "Z"]

        let output = try JSONFormatter.format(#"{"a":1,"z":2,"b":3,"c":4}"#, .sortKeys, settings: settings)

        #expect(output == "{\n  \"b\": 3,\n  \"z\": 2,\n  \"c\": 4,\n  \"a\": 1\n}\n")
    }

    @Test func primitiveArraysSortLexicallyOnlyWhenEnabled() throws {
        let source = #"{"values":[2,10,1e3,"x",null],"records":[{"z":1,"a":2},{"y":3,"b":4}]}"#
        var settings = TextSettings()
        let unchanged = try JSONFormatter.format(source, .sortKeys, settings: settings)
        settings.jsonSortPrimitiveArrays = true

        let output = try JSONFormatter.format(source, .sortKeys, settings: settings)

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

        let output = try JSONFormatter.format(source, .sortKeys, settings: settings)

        #expect(output == "{\n  \"a\": [\n    10,\n    2\n  ],\n  \"z\": {\n    \"b\": 1,\n    \"a\": 2\n  }\n}\n")
    }

    @Test func rootArraySortsOnlyItsPrimitiveElements() throws {
        var settings = TextSettings()
        settings.keySortScope = .topLevel
        settings.jsonSortPrimitiveArrays = true

        let output = try JSONFormatter.format("[2,10,1e3]", .sortKeys, settings: settings)

        #expect(output == "[\n  10,\n  1e3,\n  2\n]\n")
    }

    @Test func duplicateKeysRetainTheirSourceOrder() throws {
        var settings = TextSettings()
        settings.jsonKeyComparison = .caseInsensitive

        let output = try JSONFormatter.format(#"{"a":1,"A":2,"a":3}"#, .sortKeys, settings: settings)

        #expect(output == "{\n  \"A\": 2,\n  \"a\": 1,\n  \"a\": 3\n}\n")
    }

    @Test func unicodePinnedKeyMatchesCaseInsensitively() throws {
        var settings = TextSettings()
        settings.jsonPinnedKeys = ["é"]

        let output = try JSONFormatter.format(#"{"a":1,"É":2}"#, .sortKeys, settings: settings)

        #expect(output == "{\n  \"É\": 2,\n  \"a\": 1\n}\n")
    }
}
