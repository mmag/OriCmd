import AppKit

/// The command line under the panels: "<current path>>" prompt and an input box.
final class CommandLineView: NSView {
    static let height: CGFloat = 26

    let promptLabel = NSTextField(labelWithString: "")
    let inputField = NSComboBox()

    var directory: URL? {
        didSet { promptLabel.stringValue = (directory?.path ?? "") + ">" }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        promptLabel.font = Theme.chromeFont
        promptLabel.lineBreakMode = .byTruncatingHead
        promptLabel.alignment = .right
        promptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        promptLabel.setContentHuggingPriority(.required, for: .horizontal)

        inputField.font = Theme.chromeFont
        inputField.controlSize = .small
        inputField.completes = false
        inputField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for view in [promptLabel, inputField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            promptLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            promptLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            promptLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.5),
            inputField.leadingAnchor.constraint(equalTo: promptLabel.trailingAnchor, constant: 2),
            inputField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            inputField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
