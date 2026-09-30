import Compression
import Foundation
import ImageIO
import JavaScriptCore

/// Runs highlight.js, markdown-it, js-beautify and prettier, formats JSON and XML
/// (CodeFormatter), reads tables (TableParser), books (BookParser) and 3D models
/// (MeshParser) for the Lister. When OriCmd connects, the scripts are loaded and
/// this process forbids itself everything (see `lockDown`) before it reads any
/// message: code run through a flaw in the JavaScript engine or a parser can only
/// answer OriCmd, which checks the answer and kills this process when its work
/// takes too long.
final class HighlighterService: NSObject, NSXPCListenerDelegate, Highlighting, @unchecked Sendable {
    /// highlight.js is used from one queue at a time.
    private let queue = DispatchQueue(label: "ru.themmag.OriCmd.Highlighter")
    private var context: JSContext?
    /// Set only once `lockDown` succeeded; nothing is highlighted before.
    private var isLockedDown = false

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Locked down before the connection's first message is even decoded.
        queue.sync {
            if !isLockedDown, let context = loadedContext() {
                isLockedDown = lockDown(context)
            }
        }
        connection.exportedInterface = .highlighting
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func highlight(_ text: String, languages: [String], reply: @escaping @Sendable (Data?, Data?) -> Void) {
        queue.async { [self] in
            let (ranges, scopes) = highlighted(text, languages: languages)
            reply(ranges, scopes)
        }
    }

    func processIdentifier(reply: @escaping @Sendable (Int32) -> Void) {
        reply(getpid())
    }

    func languageNames(reply: @escaping @Sendable (Data?) -> Void) {
        queue.async { [self] in
            guard isLockedDown, let names = context?.evaluateScript("oricmdLanguageNames()")?.toString() else {
                return reply(nil)
            }
            reply(Data(names.utf8))
        }
    }

    func table(_ text: String, format: String, reply: @escaping @Sendable (Data?) -> Void) {
        queue.async { [self] in
            guard isLockedDown else { return reply(nil) }
            reply(TableParser.parse(text, format: format))
        }
    }

    func book(_ data: Data, format: String, reply: @escaping @Sendable (Data?) -> Void) {
        queue.async { [self] in
            guard isLockedDown else { return reply(nil) }
            reply(BookParser.parse(data, format: format))
        }
    }

    func markdown(_ text: String, reply: @escaping @Sendable (Data?) -> Void) {
        queue.async { [self] in
            guard isLockedDown, let result = context?.objectForKeyedSubscript("oricmdMarkdown")?.call(withArguments: [text]),
                  result.isString, let html = result.toString() else { return reply(nil) }
            reply(Data(html.utf8))
        }
    }

    func format(_ text: String, language: String, reply: @escaping @Sendable (Data?) -> Void) {
        queue.async { [self] in
            guard isLockedDown else { return reply(nil) }
            switch language {
            case "json":
                reply(CodeFormatter.json(text).map { Data($0.utf8) })
            case "xml":
                reply(CodeFormatter.xml(text).map { Data($0.utf8) })
            case "js", "css", "html", "ts", "tsx":
                guard var result = context?.objectForKeyedSubscript("oricmdFormat")?.call(withArguments: [text, language])
                else { return reply(nil) }
                if language.hasPrefix("ts") {
                    // prettier's promise, settled now that the call has returned.
                    guard let pending = context?.objectForKeyedSubscript("oricmdPendingResult")?.call(withArguments: [])
                    else { return reply(nil) }
                    result = pending
                }
                guard result.isString, let formatted = result.toString() else { return reply(nil) }
                reply(Data(formatted.utf8))
            default:
                reply(nil)
            }
        }
    }

    func mesh(_ data: Data, format: String, reply: @escaping @Sendable (Data?) -> Void) {
        queue.async { [self] in
            guard isLockedDown else { return reply(nil) }
            reply(MeshParser.parse(data, format: format))
        }
    }

