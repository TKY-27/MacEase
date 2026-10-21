import Foundation
import Testing

@testable import Engine

@Suite struct YAMLConversionTests {
    @Test func mapsPlainScalarsWithTheCoreSchema() throws {
        let yaml = """
            name: Norway
            country: NO
            enabled: yes
            strict: true
            hex: 0x1F
            octal: 0o17
            signed: +12
            padded: 007
            precise: 1.50
            short: .5
            huge: 123456789012345678901234567890
            nothing: ~
            released: 2024-01-01
            quoted: "true"
            text: 日本語
            list: [1, two]
            """
        let json = try YAMLConversion.json(fromYAML: yaml).serialized(indent: nil)
        #expect(
            json
                == #"{"name":"Norway","country":"NO","enabled":"yes","strict":true,"hex":31,"octal":15,"signed":12,"padded":7,"precise":1.50,"short":0.5,"huge":123456789012345678901234567890,"nothing":null,"released":"2024-01-01","quoted":"true","text":"日本語","list":[1,"two"]}"#
        )
    }

    @Test func emitsDeterministicYAMLThatKeepsStringsStrings() throws {
        let json =
            #"{"z":"true","a":"yes","date":"2024-01-01","n":"12","null":null,"real":1.50,"big":123456789012345678901234567890,"flag":false,"nested":{"list":["~","",{"k":"multi\nline"}]}}"#
        let first = try YAMLConversion.yaml(fromJSON: json)
        #expect(try YAMLConversion.yaml(fromJSON: json) == first)
        #expect(first.hasPrefix("z: \"true\"\na: \"yes\"\ndate: \"2024-01-01\"\nn: \"12\"\n"))
        #expect(first.contains("real: 1.50\n"))
        #expect(try YAMLConversion.json(fromYAML: first).serialized(indent: nil) == json)
    }

    @Test func smallAliasesExpand() throws {
        let json = try YAMLConversion.json(fromYAML: "base: &shared [1, 2]\ncopy: *shared\n").serialized(indent: nil)
        #expect(json == #"{"base":[1,2],"copy":[1,2]}"#)
    }

    @Test func refusesAliasExpansionBombs() {
        var lines = ["a: &a [x, x, x, x, x, x, x, x, x, x]"]
        for (previous, name) in zip("abcdefgh", "bcdefghi") {
            let aliases = Array(repeating: "*\(previous)", count: 10).joined(separator: ", ")
            lines.append("\(name): &\(name) [\(aliases)]")
        }
        #expect(throws: EngineError.invalidInput(.malformed("Conversion exceeds 100000 values"))) {
            try YAMLConversion.json(fromYAML: lines.joined(separator: "\n"))
        }
        lines.append("? *i\n: key bomb")
        #expect(throws: EngineError.invalidInput(.malformed("Conversion exceeds 100000 values"))) {
            try YAMLConversion.json(fromYAML: lines.joined(separator: "\n"))
        }
    }

    @Test(arguments: [65, 100])
    func refusesDeepNestingBeforeComposing(depth: Int) {
        let yaml = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        #expect(throws: EngineError.invalidInput(.malformed("Conversion exceeds 64 levels"))) {
            try YAMLConversion.json(fromYAML: yaml)
        }
    }

    @Test func libyamlStopsExtremeNestingBeforeEvents() {
        let yaml = String(repeating: "[", count: 5_000) + String(repeating: "]", count: 5_000)
        #expect(throws: EngineError.self) { try YAMLConversion.json(fromYAML: yaml) }
    }

    @Test func acceptsTheDeepestAllowedNesting() throws {
        let yaml = String(repeating: "[", count: 64) + String(repeating: "]", count: 64)
        #expect(try YAMLConversion.json(fromYAML: yaml).serialized(indent: nil) == yaml)
    }

    @Test func aliasesCannotStackBeyondTheDepthLimit() {
        var lines = ["a0: &a0 [x]"]
        for level in 1...70 { lines.append("a\(level): &a\(level) [*a\(level - 1)]") }
        #expect(throws: EngineError.invalidInput(.malformed("Conversion exceeds 64 levels"))) {
            try YAMLConversion.json(fromYAML: lines.joined(separator: "\n"))
        }
    }

    @Test func refusesTooManyValues() {
        let yaml = "[" + Array(repeating: "1", count: 100_001).joined(separator: ",") + "]"
        #expect(throws: EngineError.invalidInput(.malformed("Conversion exceeds 100000 values"))) {
            try YAMLConversion.json(fromYAML: yaml)
        }
    }

    @Test(arguments: [
        ("1: one", "YAML key at $ is not a string"),
        ("? [a]\n: b", "YAML key at $ is not a string"),
        ("~: x", "YAML key at $ is not a string"),
        ("base: &b {x: 1}\nchild:\n  <<: *b", "YAML merge key at $.child is unsupported"),
        ("a: 1\n---\nb: 2", "YAML streams with several documents are unsupported"),
        ("value: !!binary aGVsbG8=", "YAML tag tag:yaml.org,2002:binary at $.value is unsupported"),
        ("value: !custom x", "YAML tag !custom at $.value is unsupported"),
        ("value: .inf", "YAML tag:yaml.org,2002:float value at $.value is invalid, out of range or not finite"),
        (
            "value: 0xFFFFFFFFFFFFFFFFF",
            "YAML tag:yaml.org,2002:int value at $.value is invalid, out of range or not finite"
        ),
        ("a: 1\na: 2", "YAML mapping repeats key a"),
        ("a: *missing", "YAML alias refers to an unknown anchor"),
    ])
    func refusesUnsupportedYAML(yaml: String, message: String) {
        #expect(throws: EngineError.invalidInput(.malformed(message))) { try YAMLConversion.json(fromYAML: yaml) }
    }

    @Test func reportsSyntaxErrorLine() {
        #expect(throws: EngineError.self) { try YAMLConversion.json(fromYAML: "a: 1\nb: [unclosed\n") }
        #expect(throws: EngineError.invalidInput(.emptyInput)) {
            try YAMLConversion.json(fromYAML: "# only a comment\n")
        }
        #expect(throws: EngineError.invalidInput(.emptyInput)) { try YAMLConversion.json(fromYAML: "") }
    }

    @Test(arguments: [
        (#"{"a":1e400}"#, "Number at $.a is not finite"),
        (#"{"a":1,"a":2}"#, "Duplicate JSON keys at $ are unsupported"),
        ("[" + Array(repeating: "1", count: 100_001).joined(separator: ",") + "]", "Conversion exceeds 100000 values"),
    ])
    func refusesJSONThatYAMLCannotKeep(json: String, message: String) {
        #expect(throws: EngineError.invalidInput(.malformed(message))) { try YAMLConversion.yaml(fromJSON: json) }
    }
}

@Suite struct TOMLConversionTests {
    @Test func mapsTypesAndDatesToJSON() throws {
        let toml = """
            title = "TOML"
            count = 0x10
            ratio = 0.1
            whole = 5.0
            enabled = true
            offset = 1979-05-27T07:32:00.120-07:00
            utc = 1979-05-27 07:32:00Z
            local = 1979-05-27T07:32:00
            india = 1979-05-27T07:32:00+05:30
            scientific = 1E2
            day = 1979-05-27
            time = 07:32:00.999999999

            [[servers]]
            name = "alpha"

            [[servers]]
            name = "beta"
            """
        let json = try TOMLConversion.json(fromTOML: toml).serialized(indent: nil)
        #expect(
            json
                == #"{"count":16,"day":"1979-05-27","enabled":true,"india":"1979-05-27T07:32:00+05:30","local":"1979-05-27T07:32:00","offset":"1979-05-27T07:32:00.12-07:00","ratio":0.1,"scientific":100.0,"servers":[{"name":"alpha"},{"name":"beta"}],"time":"07:32:00.999999999","title":"TOML","utc":"1979-05-27T07:32:00Z","whole":5.0}"#
        )
    }

    @Test func emitsReadableDeterministicTOML() throws {
        let json =
            #"{"title":"multi\nline \"quoted\" 日本語","ratio":0.1,"scaled":1E2,"large":1e100,"count":9223372036854775807,"flags":[true,false],"owner":{"name":"Tom","dot.key":1},"servers":[{"name":"alpha"},{"name":"beta"}],"mixed":[1,"two",[3]]}"#
        let output = try TOMLConversion.toml(fromJSON: json)
        #expect(try TOMLConversion.toml(fromJSON: json) == output)
        #expect(output.contains("ratio = 0.1\n"))
        #expect(output.contains("[[servers]]"))
        let restored = try TOMLConversion.json(fromTOML: output).serialized(indent: nil)
        #expect(
            restored
                == #"{"count":9223372036854775807,"flags":[true,false],"large":1e+100,"mixed":[1,"two",[3]],"owner":{"dot.key":1,"name":"Tom"},"ratio":0.1,"scaled":100.0,"servers":[{"name":"alpha"},{"name":"beta"}],"title":"multi\nline \"quoted\" 日本語"}"#
        )
    }

    @Test(arguments: [
        (#"{"a":null}"#, "JSON null at $.a has no TOML value"),
        (#"{"a":[1,null]}"#, "JSON null at $.a[1] has no TOML value"),
        (#"[1]"#, "TOML requires a JSON object at the root"),
        (#"{"a":1,"a":2}"#, "Duplicate JSON keys at $ are unsupported"),
        (#"{"a":9223372036854775808}"#, "Integer exceeds signed 64-bit range"),
        (#"{"a":0.10000000000000001}"#, "Number cannot be represented without precision loss"),
        (#"{"a":1e400}"#, "Number cannot be represented without precision loss"),
        (#"{"a":"x\u0000y"}"#, "TOML NUL characters at $.a are unsupported"),
    ])
    func refusesJSONThatTOMLCannotKeep(json: String, message: String) {
        #expect(throws: EngineError.invalidInput(.malformed(message))) { try TOMLConversion.toml(fromJSON: json) }
    }

    @Test(arguments: [
        (#"a = "x\u0000y""#, "TOML NUL characters are unsupported"),
        ("a = inf", "TOML number at $.a is not finite"),
        ("a = nan", "TOML number at $.a is not finite"),
    ])
    func refusesTOMLThatJSONCannotKeep(toml: String, message: String) {
        #expect(throws: EngineError.invalidInput(.malformed(message))) { try TOMLConversion.json(fromTOML: toml) }
    }

    @Test func boundsNestingSizeAndSyntax() {
        let nested = "a = " + String(repeating: "[", count: 100) + String(repeating: "]", count: 100)
        #expect(throws: EngineError.invalidInput(.malformed("Conversion exceeds 64 levels"))) {
            try TOMLConversion.json(fromTOML: nested)
        }
        let deepJSON = String(repeating: #"{"a":"#, count: 100) + "1" + String(repeating: "}", count: 100)
        #expect(throws: EngineError.invalidInput(.malformed("Conversion exceeds 64 levels"))) {
            try TOMLConversion.toml(fromJSON: deepJSON)
        }
        let huge = "a = \"" + String(repeating: "x", count: TOMLConversion.maximumBytes) + "\""
        #expect(throws: EngineError.invalidInput(.tooLarge(limitBytes: Int64(TOMLConversion.maximumBytes)))) {
            try TOMLConversion.json(fromTOML: huge)
        }
        #expect(throws: EngineError.self) { try TOMLConversion.json(fromTOML: "a = 1\nb = \n") }
    }
}
