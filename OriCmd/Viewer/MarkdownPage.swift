import Foundation

/// Markdown made into a page: the body markdown-it wrote (in the helper service),
/// styled after GitHub's, light or dark as the system is, code colored as
/// highlight.js's GitHub theme does.
nonisolated enum MarkdownPage {
    static func html(body: String, title: String) -> String {
        let title = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8"><title>\(title)</title><style>\(style)</style></head>
            <body><article>
            \(body)
            </article></body></html>
            """
    }

    private static let style = """
        :root { color-scheme: light dark; --text: #1f2328; --muted: #59636e; --line: #d1d9e0; --soft: #f6f8fa;
                --link: #0969da; --back: #ffffff; --code: rgba(129, 139, 152, 0.15); }
        @media (prefers-color-scheme: dark) {
          :root { --text: #e6edf3; --muted: #9198a1; --line: #3d444d; --soft: #151b23; --link: #4493f8;
                  --back: #0d1117; --code: rgba(101, 108, 118, 0.2); } }
        body { margin: 0; background: var(--back); color: var(--text);
               font: 15px/1.6 -apple-system, "Helvetica Neue", sans-serif; }
        article { max-width: 880px; margin: 0 auto; padding: 24px 32px 48px; overflow-wrap: break-word; }
        h1, h2, h3, h4, h5, h6 { margin: 24px 0 16px; line-height: 1.25; font-weight: 600; }
        h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; } h6 { color: var(--muted); }
        h1, h2 { padding-bottom: 0.3em; border-bottom: 1px solid var(--line); }
        p, ul, ol, blockquote, pre, table, dl { margin: 0 0 16px; }
        a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
        code, pre, kbd { font: 12.5px/1.45 ui-monospace, "SF Mono", Menlo, monospace; }
        code { padding: 0.2em 0.4em; border-radius: 6px; background: var(--code); }
        pre { padding: 14px 16px; overflow: auto; border-radius: 6px; background: var(--soft); }
        pre code { padding: 0; background: none; }
        kbd { padding: 2px 5px; border: 1px solid var(--line); border-radius: 5px; background: var(--soft); }
        blockquote { margin-left: 0; padding: 0 1em; color: var(--muted); border-left: 0.25em solid var(--line); }
        hr { height: 0.25em; margin: 24px 0; border: 0; background: var(--line); }
        table { border-collapse: collapse; display: block; overflow: auto; }
        th, td { padding: 6px 13px; border: 1px solid var(--line); } th { font-weight: 600; }
        tr:nth-child(2n) { background: var(--soft); }
        img { max-width: 100%; }
        ul, ol { padding-left: 2em; } li + li { margin-top: 0.25em; } li.task { list-style: none; margin-left: -1.3em; }
        .hljs-doctag, .hljs-keyword, .hljs-meta .hljs-keyword, .hljs-template-tag, .hljs-template-variable,
        .hljs-type, .hljs-variable.language_ { color: #cf222e; }
        .hljs-title, .hljs-title.class_, .hljs-title.class_.inherited__, .hljs-title.function_ { color: #8250df; }
        .hljs-attr, .hljs-attribute, .hljs-literal, .hljs-meta, .hljs-number, .hljs-operator, .hljs-variable,
        .hljs-selector-attr, .hljs-selector-class, .hljs-selector-id { color: #0550ae; }
        .hljs-regexp, .hljs-string, .hljs-meta .hljs-string { color: #0a3069; }
        .hljs-built_in, .hljs-symbol { color: #953800; }
        .hljs-comment, .hljs-code, .hljs-formula { color: #6e7781; }
        .hljs-name, .hljs-quote, .hljs-selector-tag, .hljs-selector-pseudo { color: #116329; }
        .hljs-section { color: #0550ae; font-weight: bold; } .hljs-bullet { color: #953800; }
        .hljs-emphasis { font-style: italic; } .hljs-strong { font-weight: bold; }
        .hljs-addition { color: #116329; background: #f0fff4; } .hljs-deletion { color: #82071e; background: #ffebe9; }
        @media (prefers-color-scheme: dark) {
          .hljs-doctag, .hljs-keyword, .hljs-meta .hljs-keyword, .hljs-template-tag, .hljs-template-variable,
          .hljs-type, .hljs-variable.language_ { color: #ff7b72; }
          .hljs-title, .hljs-title.class_, .hljs-title.class_.inherited__, .hljs-title.function_ { color: #d2a8ff; }
          .hljs-attr, .hljs-attribute, .hljs-literal, .hljs-meta, .hljs-number, .hljs-operator, .hljs-variable,
          .hljs-selector-attr, .hljs-selector-class, .hljs-selector-id { color: #79c0ff; }
          .hljs-regexp, .hljs-string, .hljs-meta .hljs-string { color: #a5d6ff; }
          .hljs-built_in, .hljs-symbol { color: #ffa657; }
          .hljs-comment, .hljs-code, .hljs-formula { color: #8b949e; }
          .hljs-name, .hljs-quote, .hljs-selector-tag, .hljs-selector-pseudo { color: #7ee787; }
          .hljs-section { color: #1f6feb; } .hljs-bullet { color: #f2cc60; }
          .hljs-addition { color: #aff5b4; background: #033a16; } .hljs-deletion { color: #ffdcd7; background: #67060c; } }
        """
}
