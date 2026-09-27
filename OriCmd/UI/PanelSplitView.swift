import AppKit

/// The splitter between the panels: a little wider than a hairline so it is
/// easy to grab; double click splits the window evenly, as in Total Commander.
final class PanelSplitView: NSSplitView {
    var onDoubleClickDivider: (() -> Void)?

    override var dividerThickness: CGFloat { 4 }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, let first = arrangedSubviews.first,
           point.x >= first.frame.maxX, point.x <= first.frame.maxX + dividerThickness {
            onDoubleClickDivider?()
            return
        }
        super.mouseDown(with: event)
    }

    /// Puts the divider at `ratio` of the available width.
    func setRatio(_ ratio: CGFloat) {
        setPosition(((bounds.width - dividerThickness) * ratio).rounded(), ofDividerAt: 0)
    }

    var ratio: CGFloat {
        guard let first = arrangedSubviews.first, bounds.width > dividerThickness else { return 0.5 }
        return first.frame.width / (bounds.width - dividerThickness)
    }
}
