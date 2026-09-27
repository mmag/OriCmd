import AppKit

// A tool that exits early (a cancelled sftp or curl) must not take the app
// down while it is being fed its input.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
