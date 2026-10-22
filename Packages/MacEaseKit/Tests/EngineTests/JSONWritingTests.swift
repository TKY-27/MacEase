import Foundation
import Testing

@testable import Engine

@Suite struct JSONWritingTests {
    @Test(arguments: [nil, "", "  ", "\t"] as [String?])
    func boundedWritingPreservesFormattingAndEscaping(_ indent: String?) throws {
        let source = #"{"quote\"\\":"日本語😀\n\r\t\b\f\u0000","nested":[{},[],true,false,null,-1.50e+2]}"#
        let value = try JSONParser.parse(source)
        let expected: String
        if let indent {
            expected = #"""
                {
                \#(indent)"quote\"\\": "日本語😀\n\r\t\b\f\u0000",
                \#(indent)"nested": [
                \#(indent)\#(indent){},
                \#(indent)\#(indent)[],
                \#(indent)\#(indent)true,
                \#(indent)\#(indent)false,
                \#(indent)\#(indent)null,
                \#(indent)\#(indent)-1.50e+2
                \#(indent)]
                }
                """#
        } else {
            expected = source
        }
        #expect(value.serialized(indent: indent) == expected)
        #expect(try value.serialized(indent: indent, maximumBytes: expected.utf8.count) == expected)
        #expect(throws: EngineError.invalidInput(.malformed("JSON output exceeds \(expected.utf8.count - 1) bytes"))) {
            _ = try value.serialized(indent: indent, maximumBytes: expected.utf8.count - 1)
        }
    }

    @Test func countsEscapedBytesAndMultibyteKeys() throws {
        let value = JSONValue.object([("é", .string("\u{01}"))])
        let expected = #"{"é":"\u0001"}"#
        let exactBytes = 15
        #expect(expected.utf8.count == exactBytes)
        #expect(try value.serialized(indent: nil, maximumBytes: exactBytes) == expected)
        #expect(throws: EngineError.invalidInput(.malformed("JSON output exceeds \(exactBytes - 1) bytes"))) {
            _ = try value.serialized(indent: nil, maximumBytes: exactBytes - 1)
        }
    }

    @Test func boundsLargeStrings() {
        let scalarBytes = 1024 * 1024
        let outputLimit = 1024
        let value = JSONValue.string(String(repeating: "x", count: scalarBytes))
        #expect(throws: EngineError.invalidInput(.malformed("JSON output exceeds \(outputLimit) bytes"))) {
            _ = try value.serialized(indent: nil, maximumBytes: outputLimit)
        }
    }

    @Test func boundedWritingHonorsCancellation() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let value = JSONValue.array([.string("payload")])
            #expect(throws: CancellationError.self) {
                _ = try value.serialized(indent: nil, maximumBytes: ConversionInput.maximumBytes)
            }
        }
        await task.value
    }
}
