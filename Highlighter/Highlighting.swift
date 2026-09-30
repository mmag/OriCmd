import Foundation

/// What the OriCmdHighlighter service offers. The same protocol is declared in
/// OriCmd/Viewer/SyntaxHighlighter.swift: keep both alike.
@objc(ORCHighlighting) protocol Highlighting {
    /// Highlights `text` in the first of `languages` (highlight.js names or aliases)
    /// the service knows. Replies with the ranges — (start, length, scope index)
    /// UInt32 triples in UTF-16 units, outer ranges first — and the scope names they
    /// refer to, one a line (plain data: nothing for the other side to decode into
    /// objects), or nils when no language fits.
    func highlight(_ text: String, languages: [String], reply: @escaping @Sendable (Data?, Data?) -> Void)

    /// This process, for OriCmd to end it when a highlighting hangs (answered at
    /// once, also while highlight.js is busy).
    func processIdentifier(reply: @escaping @Sendable (Int32) -> Void)

    /// Every language name and alias highlight.js knows, one a line: texts in no
    /// such language are not sent at all.
    func languageNames(reply: @escaping @Sendable (Data?) -> Void)

    /// The tables of `text` in `format` ("spreadsheetml", "html", "csv", "tsv") for
    /// the Lister's table view, as plain data (see TableBuilder); nil when there are none.
    func table(_ text: String, format: String, reply: @escaping @Sendable (Data?) -> Void)

    /// The book in `data` ("fb2", "fb2.zip", "epub", "mobi") for the Lister's book view, as
    /// plain data (see BookBuilder); nil when it cannot be read.
    func book(_ data: Data, format: String, reply: @escaping @Sendable (Data?) -> Void)

    /// `text` (Markdown) as the body of an HTML page, UTF-8 (markdown-it); nil when it
    /// cannot be made.
    func markdown(_ text: String, reply: @escaping @Sendable (Data?) -> Void)

    /// `text` laid out for reading, UTF-8: "json", "xml" (CodeFormatter), "js", "css",
    /// "html" (js-beautify), "ts", "tsx" (prettier); nil when it cannot be.
    func format(_ text: String, language: String, reply: @escaping @Sendable (Data?) -> Void)
}

extension NSXPCInterface {
    static var highlighting: NSXPCInterface {
        let interface = NSXPCInterface(with: Highlighting.self)
        let strings = NSSet(array: [NSArray.self, NSString.self]) as! Set<AnyHashable>
        let selector = #selector(Highlighting.highlight(_:languages:reply:))
        interface.setClasses(strings, for: selector, argumentIndex: 1, ofReply: false)
        return interface
    }
}
