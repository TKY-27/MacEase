import AppKit
import XCTest

@testable import MacEase

final class PreviewTokenizerTests: XCTestCase {
    private struct SnippetExpectation {
        let language: PreviewLanguage
        let sample: String
        let required: [(String, PreviewToken.Kind)]
        let forbidden: [(String, PreviewToken.Kind)]

        init(
            _ language: PreviewLanguage,
            _ sample: String,
            required: [(String, PreviewToken.Kind)],
            forbidden: [(String, PreviewToken.Kind)] = []
        ) {
            self.language = language
            self.sample = sample
            self.required = required
            self.forbidden = forbidden
        }
    }

    func testEveryPreviewExtensionAndFileNameResolvesAsTabled() {
        let extensionTable: [String: PreviewLanguage] = [
            "txt": .plain, "text": .plain, "log": .plain, "csv": .plain, "tsv": .plain, "nfo": .plain,
            "srt": .plain, "vtt": .plain, "ass": .plain, "lrc": .plain, "sln": .plain,
            "gitignore": .plain, "gitattributes": .plain,
            "diff": .diff, "patch": .diff,
            "tex": .latex, "sty": .latex, "cls": .latex,
            "rst": .restructuredText, "adoc": .asciiDoc, "asciidoc": .asciiDoc,
            "ini": .ini, "cfg": .ini, "conf": .ini, "properties": .ini, "reg": .ini, "inf": .ini,
            "env": .ini, "editorconfig": .ini, "gitmodules": .ini,
            "toml": .toml, "yaml": .yaml, "yml": .yaml,
            "json": .json, "jsonc": .json, "json5": .json,
            "html": .markup, "htm": .markup, "xhtml": .markup, "xml": .markup, "xaml": .markup,
            "csproj": .markup, "vcxproj": .markup, "fsproj": .markup, "vbproj": .markup,
            "props": .markup, "targets": .markup, "plist": .markup, "manifest": .markup,
            "svg": .markup, "vue": .markup, "svelte": .markup, "astro": .markup,
            "md": .markdown, "markdown": .markdown, "mdx": .markdown,
            "css": .css, "scss": .css, "sass": .css, "less": .css,
            "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
            "ts": .javascript, "mts": .javascript, "cts": .javascript, "tsx": .javascript,
            "py": .python, "pyw": .python, "pyi": .python,
            "rb": .ruby, "php": .php, "java": .java, "kt": .kotlin, "kts": .kotlin,
            "gradle": .groovy, "groovy": .groovy, "scala": .scala, "go": .go, "rs": .rust,
            "c": .c, "h": .c,
            "cc": .cpp, "cpp": .cpp, "cxx": .cpp, "hh": .cpp, "hpp": .cpp, "hxx": .cpp, "inl": .cpp,
            "cs": .csharp, "csx": .csharp, "fs": .fsharp, "fsx": .fsharp,
            "vb": .vb, "vbs": .vb, "swift": .swift, "m": .objectiveC, "mm": .objectiveCPP,
            "lua": .lua, "pl": .perl, "pm": .perl, "r": .r, "jl": .julia, "dart": .dart,
            "ex": .elixir, "exs": .elixir, "clj": .clojure, "sql": .sql,
            "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell,
            "ps1": .powershell, "psm1": .powershell, "psd1": .powershell,
            "bat": .batch, "cmd": .batch,
            "dockerfile": .dockerfile, "cmake": .cmake, "mk": .makefile, "mak": .makefile, "make": .makefile,
            "proto": .protobuf, "graphql": .graphql, "gql": .graphql,
            "hcl": .hcl, "tf": .hcl, "tfvars": .hcl, "sol": .solidity,
        ]
        for suffix in PreviewKind.textExtensions {
            XCTAssertNotNil(extensionTable[suffix], "Missing decision for text extension: \(suffix)")
        }
        for (suffix, expected) in extensionTable {
            XCTAssertEqual(PreviewLanguage.resolve(suffix), expected, suffix)
        }

        let fileNameTable: [String: PreviewLanguage] = [
            "CMakeLists.txt": .cmake,
            "Makefile": .makefile,
            "GNUmakefile": .makefile,
            "Dockerfile": .dockerfile,
            "Containerfile": .dockerfile,
            ".dockerfile": .dockerfile,
            "Dockerfile.prod": .dockerfile,
            "Gemfile": .ruby,
            "Rakefile": .ruby,
            "Podfile": .ruby,
            "Brewfile": .ruby,
            "Fastfile": .ruby,
            "Vagrantfile": .ruby,
            "Jenkinsfile": .groovy,
            ".env": .ini,
            ".env.local": .ini,
            ".editorconfig": .ini,
            ".gitmodules": .ini,
            ".gitconfig": .ini,
            ".npmrc": .ini,
            ".gitignore": .plain,
            ".gitattributes": .plain,
            ".bashrc": .shell,
            ".zshrc": .shell,
            ".bash_profile": .shell,
            ".zprofile": .shell,
            ".zshenv": .shell,
            ".profile": .shell,
        ]
        for known in PreviewKind.textFileNames {
            XCTAssertTrue(
                fileNameTable.keys.contains { $0.lowercased() == known },
                "Missing decision for file name: \(known)")
        }
        for (name, expected) in fileNameTable {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            XCTAssertEqual(
                PreviewKind.resolve(type: nil, extension: url.pathExtension, fileName: url.lastPathComponent),
                .text, name)
            XCTAssertEqual(
                PreviewLanguage.resolve(url.pathExtension, fileName: url.lastPathComponent),
                expected, name)
        }
    }

