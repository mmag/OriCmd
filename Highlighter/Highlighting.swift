import Foundation

/// What the OriCmdHighlighter service offers. The same protocol is declared in
/// OriCmd/Viewer/SyntaxHighlighter.swift: keep both alike.
@objc(ORCHighlighting) protocol Highlighting {
    /// Highlights `text` in the first of `languages` (highlight.js names or aliases)
    /// the service knows. Replies with the ranges — (start, length, scope index)
    /// UInt32 triples in UTF-16 units, outer ranges first — and the scopes they
    /// name, or nils when no language fits.
    func highlight(_ text: String, languages: [String], reply: @escaping @Sendable (Data?, [String]?) -> Void)

    /// This process, for OriCmd to end it when a highlighting hangs (answered at
    /// once, also while highlight.js is busy).
    func processIdentifier(reply: @escaping @Sendable (Int32) -> Void)
}

extension NSXPCInterface {
    static var highlighting: NSXPCInterface {
        let interface = NSXPCInterface(with: Highlighting.self)
        let strings = NSSet(array: [NSArray.self, NSString.self]) as! Set<AnyHashable>
        let selector = #selector(Highlighting.highlight(_:languages:reply:))
        interface.setClasses(strings, for: selector, argumentIndex: 1, ofReply: false)
        interface.setClasses(strings, for: selector, argumentIndex: 1, ofReply: true)
        return interface
    }
}
