import Foundation
import JavaScriptCore

/// Runs highlight.js for the Lister. Once highlight.js is loaded, and before any
/// text comes in, this process forbids itself everything (see `lockDown`): code run
/// through a flaw in the JavaScript engine can only answer OriCmd, which checks the
/// answer and kills this process when a highlighting takes too long.
final class HighlighterService: NSObject, NSXPCListenerDelegate, Highlighting, @unchecked Sendable {
    /// highlight.js is used from one queue at a time.
    private let queue = DispatchQueue(label: "ru.themmag.OriCmd.Highlighter")
    private var context: JSContext?
    private var isLockedDown = false

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
        // Nothing is highlighted unless the process could lock itself down.
        guard let context = loadedContext(), isLockedDown || lockDown(context) else { return (nil, nil) }
        #if DEBUG
        // For the regression check that a highlighting which never ends is killed.
        if languages == ["oricmd-test-hang"] {
            context.evaluateScript("for (;;) {}")
        }
        // For the regression check that this process cannot read files: the text is a
        // path; one character colored if the file could be read, two if it could not.
        if languages == ["oricmd-test-files"] {
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let ranges: [UInt32] = FileManager.default.contents(atPath: path) != nil ? [0, 1, 0] : [0, 1, 0, 1, 1, 1]
            return (ranges.withUnsafeBytes { Data($0) }, ["string", "number"])
        }
        // For the regression check that this process cannot reach other services (the
        // pasteboard, LaunchServices…): the text is a service name, colored as above.
        if languages == ["oricmd-test-lookup"] {
            typealias LookUp = @convention(c) (mach_port_t, UnsafePointer<CChar>, UnsafeMutablePointer<mach_port_t>)
                -> kern_return_t
            var bootstrap: mach_port_t = 0
            var port: mach_port_t = 0
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let reached = task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bootstrap) == KERN_SUCCESS
                && dlsym(UnsafeMutableRawPointer(bitPattern: -2), "bootstrap_look_up").map {
                    unsafeBitCast($0, to: LookUp.self)(bootstrap, name, &port) == KERN_SUCCESS
                } == true
            let ranges: [UInt32] = reached ? [0, 1, 0] : [0, 1, 0, 1, 1, 1]
            return (ranges.withUnsafeBytes { Data($0) }, ["string", "number"])
        }
        // For the regression check that OriCmd refuses ranges that overlap: the first
        // two characters, then the second and third.
        if languages == ["oricmd-test-overlap"] {
            let ranges: [UInt32] = [0, 2, 0, 1, 2, 1]
            return (ranges.withUnsafeBytes { Data($0) }, ["string", "number"])
        }
        // For the regression check that a service which died and was started again is
        // still killed when it hangs.
        if languages == ["oricmd-test-exit"] {
            exit(0)
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

    /// Forbids this process everything — files (system ones too), the network, the
    /// pasteboard, opening URLs, reaching any other service — once highlight.js is
    /// loaded; stricter than App Sandbox, which leaves the pasteboard and
    /// LaunchServices open (and cannot be combined with this). First everything the
    /// JavaScript engine loads only when needed (ICU data for case, normalization,
    /// Unicode classes) is used once. Nothing can lift the rules afterwards.
    private func lockDown(_ context: JSContext) -> Bool {
        context.evaluateScript("""
            "Привет ÄÖÜ ß İ".toLowerCase(); "straße ǅ".toUpperCase(); "é".normalize("NFD");
            /\\p{L}+/u.test("Ωμέγα"); /[а-я]+/iu.test("ПРИВЕТ"); "б".localeCompare("а");
            oricmdHighlight("SELECT Имя FROM Таблица -- Коммент", ["sql"]);
            oricmdHighlight("<p class='x'>Текст</p><script>let a = `b${1}`</script>", ["xml"]);
            oricmdHighlight("func f() -> String { \"Привет\" }", ["swift"]);
            """)
        typealias SandboxInit = @convention(c) (
            UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) -> Int32
        // sandbox_init is deprecated but kept: browsers lock their helpers down with it.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_init") else { return false }
        let sandboxInit = unsafeBitCast(symbol, to: SandboxInit.self)
        var error: UnsafeMutablePointer<CChar>?
        let status = sandboxInit("(version 1) (deny default) (allow sysctl-read)", 0, &error)
        if let error { free(error) }
        isLockedDown = status == 0
        return isLockedDown
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
