import AppKit

/// Alt+F5's dialog: the archive to pack into and how — the compression, moving the
/// files into it, one archive per file or folder, a password for zip archives.
final class PackDialog: NSObject, NSTextFieldDelegate {
    struct Choice {
        let path: String
        let compression: ArchiveWriter.Compression
        /// The files are deleted once the archive is written and reads back whole.
        let moves: Bool
        let separately: Bool
        let password: String?
        let encryption: ArchiveWriter.Encryption
    }

    /// The dialog shown (an alert sheet does not keep its accessory's target).
    private static var shown: PackDialog?
    private static let compressionKey = "PackCompression"
    private static let encryptionKey = "PackEncryption"

    private let alert = NSAlert()
    private let pathField: NSTextField
    private let compressionPopup = NSPopUpButton()
    private let moveBox = NSButton(checkboxWithTitle: String(localized: "Move to archive (delete the originals)"),
                                   target: nil, action: nil)
    private let separateBox = NSButton(checkboxWithTitle: String(localized: "One archive per file or folder"),
                                       target: nil, action: nil)
    private let encryptBox = NSButton(checkboxWithTitle: String(localized: "Encrypt:"), target: nil, action: nil)
    private let encryptionPopup = NSPopUpButton()
    private let passwordField = NSSecureTextField()
    private let repeatField = NSSecureTextField()
    private let hint = NSTextField(labelWithString: "")

    private init(initial: String, itemCount: Int) {
        pathField = NSTextField(string: initial)
        super.init()
        compressionPopup.addItems(withTitles: [
            String(localized: "Normal"), String(localized: "Fastest"), String(localized: "Best"),
            String(localized: "Store (no compression)"),
        ])
        compressionPopup.selectItem(at: AppDefaults.store.integer(forKey: Self.compressionKey))
        encryptionPopup.addItems(withTitles: [
            String(localized: "AES-256"), String(localized: "ZipCrypto (weak, for old programs)"),
        ])
        encryptionPopup.selectItem(at: AppDefaults.store.integer(forKey: Self.encryptionKey))
        separateBox.isHidden = itemCount < 2
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for field in [pathField, passwordField, repeatField] {
            field.delegate = self
            field.target = self
            field.action = #selector(changed(_:))
        }
        for control in [moveBox, separateBox, encryptBox, compressionPopup, encryptionPopup] as [NSControl] {
            control.target = self
            control.action = #selector(changed(_:))
        }
        for (view, name) in [(pathField, "packPath"), (compressionPopup, "packCompression"), (moveBox, "packMove"),
                             (separateBox, "packSeparate"), (encryptBox, "packEncrypt"),
                             (encryptionPopup, "packEncryption"), (passwordField, "packPassword"),
                             (repeatField, "packRepeat")] as [(NSView, String)] {
            view.identifier = NSUserInterfaceItemIdentifier(name)
        }
        pathField.widthAnchor.constraint(equalToConstant: 420).isActive = true
        for field in [passwordField, repeatField] {
            field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        }

        let grid = NSGridView(views: [
            [pathField, NSGridCell.emptyContentView],
            [NSTextField(labelWithString: String(localized: "Compression:")), compressionPopup],
            [NSGridCell.emptyContentView, moveBox],
            [NSGridCell.emptyContentView, separateBox],
            [encryptBox, encryptionPopup],
            [NSTextField(labelWithString: String(localized: "Password:")), passwordField],
            [NSTextField(labelWithString: String(localized: "Repeat:")), repeatField],
            [NSGridCell.emptyContentView, hint],
        ])
        grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: 0, length: 1))
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.rowSpacing = 6
        for index in 0..<grid.numberOfRows {
            grid.row(at: index).yPlacement = .center
        }
        grid.row(at: 3).isHidden = itemCount < 2
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        alert.accessoryView = grid
    }

    /// Shows the dialog as a sheet; `completion` gets the choice when Pack is pressed.
    static func show(title: String, message: String, initial: String, selection: NSRange, itemCount: Int,
                     in window: NSWindow, completion: @escaping (Choice) -> Void) {
        let dialog = PackDialog(initial: initial, itemCount: itemCount)
        shown = dialog
        let alert = dialog.alert
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Pack"))
        alert.addCancelButton()
        alert.window.initialFirstResponder = dialog.pathField
        dialog.update()
        alert.beginSheetModal(for: window) { response in
            shown = nil
            guard response == .alertFirstButtonReturn else { return }
            AppDefaults.store.set(dialog.compressionPopup.indexOfSelectedItem, forKey: compressionKey)
            AppDefaults.store.set(dialog.encryptionPopup.indexOfSelectedItem, forKey: encryptionKey)
            completion(dialog.choice)
        }
        DispatchQueue.main.async {
            dialog.pathField.currentEditor()?.selectedRange = selection
        }
    }

    private var encrypts: Bool { encryptBox.state == .on && ArchiveWriter.isZip(pathField.stringValue) }

    private var choice: Choice {
        Choice(path: pathField.stringValue,
               compression: ArchiveWriter.Compression(rawValue: compressionPopup.indexOfSelectedItem) ?? .normal,
               moves: moveBox.state == .on, separately: !separateBox.isHidden && separateBox.state == .on,
               password: encrypts ? passwordField.stringValue : nil,
               encryption: encryptionPopup.indexOfSelectedItem == 1 ? .zipCrypto : .aes256)
    }

    func controlTextDidChange(_ notification: Notification) {
        update()
    }

    @objc private func changed(_ sender: Any?) {
        update()
    }

    /// What the archive's type allows (a password for zip only, no compression for
    /// plain tar); Pack only with a path and, when encrypting, the same password twice.
    private func update() {
        let path = pathField.stringValue
        let isZip = ArchiveWriter.isZip(path)
        compressionPopup.isEnabled = ArchiveWriter.formatOptions(for: path) != nil
            && !ArchiveWriter.compressionOptions(for: path, .best).isEmpty
        encryptBox.isEnabled = isZip
        for control in [encryptionPopup, passwordField, repeatField] as [NSControl] {
            control.isEnabled = encrypts
        }
        let differ = encrypts && !repeatField.stringValue.isEmpty && passwordField.stringValue != repeatField.stringValue
        hint.stringValue = encryptBox.state == .on && !isZip ? String(localized: "Only zip archives can be encrypted.")
            : differ ? String(localized: "The passwords differ.") : ""
        alert.buttons.first?.isEnabled = !path.trimmingCharacters(in: .whitespaces).isEmpty
            && (!encrypts || (!passwordField.stringValue.isEmpty && passwordField.stringValue == repeatField.stringValue))
    }
}
