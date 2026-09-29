import AppKit
import ApplicationServices

/// Files another program only promised on the clipboard, as Microsoft Remote
/// Desktop and virtual machines do: the file URLs they put there too point to
/// placeholders of the right size, full of zeros, until the program is asked for
/// the contents. As the Finder does, the program is asked to write the files into
/// a folder of ours (the Pasteboard Manager's paste location).
nonisolated enum PromisedFiles {
    private static let promiseTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType(kPasteboardTypeFileURLPromise as String),
        NSPasteboard.PasteboardType(kPasteboardTypeFilePromiseContent as String),
    ]

    /// Whether `pasteboard` holds promised files.
    static func areOffered(on pasteboard: NSPasteboard) -> Bool {
        pasteboard.pasteboardItems?.contains { !promiseTypes.isDisjoint(with: $0.types) } == true
    }

    /// Asks the program that filled `pasteboard` to write its promised files into
    /// `folder` and returns them. Blocks until it has (a remote copy may take long).
    static func receive(from pasteboard: NSPasteboard.Name, into folder: URL) throws -> [URL] {
        var created: Pasteboard?
        let name = (pasteboard == .general ? kPasteboardClipboard as String : pasteboard.rawValue) as CFString
        guard PasteboardCreate(name, &created) == noErr, let board = created else {
            throw RemoteError(String(localized: "Cannot read the clipboard."))
        }
        PasteboardSynchronize(board)
        let status = PasteboardSetPasteLocation(board, folder as CFURL)
        guard status == noErr else {
            throw RemoteError(String(localized: "The program that copied the files did not deliver them (\(status))."))
        }
        var count = 0
        PasteboardGetItemCount(board, &count)
        var files: [URL] = []
        // Only files written into our folder are taken: a program asked again for a promise
        // it already kept may answer with the file of an earlier paste.
        let inside = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var elsewhere = 0
        for index in stride(from: 1, through: count, by: 1) {
            var item: PasteboardItemID?
            guard PasteboardGetItemIdentifier(board, index, &item) == noErr, let item else { continue }
            var data: CFData?
            // Asking for the flavor makes the program write the file into the paste location.
            guard PasteboardCopyItemFlavorData(board, item, kPasteboardTypeFileURLPromise as CFString, &data) == noErr,
                  let bytes = data as Data?,
                  let url = URL(dataRepresentation: bytes, relativeTo: nil) else { continue }
            guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(inside) else {
                elsewhere += 1
                continue
            }
            files.append(url)
        }
        if files.isEmpty && elsewhere > 0 {
            throw RemoteError(String(localized: "The program that copied the files did not write them again. Copy them in that program once more."))
        }
        return files
    }
}
