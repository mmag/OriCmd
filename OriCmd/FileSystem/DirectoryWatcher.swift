import Foundation

/// Calls `onChange` on the main queue (coalesced) when entries of a directory
/// are added, removed or renamed, or the directory itself goes away.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    private let onChange: () -> Void
    private var isPending = false

    init?(url: URL, onChange: @escaping () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        self.onChange = onChange
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .link], queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleChange() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        source.cancel()
    }

    private func scheduleChange() {
        guard !isPending else { return }
        isPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            isPending = false
            onChange()
        }
    }
}
