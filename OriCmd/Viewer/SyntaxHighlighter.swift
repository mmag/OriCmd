import AppKit

/// What the OriCmdHighlighter service offers. The same protocol is declared in
/// Highlighter/Highlighting.swift: keep both alike.
@objc(ORCHighlighting) protocol Highlighting {
    func highlight(_ text: String, languages: [String], reply: @escaping @Sendable (Data?, [String]?) -> Void)
    func processIdentifier(reply: @escaping @Sendable (Int32) -> Void)
}

/// Syntax highlighting for the Lister. highlight.js runs in the OriCmdHighlighter
/// XPC service, sandboxed without access to files or the network: a text made to
/// attack the JavaScript engine gets nothing there, and a highlighting that takes
/// too long is ended by killing the service (a new one starts for the next text).
enum SyntaxHighlighter {
    /// Longer texts stay plain (highlight.js takes about a second for this much).
    static let sizeLimit = 512 * 1024
    /// For highlight.js's own work: longer, and the service is killed.
    private static let timeLimit: Duration = .seconds(5)
    /// For the service to start; launchd starts it again only some seconds after
    /// it was killed.
    private static let startLimit: Duration = .seconds(15)
    private static let serviceName = "ru.themmag.OriCmd.Highlighter"
    /// The connection and its service process, as the service tells (an XPC
    /// service connection has no process identifier of its own).
    private static var service: (connection: NSXPCConnection, pid: Task<pid_t?, Never>)?

