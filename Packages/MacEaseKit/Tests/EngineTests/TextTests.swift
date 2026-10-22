import Foundation
import MenuCatalog
import Testing

@testable import Engine

private func runText(
    _ operation: TextOperation,
    op: OperationID,
    on inputs: [URL],
    settings: Settings = Settings()
) async throws -> BatchOutcome {
    var settings = settings
    settings.outputMode = .replace
    let support = FileManager.default.temporaryDirectory.appending(path: "MacEaseTextSupport-\(UUID().uuidString)")
    TestTemporaryFolders.register(support)
    let engine = try JobEngine(supportDirectory: support, concurrency: 2)
    let request = OperationRequest(op: op, options: .text(operation), inputs: inputs)
    return await engine.run(OperationPlanner.batch(for: request, settings: settings), settings: settings) { _ in }
}

private func file(_ name: String, bytes: [UInt8]) throws -> URL {
    let url = try TestVolume.makeFolder().appending(path: name)
    try Data(bytes).write(to: url)
    return url
}

private func file(_ name: String, text: String) throws -> URL {
    try file(name, bytes: Array(text.utf8))
}

private func bytes(_ url: URL) throws -> [UInt8] {
    Array(try Data(contentsOf: url))
}

private func cp932(_ text: String) throws -> [UInt8] {
    Array(try #require(text.data(using: TextEncoding.cp932)))
}

private func eucJP(_ text: String) throws -> [UInt8] {
    Array(try #require(text.data(using: .japaneseEUC)))
}

private func utf16WithBOM(_ text: String, bigEndian: Bool = false) -> [UInt8] {
    let body: [UInt8] = text.utf16.flatMap { unit -> [UInt8] in
        let high = UInt8(unit >> 8)
        let low = UInt8(unit & 0xFF)
        return bigEndian ? [high, low] : [low, high]
    }
    return (bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]) + body
}

private let japanese = "日本語のテキストです。\n二行目"

@Suite(.serialized) struct TextEncodingTests {
    @Test func presetsMapToOperations() {
        let settings = Settings()
        #expect(
            OperationPlanner.options(for: .textEncoding, preset: "shift-jis", settings: settings)
                == .text(.encoding(.shiftJIS, source: nil)))
        #expect(
            OperationPlanner.options(for: .textLineEndings, preset: "crlf", settings: settings)
                == .text(.lineEndings(.crlf)))
        #expect(
            OperationPlanner.options(for: .textConvert, preset: "ini-xml", settings: settings)
                == .text(.convert(.iniToXML)))
        #expect(OperationPlanner.options(for: .textJSON, preset: "sort", settings: settings) == .text(.json(.sortKeys)))
        #expect(OperationPlanner.options(for: .textJSON, preset: nil, settings: settings) == nil)
    }

    @Test func detectsByteOrderMarks() async throws {
        let utf16 = try file("utf16.txt", bytes: utf16WithBOM(japanese))
        let utf8BOM = try file("bom.txt", bytes: [0xEF, 0xBB, 0xBF] + Array(japanese.utf8))

        let outcome = try await runText(.encoding(.utf8, source: nil), op: .textEncoding, on: [utf16, utf8BOM])

        #expect(
            outcome.outcomes == [
                .succeeded(outputs: [utf16], warnings: []), .succeeded(outputs: [utf8BOM], warnings: []),
            ])
        #expect(try bytes(utf16) == Array(japanese.utf8))
        #expect(try bytes(utf8BOM) == Array(japanese.utf8))
    }

    @Test func detectsUTF8CP932AndEUCJP() async throws {
        let utf8 = try file("utf8.txt", text: japanese)
        let shiftJIS = try file("sjis.txt", bytes: try cp932(japanese + "①"))
        let euc = try file("euc.txt", bytes: try eucJP(japanese))

        let outcome = try await runText(.encoding(.utf16, source: nil), op: .textEncoding, on: [utf8, shiftJIS, euc])

        #expect(outcome.outcomes.allSatisfy { if case .succeeded = $0 { true } else { false } })
        let expected = utf16WithBOM(japanese)
        #expect(try bytes(utf8) == expected)
        #expect(try bytes(euc) == expected)
        #expect(try String(data: Data(contentsOf: shiftJIS), encoding: .utf16) == japanese + "①")
    }

    @Test func ambiguousInputFailsUnlessThePanelChoseTheSource() async throws {
        let ambiguous = try eucJP("あ")
        #expect(String(data: Data(ambiguous), encoding: TextEncoding.cp932) != nil)
        let undecided = try file("a.txt", bytes: ambiguous)
        let chosen = try file("b.txt", bytes: ambiguous)

        let failed = try await runText(.encoding(.utf8, source: nil), op: .textEncoding, on: [undecided])
        let succeeded = try await runText(.encoding(.utf8, source: .eucJP), op: .textEncoding, on: [chosen])

        #expect(failed.outcomes == [.failed(.invalidInput(.textEncodingUndetected))])
        #expect(succeeded.outcomes == [.succeeded(outputs: [chosen], warnings: [])])
        #expect(try String(contentsOf: chosen, encoding: .utf8) == "あ")
    }

    @Test func shiftJISRoundTripsThroughCP932() async throws {
        let original = japanese + "①髙～"
        let url = try file("round.txt", text: original)

        let toShiftJIS = try await runText(.encoding(.shiftJIS, source: nil), op: .textEncoding, on: [url])
        #expect(try bytes(url) == cp932(original))
        let back = try await runText(.encoding(.utf8, source: nil), op: .textEncoding, on: [url])

        #expect(toShiftJIS.outcomes == [.succeeded(outputs: [url], warnings: [])])
        #expect(back.outcomes == [.succeeded(outputs: [url], warnings: [])])
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }

    @Test(arguments: [
        (UnmappablePolicy.questionMark, "ok\nx?y"),
        (UnmappablePolicy.numericReference, "ok\nx&#128512;y"),
    ])
    func unmappableCharactersFollowThePolicy(policy: UnmappablePolicy, expected: String) async throws {
        var settings = Settings()
        settings.text.unmappable = policy
        let url = try file("emoji.txt", text: "ok\nx😀y")

        let outcome = try await runText(
            .encoding(.shiftJIS, source: nil), op: .textEncoding, on: [url], settings: settings)

        #expect(outcome.outcomes == [.succeeded(outputs: [url], warnings: [.unmappableCharactersReplaced])])
        #expect(try bytes(url) == Array(expected.utf8))
    }

    @Test func unmappableCharactersFailWithTheirLine() async throws {
        let url = try file("emoji.txt", text: "ok\nx😀y")

        let outcome = try await runText(.encoding(.shiftJIS, source: nil), op: .textEncoding, on: [url])

        #expect(outcome.outcomes == [.failed(.invalidInput(.unmappableCharacter(line: 2)))])
        #expect(try bytes(url) == Array("ok\nx😀y".utf8))
    }

    @Test func unchangedTextIsSkipped() async throws {
        let url = try file("plain.txt", text: "plain\n")

        let outcome = try await runText(.encoding(.utf8, source: nil), op: .textEncoding, on: [url])

        #expect(outcome.outcomes == [.skipped(.alreadyDone)])
    }
}

