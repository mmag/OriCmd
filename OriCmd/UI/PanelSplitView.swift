import AppKit

/// The splitter between the panels: a little wider than a hairline so it is
/// easy to grab; double click splits the window evenly, as in Total Commander.
final class PanelSplitView: NSSplitView {
    var onDoubleClickDivider: (() -> Void)?

    override var dividerThickness: CGFloat { 4 }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, let first = arrangedSubviews.first {
            let (at, end) = isVertical ? (point.x, first.frame.maxX) : (point.y, first.frame.maxY)
            if at >= end, at <= end + dividerThickness {
                onDoubleClickDivider?()
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// The length the panels share: the width side by side, the height one above
    /// the other (Show → Horizontal Panels).
    private var length: CGFloat { isVertical ? bounds.width : bounds.height }

    /// Puts the divider at `ratio` of the available length.
    func setRatio(_ ratio: CGFloat) {
        setPosition(((length - dividerThickness) * ratio).rounded(), ofDividerAt: 0)
    }

    var ratio: CGFloat {
        guard let first = arrangedSubviews.first, length > dividerThickness else { return 0.5 }
        return (isVertical ? first.frame.width : first.frame.height) / (length - dividerThickness)
    }
}
