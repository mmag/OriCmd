#if DEBUG
import AppKit

/// Development aid: when `ORICMD_SNAPSHOT=/path/to/file.png` is set,
/// renders the main window's content into that file shortly after launch.
enum DebugSnapshot {
    static func scheduleIfRequested(for window: NSWindow) {
        guard let path = ProcessInfo.processInfo.environment["ORICMD_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let view = window.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
        }
    }
}
#endif