@Suite(.serialized) struct LineEndingTests {
    @Test func mixedEndingsAreNormalized() async throws {
        let toLF = try file("lf.txt", text: "a\r\nb\rc\nd")
        let toCRLF = try file("crlf.txt", bytes: try cp932("一\r\n二\r三\n"))

        let lf = try await runText(.lineEndings(.lf), op: .textLineEndings, on: [toLF])
        let crlf = try await runText(.lineEndings(.crlf), op: .textLineEndings, on: [toCRLF])

        #expect(lf.outcomes == [.succeeded(outputs: [toLF], warnings: [])])
        #expect(crlf.outcomes == [.succeeded(outputs: [toCRLF], warnings: [])])
        #expect(try String(contentsOf: toLF, encoding: .utf8) == "a\nb\nc\nd")
        #expect(try bytes(toCRLF) == cp932("一\r\n二\r\n三\r\n"))
    }

    @Test func utf16KeepsItsByteOrderMark() async throws {
        let text = "x\ny\rz"
        let url = try file("wide.txt", bytes: utf16WithBOM(text, bigEndian: true))

        _ = try await runText(.lineEndings(.crlf), op: .textLineEndings, on: [url])

        #expect(try bytes(url) == utf16WithBOM("x\r\ny\r\nz", bigEndian: true))
    }

