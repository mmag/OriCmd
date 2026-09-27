import Foundation

/// Total Commander's "F2 Queue": queued operations run one after another,
/// each in its own background progress window.
final class TransferQueue {
    static let shared = TransferQueue()

    private var jobs: [() async -> Void] = []
    private var isRunning = false

    /// Operations waiting behind the running one.
    var waitingCount: Int { jobs.count }

    func add(_ job: @escaping () async -> Void) {
        jobs.append(job)
        guard !isRunning else { return }
        isRunning = true
        Task {
            while !jobs.isEmpty {
                let next = jobs.removeFirst()
                await next()
            }
            isRunning = false
        }
    }
}
