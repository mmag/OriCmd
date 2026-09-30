import AppKit
import Network
import UniformTypeIdentifiers
import WebKit

/// A web page in the Lister (an HTML file, Markdown made into a page), shown and
/// nothing more: JavaScript is off; nothing comes from the network (a content rule
/// list blocks every load but the viewer's own scheme, and the pages' proxy leads
/// nowhere); nothing is stored; the only files served are the document's folder's
/// (and its subfolders'), read by OriCmd, not by WebKit. A link clicked opens in the
/// browser; nothing else leaves the page.
final class WebPreview: NSView, WKNavigationDelegate, WKUIDelegate {
    nonisolated static let scheme = "oricmd-page"
    private static var ruleList: WKContentRuleList?

    let webView: WKWebView
    private let files: LocalFiles
    private let pageURL: URL

    /// A preview of the HTML file at `url`, or of `page` (a page made of it, as from
    /// Markdown) in its place; nil when WebKit cannot be set up so. `encoding`: the
    /// Lister's choice for pages that do not name theirs.
    static func make(showing url: URL, page: String? = nil, encoding: TextEncoding) async -> WebPreview? {
        guard let rules = await rules() else { return nil }
        return WebPreview(url: url, page: page, encoding: encoding, rules: rules)
    }

    /// Blocks everything, then lets the viewer's scheme and inline data through.
    private static func rules() async -> WKContentRuleList? {
        if let ruleList { return ruleList }
        let json = """
            [{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
             {"trigger": {"url-filter": "^\(scheme):"}, "action": {"type": "ignore-previous-rules"}},
             {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}}]
            """
        ruleList = try? await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "ru.themmag.OriCmd.Lister", encodedContentRuleList: json)
        return ruleList
    }

    private init(url: URL, page: String?, encoding: TextEncoding, rules: WKContentRuleList) {
        let folder = url.deletingLastPathComponent().standardizedFileURL
        files = LocalFiles(root: folder, document: url.standardizedFileURL, page: page.map { Data($0.utf8) },
                           encoding: encoding)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(files, forURLScheme: Self.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.userContentController.add(rules)
        let store = WKWebsiteDataStore.nonPersistent()
        // Whatever the rules let pass (a preconnect, say) goes to a proxy that is not there.
        store.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: 9))]
        configuration.websiteDataStore = store
        webView = PreviewWebView(frame: .zero, configuration: configuration)
        webView.allowsLinkPreview = false
        webView.allowsMagnification = true
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "local"
        components.path = "/" + url.lastPathComponent
        pageURL = components.url ?? URL(string: "\(Self.scheme)://local/")!
        super.init(frame: .zero)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
        webView.load(URLRequest(url: pageURL))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The page takes the keys (arrows, space, page up and down).
    var firstResponderView: NSView { webView }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        preferences.allowsContentJavaScript = false
        guard let url = navigationAction.request.url else { return (.cancel, preferences) }
        if navigationAction.navigationType == .linkActivated {
            // A place on this page; a web or mail address in the browser; nothing else.
            if url.scheme == Self.scheme, url.path == pageURL.path, url.fragment != nil { return (.allow, preferences) }
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return (.cancel, preferences)
        }
        // The page and its frames, from the viewer's own scheme only.
        let allowed = url.scheme == Self.scheme || url.absoluteString == "about:blank"
        return (allowed ? .allow : .cancel, preferences)
    }

    /// No other windows (target="_blank" links are clicks like the others).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}

/// WebKit's context menu without what would load or open something (links, pictures
/// and frames in new windows, downloads, reloading, the inspector).
private final class PreviewWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let unwanted = ["OpenLink", "OpenImage", "OpenFrame", "OpenMedia", "Download", "Reload", "Inspect"]
        for item in menu.items where unwanted.contains(where: { item.identifier?.rawValue.contains($0) == true }) {
            menu.removeItem(item)
        }
        super.willOpenMenu(menu, with: event)
    }
}

/// Serves the page and the files of its folder (and subfolders) under the viewer's
/// scheme: regular files up to 64 MB, read in the background.
private final class LocalFiles: NSObject, WKURLSchemeHandler {
    let root: URL
    let document: URL
    let page: Data?
    let encoding: TextEncoding
    /// Tasks WebKit has not stopped (answering a stopped one raises an exception).
    private var running: Set<ObjectIdentifier> = []

    init(root: URL, document: URL, page: Data?, encoding: TextEncoding) {
        self.root = root
        self.document = document
        self.page = page
        self.encoding = encoding
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        running.insert(id)
        guard let url = task.request.url, let file = file(for: url) else {
            return fail(task)
        }
        let isDocument = file == document
        if isDocument, let page {
            return respond(task, url: url, data: page, type: "text/html", charset: "utf-8")
        }
        let encoding = encoding, root = root
        nonisolated(unsafe) let task = task
        Task.detached {
            let answer = Self.read(file, in: root, asPage: isDocument, encoding: encoding)
            await MainActor.run {
                guard let answer else { return self.fail(task) }
                self.respond(task, url: url, data: answer.data, type: answer.type, charset: answer.charset)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        running.remove(ObjectIdentifier(task))
    }

    /// The file `url` names inside the root; nil for anything outside it.
    private func file(for url: URL) -> URL? {
        guard url.scheme == WebPreview.scheme, url.host == "local" else { return nil }
        let path = url.path(percentEncoded: false)
        let file = root.appending(path: path).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(rootPath) else { return nil }
        return file
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, type: String, charset: String?) {
        guard running.remove(ObjectIdentifier(task)) != nil else { return }
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count, textEncodingName: charset))
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: any WKURLSchemeTask) {
        guard running.remove(ObjectIdentifier(task)) != nil else { return }
        task.didFailWithError(URLError(.fileDoesNotExist))
    }

    /// A regular file (after following links, still inside the root folder) and its
    /// type. The page itself as UTF-8, unless it names its own character set and no
    /// encoding was chosen in the Lister.
    private nonisolated static func read(_ file: URL, in root: URL, asPage: Bool, encoding: TextEncoding)
        -> (data: Data, type: String, charset: String?)? {
        let rootPath = root.resolvingSymlinksInPath().path
        let file = file.resolvingSymlinksInPath()
        guard file.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else { return nil }
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, (values?.fileSize ?? .max) <= 64 * 1024 * 1024,
              let data = try? Data(contentsOf: file) else { return nil }
        let type = UTType(filenameExtension: file.pathExtension.lowercased())?.preferredMIMEType ?? "application/octet-stream"
        guard asPage else { return (data, type, nil) }
        let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        if encoding == .automatic, head.contains("charset=") || head.contains("charset =") || head.contains("encoding=") {
            return (data, "text/html", nil)
        }
        return (Data(TextDecoding.decode(data, as: encoding).text.utf8), "text/html", "utf-8")
    }
}