    func testLanguageSnippetsAndKnownTraps() throws {
        let cases: [SnippetExpectation] = [
            SnippetExpectation(
                .swift,
                "#if DEBUG\n/* outer /* inner */ end */\nlet name: String = \"ok\"\nlet regex = /don't/\nlet n = 0xFF\n#endif",
                required: [
                    ("#if", .keyword), ("/* outer /* inner */ end */", .comment), ("let", .keyword),
                    ("String", .type), ("\"ok\"", .string), ("0xFF", .number),
                ],
                forbidden: [("'/", .string)]
            ),
            SnippetExpectation(
                .javascript,
                "// note\nexport const x: number = 42;\nconst s = `a\nb`;",
                required: [
                    ("// note", .comment), ("export", .keyword), ("number", .type),
                    ("42", .number), ("`a\nb`", .string),
                ]
            ),
            SnippetExpectation(
                .python,
                "# header\ndef f(x: int) -> str:\n    raw = r\"a\\\"b\"\n    return len(raw)\n",
                required: [
                    ("# header", .comment), ("def", .keyword), ("int", .type),
                    ("r\"a\\\"b\"", .string), ("len", .type),
                ]
            ),
            SnippetExpectation(
                .c,
                "#include <stdio.h>\n/* note */\nint n = 1'000'000; char c = 'x';",
                required: [
                    ("#include", .keyword), ("/* note */", .comment), ("int", .type),
                    ("1'000'000", .number), ("'x'", .string),
                ],
                forbidden: [("#include", .comment)]
            ),
            SnippetExpectation(
                .cpp,
                "#define X 1\nnamespace app { std::string s = R\"tag(has \"//\" inside)tag\"; }",
                required: [
                    ("#define", .keyword), ("namespace", .keyword), ("std", .type),
                    ("R\"tag(has \"//\" inside)tag\"", .string),
                ],
                forbidden: [("//", .comment)]
            ),
            SnippetExpectation(
                .objectiveC,
                "#import <Foundation/Foundation.h>\n@interface App : NSObject\nNSString *s = @\"hi\";\n@end",
                required: [
                    ("#import", .keyword), ("@interface", .keyword), ("NSObject", .type),
                    ("@\"hi\"", .string), ("@end", .keyword),
                ]
            ),
            SnippetExpectation(
                .objectiveCPP,
                "@implementation Bridge\nstd::vector<int> v; NSString *s = @\"ok\"; auto r = R\"(a\"b)\";\n@end",
                required: [
                    ("@implementation", .keyword), ("vector", .type), ("@\"ok\"", .string),
                    ("R\"(a\"b)\"", .string), ("@end", .keyword),
                ]
            ),
            SnippetExpectation(
                .go,
                "// go\npackage main\nfunc f() string { return `raw\\path` + \"ok\" }\nconst n = 0x10",
                required: [
                    ("// go", .comment), ("package", .keyword), ("string", .type),
                    ("`raw\\path`", .string), ("\"ok\"", .string), ("0x10", .number),
                ]
            ),
            SnippetExpectation(
                .rust,
                "/* a /* b */ c */\nfn pick<'a, 'b>(x: &'a str, y: &'b str) -> &'a str {\n    let c = '\\n';\n    let s = r#\"quote \" here\"#;\n    let n = 42;\n    x\n}",
                required: [
                    ("/* a /* b */ c */", .comment), ("fn", .keyword), ("str", .type),
                    ("'\\n'", .string), ("r#\"quote \" here\"#", .string), ("42", .number),
                ],
                forbidden: [("'a, '", .string), ("'a str, y: &'", .string)]
            ),
            SnippetExpectation(
                .ruby,
                "# comment\ndef greet\n  sql = <<~SQL\n    SELECT 1\n  SQL\n  puts \"hi\"\nend",
                required: [
                    ("# comment", .comment), ("def", .keyword), ("puts", .type),
                    ("\"hi\"", .string), ("<<~SQL\n    SELECT 1\n  SQL", .string),
                ]
            ),
            SnippetExpectation(
                .php,
                "<?php\n# hash\n// slash\nfunction f(): string { $return = 'ok'; return $return; }",
                required: [
                    ("<?php", .keyword), ("# hash", .comment), ("// slash", .comment),
                    ("function", .keyword), ("string", .type), ("'ok'", .string),
                ],
                forbidden: [("$return", .keyword)]
            ),
            SnippetExpectation(
                .java,
                "// doc\npublic record User(String name) {\n    String sql = \"\"\"\n        hello\n        \"\"\";\n    int n = 7;\n}",
                required: [
                    ("// doc", .comment), ("record", .keyword), ("String", .type),
                    ("\"\"\"\n        hello\n        \"\"\"", .string), ("7", .number),
                ]
            ),
            SnippetExpectation(
                .kotlin,
                "/* a /* b */ c */\nfun greet(name: String) = \"\"\"raw \\\" text\"\"\"",
                required: [
                    ("/* a /* b */ c */", .comment), ("fun", .keyword), ("String", .type),
                    ("\"\"\"raw \\\" text\"\"\"", .string),
                ]
            ),
            SnippetExpectation(
                .csharp,
                "#region Demo\nvar path = @\"C:\\dir\\\"\"name\"\"\";\nint n = 9;\n#endregion",
                required: [
                    ("#region", .keyword), ("var", .keyword), ("@\"C:\\dir\\\"\"name\"\"\"", .string),
                    ("9", .number), ("#endregion", .keyword),
                ]
            ),
            SnippetExpectation(
                .scala,
                "/* nested /* ok */ */\nval raw: Option[Int] = Some(1)\nval s = \"\"\"hello\"\"\"",
                required: [
                    ("/* nested /* ok */ */", .comment), ("val", .keyword), ("Option", .type),
                    ("\"\"\"hello\"\"\"", .string), ("1", .number),
                ]
            ),
            SnippetExpectation(
                .dart,
                "// dart\nFuture<String> load() async { final p = r'C:\\tmp'; return p; }",
                required: [
                    ("// dart", .comment), ("Future", .type), ("async", .keyword),
                    ("r'C:\\tmp'", .string),
                ]
            ),
            SnippetExpectation(
                .lua,
                "--[=[ block with ]] inside ]=]\nlocal msg = [[hello]]\n-- tail\nreturn 3",
                required: [
                    ("--[=[ block with ]] inside ]=]", .comment), ("local", .keyword),
                    ("[[hello]]", .string), ("-- tail", .comment), ("3", .number),
                ]
            ),
            SnippetExpectation(
                .perl,
                "# perl\nmy $my = \"ok\";\nprint length($my);",
                required: [
                    ("# perl", .comment), ("my", .keyword), ("\"ok\"", .string), ("length", .type),
                ],
                forbidden: [("$my", .keyword)]
            ),
            SnippetExpectation(
                .r,
                "# r\nfn <- function(x) { if (TRUE) return(mean(x) + 1.5) }",
                required: [
                    ("# r", .comment), ("function", .keyword), ("TRUE", .keyword),
                    ("mean", .type), ("1.5", .number),
                ]
            ),
            SnippetExpectation(
                .shell,
                "# sh\nif [ -f 'a\\' ]; then\n  echo $if\n  cat <<'EOF'\nbody\nEOF\nfi",
                required: [
                    ("# sh", .comment), ("if", .keyword), ("'a\\'", .string),
                    ("echo", .type), ("<<'EOF'\nbody\nEOF", .string), ("fi", .keyword),
                ],
                forbidden: [("$if", .keyword)]
            ),
            SnippetExpectation(
                .powershell,
                "<# block #>\nFUNCTION Test-It { $if = \"a`\"b\"; Write-Output $true }",
                required: [
                    ("<# block #>", .comment), ("FUNCTION", .keyword), ("\"a`\"b\"", .string),
                    ("Write-Output", .type), ("$true", .keyword),
                ],
                forbidden: [("$if", .keyword)]
            ),
            SnippetExpectation(
                .batch,
                "REM header\n:: second\nECHO \"hi\"\nset remove=1",
                required: [
                    ("REM header", .comment), (":: second", .comment), ("ECHO", .keyword),
                    ("\"hi\"", .string), ("set", .keyword), ("1", .number),
                ],
                forbidden: [("remove", .comment)]
            ),
            SnippetExpectation(
                .sql,
                "-- query\nSELECT count(*) FROM users WHERE note = 'it''s ok' AND id = 7;",
                required: [
                    ("-- query", .comment), ("SELECT", .keyword), ("count", .type),
                    ("'it''s ok'", .string), ("7", .number),
                ]
            ),
            SnippetExpectation(
                .json,
                "// jsonc\n{\"count\": 12, \"ok\": true}",
                required: [
                    ("// jsonc", .comment), ("\"count\"", .string), ("12", .number), ("true", .keyword),
                ]
            ),
            SnippetExpectation(
                .yaml,
                "# cfg\nurl: https://example.com\nnote: don't break\nquoted: 'it''s'\nport: 8080",
                required: [
                    ("# cfg", .comment), ("url", .keyword), ("'it''s'", .string), ("8080", .number),
                ],
                forbidden: [("https", .keyword), ("'t break", .string)]
            ),
            SnippetExpectation(
                .toml,
                "# toml\n[package]\nname = 'C:\\Users\\me'\nversion = \"1.0\"\nport = 443",
                required: [
                    ("# toml", .comment), ("[package]", .keyword), ("name", .keyword),
                    ("'C:\\Users\\me'", .string), ("\"1.0\"", .string), ("443", .number),
                ]
            ),
            SnippetExpectation(
                .ini,
                "; comment\n[server]\napp.host = localhost\nnote = don't stop\nport = 8080",
                required: [
                    ("; comment", .comment), ("[server]", .keyword), ("app.host", .keyword), ("8080", .number),
                ],
                forbidden: [("'t stop", .string)]
            ),
            SnippetExpectation(
                .dockerfile,
                "# image\nFROM swift:6.0 AS builder\nRUN echo from here",
                required: [
                    ("# image", .comment), ("FROM", .keyword), ("AS", .keyword), ("RUN", .keyword),
                ],
                forbidden: [("from", .keyword)]
            ),
            SnippetExpectation(
                .makefile,
                "# rules\nbuild: deps\n\techo building\nifeq ($(A),1)\nendif",
                required: [
                    ("# rules", .comment), ("build", .type), ("ifeq", .keyword), ("endif", .keyword),
                ],
                forbidden: [("echo", .type)]
            ),
            SnippetExpectation(
                .cmake,
                "#[[ block ]]\nPROJECT(MacEase)\nadd_executable(app main.cpp)\ntarget_link_libraries(app PRIVATE m)",
                required: [
                    ("#[[ block ]]", .comment), ("PROJECT", .keyword), ("add_executable", .keyword),
                    ("PRIVATE", .type),
                ]
            ),
            SnippetExpectation(
                .groovy,
                "// gradle\nplugins { id 'java' }\ndependencies { implementation '''a\nb''' }",
                required: [
                    ("// gradle", .comment), ("plugins", .keyword), ("'java'", .string),
                    ("implementation", .keyword), ("'''a\nb'''", .string),
                ]
            ),
            SnippetExpectation(
                .hcl,
                "# tf\n// also\nresource \"aws_s3_bucket\" \"b\" {\n  count = 2\n  policy = <<-EOT\n    {}\n  EOT\n}",
                required: [
                    ("# tf", .comment), ("// also", .comment), ("resource", .keyword),
                    ("\"aws_s3_bucket\"", .string), ("2", .number), ("<<-EOT\n    {}\n  EOT", .string),
                ]
            ),
            SnippetExpectation(
                .protobuf,
                "// proto\nsyntax = \"proto3\";\nmessage Item { int64 id = 1; }",
                required: [
                    ("// proto", .comment), ("syntax", .keyword), ("\"proto3\"", .string),
                    ("message", .keyword), ("int64", .type), ("1", .number),
                ]
            ),
            SnippetExpectation(
                .graphql,
                "# schema\n\"\"\"User doc\"\"\"\ntype User { id: ID! }",
                required: [
                    ("# schema", .comment), ("\"\"\"User doc\"\"\"", .string),
                    ("type", .keyword), ("ID", .type),
                ]
            ),
            SnippetExpectation(
                .css,
                "/* css */\n@media (min-width: 600px) {\n  .a { background-color: #336699; background: url(https://example.com/a.png); }\n}",
                required: [
                    ("/* css */", .comment), ("@media", .keyword), ("600px", .number),
                    ("background-color", .keyword), ("#336699", .number),
                ],
                forbidden: [("//example.com/a.png); }", .comment)]
            ),
            SnippetExpectation(
                .markup,
                "<template><p>don't</p></template>\n<script lang=\"ts\">\nconst count: number = 42;\n</script>\n<style scoped>\n.x { color: #ff00aa; }\n</style>",
                required: [
                    ("<template", .keyword), ("<script", .keyword), ("\"ts\"", .string),
                    ("const", .keyword), ("number", .type), ("42", .number), ("</script", .keyword),
                    ("<style", .keyword), ("color", .keyword), ("#ff00aa", .number), ("</style", .keyword),
                ],
                forbidden: [("'t</p></template>", .string)]
            ),
            SnippetExpectation(
                .markdown,
                "# Title\nIt's fine.\n```swift\nlet x = 1\n```",
                required: [
                    ("# Title", .keyword), ("```swift\nlet x = 1\n```", .string),
                ],
                forbidden: [("'s fine.", .string)]
            ),
            SnippetExpectation(
                .latex,
                "\\section{Intro}\n50\\% off % real comment",
                required: [
                    ("\\section", .keyword), ("\\%", .keyword), ("% real comment", .comment),
                ],
                forbidden: [("% off % real comment", .comment)]
            ),
            SnippetExpectation(
                .restructuredText,
                "Title\n=====\nDon't break ``literal`` here.",
                required: [
                    ("Title", .keyword), ("=====", .keyword), ("``literal``", .string),
                ],
                forbidden: [("'t break", .string)]
            ),
            SnippetExpectation(
                .asciiDoc,
                "== Section\nDon't break `inline` or:\n----\nblock\n----\na == b",
                required: [
                    ("== Section", .keyword), ("`inline`", .string), ("----\nblock\n----", .string),
                ],
                forbidden: [("a == b", .keyword), ("'t break", .string)]
            ),
            SnippetExpectation(
                .diff,
                "diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1,2 +1,3 @@\n context\n-old\n+new\n+++i",
                required: [
                    ("diff --git a/a.swift b/a.swift", .keyword),
                    ("--- a/a.swift", .keyword),
                    ("+++ b/a.swift", .keyword),
                    ("@@ -1,2 +1,3 @@", .number),
                    ("-old", .diffRemoved),
                    ("+new", .diffAdded),
                    ("+++i", .diffAdded),
                ]
            ),
            SnippetExpectation(
                .fsharp,
                "(* a (* b *) c *)\nlet id (x: 'a) = x\nlet s = @\"a\"\"b\" + string 1",
                required: [
                    ("(* a (* b *) c *)", .comment), ("let", .keyword),
                    ("@\"a\"\"b\"", .string), ("string", .type), ("1", .number),
                ],
                forbidden: [("'a) = x", .string)]
            ),
            SnippetExpectation(
                .vb,
                "' comment\nSub Main()\n  Dim s As String = \"say \"\"hi\"\"\"\nEnd Sub",
                required: [
                    ("' comment", .comment), ("Sub", .keyword), ("String", .type),
                    ("\"say \"\"hi\"\"\"", .string),
                ]
            ),
            SnippetExpectation(
                .julia,
                "#= a #= b =# c =#\nfunction f(A::Matrix)\n  return A' + 'x'\nend",
                required: [
                    ("#= a #= b =# c =#", .comment), ("function", .keyword),
                    ("Matrix", .type), ("'x'", .string),
                ],
                forbidden: [("' + '", .string)]
            ),
            SnippetExpectation(
                .elixir,
                "# ex\ndefmodule App do\n  def run, do: \"\"\"doc\"\"\"\nend",
                required: [
                    ("# ex", .comment), ("defmodule", .keyword), ("\"\"\"doc\"\"\"", .string),
                ]
            ),
            SnippetExpectation(
                .clojure,
                "; clj\n(defn- pick [x] (if-let [v (first 'sym)] \"ok\" 1))",
                required: [
                    ("; clj", .comment), ("defn-", .keyword), ("if-let", .keyword),
                    ("first", .type), ("\"ok\"", .string), ("1", .number),
                ],
                forbidden: [("'sym)] ", .string)]
            ),
            SnippetExpectation(
                .solidity,
                "// sol\npragma solidity ^0.8.0;\ncontract Vault { uint256 public total = 1; }",
                required: [
                    ("// sol", .comment), ("pragma", .keyword), ("contract", .keyword),
                    ("uint256", .type), ("1", .number),
                ]
            ),
        ]

        let tested = Set(cases.map(\.language))
        for language in PreviewLanguage.allCases where language != .plain {
            XCTAssertTrue(tested.contains(language), "Missing table-driven snippet test for \(language)")
        }

        for entry in cases {
            let tokens = try PreviewTokenizer.tokens(entry.sample, language: entry.language)
            let source = entry.sample as NSString
            for (literal, expectedKind) in entry.required {
                XCTAssertTrue(
                    tokens.contains { $0.kind == expectedKind && source.substring(with: $0.range) == literal },
                    "\(entry.language): expected \(expectedKind) for \(literal.debugDescription)")
            }
            for (literal, forbiddenKind) in entry.forbidden {
                XCTAssertFalse(
                    tokens.contains { $0.kind == forbiddenKind && source.substring(with: $0.range) == literal },
                    "\(entry.language): did not expect \(forbiddenKind) for \(literal.debugDescription)")
            }
        }
    }

