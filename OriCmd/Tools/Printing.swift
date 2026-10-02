import AppKit

/// Total Commander's Files → Print: a file list (with the subfolders' files too)
/// or a text file, printed with the panel's monospaced numbers.
enum Printing {
    /// Prints `text` in a plain font through the print panel.
    static func print(_ text: String, title: String, in window: NSWindow?) {
        #if DEBUG
        if DebugAutomation.printed(text) { return }
        #endif
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.string = text
        view.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        view.isEditable = false
        view.sizeToFit()
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = title
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    /// Prints what a view shows (the Lister's page, table or book).
    static func print(_ view: NSView, title: String, in window: NSWindow) {
        #if DEBUG
        if DebugAutomation.printed((view as? NSTextView)?.string ?? "[\(type(of: view))]") { return }
        #endif
        let operation = NSPrintOperation(view: view)
        operation.jobTitle = title
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// The entries of `folder` as lines (name, size or <DIR>, date); with
    /// `subfolders`, the files of the folders inside too, by their paths.
    static func list(_ items: [FileItem], in folder: URL, subfolders: Bool) -> String {
        var lines = [folder.path, ""]
        func add(_ items: [FileItem], prefix: String) {
            for item in items where !item.isParent {
                let name = prefix + item.name
                let size = item.isFolder ? "<DIR>" : item.size.formatted(.number.grouping(.automatic))
                let padded = name.count < 48 ? name.padding(toLength: 48, withPad: " ", startingAt: 0) : name + " "
                lines.append(padded + size.leftPadded(to: 16) + "  " + dateFormatter.string(from: item.modified))
                if subfolders, item.isFolder, !item.isSymlink {
                    let children = ((try? DirectoryListing.items(in: item.url)) ?? [])
                        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    add(children, prefix: name + "/")
                }
            }
        }
        add(items, prefix: "")
        return lines.joined(separator: "\n")
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: " ", count: length - count) + self
    }
}
