import Foundation

/// Files another program put on the clipboard (or drags) may not be written yet:
/// Microsoft Remote Desktop creates zero-filled placeholders of the right size and
/// writes the contents only when someone reads them through file coordination, as
/// the Finder does. A coordinated read makes such programs finish first.
nonisolated enum FileCoordination {
    /// Waits until the programs presenting `urls` have written them. Cancelling the
    /// task stops waiting.
    static func waitUntilWritten(_ urls: [URL]) async throws {
        // NSFileCoordinator's cancel is thread-safe.
        nonisolated(unsafe) let coordinator = NSFileCoordinator(filePresenter: nil)
        let intents = urls.map { NSFileAccessIntent.readingIntent(with: $0, options: []) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                coordinator.coordinate(with: intents, queue: OperationQueue()) { error in
                    if let error {
                        let cancelled = (error as NSError).domain == NSCocoaErrorDomain
                            && (error as NSError).code == NSUserCancelledError
                        continuation.resume(throwing: cancelled ? CancellationError() : error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            coordinator.cancel()
        }
    }
}
