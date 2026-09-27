import AppKit

/// The current path line above a file list, e.g. "/Users/me/*.*".
/// Highlighted when its panel is the active one.
final class PathBar: NSView {
    var path = "" {
        didSet { needsDisplay = true }
    }

    var isActive = false {
        didSet { needsDisplay = true }
    }

    /// Appends the file mask ("*.*", or the panel filter), as Total Commander does.
    var showsMask = true {
        didSet { needsDisplay = true }
    }

    var mask = "*.*" {
        didSet { needsDisplay = true }
    }

    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 18) }

    override func draw(_ dirtyRect: NSRect) {
        (isActive ? Theme.activeHeaderBackground : Theme.inactiveHeaderBackground).setFill()
        bounds.fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingHead
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.panelFont,
            .foregroundColor: isActive ? Theme.activeHeaderText : Theme.inactiveHeaderText,
            .paragraphStyle: paragraph,
        ]
        let text = showsMask ? (path.hasSuffix("/") ? path : path + "/") + mask : path
        let height = (text as NSString).size(withAttributes: attributes).height
        (text as NSString).draw(
            in: NSRect(x: 4, y: (bounds.height - height) / 2, width: bounds.width - 8, height: height),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
