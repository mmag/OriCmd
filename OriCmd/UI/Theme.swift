import AppKit

/// Visual constants modelled on Total Commander's default look,
/// adapted to light and dark appearance.
enum Theme {
    static var panelFont: NSFont { Settings.panelFont }

    /// The panel font with fixed-width digits, for sizes and dates.
    static var panelNumberFont: NSFont {
        let font = panelFont
        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    static let chromeFont = NSFont.systemFont(ofSize: 11)

    /// Row height follows the panel font (18 pt for the default 12 pt font).
    static var rowHeight: CGFloat {
        let font = panelFont
        return max(ceil(font.ascender - font.descender + font.leading) + 4, 16)
    }

    static let panelBackground = NSColor.textBackgroundColor
    static let panelText = NSColor.textColor
    /// Marked (selected) files are drawn in red, as in Total Commander.
    static let markedText = dynamic(
        light: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
        dark: NSColor(srgbRed: 1, green: 0.4, blue: 0.4, alpha: 1)
    )
    static let markedCursorText = NSColor.systemYellow
    static let cursorBackground = NSColor.selectedContentBackgroundColor
    static let cursorText = NSColor.alternateSelectedControlTextColor
    static let inactiveCursorFrame = NSColor.secondaryLabelColor

    static let activeHeaderBackground = NSColor.selectedContentBackgroundColor
    static let activeHeaderText = NSColor.alternateSelectedControlTextColor
    static let inactiveHeaderBackground = NSColor.unemphasizedSelectedContentBackgroundColor
    static let inactiveHeaderText = NSColor.textColor

    static let chromeBackground = NSColor.windowBackgroundColor
    static let chromeText = NSColor.controlTextColor
    static let separator = NSColor.separatorColor

    nonisolated private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