    func testUnterminatedSingleQuotesStayBounded() throws {
        let swiftFiller = String(repeating: "let ok = 42\n", count: 400)
        let straySingleLine = "let broken = \"unterminated\n" + swiftFiller
        let singleLineTokens = try PreviewTokenizer.tokens(straySingleLine, language: .swift)
        XCTAssertEqual(singleLineTokens.filter { $0.kind == .keyword }.count, 401)

        let rubyFiller = String(repeating: "def ok; 42; end\n", count: 400)
        let strayMultilineQuote = "s = 'unterminated\n" + rubyFiller
        let multilineTokens = try PreviewTokenizer.tokens(strayMultilineQuote, language: .ruby)
        XCTAssertGreaterThan(multilineTokens.filter { $0.kind == .keyword }.count, 200)
    }

    func testLongUnambiguousBlocksDoNotInvertParity() throws {
        let cBody = String(
            repeating: " * License clause line with 80 chars padding for testing long header blocks.\n", count: 300)
        let cSource = "/*\n" + cBody + " */\nint status = 1;\n"
        let cTokens = try PreviewTokenizer.tokens(cSource, language: .c)
        let cNS = cSource as NSString
        let cComments = cTokens.filter { $0.kind == .comment }
        XCTAssertEqual(cComments.count, 1)
        XCTAssertEqual(cComments[0].range, NSRange(location: 0, length: ("/*\n" + cBody + " */" as NSString).length))
        XCTAssertTrue(cTokens.contains { $0.kind == .type && cNS.substring(with: $0.range) == "int" })
        XCTAssertTrue(cTokens.contains { $0.kind == .number && cNS.substring(with: $0.range) == "1" })

        let pyBody = String(repeating: "Documentation paragraph line.\n", count: 400)
        let pySource =
            "def f():\n    \"\"\"\n" + pyBody
            + "    \"\"\"\n    return 1\n\ndef g():\n    \"\"\"short\"\"\"\n    return 2\n"
        let pyTokens = try PreviewTokenizer.tokens(pySource, language: .python)
        let pyNS = pySource as NSString
        let pyStrings = pyTokens.filter { $0.kind == .string }
        XCTAssertEqual(pyStrings.count, 2)
        XCTAssertEqual(pyNS.substring(with: pyStrings[1].range), "\"\"\"short\"\"\"")
        XCTAssertEqual(
            pyTokens.filter { $0.kind == .keyword }.map { pyNS.substring(with: $0.range) },
            ["def", "return", "def", "return"])

        let mdBody = String(repeating: "let line = 1\n", count: 300)
        let mdBacktick = "```swift\n" + mdBody + "```\n## Next heading\n"
        let mdBacktickTokens = try PreviewTokenizer.tokens(mdBacktick, language: .markdown)
        let mdBacktickNS = mdBacktick as NSString
        XCTAssertEqual(mdBacktickTokens.count, 2)
        XCTAssertEqual(mdBacktickTokens[0].kind, .string)
        XCTAssertEqual(mdBacktickTokens[1].kind, .keyword)
        XCTAssertEqual(mdBacktickNS.substring(with: mdBacktickTokens[1].range), "## Next heading")

        let mdTilde = "~~~python\n" + mdBody + "~~~\n## After tilde\n    # indented comment\n"
        let mdTildeTokens = try PreviewTokenizer.tokens(mdTilde, language: .markdown)
        let mdTildeNS = mdTilde as NSString
        XCTAssertEqual(mdTildeTokens.count, 2)
        XCTAssertEqual(mdTildeTokens[0].kind, .string)
        XCTAssertEqual(mdTildeTokens[1].kind, .keyword)
        XCTAssertEqual(mdTildeNS.substring(with: mdTildeTokens[1].range), "## After tilde")
    }

