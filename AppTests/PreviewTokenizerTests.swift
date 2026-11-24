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
                "# hash\n// slash\nfunction f(): string { $return = 'ok'; return $return; }",
                required: [
                    ("# hash", .comment), ("// slash", .comment), ("function", .keyword),
                    ("string", .type), ("'ok'", .string),
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

    func testUnterminatedConstructsDoNotPaintLargeFiles() throws {
        let filler = String(repeating: "let ok = 42\n", count: 400)

        let strayQuote = "let broken = \"unterminated\n" + filler
        let quoteTokens = try PreviewTokenizer.tokens(strayQuote, language: .swift)
        XCTAssertGreaterThan(quoteTokens.filter { $0.kind == .keyword }.count, 350)

        let unclosedComment = "/* unterminated comment\n" + filler
        let commentTokens = try PreviewTokenizer.tokens(unclosedComment, language: .swift)
        XCTAssertGreaterThan(commentTokens.filter { $0.kind == .keyword }.count, 100)

        let unclosedTriple = "let s = \"\"\"\n" + filler
        let tripleTokens = try PreviewTokenizer.tokens(unclosedTriple, language: .swift)
        XCTAssertGreaterThan(tripleTokens.filter { $0.kind == .keyword }.count, 100)
    }

    func testInvisibleAndBidiOverrideCharactersAreMarkedWithoutFlaggingEmojiZWJ() throws {
        let trojan =
            "let ok = true // \u{202E} } if (isAdmin) {\u{2066} /* x */\u{2069}\n"
            + "let z = \"a\u{200B}\u{200C}\u{200D}b\u{2060}\u{FEFF}\u{061C}\u{200E}\u{200F}\u{0007}\u{0085}\"\n"
        let tokens = try PreviewTokenizer.tokens(trojan, language: .swift)
        let invisible = tokens.filter { $0.kind == .invisible }
        let source = trojan as NSString
        XCTAssertEqual(
            invisible.map { source.substring(with: $0.range) },
            [
                "\u{202E}", "\u{2066}", "\u{2069}", "\u{200B}", "\u{200C}", "\u{200D}",
                "\u{2060}", "\u{FEFF}", "\u{061C}", "\u{200E}", "\u{200F}", "\u{0007}", "\u{0085}",
            ])

        let plainTrojan = "plain\u{202E}text\u{200D}here"
        let plainTokens = try PreviewTokenizer.tokens(plainTrojan, language: .plain)
        XCTAssertEqual(plainTokens.map(\.kind), [.invisible, .invisible])

        let cjkText = "日本語のテスト\t简体中文\n한국어 텍스트\r\n"
        XCTAssertTrue(try PreviewTokenizer.tokens(cjkText, language: .plain).isEmpty)

        let emojiSequences =
            "let family = \"👨\u{200D}👩\u{200D}👧\u{200D}👦 👩\u{200D}💻 🏳\u{FE0F}\u{200D}🌈 ❤\u{FE0F}\u{200D}🔥 👩🏽\u{200D}🚀\""
        let emojiTokens = try PreviewTokenizer.tokens(emojiSequences, language: .swift)
        XCTAssertTrue(emojiTokens.filter { $0.kind == .invisible }.isEmpty)

        let digitZWJ = "1\u{200D}2"
        XCTAssertEqual(try PreviewTokenizer.tokens(digitZWJ, language: .plain).map(\.kind), [.invisible])

        let beyondCap = String(repeating: "a", count: PreviewTextSource.highlightBytes) + "\u{202E}"
        XCTAssertTrue(try PreviewTokenizer.tokens(beyondCap, language: .plain).isEmpty)
    }

    @MainActor
    func testDiffAndInvisibleAttributesRenderWithAppearanceAwareTints() throws {
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

        let storage = try XCTUnwrap(textView.textStorage)
        let addedOffset = (patchText as NSString).range(of: "+new").location
        let removedOffset = (patchText as NSString).range(of: "-old").location
        let bidiOffset = (patchText as NSString).range(of: "\u{202E}").location

        let addedBg = try XCTUnwrap(
            storage.attribute(.backgroundColor, at: addedOffset, effectiveRange: nil) as? NSColor)
        let removedBg = try XCTUnwrap(
            storage.attribute(.backgroundColor, at: removedOffset, effectiveRange: nil) as? NSColor)
        let bidiUnderline = storage.attribute(.underlineStyle, at: bidiOffset, effectiveRange: nil) as? Int
        let bidiToolTip = storage.attribute(.toolTip, at: bidiOffset, effectiveRange: nil) as? String
        XCTAssertEqual(bidiUnderline, NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(bidiToolTip, "U+202E")

        XCTAssertNotEqual(resolvedAlpha(of: addedBg, in: .aqua), resolvedAlpha(of: addedBg, in: .darkAqua))
        XCTAssertNotEqual(resolvedAlpha(of: removedBg, in: .aqua), resolvedAlpha(of: removedBg, in: .darkAqua))
        XCTAssertGreaterThan(
            PreviewTextView.diffBackgroundColor(added: true, dark: false, highContrast: true).alphaComponent,
            PreviewTextView.diffBackgroundColor(added: true, dark: false, highContrast: false).alphaComponent)
        XCTAssertGreaterThan(
            PreviewTextView.diffBackgroundColor(added: false, dark: true, highContrast: true).alphaComponent,
            PreviewTextView.diffBackgroundColor(added: false, dark: true, highContrast: false).alphaComponent)
    }

    func testPathologicalAndLarge512KiBInputsStayLinearAndWithinBound() throws {
        let budgetSeconds = 0.5
        let cases: [(String, PreviewLanguage, String)] = [
            ("swift-512k", .swift, Self.make512KiB("struct Box { let n: Int = 42 // note\n  let s = \"hi\"\n}\n")),
            ("rust-512k", .rust, Self.make512KiB("fn f<'a>(x: &'a str) -> usize { /* a */ x.len() + 1 }\n")),
            ("python-512k", .python, Self.make512KiB("# note\ndef f(x: int):\n    return r\"ok\" + str(x)\n")),
            ("sql-512k", .sql, Self.make512KiB("-- q\nSELECT count(*) FROM items WHERE name = 'it''s' AND id = 1;\n")),
            ("markup-512k", .markup, Self.make512KiB("<div class=\"c\">don't</div><script>const x = 1;</script>\n")),
            ("single-line-512k", .swift, Self.make512KiB("let alpha = 123 + beta * \"text\" + gamma; ")),
            ("only-dquotes-512k", .javascript, String(repeating: "\"", count: 512 * 1024)),
            ("only-squotes-512k", .javascript, String(repeating: "'", count: 512 * 1024)),
            (
                "nested-comments-512k", .rust,
                String(repeating: "/*", count: 128 * 1024) + String(repeating: "*/", count: 128 * 1024)
            ),
            ("unclosed-nested-512k", .swift, String(repeating: "/*", count: 256 * 1024)),
            (
                "minified-js-512k", .javascript,
                Self.make512KiB(
                    "function a(b,c){var d=\"str\\\"ing\",e=12345.67,f=true;return b?c+d.length+e:(f&&null)||'x';}")
            ),
        ]
        for (name, language, input) in cases {
            let start = CFAbsoluteTimeGetCurrent()
            let tokens = try PreviewTokenizer.tokens(input, language: language)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            XCTAssertFalse(tokens.isEmpty, name)
            XCTAssertLessThan(elapsed, budgetSeconds, "\(name) took \(elapsed)s")
        }
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
