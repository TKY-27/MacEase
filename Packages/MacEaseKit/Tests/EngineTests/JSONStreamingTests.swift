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

        for (index, fixture) in [
            (JSONFormatting.minify, minified),
            (.pretty, pretty),
            (.sortKeys, sorted),
        ].enumerated() {
            let destination = directory.appendingPathComponent("output-\(index).json")
            try JSONFormatter.write(source, fixture.0, settings: TextSettings(), to: destination)
            #expect(try Data(contentsOf: destination) == Data(fixture.1.utf8))
        }
    }

    @Test func flushesLargeStringsWithoutChangingBytes() throws {
        let payload = String(repeating: "é", count: 100_000)
        let source = "\"\(payload)\""
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: destination) } }

        try JSONFormatter.write(source, .pretty, settings: TextSettings(), to: destination)

        #expect(try Data(contentsOf: destination) == Data("\"\(payload)\"\n".utf8))
    }

    @Test func refusesExistingDestinationWithoutChangingIt() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = Data("keep".utf8)
        try original.write(to: destination)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: destination) } }

        #expect(throws: NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST))) {
            try JSONFormatter.write("{}", .pretty, settings: TextSettings(), to: destination)
        }
        #expect(try Data(contentsOf: destination) == original)
    }
}