    func testPHPTemplatesAndShellAnsiCQuotes() throws {
        let phpTemplate = """
            <p>Don't forget to sign in.</p>
            <?php
            $user = 'admin';
            echo $user;
            ?>
            <p>Footer's fine</p>
            <?= $user ?>
            """
        let phpTokens = try PreviewTokenizer.tokens(phpTemplate, language: .php)
        let phpNS = phpTemplate as NSString
        let phpPairs = phpTokens.map { (phpNS.substring(with: $0.range), $0.kind) }
        XCTAssertEqual(phpPairs.map(\.0), ["<p", "</p", "<?php", "'admin'", "echo", "?>", "<p", "</p", "<?=", "?>"])
        XCTAssertEqual(
            phpPairs.map(\.1),
            [.keyword, .keyword, .keyword, .string, .keyword, .keyword, .keyword, .keyword, .keyword, .keyword])

        let shellSample = """
            echo $'it\\'s escaped' "don't"
            if true; then
              echo ok
            fi
            """
        let shellTokens = try PreviewTokenizer.tokens(shellSample, language: .shell)
        let shellNS = shellSample as NSString
        XCTAssertEqual(
            shellTokens.filter { $0.kind == .string }.map { shellNS.substring(with: $0.range) },
            ["$'it\\'s escaped'", "\"don't\""])
        XCTAssertEqual(
            shellTokens.filter { $0.kind == .keyword }.map { shellNS.substring(with: $0.range) },
            ["if", "true", "then", "fi"])
    }

