import AppKit

/// What the OriCmdHighlighter service offers. The same protocol is declared in
/// Highlighter/Highlighting.swift: keep both alike.
@objc(ORCHighlighting) nonisolated protocol Highlighting {
    func highlight(_ text: String, languages: [String], reply: @escaping @Sendable (Data?, Data?) -> Void)
    func processIdentifier(reply: @escaping @Sendable (Int32) -> Void)
    func languageNames(reply: @escaping @Sendable (Data?) -> Void)
    func table(_ text: String, format: String, reply: @escaping @Sendable (Data?) -> Void)
    func book(_ data: Data, format: String, reply: @escaping @Sendable (Data?) -> Void)
    func markdown(_ text: String, reply: @escaping @Sendable (Data?) -> Void)
    func format(_ text: String, language: String, reply: @escaping @Sendable (Data?) -> Void)
    func mesh(_ data: Data, format: String, reply: @escaping @Sendable (Data?) -> Void)
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
    /// For reading a table (up to 32 MB of text).
    private static let tableTimeLimit: Duration = .seconds(20)
    /// For reading a book (with its pictures).
    private static let bookTimeLimit: Duration = .seconds(60)
    /// Larger books are not sent; scanned DjVu books are often larger (the service
    /// only reads their page sizes and text layers).
    static func bookSizeLimit(for format: String) -> Int {
        format == "djvu" ? 400 * 1024 * 1024 : 100 * 1024 * 1024
    }
    /// For formatting a text or making a page of Markdown (js-beautify takes some
    /// seconds for megabytes).
    private static let formatTimeLimit: Duration = .seconds(20)
    /// Larger 3D models are not sent (4 million triangles take 200 MB as binary STL).
    static let meshSizeLimit = 256 * 1024 * 1024
    /// Longer texts are neither formatted nor made into pages: JSON and XML are laid
    /// out by OriCmd's own code, in time and memory in proportion to the text; the
    /// JavaScript libraries can take a gigabyte for a few megabytes made for it.
    static func formatSizeLimit(for language: String) -> Int {
        ["json", "xml"].contains(language) ? 8 * 1024 * 1024 : 2 * 1024 * 1024
    }
    /// For the service to start; launchd starts it again only some seconds after
    /// it was killed.
    private static let startLimit: Duration = .seconds(15)
    private static let serviceName = "ru.themmag.OriCmd.Highlighter"
    private static var connection: NSXPCConnection?
    /// highlight.js's language names and aliases, asked once: a text in none of
    /// them is not sent to the service at all.
    private static var knownLanguages: Set<String>?
    #if DEBUG
    /// Services killed for hanging and texts sent (for the regression checks).
    static var kills = 0
    static var textsSent = 0
    #endif

    /// The colored ranges of `text` in the first of `languages` highlight.js knows;
    /// nil when none fits, the text is too long, the task was cancelled (another
    /// file is shown), or the service fails, hangs or replies nonsense. One text at a
    /// time goes to the service, so the time limit counts only its own work.
    static func highlight(_ text: String, languages: [String]) async -> [(range: NSRange, scope: String)]? {
        guard !languages.isEmpty, text.utf16.count <= sizeLimit else { return nil }
        await takeTurn()
        defer { endTurn() }
        guard !Task.isCancelled else { return nil }
        if knownLanguages == nil {
            knownLanguages = await askLanguageNames()
        }
        let languages = languages.filter { language in
            #if DEBUG
            if language.hasPrefix("oricmd-test-") { return true }
            #endif
            return knownLanguages?.contains(language.lowercased()) == true
        }
        guard !languages.isEmpty, !Task.isCancelled else { return nil }
        let outcome = await requestTwice(timeLimit: timeLimit) { proxy, answer in
            proxy.highlight(text, languages: languages) { @Sendable ranges, scopes in answer.give(.done(ranges, scopes)) }
        }
        guard case .done(let data?, let scopeData?) = outcome, let scopes = names(in: scopeData) else { return nil }
        return checkedRanges(data, scopes: scopes, length: text.utf16.count)
    }

    /// The tables of `text` in `format` ("spreadsheetml", "html", "csv", "tsv"), read
    /// in the service; nil when there are none, or the service fails, hangs or
    /// replies nonsense (the reply is checked as a stranger's, see ViewerTable).
    static func tables(_ text: String, format: String) async -> ViewerTable? {
        await takeTurn()
        defer { endTurn() }
        guard !Task.isCancelled else { return nil }
        let outcome = await requestTwice(timeLimit: tableTimeLimit) { proxy, answer in
            proxy.table(text, format: format) { @Sendable data in answer.give(.done(data, nil)) }
        }
        guard case .done(let data?, _) = outcome else { return nil }
        return await Task.detached { ViewerTable(data) }.value
    }

    /// The book in `data` ("fb2", "fb2.zip", "epub", "mobi", "djvu"), read in the service; nil when
    /// it cannot be read, or the service fails, hangs or replies nonsense (the reply
    /// is checked as a stranger's, see BookDocument).
    static func book(_ data: Data, format: String) async -> BookDocument? {
        guard data.count <= bookSizeLimit(for: format) else { return nil }
        await takeTurn()
        defer { endTurn() }
        guard !Task.isCancelled else { return nil }
        let outcome = await requestTwice(timeLimit: bookTimeLimit) { proxy, answer in
            proxy.book(data, format: format) { @Sendable reply in answer.give(.done(reply, nil)) }
        }
        guard case .done(let reply?, _) = outcome else { return nil }
        return await Task.detached { BookDocument(reply) }.value
    }

    /// `text` (Markdown) as the body of an HTML page, made in the service; nil when
    /// it is too long, or the service fails, hangs or replies nonsense. The page is
    /// shown locked (see WebPreview), whatever it holds.
    static func markdown(_ text: String) async -> String? {
        guard text.utf8.count <= formatSizeLimit(for: "markdown") else { return nil }
        await takeTurn()
        defer { endTurn() }
        guard !Task.isCancelled else { return nil }
        let outcome = await requestTwice(timeLimit: formatTimeLimit) { proxy, answer in
            proxy.markdown(text) { @Sendable data in answer.give(.done(data, nil)) }
        }
        // Colored code is much longer than the code itself (a tag around every token).
        guard case .done(let data?, _) = outcome, data.count <= min(text.utf8.count * 64 + 1_000_000, 64 * 1024 * 1024)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `text` laid out for reading in `language` ("json", "xml", "js", "ts", "tsx", "css", "html"),
    /// done in the service; nil when it is too long, or the service fails, hangs or
    /// replies nonsense (more than some times the text).
    static func format(_ text: String, language: String) async -> String? {
        guard text.utf8.count <= formatSizeLimit(for: language) else { return nil }
        await takeTurn()
        defer { endTurn() }
        guard !Task.isCancelled else { return nil }
        let outcome = await requestTwice(timeLimit: formatTimeLimit) { proxy, answer in
            proxy.format(text, language: language) { @Sendable data in answer.give(.done(data, nil)) }
        }
        guard case .done(let data?, _) = outcome, data.count <= text.utf8.count * 8 + 1_000_000 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The 3D model in `data` ("stl"), read in the service; nil when it has no
    /// triangles, is too large, or the service fails, hangs or replies nonsense
    /// (checked as a stranger's, see MeshDocument).
    static func mesh(_ data: Data, format: String) async -> MeshDocument? {
        guard data.count <= meshSizeLimit else { return nil }
        await takeTurn()
        defer { endTurn() }
        guard !Task.isCancelled else { return nil }
        let outcome = await requestTwice(timeLimit: bookTimeLimit) { proxy, answer in
            proxy.mesh(data, format: format) { @Sendable reply in answer.give(.done(reply, nil)) }
        }
        guard case .done(let reply?, _) = outcome else { return nil }
        return await Task.detached { MeshDocument(reply) }.value
    }

    /// A request, once more on a new connection when the service went away (not
    /// after a hang).
    private static func requestTwice(timeLimit: Duration, _ send: @escaping Send) async -> Outcome {
        let outcome = await request(timeLimit: timeLimit, send)
        guard case .broken = outcome, !Task.isCancelled else { return outcome }
        return await request(timeLimit: timeLimit, send)
    }

    /// Names one a line, as the service sends scopes and languages; nil unless every
    /// name is short and made of letters, digits and `_ . : + # -` (a taken-over
    /// service could send huge or odd names to slow OriCmd down).
    private static func names(in data: Data, limit: Int = 1000) -> [String]? {
        guard data.count <= 64 * 1024, let text = String(data: data, encoding: .utf8) else { return nil }
        let names = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:+#-")
        guard names.count <= limit, names.allSatisfy({ (1...64).contains($0.count) && $0.allSatisfy(allowed.contains) })
        else { return nil }
        return names
    }

    /// The service's language names and aliases; nil (nothing highlighted) when it
    /// does not answer.
    private static func askLanguageNames() async -> Set<String>? {
        let connection = currentConnection()
        guard await processIdentifier(of: connection) != nil else {
            drop(connection)
            return nil
        }
        let data: Data? = await withCheckedContinuation { continuation in
            let answer = Once<Data?>(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in answer.give(nil) } as? Highlighting
            proxy?.languageNames { @Sendable data in answer.give(data) }
            if proxy == nil { answer.give(nil) }
            Task {
                try? await Task.sleep(for: timeLimit)
                answer.give(nil)
            }
        }
        return data.flatMap { names(in: $0, limit: 2000) }.map { Set($0.map { $0.lowercased() }) }
    }

    /// The ranges of a reply, all or none. The reply is checked as coming from a
    /// stranger — a service taken over could send anything, e.g. overlapping ranges
    /// that would keep the main thread coloring for minutes: at most one range a
    /// character (and a few), lying in the text, starting in order, nesting properly
    /// and together covering at most eight times the text.
    private static func checkedRanges(_ data: Data, scopes: [String], length: Int)
        -> [(range: NSRange, scope: String)]? {
        guard data.count % 12 == 0, data.count / 12 <= length + 64 else { return nil }
        var ranges: [(range: NSRange, scope: String)] = []
        ranges.reserveCapacity(data.count / 12)
        let valid = data.withUnsafeBytes { bytes -> Bool in
            var enclosingEnds: [Int] = []
            var previousStart = 0
            var covered = 0
            for offset in stride(from: 0, to: bytes.count, by: 12) {
                let start = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                let count = Int(bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
                let scope = Int(bytes.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self))
                guard start >= previousStart, start + count <= length, scopes.indices.contains(scope) else { return false }
                previousStart = start
                guard count > 0 else { continue }
                while let end = enclosingEnds.last, end <= start { enclosingEnds.removeLast() }
                if let end = enclosingEnds.last, start + count > end { return false }
                enclosingEnds.append(start + count)
                covered += count
                guard covered <= 8 * length + 1024 else { return false }
                ranges.append((NSRange(location: start, length: count), scopes[scope]))
            }
            return true
        }
        return valid ? ranges : nil
    }

    private enum Outcome: Sendable {
        case done(Data?, Data?)
        case broken
        case timedOut
    }

    /// Sends a request to the service's proxy; the reply goes to the `Once`.
    private typealias Send = @Sendable (Highlighting, Once<Outcome>) -> Void

    /// Sends a request once the service runs and has told its process identifier
    /// (asked every time: a service that died is started again under another one);
    /// the time limit starts then.
    private static func request(timeLimit: Duration, _ send: @escaping Send) async -> Outcome {
        let connection = currentConnection()
        guard let pid = await processIdentifier(of: connection) else {
            drop(connection)
            return .broken
        }
        #if DEBUG
        textsSent += 1
        #endif
        let outcome: Outcome = await withCheckedContinuation { continuation in
            let answer = Once(continuation)
            // XPC calls these on its own queues.
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in
                answer.give(.broken)
            } as? Highlighting
            if let proxy { send(proxy, answer) } else { answer.give(.broken) }
            Task {
                try? await Task.sleep(for: timeLimit)
                if answer.give(.timedOut) { stop(connection, pid: pid) }
            }
        }
        // The retry goes over a new connection.
        if case .broken = outcome { drop(connection) }
        return outcome
    }

    /// The service's process: as the kernel tells once the service answered (a
    /// taken-over service could tell another one), else as the service tells; nil
    /// when it does not start or answer in time.
    private static func processIdentifier(of connection: NSXPCConnection) async -> pid_t? {
        let told: pid_t? = await withCheckedContinuation { continuation in
            let answer = Once<pid_t?>(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in answer.give(nil) } as? Highlighting
            proxy?.processIdentifier { @Sendable pid in answer.give(pid) }
            if proxy == nil { answer.give(nil) }
            Task {
                try? await Task.sleep(for: startLimit)
                answer.give(nil)
            }
        }
        guard let told else { return nil }
        return connection.processIdentifier > 0 ? connection.processIdentifier : told
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

    private static func currentConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = .highlighting
        let this = WeakConnection(connection)
        // The service died (crashed, killed, or ended by the system): the next text
        // goes over a new connection.
        connection.interruptionHandler = { @Sendable in
            Task { @MainActor in
                if let connection = this.connection, SyntaxHighlighter.connection === connection { drop(connection) }
            }
        }
        connection.invalidationHandler = { @Sendable in
            Task { @MainActor in
                if let connection = this.connection, SyntaxHighlighter.connection === connection {
                    SyntaxHighlighter.connection = nil
                }
            }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    /// Ends a service that hangs: killed, as JavaScript cannot be interrupted. Only
    /// a process running our service's program is killed, whatever it told.
    private static func stop(_ connection: NSXPCConnection, pid: pid_t) {
        // The kernel's current answer: the service may have been started again since.
        let pid = connection.processIdentifier > 0 ? connection.processIdentifier : pid
        if pid > 0, isService(pid) {
            kill(pid, SIGKILL)
            #if DEBUG
            kills += 1
            #endif
        }
        drop(connection)
    }

    private static func drop(_ connection: NSXPCConnection) {
        connection.invalidate()
        if self.connection === connection { self.connection = nil }
    }

    /// Whether `pid` runs our service's program, found next to OriCmd's own program
    /// where it is now (the app may have been moved since it started).
    private static func isService(_ pid: pid_t) -> Bool {
        func program(of pid: pid_t) -> URL? {
            var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = Int(proc_pidpath(pid, &path, UInt32(path.count)))
            guard length > 0 else { return nil }
            return URL(filePath: String(decoding: path.prefix(length), as: UTF8.self)).resolvingSymlinksInPath()
        }
        guard let own = program(of: getpid()), let target = program(of: pid) else { return false }
        let service = own.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "XPCServices/OriCmdHighlighter.xpc/Contents/MacOS/OriCmdHighlighter")
        return target.path == service.resolvingSymlinksInPath().path
    }

    /// A connection its own handlers refer to without keeping it.
    private nonisolated final class WeakConnection: @unchecked Sendable {
        weak var connection: NSXPCConnection?
        init(_ connection: NSXPCConnection) { self.connection = connection }
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
        if ext == "oricmdoverlap" { return ["oricmd-test-overlap"] }
        if ext == "oricmdexit" { return ["oricmd-test-exit"] }
        if ext == "oricmdlookup" { return ["oricmd-test-lookup"] }
        if ext == "oricmdlongscope" { return ["oricmd-test-longscope"] }
        if ext == "oricmdprefs" { return ["oricmd-test-prefs"] }
        if ext == "oricmdmemory" { return ["oricmd-test-memory"] }
        #endif
        guard !plainExtensions.contains(ext) else { return [] }
        let markup = start.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
        // Documents are zip files; one that is text after all is XML (Excel 2003 XML,
        // an export with the wrong name), never the language named like it (highlight.js
        // takes xlsx for Excel formulae).
        if documentExtensions.contains(ext) { return markup.hasPrefix("<") ? ["xml"] : [] }
        if ["asm", "s", "nasm"].contains(ext) { return [assemblyLanguage(start)] }
        var languages = byExtension[ext].map { [$0] } ?? []
        if !ext.isEmpty { languages.append(ext) }
        if languages.isEmpty, let language = interpreterLanguage(firstLine) { languages.append(language) }
        // Unknown names that turn out to be XML or HTML.
        let lowercased = markup.prefix(15).lowercased()
        if lowercased.hasPrefix("<?xml") || lowercased.hasPrefix("<!doctype html") || lowercased.hasPrefix("<html") {
            languages.append("xml")
        }
        return languages
    }

    /// Office and similar documents (zip files, or XML at most).
    private static let documentExtensions: Set<String> = [
        "xlsx", "xlsm", "xlsb", "xls", "xlt", "xltx", "xltm", "docx", "docm", "doc", "dot", "dotx", "dotm",
        "pptx", "pptm", "ppt", "pps", "ppsx", "pot", "potx", "odt", "ods", "odp", "odg", "ott", "ots", "otp",
        "pages", "numbers", "epub",
    ]

    /// Plain text, and files that usually hold keys, certificates or signatures:
    /// never sent to the service, whatever highlight.js would make of them.
    private static let plainExtensions: Set<String> = [
        "txt", "text", "log", "out", "plaintext",
        "asc", "gpg", "pgp", "sig", "key", "pem", "crt", "cer", "csr", "der", "p8", "p12", "pfx", "keystore",
    ]

    private static let byName: [String: String] = [
        "makefile": "makefile", "gnumakefile": "makefile", "dockerfile": "dockerfile", "containerfile": "dockerfile",
        "cmakelists.txt": "cmake", "gemfile": "ruby", "podfile": "ruby", "rakefile": "ruby", "vagrantfile": "ruby",
        "fastfile": "ruby", "brewfile": "ruby", "appfile": "ruby", "guardfile": "ruby",
        ".bashrc": "bash", ".bash_profile": "bash", ".bash_aliases": "bash", ".profile": "bash", ".zshrc": "bash",
        ".zprofile": "bash", ".zshenv": "bash", ".gitconfig": "ini", ".editorconfig": "ini",
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

    /// The provider may be called off the main thread (drawing elsewhere).
    nonisolated private static func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
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
