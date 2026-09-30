import Foundation

let service = HighlighterService()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
