import Foundation

// A text made to make the scripts take memory without end ends the service instead.
MemoryWatch.start()
let service = HighlighterService()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