    func testPHPCommentsEndAtCloseTagRubyAppendsAndSpreadKeepsKeywords() throws {
        func substrings(_ text: String, _ language: PreviewLanguage, _ kind: PreviewToken.Kind) throws -> [String] {
            try PreviewTokenizer.tokens(text, language: language).filter { $0.kind == kind }.map {
                (text as NSString).substring(with: $0.range)
            }
        }
        let template = """
            <?php // header ?>
            <p>Don't forget</p>
            <?php echo $a; ?>
            <p>It's done</p>
            <?php # hash ?>
            <p>Won't break</p>
            """
        XCTAssertEqual(try substrings(template, .php, .comment), ["// header ", "# hash "])
        XCTAssertEqual(try substrings(template, .php, .string), [])
        XCTAssertEqual(
            try substrings(template, .php, .keyword),
            ["<?php", "?>", "<p", "</p", "<?php", "echo", "?>", "<p", "</p", "<?php", "?>", "<p", "</p"])

        let ruby = "log << \"started\"\ndef run\n  puts \"x\"\nend\nsql = <<~\"SQL\"\n  select 1\nSQL\n"
        XCTAssertEqual(try substrings(ruby, .ruby, .string), ["\"started\"", "\"x\"", "<<~\"SQL\"\n  select 1\nSQL"])
        XCTAssertEqual(try substrings(ruby, .ruby, .keyword), ["def", "end"])
        XCTAssertEqual(try substrings("cat << \"EOF\"\nhi\nEOF\n", .shell, .string), ["<< \"EOF\"\nhi\nEOF"])

        XCTAssertEqual(try substrings("from . import views\n", .python, .keyword), ["from", "import"])
        XCTAssertEqual(
            try substrings("const s = [...new Set(a)]; f(...await g()); obj.default;", .javascript, .keyword),
            ["const", "new", "await"])
    }

    func testDiffHeadersDoNotMisclassifyHunkLines() throws {
        let patch = """
            diff --git a/query.sql b/query.sql
            --- a/query.sql
            +++ b/query.sql
            @@ -1,3 +1,3 @@
            --- removed sql comment
            +++ added line
             context
            """
        let tokens = try PreviewTokenizer.tokens(patch, language: .diff)
        let ns = patch as NSString
        XCTAssertEqual(
            tokens.map { (ns.substring(with: $0.range), $0.kind) }.map(\.0),
            [
                "diff --git a/query.sql b/query.sql",
                "--- a/query.sql",
                "+++ b/query.sql",
                "@@ -1,3 +1,3 @@",
                "--- removed sql comment",
                "+++ added line",
            ])
        XCTAssertEqual(
            tokens.map(\.kind),
            [.keyword, .keyword, .keyword, .number, .diffRemoved, .diffAdded])

        let concatenated = """
            --- a/first.sql
            +++ b/first.sql
            @@ -1 +1 @@
            --- old comment
            --- a/second.sql
            +++ b/second.sql
            @@ -1 +1 @@
            -old
            """
        let concatTokens = try PreviewTokenizer.tokens(concatenated, language: .diff)
        let concatNS = concatenated as NSString
        XCTAssertEqual(
            concatTokens.map { (concatNS.substring(with: $0.range), $0.kind) }.map(\.1),
            [.keyword, .keyword, .number, .diffRemoved, .keyword, .keyword, .number, .diffRemoved])
        XCTAssertEqual(concatNS.substring(with: concatTokens[3].range), "--- old comment")
        XCTAssertEqual(concatNS.substring(with: concatTokens[4].range), "--- a/second.sql")
    }

    func testINICommentsRequireLineStartOrWhitespace() throws {
        let envFile = """
            ; full line comment
            DATABASE_URL=Server=db;Database=app
            THEME_COLOR=#336699
            PORT=8080 # trailing hash
            HOST=localhost ; trailing semi
            """
        let tokens = try PreviewTokenizer.tokens(envFile, language: .ini)
        let ns = envFile as NSString
        let comments = tokens.filter { $0.kind == .comment }.map { ns.substring(with: $0.range) }
        XCTAssertEqual(comments, ["; full line comment", "# trailing hash", "; trailing semi"])
        XCTAssertEqual(
            tokens.filter { $0.kind == .keyword }.map { ns.substring(with: $0.range) },
            ["DATABASE_URL", "THEME_COLOR", "PORT", "HOST"])
    }

