import Foundation
import Testing

@testable import Engine

@Suite struct CSVConversionTests {
    @Test(arguments: [
        (#"[{"id":"first","id":"second"}]"#, "$[0].id"),
        (#"[{"id":"valid"},{"id":"first","id":"second"}]"#, "$[1].id"),
        (#"[{"id":"first","\u0069d":"second"}]"#, "$[0].id"),
        (#"[{"id":null,"id":"second"}]"#, "$[0].id"),
        (#"[{"id":"","id":"second"}]"#, "$[0].id"),
    ])
    func refusesDuplicateJSONKeysWithTheirRowPath(input: String, path: String) {
        #expect(throws: EngineError.invalidInput(.jsonNotFlatArray(path: path))) {
            try TextConverter.convert(
                Data(input.utf8), .jsonToCSV, settings: TextSettings(), title: "Duplicate keys")
        }
    }

    @Test func preservesRepeatedColumnNamesAcrossRows() throws {
        let input = #"[{"id":"first","ID":"upper"},{"id":"second","extra":null}]"#
        let output = try TextConverter.convert(
            Data(input.utf8), .jsonToCSV, settings: TextSettings(), title: "Shared columns")

        #expect(output == "id,ID,extra\r\nfirst,upper,\r\nsecond,,\r\n")
    }

    @Test(arguments: [
        ("a|b\n1|2\n", "a", "1", "2"),
        ("\"a,;\t\"|b\n\"one|\"\"two\"\"\"|\"line1\nline2\"\n", "a,;\t", "one|\"two\"", "line1\nline2"),
        ("a,b\n\"one|two\",2\n", "a", "one|two", "2"),
    ])
    func delimitersPreserveQuotedFields(input: String, key: String, first: String, second: String) throws {
        let output = try TextConverter.convert(
            Data(input.utf8), .csvToJSON, settings: TextSettings(), title: "Delimited fields")
        let rows = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: String]])
        #expect(rows == [[key: first, "b": second]])
    }
}
