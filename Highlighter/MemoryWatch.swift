import Foundation

/// Ends the service when its memory grows past `limit`: a file made to make the
/// JavaScript engine or a parser take memory without end would otherwise press on
/// the whole Mac until OriCmd's time limit. Every reader has its own limits, far
/// below this; OriCmd sees the service gone and shows the file without it.
enum MemoryWatch {
    static let limit: UInt64 = 2 * 1024 * 1024 * 1024
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    static func start() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler {
            if footprint() > limit { _exit(1) }
        }
        timer.resume()
        self.timer = timer
    }

    /// The memory the system charges this process with.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
