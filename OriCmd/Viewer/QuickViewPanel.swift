import AppKit
import Quartz

/// Ctrl+Q: shown in place of the inactive panel, previews the entry under
/// the cursor of the active panel with Quick Look.
final class QuickViewPanel: NSView {
    private let titleBar = PathBar()
    private let preview = QLPreviewView(frame: .zero, style: .normal)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleBar.path = "Quick View"
        titleBar.showsMask = false
        var views: [NSView] = [titleBar]
        if let preview { views.append(preview) }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }
        titleBar.topAnchor.constraint(equalTo: topAnchor, constant: 29).isActive = true
        preview?.topAnchor.constraint(equalTo: titleBar.bottomAnchor).isActive = true
        preview?.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ url: URL?) {
        titleBar.path = url.map { "Quick View: \($0.lastPathComponent)" } ?? "Quick View"
        preview?.previewItem = url as NSURL?
    }

    func close() {
        preview?.close()
    }
}
