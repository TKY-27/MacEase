import Foundation
import Testing

@testable import Engine

@Suite struct XMLConversionTests {
    @Test(arguments: [
        (##"{"#text":"first","#text":"second"}"##, "$.#text"),
        (##"{"book":{"#text":"first","#text":"second"}}"##, "$.book.#text"),
        (##"{"books":[{"#text":"first","#text":"second"}]}"##, "$.books[0].#text"),
        (##"[{"#text":"first","#text":"second"}]"##, "$[0].#text"),
        (##"{"#text":null,"#text":"second"}"##, "$.#text"),
        (#"{"book":{"@id":"first","@id":"second"}}"#, "$.book.@id"),
        (#"{"book":{"@a:b":"first","@a?b":"second"}}"#, "$.book.@a?b"),
    ])
    func refusesDuplicateTextAndAttributesWithTheirPath(input: String, path: String) {
        #expect(throws: EngineError.invalidInput(.malformed("Duplicate JSON keys at \(path) are unsupported"))) {
            try TextConverter.convert(
                Data(input.utf8), .jsonToXML, settings: TextSettings(), title: "Duplicate keys")
        }
    }

    @Test func preservesRepeatedChildElementsAndTextInSeparateObjects() throws {
        let input = ##"{"book":{"#text":"first"},"book":{"#text":"second"}}"##
        let output = try TextConverter.convert(
            Data(input.utf8), .jsonToXML, settings: TextSettings(), title: "Repeated children")

        #expect(
            output
                == "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root>\n  <book>first</book>\n  <book>second</book>\n</root>\n"
        )
    }
}