    private func highlighted(_ text: String, languages: [String]) -> (Data?, Data?) {
        guard isLockedDown, let context else { return (nil, nil) }
        #if DEBUG
        if let test = testReply(text, languages: languages, context: context) { return test }
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
        // Scope names one a line (they never hold a line break).
        return (Data(bytes: bytes, count: count), Data(scopes.joined(separator: "\n").utf8))
    }

    /// Forbids this process everything — files (system ones too), the network, the
    /// pasteboard, opening URLs, looking up any other service — once highlight.js is
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
            oricmdHighlight("func f() -> String { \\"Привет\\" }", ["swift"]);
            oricmdLanguageNames();
            oricmdMarkdown("---\ntitle: Т\n---\n# Заголовок\n\n| a | b |\n|:--|--:|\n| *к* | `к` |\n\n" +
                "```swift\nlet a = \"б\"\n```\n\n- [x] готово\n- [ ] нет\n\n> <b>HTML</b> &amp; https://пример.рф " +
                "www.example.com ~~x~~ [с](http://a.b \"t\") ![к](a.png)\n\n1. один\n\n    отступ\n");
            oricmdFormat("function f(a){return {b:[1,2],c:'д',d:`${a}`}} class X extends Y{#p=1}", "js");
            oricmdFormat("@media (x){a>b:hover{color:red;content:'ж'}}", "css");
            oricmdFormat("<!DOCTYPE html><div><p>Т<br></p><script>let a=1</script><style>a{b:c}</style></div>", "html");
            oricmdFormat("interface U<T>{n:string;a?:number}export default class C implements U<'ж'>{#p=1;" +
                "constructor(private readonly x:number){} get y():`t${string}`{return `t${this.x}` as const}}" +
                "enum E{A=1} declare module 'm'{} type F=(a:number)=>void;", "ts");
            oricmdPendingResult();
            oricmdFormat("const e=<div className='a'>{b ? <B/> : null}</div>", "tsx");
            oricmdPendingResult();
            """)
        _ = MeshParser.parse(Data("solid a\n facet normal 0 0 1\n outer loop\n vertex 0 0 0\n vertex 1 0 0\n vertex 0 1.5e0 0\n endloop\n endfacet\nendsolid a\n".utf8), format: "stl")
        _ = CodeFormatter.json(#"{"a": [1, 2.5e3, "ж\"", {}], // c\n "b": {"c": null}}"#)
        _ = CodeFormatter.xml(#"<?xml version="1.0"?><!DOCTYPE a [<!ENTITY b "c">]><a x="1>"><!-- к --><b>т</b><c/><![CDATA[<>]]></a>"#)
        // The table readers too: the XML parser (libxml2) and regular expressions.
        _ = TableParser.parse(#"<?xml version="1.0" encoding="windows-1251"?><Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet" xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet"><Worksheet ss:Name="Лист"><Table><Row><Cell ss:Index="2" ss:MergeAcross="1"><Data ss:Type="String">Ячейка</Data></Cell></Row></Table></Worksheet></Workbook>"#, format: "spreadsheetml")
        _ = TableParser.parse("<table><tr><td colspan=2 rowspan='2'>Ячейка &amp; &#171;x&#xBB;</td></tr></table>", format: "html")
        _ = TableParser.parse("a;\"b\"\"c\";Ж\n1;2;3\n", format: "csv")
        warmUpBooks()
        typealias SandboxInit = @convention(c) (
            UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) -> Int32
        // sandbox_init is deprecated but kept: browsers lock their helpers down with it.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_init") else { return false }
        var error: UnsafeMutablePointer<CChar>?
        let status = unsafeBitCast(symbol, to: SandboxInit.self)("(version 1) (deny default)", 0, &error)
        if let error { free(error) }
        return status == 0
    }

    /// Book reading used once before the lockdown: picture decoders (each format
    /// OriCmd shows), an FB2 in Windows-1251 (the XML parser's encodings) and a zip.
    private func warmUpBooks() {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return }
        for type in ["public.png", "public.jpeg", "com.compuserve.gif", "public.tiff", "com.microsoft.bmp"] {
            let data = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                if CGImageDestinationFinalize(destination) { _ = BookBuilder.pixels(of: data as Data) }
            }
        }
        let fb2 = #"<?xml version="1.0" encoding="windows-1251"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><body><section><p>Ж</p></section></body></FictionBook>"#
        if let data = fb2.data(using: .windowsCP1251) { _ = BookParser.parse(data, format: "fb2") }
        // Deflate (zip entries) both ways.
        let plain = [UInt8](repeating: 65, count: 256)
        var packed = [UInt8](repeating: 0, count: 512), unpacked = [UInt8](repeating: 0, count: 256)
        let size = compression_encode_buffer(&packed, packed.count, plain, plain.count, nil, COMPRESSION_ZLIB)
        _ = compression_decode_buffer(&unpacked, unpacked.count, packed, size, nil, COMPRESSION_ZLIB)
    }

    private func loadedContext() -> JSContext? {
        if let context { return context }
        // JavaScriptCore would otherwise connect to the Web Inspector daemon, and that
        // connection would outlive the lockdown.
        typealias DisableAutoStart = @convention(c) () -> Void
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSRemoteInspectorDisableAutoStart") {
            unsafeBitCast(symbol, to: DisableAutoStart.self)()
        }
        guard let context = JSContext() else { return nil }
        context.isInspectable = false
        for name in ["prelude", "highlight.min", "markdown-it.min", "beautifier.min", "prettier.min", "bridge"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
                  let script = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            context.evaluateScript(script, withSourceURL: url)
        }
        self.context = context
        return context
    }

    #if DEBUG
    /// Debug-only test languages for the regression checks; nil for the others.
    private func testReply(_ text: String, languages: [String], context: JSContext) -> (Data?, Data?)? {
        func reply(_ ranges: [UInt32], _ scopes: String = "string\nnumber") -> (Data?, Data?) {
            (ranges.withUnsafeBytes { Data($0) }, Data(scopes.utf8))
        }
        // One character colored if the probe got through, two if it was refused.
        let through: [UInt32] = [0, 1, 0], refused: [UInt32] = [0, 1, 0, 1, 1, 1]
        let argument = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch languages {
        case ["oricmd-test-hang"]:
            // A highlighting that never ends: OriCmd must kill this process.
            context.evaluateScript("for (;;) {}")
            return (nil, nil)
        case ["oricmd-test-exit"]:
            // A service that dies: started again, it must still be killed when it hangs.
            exit(0)
        case ["oricmd-test-files"]:
            // The text is a path: no file may be read.
            return reply(FileManager.default.contents(atPath: argument) != nil ? through : refused)
        case ["oricmd-test-lookup"]:
            // The text is a service name: no service may be looked up.
            typealias LookUp = @convention(c) (mach_port_t, UnsafePointer<CChar>, UnsafeMutablePointer<mach_port_t>)
                -> kern_return_t
            var bootstrap: mach_port_t = 0
            var port: mach_port_t = 0
            let reached = task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bootstrap) == KERN_SUCCESS
                && dlsym(UnsafeMutableRawPointer(bitPattern: -2), "bootstrap_look_up").map {
                    unsafeBitCast($0, to: LookUp.self)(bootstrap, argument, &port) == KERN_SUCCESS
                } == true
            return reply(reached ? through : refused)
        case ["oricmd-test-prefs"]:
            // The text is a preferences domain: nothing may be written there (a service
            // taken over must not change what other programs, OriCmd too, will run).
            CFPreferencesSetAppValue("probe" as CFString, "written" as CFString, argument as CFString)
            let written = CFPreferencesAppSynchronize(argument as CFString)
            return reply(written ? through : refused)
        case ["oricmd-test-overlap"]:
            // Ranges that overlap (the first two characters, then the second and third).
            return reply([0, 2, 0, 1, 2, 1])
        case ["oricmd-test-longscope"]:
            // A scope name far too long (hashed once a range, it could stall OriCmd).
            return reply([0, 1, 0, 1, 1, 1], "string\n" + String(repeating: "x", count: 100_000))
        default:
            return nil
        }
    }
    #endif
}
