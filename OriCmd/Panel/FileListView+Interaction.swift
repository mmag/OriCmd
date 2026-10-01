import AppKit

// MARK: - Context menu

extension FileListView {
    /// Right click: the clicked entry becomes the cursor unless it is marked,
    /// then the menu applies to the marked entries or the cursor entry.
    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let row = index(at: point), !marked.contains(items[row].name) {
            moveCursor(to: row)
        }
        return delegate?.fileList(self, contextMenuFor: selectedEntries)
    }

    /// Marked entries, or the entry under the cursor.
    var selectedEntries: [FileItem] {
        let markedItems = items.filter { marked.contains($0.name) }
        if !markedItems.isEmpty { return markedItems }
        return currentItem.map { $0.isParent ? [] : [$0] } ?? []
    }
}

// MARK: - Services

extension FileListView {
    /// The paths of files, as older services take them (SnailSVN's, for one).
    private static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    /// Offers the selected files to macOS Services (e.g. in the context menu), as file
    /// URLs and as paths: a service is listed only when it gets the kind it asks for.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let sendType, [.fileURL, Self.filenamesType].contains(sendType), returnType == nil,
           delegate?.fileListCanDragItems(self) == true, !selectedEntries.isEmpty {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// The files as URLs, as paths and as the text of their paths: a service reads what
    /// it reads whatever it declares (SnailSVN's asks for paths and reads the text).
    @objc func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let urls = selectedEntries.map(\.url)
        guard !urls.isEmpty else { return false }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(urls as [NSURL]) else { return false }
        pasteboard.setPropertyList(urls.map(\.path), forType: Self.filenamesType)
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        return true
    }
}

// MARK: - Dragging out

extension FileListView: NSDraggingSource {
    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, delegate?.fileListCanDragItems(self) == true else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.point.x, point.y - origin.point.y) > 4,
              items.indices.contains(origin.row), !items[origin.row].isParent else { return }
        dragOrigin = nil

        let item = items[origin.row]
        let dragged = marked.contains(item.name) ? items.filter { marked.contains($0.name) } : [item]
        let draggingItems = dragged.enumerated().map { offset, file in
            let draggingItem = NSDraggingItem(pasteboardWriter: file.url as NSURL)
            let image = dragImage(for: file)
            let origin = NSPoint(x: point.x - 10, y: point.y - image.size.height / 2 + CGFloat(offset) * image.size.height)
            draggingItem.setDraggingFrame(NSRect(origin: origin, size: image.size), contents: image)
            return draggingItem
        }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move] : [.copy, .move, .generic, .link]
    }

    private func dragImage(for item: FileItem) -> NSImage {
        let name = item.isFolder ? "[\(item.name)]" : item.name
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.panelFont, .foregroundColor: Theme.panelText]
        let width = min((name as NSString).size(withAttributes: attributes).width + 28, 320)
        let height = Theme.rowHeight
        return NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            FileIcons.icon(for: item).draw(in: NSRect(x: 2, y: (height - 16) / 2, width: 16, height: 16))
            (name as NSString).draw(at: NSPoint(x: 22, y: (height - Theme.panelFont.pointSize) / 2 - 2),
                                    withAttributes: attributes)
            return true
        }
    }
}

// MARK: - Dropping in

extension FileListView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropTarget(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropTarget(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTargetRow = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let folder = dropTargetRow.map { items[$0] }
        let operation = dropOperation(sender)
        dropTargetRow = nil
        // Promised files first: the file URLs such programs add point to placeholders.
        let promises = sender.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])
            as? [NSFilePromiseReceiver] ?? []
        if !promises.isEmpty, operation != [] {
            return delegate?.fileList(self, dropPromises: promises, into: folder) ?? false
        }
        let urls = droppedURLs(sender)
        guard !urls.isEmpty, operation != [] else { return false }
        return delegate?.fileList(self, drop: urls, into: folder, moving: operation == .move) ?? false
    }

    private func droppedURLs(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Folder entries (including "[..]") are drop targets; elsewhere files go
    /// to the panel's folder. Dropping a panel onto itself does nothing.
    private func updateDropTarget(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let urls = Set(droppedURLs(sender).map(\.standardizedFileURL))
        if let row = index(at: point), items[row].isFolder, !urls.contains(items[row].url.standardizedFileURL) {
            dropTargetRow = row
        } else {
            dropTargetRow = nil
            if sender.draggingSource as? FileListView === self { return [] }
        }
        return dropOperation(sender)
    }

    /// Copy by default, as in Total Commander; ⌘ (which limits the source mask
    /// to moving) moves.
    private func dropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        let mask = sender.draggingSourceOperationMask
        if mask.contains(.copy) { return .copy }
        if mask.contains(.move) || mask.contains(.generic) { return .move }
        return []
    }
}
