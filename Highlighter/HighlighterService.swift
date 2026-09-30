import Foundation
import JavaScriptCore

/// Runs highlight.js for the Lister. This process is sandboxed without any access
/// (no files, no network): a text made to attack the JavaScript engine finds
/// nothing to reach, and OriCmd kills the process when a highlighting takes too long.
final class HighlighterService: NSObject, NSXPCListenerDelegate, Highlighting, @unchecked Sendable {
    /// highlight.js is used from one queue at a time.
    private let queue = DispatchQueue(label: "ru.themmag.OriCmd.Highlighter")
    private var context: JSContext?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = .highlighting
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func highlight(_ text: String, languages: [String], reply: @escaping @Sendable (Data?, [String]?) -> Void) {
        queue.async { [self] in
            let (ranges, scopes) = highlighted(text, languages: languages)
            reply(ranges, scopes)
        }
    }

    func processIdentifier(reply: @escaping @Sendable (Int32) -> Void) {
        reply(getpid())
    }

    private func highlighted(_ text: String, languages: [String]) -> (Data?, [String]?) {
        guard let context = loadedContext() else { return (nil, nil) }
        #if DEBUG
        // For the regression check that a highlighting which never ends is killed.
        if languages == ["oricmd-test-hang"] {
            context.evaluateScript("for (;;) {}")
        }
        // For the regression check that the sandbox keeps this process from files:
        // the text is a path, its first character colored only if that file could be read.
        if languages == ["oricmd-test-files"] {
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let range: [UInt32] = FileManager.default.contents(atPath: path) != nil ? [0, 1, 0] : []
            return (range.withUnsafeBytes { Data($0) }, ["string"])
        }
        #endif
        guard let function = context.objectForKeyedSubscript("oricmdHighlight"),
              let result = function.call(withArguments: [text, languages]), result.isObject,
              let scopes = result.forProperty("scopes")?.toArray() as? [String],
              let ranges = result.forProperty("ranges") else { return (nil, nil) }
        // The typed array's bytes as they are, without a JavaScript number per value.
        let contextRef = context.jsGlobalContextRef
        var exception: JSValueRef?
        guard let object = JSValueToObject(contextRef, ranges.jsValueRef, &exception),
              let bytes = JSObjectGetTypedArrayBytesPtr(contextRef, object, &exception) else { return (nil, nil) }
        let count = JSObjectGetTypedArrayByteLength(contextRef, object, &exception)
        return (Data(bytes: bytes, count: count), scopes)
    }

    private func loadedContext() -> JSContext? {
        if let context { return context }
        guard let context = JSContext() else { return nil }
        for name in ["highlight.min", "bridge"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
                  let script = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            context.evaluateScript(script, withSourceURL: url)
        }
        self.context = context
        return context
    }
}