    func testDotAccessYAMLHyphensCSSSelectorsAndSwiftRawStrings() throws {
        let jsSample = "map.get(key); params.set(k, v); event.type; obj.default; const x = 1;"
        let jsTokens = try PreviewTokenizer.tokens(jsSample, language: .javascript)
        let jsNS = jsSample as NSString
        XCTAssertEqual(
            jsTokens.filter { $0.kind == .keyword }.map { jsNS.substring(with: $0.range) },
            ["const"])

        let yamlSample = "runs-on: macos-15\ntimeout-minutes: 30\n"
        let yamlTokens = try PreviewTokenizer.tokens(yamlSample, language: .yaml)
        let yamlNS = yamlSample as NSString
        XCTAssertEqual(
            yamlTokens.filter { $0.kind == .keyword }.map { yamlNS.substring(with: $0.range) },
            ["runs-on", "timeout-minutes"])

        let cssSample = """
            a:hover, li:first-child { color: red; }
            .card { a:hover { margin: 0; } }
            .min{padding:4px;}
            """
        let cssTokens = try PreviewTokenizer.tokens(cssSample, language: .css)
        let cssNS = cssSample as NSString
        XCTAssertEqual(
            cssTokens.filter { $0.kind == .keyword }.map { cssNS.substring(with: $0.range) },
            ["color", "margin", "padding"])

        let swiftSample = """
            let a = #"quote " inside"#
            let b = ##"hash "# inside"##
            let c = #\"\"\"
            multi " quote
            \"\"\"#
            """
        let swiftTokens = try PreviewTokenizer.tokens(swiftSample, language: .swift)
        let swiftNS = swiftSample as NSString
        XCTAssertEqual(
            swiftTokens.filter { $0.kind == .string }.map { swiftNS.substring(with: $0.range) },
            [
                "#\"quote \" inside\"#",
                "##\"hash \"# inside\"##",
                "#\"\"\"\nmulti \" quote\n\"\"\"#",
            ])
    }

    func testTokenRangesNeverSplitSurrogatePairs() throws {
        let latex = "\\😀 text"
        let latexTokens = try PreviewTokenizer.tokens(latex, language: .latex)
        XCTAssertEqual(latexTokens.count, 1)
        XCTAssertEqual(latexTokens[0].kind, .keyword)
        XCTAssertEqual(latexTokens[0].range, NSRange(location: 0, length: 3))

        let capStraddle = "\"" + String(repeating: "a", count: 16_382) + "😀tail"
        let capTokens = try PreviewTokenizer.tokens(capStraddle, language: .rust)
        let stringToken = try XCTUnwrap(capTokens.first { $0.kind == .string })
        XCTAssertEqual(stringToken.range, NSRange(location: 0, length: 16_383))

        let escapedStraddle = "\"" + String(repeating: "a", count: 16_381) + "\\😀tail"
        let escapedTokens = try PreviewTokenizer.tokens(escapedStraddle, language: .rust)
        assertNoSurrogateSplits(in: escapedStraddle, tokens: escapedTokens)

        let probes = [
            "\\😀 \\🚀 % 😀\n",
            "\"a😀b\" '😀' /* 😀 */ // 😀\n",
            String(repeating: "😀\\😀\"😀", count: 200),
        ]
        for language in [PreviewLanguage.latex, .swift, .rust, .ruby, .python, .markdown, .php] {
            for probe in probes {
                let tokens = try PreviewTokenizer.tokens(probe, language: language)
                assertNoSurrogateSplits(in: probe, tokens: tokens)
            }
        }
    }

    func testInvisibleAndConfusablePolicyCoversAttackClassesWithoutFlaggingNaturalText() throws {
        let alwaysFlagged =
            "a\u{202A}\u{202E}\u{2066}\u{2069}\u{0007}\u{007F}\u{0085}"
            + "\u{200B}\u{2060}\u{2062}\u{FEFF}\u{2028}\u{2029}"
            + "\u{E0041}\u{E0042}\u{115F}\u{1160}\u{3164}\u{FFA0}\u{180E}\u{2800}"
            + "\u{034F}\u{17B4}\u{FFF9}b"
        let alwaysMarks = try Self.invisibleMarks(alwaysFlagged, language: .plain)
        XCTAssertEqual(
            alwaysMarks.map(\.codePointLabel),
            [
                "U+202A", "U+202E", "U+2066", "U+2069", "U+0007", "U+007F", "U+0085",
                "U+200B", "U+2060", "U+2062", "U+FEFF", "U+2028", "U+2029",
                "U+E0041", "U+E0042", "U+115F", "U+1160", "U+3164", "U+FFA0", "U+180E", "U+2800",
                "U+034F", "U+17B4", "U+FFF9",
            ])
        let tagMark = try XCTUnwrap(alwaysMarks.first { $0.scalar == Unicode.Scalar(0xE0041) })
        XCTAssertEqual(tagMark.range.length, 2)

        XCTAssertTrue(try Self.invisibleMarks("\u{FEFF}leading BOM", language: .plain).isEmpty)

        let validFlag = "🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        XCTAssertTrue(try Self.invisibleMarks(validFlag, language: .plain).isEmpty)

        let unclosedTag = "🏴\u{E0041}"
        let unclosedMarks = try Self.invisibleMarks(unclosedTag, language: .plain)
        XCTAssertEqual(unclosedMarks.map(\.codePointLabel), ["U+E0041"])

        let vsAttack = "\u{FE00} a\u{FE00} 😀\u{E0100} 😀\u{FE0F}\u{FE0F}"
        let vsMarks = try Self.invisibleMarks(vsAttack, language: .plain)
        XCTAssertEqual(vsMarks.map(\.codePointLabel), ["U+FE00", "U+FE00", "U+E0100", "U+FE0F"])

        let validVS = "❤\u{FE0F} 🏳\u{FE0F} 1\u{FE0F}\u{20E3} 葛\u{E0100}"
        XCTAssertTrue(try Self.invisibleMarks(validVS, language: .plain).isEmpty)

        let asciiAdjacent = "admin\u{200D}user 1\u{200D}2 a\u{200C}b a\u{200E}b a\u{200F}b a\u{061C}b"
        let adjacentMarks = try Self.invisibleMarks(asciiAdjacent, language: .plain)
        XCTAssertEqual(
            adjacentMarks.map(\.codePointLabel),
            ["U+200D", "U+200D", "U+200C", "U+200E", "U+200F", "U+061C"])

        let codeSoftHyphen = "let is\u{00AD}Admin = true"
        let codeSoftMarks = try Self.invisibleMarks(codeSoftHyphen, language: .swift)
        XCTAssertEqual(codeSoftMarks.map(\.codePointLabel), ["U+00AD"])

        let naturalParagraphs: [(String, String)] = [
            ("persian", "من می\u{200C}خواهم این کتاب\u{200C}ها را بخوانم و خانه\u{200C}ها را ببینم."),
            ("hindi", "हिन्दी पाठ में क्\u{200D}ष और र\u{200D}\u{094D}य जैसे संयुक्त अक्षर होते हैं।"),
            ("malayalam", "അവന്\u{200D} വന്നു. അവള്\u{200D} പോയി. അവര്\u{200D} കണ്ടു."),
            ("hebrew", "שלום \u{200F}עולם\u{200F} (123)\u{200E} — בדיקת כיווניות בטקסט רגיל."),
            (
                "german",
                "Die Donau\u{00AD}dampf\u{00AD}schiff\u{00AD}fahrts\u{00AD}gesell\u{00AD}schaft baut Schiffe mit Geschwindig\u{00AD}keits\u{00AD}begren\u{00AD}zung."
            ),
            (
                "cjk-emoji",
                "日本語のテスト\t简体中文\n한국어 텍스트\r\n👨\u{200D}👩\u{200D}👧\u{200D}👦 👩\u{200D}💻 🏳\u{FE0F}\u{200D}🌈 ❤\u{FE0F}\u{200D}🔥 👩🏽\u{200D}🚀"
            ),
        ]
        for (label, text) in naturalParagraphs {
            let marks = try Self.invisibleMarks(text, language: .plain)
            XCTAssertTrue(marks.isEmpty, "\(label) unexpectedly flagged: \(marks.map(\.codePointLabel))")
        }

        let beyondCap = String(repeating: "a", count: PreviewTextSource.highlightBytes) + "\u{202E}"
        XCTAssertTrue(try PreviewTokenizer.tokens(beyondCap, language: .plain).isEmpty)
    }

