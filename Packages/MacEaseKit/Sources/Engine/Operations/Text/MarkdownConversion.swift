import Foundation
import cmark_gfm
import cmark_gfm_extensions

enum MarkdownConversion {
    /// Pathological nesting allocates ~250× the input.
    static let maximumBytes = 1024 * 1024
    private static let extensions = ["table", "strikethrough", "autolink", "tagfilter", "tasklist"]
    // Safe mode drops raw HTML, unsafe links.
    private static let options = CMARK_OPT_DEFAULT | CMARK_OPT_FOOTNOTES
    static func html(_ markdown: String, title: String) throws -> String {
        guard markdown.utf8.count <= maximumBytes else {
            throw EngineError.invalidInput(.tooLarge(limitBytes: Int64(maximumBytes)))
        }
        let body = try render(markdown)
        let html = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <title>\(XMLConversion.escaped(title))</title>
            </head>
            <body>
            \(body)</body>
            </html>

            """
        guard html.utf8.count <= ConversionInput.maximumBytes else {
            throw EngineError.invalidInput(.tooLarge(limitBytes: Int64(ConversionInput.maximumBytes)))
        }
        return html
    }

    private static func render(_ markdown: String) throws -> String {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(options) else { throw failure("parser could not start") }
        defer { cmark_parser_free(parser) }
        for name in extensions {
            guard let syntax = cmark_find_syntax_extension(name),
                cmark_parser_attach_syntax_extension(parser, syntax) != 0
            else { throw failure("extension \(name) is unavailable") }
        }
        var source = markdown
        source.withUTF8 { bytes in
            bytes.withMemoryRebound(to: CChar.self) { cmark_parser_feed(parser, $0.baseAddress, $0.count) }
        }
        guard let document = cmark_parser_finish(parser) else { throw failure("document could not be parsed") }
        defer { cmark_node_free(document) }
        guard let rendered = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser)) else {
            throw failure("HTML could not be rendered")
        }
        defer { free(rendered) }
        return String(cString: rendered)
    }

    private static func failure(_ reason: String) -> EngineError {
        .encodeFailed("Markdown \(reason)")
    }
}