    /// The colored ranges of `text` in the first of `languages` highlight.js knows;
    /// nil when none fits, the text is too long, the task was cancelled (another
    /// file is shown), or the service fails or hangs. One text at a time goes to the
    /// service, so the time limit counts only its own work.
    static func highlight(_ text: String, languages: [String]) async -> [(range: NSRange, scope: String)]? {
        guard !languages.isEmpty, text.utf16.count <= sizeLimit else { return nil }
        await takeTurn()
        defer { endTurn() }
        guard !Task.isCancelled else { return nil }
        var outcome = await request(text, languages: languages)
        // Once more on a new connection when the service went away, not after a hang.
        if case .broken = outcome, !Task.isCancelled {
            outcome = await request(text, languages: languages)
        }
        // The reply is checked as coming from a stranger: a service taken over could
        // send anything. At most four ranges a character and a thousand scope names.
        let length = text.utf16.count
        guard case .done(let data?, let scopes?) = outcome, data.count <= 48 * (length + 1),
              scopes.count <= 1000 else { return nil }
        let values: [UInt32] = data.withUnsafeBytes { bytes in
            (0..<bytes.count / 4).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) }
        }
        return stride(from: 0, to: values.count - 2, by: 3).compactMap { index in
            let start = Int(values[index]), count = Int(values[index + 1]), scope = Int(values[index + 2])
            guard scopes.indices.contains(scope), count > 0, start + count <= length else { return nil }
            return (NSRange(location: start, length: count), scopes[scope])
        }
    }

    private enum Outcome: Sendable {
        case done(Data?, [String]?)
        case broken
        case timedOut
    }

    /// Sends `text` once the service runs; the time limit starts then.
    private static func request(_ text: String, languages: [String]) async -> Outcome {
        let (connection, pidTask) = currentService()
        guard let pid = await pidTask.value else {
            drop(connection)
            return .broken
        }
        return await withCheckedContinuation { continuation in
            let answer = Once(continuation)
            // XPC calls these on its own queues.
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in
                answer.give(.broken)
            } as? Highlighting
            proxy?.highlight(text, languages: languages) { @Sendable data, scopes in
                answer.give(.done(data, scopes))
            }
            if proxy == nil { answer.give(.broken) }
            Task {
                try? await Task.sleep(for: timeLimit)
                if answer.give(.timedOut) { stop(connection, pid: pid) }
            }
        }
    }

    private static var isBusy = false
    private static var turns: [CheckedContinuation<Void, Never>] = []

    private static func takeTurn() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { turns.append($0) }
    }

    private static func endTurn() {
        if turns.isEmpty {
            isBusy = false
        } else {
            turns.removeFirst().resume()
        }
    }

    private static func currentService() -> (connection: NSXPCConnection, pid: Task<pid_t?, Never>) {
        if let service { return service }
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = .highlighting
        let id = ObjectIdentifier(connection)
        connection.invalidationHandler = { @Sendable in
            Task { @MainActor in
                if service.map({ ObjectIdentifier($0.connection) }) == id { service = nil }
            }
        }
        connection.resume()
        let pid = Task { () -> pid_t? in
            await withCheckedContinuation { continuation in
                let answer = Once(continuation)
                let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in answer.give(nil) } as? Highlighting
                proxy?.processIdentifier { @Sendable pid in answer.give(pid) }
                if proxy == nil { answer.give(nil) }
                Task {
                    try? await Task.sleep(for: startLimit)
                    answer.give(nil)
                }
            }
        }
        service = (connection, pid)
        return (connection, pid)
    }

    /// Ends a service that hangs: killed, as JavaScript cannot be interrupted. Only
    /// a process running our service's program is killed, whatever it told.
    private static func stop(_ connection: NSXPCConnection, pid: pid_t) {
        if pid > 0, isService(pid) {
            kill(pid, SIGKILL)
        }
        drop(connection)
    }

    private static func drop(_ connection: NSXPCConnection) {
        connection.invalidate()
        if service?.connection === connection { service = nil }
    }

    private static func isService(_ pid: pid_t) -> Bool {
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = Int(proc_pidpath(pid, &path, UInt32(path.count)))
        guard length > 0 else { return false }
        let program = Bundle.main.bundleURL
            .appending(path: "Contents/XPCServices/OriCmdHighlighter.xpc/Contents/MacOS/OriCmdHighlighter")
        return URL(filePath: String(decoding: path.prefix(length), as: UTF8.self)).resolvingSymlinksInPath().path
            == program.resolvingSymlinksInPath().path
    }

    /// Resumes a waiting task once: with the reply, a failure or the timeout.
    private nonisolated final class Once<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?

        init(_ continuation: CheckedContinuation<Value, Never>) {
            self.continuation = continuation
        }

        /// False when already answered.
        @discardableResult
        func give(_ value: Value) -> Bool {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
            return continuation != nil
        }
    }

    // MARK: - Languages

    /// highlight.js names to try for `url`: by the file's name, its extension (most
    /// extensions are highlight.js aliases), or the program on its `#!` line. `start`
    /// is the beginning of the text (assembly is told by it).
    static func languages(for url: URL, start: Substring) -> [String] {
        let firstLine = start.prefix { $0 != "\n" }
        let name = url.lastPathComponent.lowercased()
        if let language = byName[name] { return [language] }
        let ext = url.pathExtension.lowercased()
        #if DEBUG
        if ext == "oricmdhang" { return ["oricmd-test-hang"] }
        if ext == "oricmdfiles" { return ["oricmd-test-files"] }
        #endif
        guard !plainExtensions.contains(ext) else { return [] }
        if ["asm", "s", "nasm"].contains(ext) { return [assemblyLanguage(start)] }
        var languages = byExtension[ext].map { [$0] } ?? []
        if !ext.isEmpty { languages.append(ext) }
        if languages.isEmpty, let language = interpreterLanguage(firstLine) { languages.append(language) }
        return languages
    }

    private static let plainExtensions: Set<String> = ["txt", "text", "log", "out", "plaintext"]

    private static let byName: [String: String] = [
        "makefile": "makefile", "gnumakefile": "makefile", "dockerfile": "dockerfile", "containerfile": "dockerfile",
        "cmakelists.txt": "cmake", "gemfile": "ruby", "podfile": "ruby", "rakefile": "ruby", "vagrantfile": "ruby",
        "fastfile": "ruby", "brewfile": "ruby", "appfile": "ruby", "guardfile": "ruby",
        ".bashrc": "bash", ".bash_profile": "bash", ".bash_aliases": "bash", ".profile": "bash", ".zshrc": "bash",
        ".zprofile": "bash", ".zshenv": "bash", ".env": "bash", ".gitconfig": "ini", ".editorconfig": "ini",
        "nginx.conf": "nginx",
    ]

    /// Extensions highlight.js has no alias for.
    private static let byExtension: [String: String] = [
        "m": "objectivec", "command": "bash", "ksh": "bash", "fish": "bash",
        "cu": "cpp", "cuh": "cpp", "ipp": "cpp", "tpp": "cpp", "metal": "cpp", "hlsl": "cpp",
        "vert": "glsl", "frag": "glsl", "geom": "glsl", "comp": "glsl", "tesc": "glsl", "tese": "glsl",
        "pyw": "python", "pyi": "python", "pyx": "python", "pxd": "python", "gypi": "python", "bzl": "python",
        "bazel": "python", "star": "python",
        "rake": "ruby", "ru": "ruby", "jbuilder": "ruby", "sbt": "scala", "sc": "scala",
        "fsx": "fsharp", "fsi": "fsharp", "mli": "ocaml", "lhs": "haskell", "hrl": "erlang",
        "cljs": "clojure", "cljc": "clojure", "rkt": "scheme", "el": "lisp", "jl": "julia",
        "psm1": "powershell", "psd1": "powershell", "bas": "basic", "lpr": "delphi", "f": "fortran",
        "for": "fortran", "adb": "ada", "ads": "ada", "vhd": "vhdl", "csx": "csharp", "ll": "llvm", "wat": "wasm",
        "au3": "autoit", "nsi": "nsis", "sass": "scss",
        "htm": "xml", "vue": "xml", "svelte": "xml", "astro": "xml", "ejs": "xml", "phtml": "php-template",
        "mustache": "handlebars", "liquid": "django",
        "plist": "xml", "xib": "xml", "storyboard": "xml", "entitlements": "xml", "csproj": "xml",
        "vcxproj": "xml", "xaml": "xml", "props": "xml", "targets": "xml", "resx": "xml", "wxs": "xml",
        "nuspec": "xml", "xslt": "xml", "kml": "xml", "gpx": "xml",
        "jsonc": "json", "json5": "json", "ipynb": "json",
        "conf": "ini", "cfg": "ini", "xcconfig": "ini", "service": "ini", "socket": "ini", "timer": "ini",
        "reg": "ini",
    ]

    /// Assembly files share their extensions whatever the processor: ARM by its
    /// registers and instructions, MIPS by `$` registers, AVR by r0–r31 with its
    /// instructions, x86 otherwise.
    private static func assemblyLanguage(_ text: Substring) -> String {
        func has(_ pattern: String) -> Bool {
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        if has(#"\b[xw]([0-9]|[12][0-9]|30)\b|\b(adrp|ldp|stp|cbnz|cbz|ldr)\b"#) { return "armasm" }
        if has(#"\$(t[0-9]|s[0-7]|a[0-3]|v[01]|ra|sp|zero)\b"#) { return "mipsasm" }
        if has(#"\br([0-9]|[12][0-9]|3[01])\b"#), has(#"\b(ldi|rjmp|rcall|brne|sbi|cbi)\b"#) { return "avrasm" }
        return "x86asm"
    }

    /// The language of the program on a `#!` line (`#!/usr/bin/env python3` → python).
    private static func interpreterLanguage(_ line: Substring) -> String? {
        guard line.hasPrefix("#!") else { return nil }
        var words = line.dropFirst(2).split(separator: " ").map { String($0.split(separator: "/").last ?? "") }
        if words.first == "env" { words = Array(words.dropFirst().drop { $0.hasPrefix("-") }) }
        guard let program = words.first else { return nil }
        let interpreters: [(prefix: String, language: String)] = [
            ("bash", "bash"), ("zsh", "bash"), ("ksh", "bash"), ("dash", "bash"), ("sh", "bash"), ("python", "python"),
            ("node", "javascript"), ("deno", "typescript"), ("ruby", "ruby"), ("perl", "perl"), ("php", "php"),
            ("lua", "lua"), ("tclsh", "tcl"), ("osascript", "applescript"), ("swift", "swift"), ("awk", "awk"),
        ]
        return interpreters.first { program.hasPrefix($0.prefix) }?.language
    }
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

// MARK: - Colors

/// Colors of highlight.js scopes, in the manner of Xcode's default themes, light
/// and dark.
enum SyntaxTheme {
    /// The attributes of `scope` ("title.function" falls back to "title"); nil
    /// leaves the text as it is.
    static func attributes(for scope: String, font: NSFont) -> [NSAttributedString.Key: Any]? {
        let style = styles[scope] ?? scope.split(separator: ".").first.flatMap { styles[String($0)] }
        guard let style else { return nil }
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: style.color]
        if style.bold {
            attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        } else if style.italic {
            attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return attributes
    }

    private struct Style {
        var color: NSColor
        var bold = false
        var italic = false
    }

    private static func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
        func rgb(_ value: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light)
        }
    }

    private static let keyword = color(0x9B2393, 0xFC5FA3)
    private static let type = color(0x0B4F79, 0x5DD8FF)
    private static let function = color(0x326D74, 0x67B7A4)
    private static let string = color(0xC41A16, 0xFC6A5D)
    private static let number = color(0x1C00CF, 0xD0BF69)
    private static let comment = color(0x5D6C79, 0x7F8C98)
    private static let preprocessor = color(0x643820, 0xFD8F3F)
    private static let attribute = color(0x815F03, 0xBF8555)
    private static let link = color(0x0E0EFF, 0x5482FF)

    private static let styles: [String: Style] = [
        "keyword": Style(color: keyword), "selector-tag": Style(color: keyword), "literal": Style(color: keyword),
        "template-tag": Style(color: keyword), "name": Style(color: keyword), "bullet": Style(color: keyword),
        "variable.language": Style(color: keyword),
        "built_in": Style(color: type), "type": Style(color: type), "title.class": Style(color: type),
        "class": Style(color: type), "selector-id": Style(color: type), "selector-class": Style(color: type),
        "variable.constant": Style(color: type),
        "title": Style(color: function), "title.function": Style(color: function), "function": Style(color: function),
        "section": Style(color: type, bold: true),
        "string": Style(color: string), "regexp": Style(color: string), "symbol": Style(color: string),
        "char": Style(color: string), "code": Style(color: string), "quote": Style(color: comment, italic: true),
        "number": Style(color: number),
        "comment": Style(color: comment), "doctag": Style(color: comment, bold: true),
        "meta": Style(color: preprocessor), "meta.keyword": Style(color: preprocessor),
        "attr": Style(color: attribute), "attribute": Style(color: attribute), "property": Style(color: attribute),
        "params": Style(color: attribute), "variable": Style(color: attribute),
        "template-variable": Style(color: attribute), "selector-attr": Style(color: attribute),
        "selector-pseudo": Style(color: attribute),
        "link": Style(color: link),
        "addition": Style(color: color(0x1A7F37, 0x7EE787)), "deletion": Style(color: color(0xCF222E, 0xFFA198)),
        "emphasis": Style(color: .textColor, italic: true), "strong": Style(color: .textColor, bold: true),
        // Interpolation inside a string: the ordinary color again.
        "subst": Style(color: .textColor),
    ]
}
