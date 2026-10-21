import Foundation
import Testing

@testable import Engine

@Suite struct CSVConversionTests {
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