    @Test func alreadyNormalizedTextIsSkipped() async throws {
        let url = try file("done.txt", text: "a\nb\n")

        let outcome = try await runText(.lineEndings(.lf), op: .textLineEndings, on: [url])

        #expect(outcome.outcomes == [.skipped(.alreadyDone)])
    }
}

@Suite(.serialized) struct TextConvertTests {
    private static let csv = "name,quote,count\r\n\"Smith, J\",\"He said \"\"hi\"\"\",3\r\nLee,\"line1\nline2\",x\r\n"

    private func convert(
        _ conversion: TextConversion,
        name: String,
        input: String,
        settings: Settings = Settings()
    ) async throws -> (outcome: BatchOutcome, output: URL) {
        let url = try file(name, text: input)
        let outcome = try await runText(.convert(conversion), op: .textConvert, on: [url], settings: settings)
        #expect(try String(contentsOf: url, encoding: .utf8) == input)
        let output = url.deletingPathExtension().appendingPathExtension(conversion.outputExtension)
        return (outcome, output)
    }

    private func converted(
        _ conversion: TextConversion,
        name: String,
        input: String,
        settings: Settings = Settings()
    ) async throws -> String {
        let (outcome, output) = try await convert(conversion, name: name, input: input, settings: settings)
        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: [])])
        return try String(contentsOf: output, encoding: .utf8)
    }

    @Test func csvToJSONQuotesNewlinesAndTypeInference() async throws {
        let strings = try await converted(.csvToJSON, name: "people.csv", input: Self.csv)
        var settings = Settings()
        settings.text.csvTypeInference = true
        let typed = try await converted(.csvToJSON, name: "people.csv", input: Self.csv, settings: settings)

        #expect(
            strings == """
                [
                  {
                    "name": "Smith, J",
                    "quote": "He said \\"hi\\"",
                    "count": "3"
                  },
                  {
                    "name": "Lee",
                    "quote": "line1\\nline2",
                    "count": "x"
                  }
                ]

                """)
        #expect(typed.contains("\"count\": 3\n"))
        #expect(typed.contains("\"count\": \"x\""))
    }

    @Test func csvDelimitersAreDetected() async throws {
        var settings = Settings()
        settings.text.jsonIndent = .tab
        let semicolon = try await converted(.csvToJSON, name: "semi.csv", input: "a;b\n1,5;2\n", settings: settings)
        let tab = try await converted(.csvToJSON, name: "tab.csv", input: "a\tb\n1;5\t2\n", settings: settings)

        #expect(semicolon == "[\n\t{\n\t\t\"a\": \"1,5\",\n\t\t\"b\": \"2\"\n\t}\n]\n")
        #expect(tab == "[\n\t{\n\t\t\"a\": \"1;5\",\n\t\t\"b\": \"2\"\n\t}\n]\n")
    }

    @Test func csvDistinguishesBlankRecordsFromTrailingTerminators() async throws {
        let blank = try await converted(.csvToJSON, name: "blank.csv", input: "value\n\n")
        let terminated = try await converted(.csvToJSON, name: "terminated.csv", input: "value\n")
        let emptyFields = try await converted(.csvToJSON, name: "fields.csv", input: "a,b\n,\n")

        #expect(blank == "[\n  {\n    \"value\": \"\"\n  }\n]\n")
        #expect(terminated == "[]\n")
        #expect(emptyFields == "[\n  {\n    \"a\": \"\",\n    \"b\": \"\"\n  }\n]\n")
    }

    @Test func csvBlankRecordMustMatchHeaderWidth() async throws {
        let (outcome, _) = try await convert(.csvToJSON, name: "blank-width.csv", input: "a,b\n\n")

        #expect(outcome.outcomes == [.failed(.invalidInput(.malformed("CSV record 2 has 1 fields, the header has 2")))])
    }

    @Test func csvToXML() async throws {
        let xml = try await converted(.csvToXML, name: "people.csv", input: Self.csv)

        #expect(
            xml == """
                <?xml version="1.0" encoding="UTF-8"?>
                <rows>
                  <row>
                    <name>Smith, J</name>
                    <quote>He said &quot;hi&quot;</quote>
                    <count>3</count>
                  </row>
                  <row>
                    <name>Lee</name>
                    <quote>line1
                line2</quote>
                    <count>x</count>
                  </row>
                </rows>

                """)
    }

    @Test func csvToHTML() async throws {
        let html = try await converted(.csvToHTML, name: "a<b.csv", input: "x,y\n1,<2>\n")

        #expect(
            html == """
                <!DOCTYPE html>
                <html>
                <head>
                <meta charset="utf-8">
                <title>a&lt;b</title>
                </head>
                <body>
                <table>
                <thead>
                <tr><th>x</th><th>y</th></tr>
                </thead>
                <tbody>
                <tr><td>1</td><td>&lt;2&gt;</td></tr>
                </tbody>
                </table>
                </body>
                </html>

                """)
    }

    @Test func csvToMarkdown() async throws {
        let markdown = try await converted(.csvToMarkdown, name: "people.csv", input: Self.csv + "a|b,c,d\r\n")

        #expect(
            markdown == """
                | name | quote | count |
                | --- | --- | --- |
                | Smith, J | He said "hi" | 3 |
                | Lee | line1<br>line2 | x |
                | a\\|b | c | d |

                """)
    }

    @Test func csvWithRaggedRowsFails() async throws {
        let (outcome, _) = try await convert(.csvToJSON, name: "bad.csv", input: "a,b\n1\n")

        #expect(outcome.outcomes == [.failed(.invalidInput(.malformed("CSV record 2 has 1 fields, the header has 2")))])
    }

    @Test func jsonToCSVQuotesPerRFC4180() async throws {
        let csv = try await converted(
            .jsonToCSV, name: "rows.json",
            input: #"[{"a":"x,y","b":1.50},{"b":true,"c":null,"a":"q\"z"},{"c":"two\nlines"}]"#)

        #expect(csv == "a,b,c\r\n\"x,y\",1.50,\r\n\"q\"\"z\",true,\r\n,,\"two\nlines\"\r\n")
    }

    @Test(arguments: [
        (#"{"a":1}"#, "$"),
        (#"[{"a":1},2]"#, "$[1]"),
        (#"[{"a":1},{"b":{"c":1}}]"#, "$[1].b"),
        (#"[{"list":[1]}]"#, "$[0].list"),
        (#"[{"id":"first","id":"second"}]"#, "$[0].id"),
    ])
    func jsonToCSVNamesTheOffendingPath(input: String, path: String) async throws {
        let (outcome, output) = try await convert(.jsonToCSV, name: "nested.json", input: input)

        #expect(outcome.outcomes == [.failed(.invalidInput(.jsonNotFlatArray(path: path)))])
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func jsonToXMLMapsAttributesTextAndArrays() async throws {
        let xml = try await converted(
            .jsonToXML, name: "book.json",
            input:
                ##"{"book":{"@id":"7","title":"Swift & You","tags":["a","b"],"price":12.50,"note":null,"by":{"@x":"1","#text":"Ann"}}}"##
        )

        #expect(
            xml == """
                <?xml version="1.0" encoding="UTF-8"?>
                <root>
                  <book id="7">
                    <title>Swift &amp; You</title>
                    <tags>a</tags>
                    <tags>b</tags>
                    <price>12.50</price>
                    <note/>
                    <by x="1">Ann</by>
                  </book>
                </root>

                """)
    }

    @Test func xmlToJSONMapsAttributesTextAndRepeatedSiblings() async throws {
        let json = try await converted(
            .xmlToJSON, name: "library.xml",
            input: """
                <?xml version="1.0"?>
                <library>
                  <book lang="en" id="1"><title>A</title></book>
                  <book id="2"><title>B</title><note>x <b>y</b></note></book>
                  <empty/>
                  <code><![CDATA[a < b]]></code>
                </library>
                """)

        #expect(
            json == """
                {
                  "library": {
                    "book": [
                      {
                        "@id": "1",
                        "@lang": "en",
                        "title": "A"
                      },
                      {
                        "@id": "2",
                        "title": "B",
                        "note": {
                          "b": "y",
                          "#text": "x"
                        }
                      }
                    ],
                    "empty": null,
                    "code": "a < b"
                  }
                }

                """)
    }

    @Test func xmlExternalEntitiesAreNeverRead() async throws {
        let secret = try TestVolume.makeFolder().appending(path: "secret.txt")
        try Data("TOP-SECRET".utf8).write(to: secret)
        let input = #"<!DOCTYPE r [<!ENTITY leak SYSTEM "URL">]><r>&leak;</r>"#.replacing(
            "URL", with: secret.absoluteString)

        let (outcome, output) = try await convert(.xmlToJSON, name: "xxe.xml", input: input)

        #expect(outcome.outcomes == [.succeeded(outputs: [output], warnings: [])])
        #expect(try String(contentsOf: output, encoding: .utf8) == "{\n  \"r\": null\n}\n")
    }

    @Test func xmlInternalEntityDeclarationsAreRejected() async throws {
        let input = #"<!DOCTYPE r [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;">]><r>&b;</r>"#

        let (outcome, output) = try await convert(.xmlToJSON, name: "laughs.xml", input: input)

        #expect(outcome.outcomes == [.failed(.invalidInput(.malformed("XML entity declarations are not supported")))])
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func malformedXMLFailsWithItsPosition() async throws {
        let (outcome, _) = try await convert(.xmlToJSON, name: "broken.xml", input: "<a>\n<b></a>")

        guard case .failed(.invalidInput(.malformed(let detail))) = outcome.outcomes.first else {
            Issue.record("expected a malformed failure, got \(outcome.outcomes)")
            return
        }
        #expect(detail.contains("line 2"))
    }

    private static let ini = """
        ; leading comment
        top = 1
        [server]
        host = example.com
        # another comment
        port: 8080
        [client]
        name = "x"
        [server]
        host = override
        """

    @Test func iniToJSON() async throws {
        let json = try await converted(.iniToJSON, name: "app.ini", input: Self.ini)

        #expect(
            json == """
                {
                  "top": "1",
                  "server": {
                    "host": "override",
                    "port": "8080"
                  },
                  "client": {
                    "name": "\\"x\\""
                  }
                }

                """)
    }

    @Test func iniToXML() async throws {
        let xml = try await converted(.iniToXML, name: "app.ini", input: Self.ini)

        #expect(
            xml == """
                <?xml version="1.0" encoding="UTF-8"?>
                <root>
                  <top>1</top>
                  <server>
                    <host>override</host>
                    <port>8080</port>
                  </server>
                  <client>
                    <name>&quot;x&quot;</name>
                  </client>
                </root>

                """)
    }

    @Test(arguments: [TextConversion.iniToJSON, .iniToXML])
    func iniGlobalKeyMatchingSectionNameFailsWithItsPath(conversion: TextConversion) async throws {
        let (outcome, output) = try await convert(
            conversion, name: "profile.ini", input: "profile=plain\n[profile]\nmode=dev\n")

        #expect(
            outcome.outcomes == [
                .failed(.invalidInput(.malformed("Duplicate JSON keys at $.profile are unsupported")))
            ])
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test(arguments: [TextConversion.iniToJSON, .iniToXML])
    func iniDistinctGlobalKeyAndSectionPreserveBothValues(conversion: TextConversion) async throws {
        let output = try await converted(
            conversion, name: "profile.ini", input: "profile=plain\n[server]\nmode=dev\n")

        let expected =
            conversion == .iniToJSON
            ? "{\n  \"profile\": \"plain\",\n  \"server\": {\n    \"mode\": \"dev\"\n  }\n}\n"
            : "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root>\n  <profile>plain</profile>\n  <server>\n    <mode>dev</mode>\n  </server>\n</root>\n"
        #expect(output == expected)
    }

    @Test func iniLineWithoutValueFails() async throws {
        let (outcome, _) = try await convert(.iniToJSON, name: "bad.ini", input: "[a]\njust words\n")

        #expect(outcome.outcomes == [.failed(.invalidInput(.malformed("INI line 2 is not a key and value")))])
    }
}

@Suite(.serialized) struct JSONFormattingTests {
    private static let source = #"{"b":{"z":1,"B":[{"y":1.0,"a":1e3}]},"é":"\u00e9\t","A":null}"#

    private func formatted(_ formatting: JSONFormatting, settings: Settings = Settings()) async throws -> String {
        let url = try file("data.json", text: Self.source)
        let outcome = try await runText(.json(formatting), op: .textJSON, on: [url], settings: settings)
        #expect(outcome.outcomes == [.succeeded(outputs: [url], warnings: [])])
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func prettyPrintKeepsOrderAndLiterals() async throws {
        var settings = Settings()
        settings.text.jsonIndent = .four
        let pretty = try await formatted(.pretty, settings: settings)

        #expect(
            pretty == """
                {
                    "b": {
                        "z": 1,
                        "B": [
                            {
                                "y": 1.0,
                                "a": 1e3
                            }
                        ]
                    },
                    "é": "é\\t",
                    "A": null
                }

                """)
    }

    @Test func minifyRemovesWhitespace() async throws {
        let minified = try await formatted(.minify)

        #expect(minified == #"{"b":{"z":1,"B":[{"y":1.0,"a":1e3}]},"é":"é\t","A":null}"#)
    }

    @Test func sortKeysByUnicodeScalarRecursivelyOrTopLevel() async throws {
        let recursive = try await formatted(.sortKeys)
        var settings = Settings()
        settings.text.keySortScope = .topLevel
        let topLevel = try await formatted(.sortKeys, settings: settings)

        #expect(
            recursive == """
                {
                  "A": null,
                  "b": {
                    "B": [
                      {
                        "a": 1e3,
                        "y": 1.0
                      }
                    ],
                    "z": 1
                  },
                  "é": "é\\t"
                }

                """)
        #expect(topLevel.hasPrefix("{\n  \"A\": null,\n  \"b\": {\n    \"z\": 1,"))
    }

    @Test(arguments: [
        ("{\n  \"a\": 1,\n  \"b\" 2\n}", 3, 7),
        ("[1, 2,]", 1, 7),
        ("{\"é\": tru}", 1, 10),
        ("[\"\\ud800x\"]", 1, 9),
        ("", 1, 1),
    ])
    func invalidJSONReportsLineAndColumn(input: String, line: Int, column: Int) async throws {
        let url = try file("broken.json", text: input)

        let outcome = try await runText(.json(.pretty), op: .textJSON, on: [url])

        #expect(outcome.outcomes == [.failed(.invalidInput(.jsonSyntax(line: line, column: column)))])
        #expect(try String(contentsOf: url, encoding: .utf8) == input)
    }
}