    private static func invisibleMarks(_ text: String, language: PreviewLanguage) throws -> [PreviewInvisibleCharacter]
    {
        try PreviewTokenizer.tokens(text, language: language).compactMap { token in
            token.invisibleScalar.map { PreviewInvisibleCharacter(range: token.range, scalar: $0) }
        }
    }

    private static func tags(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.compactMap { Unicode.Scalar($0.value + 0xE0000) }))
    }

    func testTagFlagsVariationSelectorsAndContextRulesResistHiding() throws {
        let cancel = "\u{E007F}"
        let hiddenFlags = [
            "🏴" + Self.tags("Ignore previous") + cancel,
            "🏴" + Self.tags("ignore previous") + cancel,
            "🏴" + Self.tags("ignoreall") + cancel,
            "🏴" + Self.tags("gb") + cancel,
            "🏴" + Self.tags("1bab") + cancel,
            "🏴" + Self.tags("GBENG") + cancel,
        ]
        for text in hiddenFlags {
            let marks = try Self.invisibleMarks(text, language: .javascript)
            XCTAssertEqual(marks.count, text.unicodeScalars.count - 1, "every tag is flagged: \(marks.count)")
        }
        for subdivision in ["gbeng", "gbsct", "gbwls", "usca", "fr75"] {
            let flag = "🏴" + Self.tags(subdivision) + cancel
            XCTAssertTrue(try Self.invisibleMarks(flag, language: .javascript).isEmpty, subdivision)
        }

        let selectorAttacks = [
            "const user1\u{FE00} = 1; const user1 = 2;", "const _\u{FE00} = 1;", "var a = \"x\u{FE00}\";",
            "let b = 1\u{FE00};", "let c = x\u{FE0F};", "let d = #\u{FE01};",
        ]
        for text in selectorAttacks {
            XCTAssertEqual(try Self.invisibleMarks(text, language: .javascript).count, 1, text)
        }
        XCTAssertTrue(
            try Self.invisibleMarks("1\u{FE0F}\u{20E3} #\u{FE0F}\u{20E3} *\u{FE0E}", language: .plain).isEmpty)

        let codeAttacks = [
            "const кл\u{200D}юч = 1; const ключ = 2;", "let ρο\u{200C}λος = admin;",
            "if (role === \"адм\u{200D}ин\") grant();", "café\u{200D}s = 1", "naïve\u{200C}x = 1",
            "x = \u{200F}1 - 2; // שלום", "x = \"\u{200F}1 - 2\"; // שלום", "t(\"שלום\"); x = \"\u{200F}1 - 2\";",
            "if (isAdmin \u{200F}) {} // עברית", "let s = \"\u{200B}\";", "let 日本\u{200B}語 = 1",
        ]
        for text in codeAttacks {
            XCTAssertEqual(try Self.invisibleMarks(text, language: .javascript).count, 1, text)
        }
        XCTAssertTrue(
            try Self.invisibleMarks("const s = \"שלום\u{200F}עולם\";", language: .javascript).isEmpty,
            "a mark between right-to-left letters stays clean in code")
        XCTAssertEqual(try Self.invisibleMarks("pass\u{200B}word", language: .plain).count, 1)

        let naturalText = [
            "من می\u{200C}خواهم این کتاب\u{200C}ها را بخوانم.", "لا\u{200C} أعرف", "یہ کتاب\u{200C} ہے",
            "क्\u{200D}ष र\u{200D}्\u{200D}य हिन्दी", "मराठी: र्\u{200D}य आणि र\u{200D}्य", "বাংলা: র\u{200D}্যাব",
            "தமிழ்\u{200C} எழுத்து", "മലയാളം: ന്\u{200D} ര്\u{200D} ള്\u{200D}", "සිංහල: ශ්\u{200D}රී ක්\u{200D}ය",
            "שלום \u{200F}עולם\u{200F} (123)\u{200E} טקסט", "המחיר הוא 50 ש״ח (כולל מע״מ)\u{200F}.",
            "אני משתמש ב-C++\u{200E} כל יום", "Donau\u{AD}dampf\u{AD}schiff\u{AD}fahrt",
            "Megszentségtelenít\u{AD}het\u{AD}etlen\u{AD}ség", "ភាសា\u{200B}ខ្មែរ\u{200B}គឺ\u{200B}ជា",
            "ภาษา\u{200B}ไทย\u{200B}เป็น", "日本語\u{200B}の\u{200B}テキスト",
            "👨\u{200D}👩\u{200D}👧 🏳\u{FE0F}\u{200D}🌈 👍🏽 1\u{FE0F}\u{20E3} ©\u{FE0F}",
        ]
        for language in [PreviewLanguage.plain, .markdown] {
            for text in naturalText {
                let marks = try Self.invisibleMarks(text, language: language)
                XCTAssertTrue(marks.isEmpty, "\(language) \(text): \(marks.map(\.codePointLabel))")
            }
        }
    }

    @MainActor
    func testDiffAndInvisibleAttributesKeepCopyAndAvoidShapingBreakage() throws {
        let directory = try PreviewFixtures.directory(self)
        let patchURL = directory.appendingPathComponent("change.diff")
        let patchText = "--- a/x.swift\n+++ b/x.swift\n@@ -1 +1 @@\n-old\n+new\u{202E}\n"
        try Data(patchText.utf8).write(to: patchURL)
        let rendering = try PreviewTextRendering.make(
            source: try PreviewTextSource.read(patchURL),
            encoding: .automatic, rich: false, kind: .text, url: patchURL, restricted: false)
        let textView = PreviewTextView(usingTextLayoutManager: true)
        textView.show(rendering, font: .monospacedSystemFont(ofSize: 12, weight: .regular))

        XCTAssertEqual(textView.string, patchText)
        textView.setSelectedRange(NSRange(location: 0, length: (patchText as NSString).length))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), patchText)

        let invisibleTokens = rendering.tokens.filter { $0.kind == .invisible }
        XCTAssertEqual(invisibleTokens.count, 1)
        XCTAssertEqual(invisibleTokens[0].invisibleScalar, Unicode.Scalar(0x202E))

        let storage = try XCTUnwrap(textView.textStorage)
        let bidiOffset = (patchText as NSString).range(of: "\u{202E}").location
        XCTAssertNil(storage.attribute(.backgroundColor, at: bidiOffset, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.kern, at: bidiOffset, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.underlineStyle, at: bidiOffset, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.underlineColor, at: bidiOffset, effectiveRange: nil))

        let addedBg = PreviewTextView.diffAddedBackground
        let removedBg = PreviewTextView.diffRemovedBackground
        XCTAssertNotEqual(resolvedAlpha(of: addedBg, in: .aqua), resolvedAlpha(of: addedBg, in: .darkAqua))
        XCTAssertNotEqual(resolvedAlpha(of: removedBg, in: .aqua), resolvedAlpha(of: removedBg, in: .darkAqua))
        XCTAssertGreaterThan(
            PreviewTextView.diffBackgroundColor(added: true, dark: false, highContrast: true).alphaComponent,
            PreviewTextView.diffBackgroundColor(added: true, dark: false, highContrast: false).alphaComponent)
        XCTAssertGreaterThan(
            PreviewTextView.diffBackgroundColor(added: false, dark: true, highContrast: true).alphaComponent,
            PreviewTextView.diffBackgroundColor(added: false, dark: true, highContrast: false).alphaComponent)
    }

    func testHeredocAndPathologicalInputsScaleLinearly() throws {
        let heredocLanguages: [(PreviewLanguage, String)] = [
            (.shell, ""),
            (.ruby, ""),
            (.php, "<?php "),
            (.perl, ""),
            (.hcl, ""),
        ]
        for (language, prefix) in heredocLanguages {
            let small = prefix + String(repeating: "x<<A ", count: 3_000)
            let large = prefix + String(repeating: "x<<A ", count: 12_000)
            let smallTime = try minimumThreadTime { _ = try PreviewTokenizer.tokens(small, language: language) }
            let largeTime = try minimumThreadTime { _ = try PreviewTokenizer.tokens(large, language: language) }
            let ratio = largeTime / max(smallTime, 1e-6)
            XCTAssertLessThan(
                ratio, Self.maximumLinearRatio,
                "\(language) heredoc scaled superlinearly: \(smallTime)s -> \(largeTime)s (ratio \(ratio))")
        }

        let scalingCases: [(String, PreviewLanguage, (Int) -> String)] = [
            (
                "swift", .swift,
                { String(repeating: "struct Box { let n: Int = 42 // note\n  let s = \"hi\"\n}\n", count: $0) }
            ),
            (
                "minified-js", .javascript,
                {
                    String(
                        repeating:
                            "function a(b,c){var d=\"str\\\"ing\",e=12345.67,f=true;return b?c+d.length+e:(f&&null)||'x';}",
                        count: $0)
                }
            ),
            ("only-dquotes", .javascript, { String(repeating: "\"", count: $0 * 40) }),
            ("only-lt", .markup, { String(repeating: "<", count: $0 * 40) }),
            (
                "nested-comments", .rust,
                { String(repeating: "/*", count: $0 * 20) + String(repeating: "*/", count: $0 * 20) }
            ),
        ]
        for (name, language, builder) in scalingCases {
            let small = builder(400)
            let large = builder(1_600)
            let smallTime = try minimumThreadTime { _ = try PreviewTokenizer.tokens(small, language: language) }
            let largeTime = try minimumThreadTime { _ = try PreviewTokenizer.tokens(large, language: language) }
            let ratio = largeTime / max(smallTime, 1e-6)
            XCTAssertLessThan(
                ratio, Self.maximumLinearRatio,
                "\(name) scaled superlinearly: \(smallTime)s -> \(largeTime)s (ratio \(ratio))")
        }

        let large512Cases: [(String, PreviewLanguage, String)] = [
            ("heredoc-512k", .shell, Self.make512KiB("x<<A ")),
            ("swift-512k", .swift, Self.make512KiB("struct Box { let n: Int = 42 // note\n  let s = \"hi\"\n}\n")),
            ("unclosed-nested-512k", .swift, String(repeating: "/*", count: 256 * 1024)),
        ]
        for (name, language, input) in large512Cases {
            let tokens = try PreviewTokenizer.tokens(input, language: language)
            if name == "heredoc-512k" {
                XCTAssertTrue(tokens.isEmpty, name)
            } else {
                XCTAssertFalse(tokens.isEmpty, name)
            }
        }
    }

    private func assertNoSurrogateSplits(
        in text: String, tokens: [PreviewToken], file: StaticString = #filePath, line: UInt = #line
    ) {
        let units = Array(text.utf16)
        for token in tokens {
            let start = token.range.location
            let end = token.range.location + token.range.length
            XCTAssertGreaterThanOrEqual(start, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(end, units.count, file: file, line: line)
            if start < units.count {
                XCTAssertFalse(
                    UTF16.isTrailSurrogate(units[start]),
                    "Token starts on trail surrogate at \(start)", file: file, line: line)
            }
            if end > 0, end < units.count {
                XCTAssertFalse(
                    UTF16.isLeadSurrogate(units[end - 1]) && UTF16.isTrailSurrogate(units[end]),
                    "Token ends inside surrogate pair at \(end)", file: file, line: line)
            }
        }
    }

    // Linear stays near 4; quadratic reaches 16.
    private static let maximumLinearRatio = 11.0
    private static let timingRuns = 5
    private static let nanosecondsPerSecond = 1e9

    // Thread CPU time ignores other busy processes.
    private func minimumThreadTime(_ body: () throws -> Void) throws -> Double {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<Self.timingRuns {
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            try body()
            let elapsed = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / Self.nanosecondsPerSecond
            best = min(best, elapsed)
        }
        return best
    }

    private func resolvedAlpha(of color: NSColor, in appearanceName: NSAppearance.Name) -> CGFloat {
        guard let appearance = NSAppearance(named: appearanceName) else { return 0 }
        var alpha: CGFloat = 0
        appearance.performAsCurrentDrawingAppearance {
            alpha = color.usingColorSpace(.sRGB)?.alphaComponent ?? 0
        }
        return alpha
    }

    private static func make512KiB(_ chunk: String) -> String {
        let target = PreviewTextSource.highlightBytes
        let reps = (target / chunk.utf8.count) + 1
        let repeated = String(repeating: chunk, count: reps)
        return String(decoding: repeated.utf8.prefix(target), as: UTF8.self)
    }
}
