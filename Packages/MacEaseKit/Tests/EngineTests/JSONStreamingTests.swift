import Foundation
import Testing

@testable import Engine

@Suite struct JSONStreamingTests {
    @Test func preservesFormattingEscapesNumbersAndDuplicateKeys() throws {
        let source =
            #"{ "z":1.20e+03,"a":"quote\" slash\\ newline\n \u0001 \uD83D\uDE00","a":[true,false,null,0,-0.0] }"#
        let escaped = #"quote\" slash\\ newline\n \u0001 😀"#
        let minified = #"{"z":1.20e+03,"a":"quote\" slash\\ newline\n \u0001 😀","a":[true,false,null,0,-0.0]}"#
        let pretty = [
            "{",
            #"  "z": 1.20e+03,"#,
            #"  "a": "\#(escaped)","#,
            #"  "a": ["#,
            "    true,",
            "    false,",
            "    null,",
            "    0,",
            "    -0.0",
            "  ]",
            "}",
            "",
        ].joined(separator: "\n")
        let sorted = [
            "{",
            #"  "a": "\#(escaped)","#,
            #"  "a": ["#,
            "    true,",
            "    false,",
            "    null,",
            "    0,",
            "    -0.0",
            "  ],",
            #"  "z": 1.20e+03"#,
            "}",
            "",
        ].joined(separator: "\n")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }

        let input = directory.appendingPathComponent("source.json")
        try Data(source.utf8).write(to: input)

        for (index, fixture) in [
            (JSONFormatting.minify, minified),
            (.pretty, pretty),
            (.sortKeys, sorted),
        ].enumerated() {
            let destination = directory.appendingPathComponent("output-\(index).json")
            try JSONFormatter.write(input, fixture.0, settings: TextSettings(), to: destination)
            #expect(try Data(contentsOf: destination) == Data(fixture.1.utf8))
        }
    }

    @Test func refusesExistingDestinationWithoutChangingIt() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = Data("keep".utf8)
        try original.write(to: destination)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: destination) } }

        let input = destination.appendingPathExtension("source")
        try Data("{}".utf8).write(to: input)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: input) } }
        #expect(throws: NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST))) {
            try JSONFormatter.write(input, .pretty, settings: TextSettings(), to: destination)
        }
        #expect(try Data(contentsOf: destination) == original)
    }
}

@Suite struct JSONFileFormattingTests {
    private func fixture(_ bytes: Data, body: (URL, URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let source = directory.appendingPathComponent("source.json")
        let output = directory.appendingPathComponent("output.json")
        try bytes.write(to: source)
        try body(source, output, directory)
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test(arguments: [JSONFormatting.pretty, .minify, .sortKeys])
    func streamsLargeScalarValuesAndNumberLexemes(_ formatting: JSONFormatting) throws {
        let scalar = String(repeating: "é😀", count: 180_000)
        let number =
            "-1." + String(repeating: "23456789", count: 150_000) + "e+" + String(repeating: "9", count: 70_000)
        let source = "[\"\(scalar)\",\(number)]"
        let expected = formatting == .minify ? source : "[\n  \"\(scalar)\",\n  \(number)\n]\n"
        try fixture(Data(source.utf8)) { input, output, directory in
            try JSONFormatter.write(input, formatting, settings: TextSettings(), to: output)
            #expect(try Data(contentsOf: output) == Data(expected.utf8))
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == [
                    "output.json", "source.json",
                ])
        }
    }

    @Test(arguments: [JSONFormatting.pretty, .minify, .sortKeys])
    func preservesInteriorByteOrderMarkAtReadBoundary(_ formatting: JSONFormatting) throws {
        let source = "\"" + String(repeating: "a", count: 65_535) + "\u{FEFF}\""
        let expected = formatting == .minify ? source : source + "\n"
        try fixture(Data(source.utf8)) { input, output, _ in
            try JSONFormatter.write(input, formatting, settings: TextSettings(), to: output)
            #expect(try Data(contentsOf: output) == Data(expected.utf8))
        }
    }

    @Test(arguments: Array(65_520...65_538))
    func escapesAndSurrogatePairsCrossReadBoundaries(_ prefix: Int) throws {
        let source = String(repeating: " ", count: prefix) + #"["\uD83D\uDE00\/\u0001\"\\é"]"#
        try fixture(Data(source.utf8)) { input, output, _ in
            try JSONFormatter.write(input, .minify, settings: TextSettings(), to: output)
            #expect(try String(contentsOf: output, encoding: .utf8) == #"["😀/\u0001\"\\é"]"#)
        }
    }

    @Test(arguments: [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian, .shiftJIS])
    func normalizesFileEncodings(_ encoding: String.Encoding) throws {
        let source = #"{"あ":1,"a":2}"#
        var bytes = try #require(source.data(using: encoding))
        if encoding == .utf16LittleEndian { bytes = Data([0xFF, 0xFE]) + bytes }
        if encoding == .utf16BigEndian { bytes = Data([0xFE, 0xFF]) + bytes }
        if encoding == .utf8 { bytes = Data([0xEF, 0xBB, 0xBF]) + bytes }
        try fixture(bytes) { input, output, _ in
            try JSONFormatter.write(input, .sortKeys, settings: TextSettings(), to: output)
            #expect(try Data(contentsOf: output) == Data("{\n  \"a\": 2,\n  \"あ\": 1\n}\n".utf8))
        }
    }

    @Test func ambiguousLegacyEncodingLeavesOnlyOriginal() throws {
        let bytes = Data([34, 0xA4, 0xA2, 34])
        try fixture(bytes) { input, output, directory in
            #expect(throws: EngineError.invalidInput(.textEncodingUndetected)) {
                try JSONFormatter.write(input, .minify, settings: TextSettings(), to: output)
            }
            let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(remaining == ["source.json"])
        }
    }

    @Test func mergesPrimitiveArrayRunsUsingLexicalOrder() throws {
        let values = (100_000..<170_000).map(String.init)
        let source = "[" + values.reversed().joined(separator: ",") + "]"
        let expected = "[\n  " + values.joined(separator: ",\n  ") + "\n]\n"
        var settings = TextSettings()
        settings.jsonSortPrimitiveArrays = true
        try fixture(Data(source.utf8)) { input, output, _ in
            try JSONFormatter.write(input, .sortKeys, settings: settings, to: output)
            #expect(try Data(contentsOf: output) == Data(expected.utf8))
        }
    }

    @Test func mergesNaturalKeysWithPinnedRanksAndStableDuplicates() throws {
        let keys = ["file10", "File2", "pinned", "file1"]
        let count = 34_000
        let source = "{" + (0..<count).map { "\"\(keys[$0 % keys.count])\":\($0)" }.joined(separator: ",") + "}"
        let expectedKeys = ["pinned", "file10", "File2", "file1"]
        let members = expectedKeys.flatMap { key in
            (0..<count).filter { keys[$0 % keys.count] == key }.map { "  \"\(key)\": \($0)" }
        }
        let expected = "{\n" + members.joined(separator: ",\n") + "\n}\n"
        var settings = TextSettings()
        settings.jsonKeyComparison = .natural
        settings.jsonDescending = true
        settings.jsonPinnedKeys = ["PINNED", "pinned"]
        try fixture(Data(source.utf8)) { input, output, _ in
            try JSONFormatter.write(input, .sortKeys, settings: settings, to: output)
            #expect(try Data(contentsOf: output) == Data(expected.utf8))
        }
    }

    @Test(arguments: [JSONFormatting.minify, .sortKeys])
    func malformedSuffixReportsScalarColumnAndRemovesOwnedFiles(_ formatting: JSONFormatting) throws {
        let prefix = String(repeating: " ", count: 65_534)
        let source = "\n" + prefix + #"["😀",]"#
        try fixture(Data(source.utf8)) { input, output, directory in
            #expect(throws: EngineError.invalidInput(.jsonSyntax(line: 2, column: prefix.count + 6))) {
                try JSONFormatter.write(input, formatting, settings: TextSettings(), to: output)
            }
            let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(remaining == ["source.json"])
        }
    }

    @Test(arguments: [JSONFormatting.minify, .sortKeys])
    func preservesTheExistingDepthBoundary(_ formatting: JSONFormatting) throws {
        let accepted = String(repeating: "[", count: 512) + String(repeating: "]", count: 512)
        try fixture(Data(accepted.utf8)) { input, output, _ in
            try JSONFormatter.write(input, formatting, settings: TextSettings(), to: output)
            let result = try String(contentsOf: output, encoding: .utf8)
            #expect(result.filter { !$0.isWhitespace } == accepted)
        }
        let refused = "[" + accepted + "]"
        try fixture(Data(refused.utf8)) { input, output, directory in
            #expect(throws: EngineError.invalidInput(.malformed("JSON nests deeper than 512 levels"))) {
                try JSONFormatter.write(input, formatting, settings: TextSettings(), to: output)
            }
            let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(remaining == ["source.json"])
        }
    }

    @Test func nestedContainerRecordsSurviveBufferedIndexBoundaries() throws {
        let count = 1_000
        let source = "[" + (0..<count).map { "{\"z\":\($0),\"a\":[\($0)]}" }.joined(separator: ",") + "]"
        let children = (0..<count).map { "  {\n    \"a\": [\n      \($0)\n    ],\n    \"z\": \($0)\n  }" }
        let expected = "[\n" + children.joined(separator: ",\n") + "\n]\n"
        try fixture(Data(source.utf8)) { input, output, _ in
            try JSONFormatter.write(input, .sortKeys, settings: TextSettings(), to: output)
            #expect(try Data(contentsOf: output) == Data(expected.utf8))
        }
    }

    @Test(arguments: ["values", "folded"])
    func cancellationDuringSpoolingRemovesOwnedFiles(_ phase: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: directory) } }
        let source = directory.appendingPathComponent("source.json")
        let output = directory.appendingPathComponent("output.json")
        let document: String
        if phase == "folded" {
            let key = String(repeating: "a", count: 128 * 1024)
            document = "{" + (0..<128).map { "\"\($0)-\(key)\":\($0)" }.joined(separator: ",") + "}"
        } else {
            document = "\"" + String(repeating: "a", count: 12 * 1024 * 1024) + "\""
        }
        let bytes = Data(document.utf8)
        try bytes.write(to: source)
        let task = Task.detached {
            var settings = TextSettings()
            settings.jsonKeyComparison = .caseInsensitive
            try JSONFormatter.write(source, .sortKeys, settings: settings, to: output)
        }
        let reachedSpooling: Bool = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "JSONSpoolCancellationObserver").async {
                do {
                    let reached = try Self.waitForSpool(phase, in: directory)
                    task.cancel()
                    continuation.resume(returning: reached)
                } catch {
                    task.cancel()
                    continuation.resume(throwing: error)
                }
            }
        }
        #expect(reachedSpooling)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["source.json"])
        #expect(try Data(contentsOf: source) == bytes)
    }

    private static func waitForSpool(_ phase: String, in directory: URL) throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(120))
        while clock.now < deadline {
            let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            if let scratch = children.first(where: { $0.lastPathComponent.hasPrefix(".json-") }) {
                let values = scratch.appendingPathComponent(phase)
                if let attributes = try? FileManager.default.attributesOfItem(atPath: values.path),
                    let size = attributes[.size] as? NSNumber, size.intValue >= 65_536
                {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return false
    }
}
