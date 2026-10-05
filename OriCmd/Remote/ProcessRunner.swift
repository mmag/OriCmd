import Foundation
import os

/// Runs a command line tool (ssh, sftp, curl) off the main thread, feeding
/// stdin and collecting stdout/stderr without pipe dead-locks. Cancelling the
/// progress terminates it. `onOutput` / `onErrors` see the output as it arrives.
nonisolated enum ProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let output: Data
        let errors: String

        var text: String { String(decoding: output, as: UTF8.self) }
    }

    private struct Collected {
        var output = Data()
        var errors = Data()
        /// Pipes not read to their end yet.
        var openPipes = 2
    }

    @concurrent
    static func run(_ executable: String, _ arguments: [String], input: String? = nil,
                    environment: [String: String] = [:], progress: TransferProgress? = nil,
                    onOutput: (@Sendable (Data) -> Void)? = nil,
                    onErrors: (@Sendable (Data) -> Void)? = nil) async throws -> Output {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe

        // Each pipe is read to its end, where its handler removes itself: there it would
        // be called again and again with no data, a core each for as long as the app runs.
        let collected = OSAllocatedUnfairLock(initialState: Collected())
        func read(_ pipe: Pipe, errors: Bool, then callback: (@Sendable (Data) -> Void)?) {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    collected.withLock { $0.openPipes -= 1 }
                    return
                }
                collected.withLock { errors ? $0.errors.append(data) : $0.output.append(data) }
                callback?(data)
            }
        }
        read(outputPipe, errors: false, then: onOutput)
        read(errorPipe, errors: true, then: onErrors)
        // Not read any longer, however the run ends (a cancelled tool may have left a
        // process of its own holding a pipe open).
        defer {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
        }

        try process.run()
        if let input {
            // Long batches do not fit the pipe buffer: the tool reads them as it goes.
            let writer = inputPipe.fileHandleForWriting
            DispatchQueue.global().async {
                try? writer.write(contentsOf: Data(input.utf8))
                try? writer.close()
            }
        }
        // Paused in the progress window: the tool is stopped (SIGSTOP) until it goes on.
        var stopped = false
        while process.isRunning {
            // Cancelled through the progress window, or the task was (Esc while listing).
            if progress?.isCancelled == true || Task.isCancelled {
                if stopped { kill(process.processIdentifier, SIGCONT) }
                process.terminate()
                process.waitUntilExit()
                throw CancellationError()
            }
            if let paused = progress?.snapshot.isPaused, paused != stopped {
                kill(process.processIdentifier, paused ? SIGSTOP : SIGCONT)
                stopped = paused
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        // What the tool wrote last may still be on its way: both pipes are read to their
        // end, but not waited for long (a process it left behind may keep one open), nor
        // once the task is cancelled (the tool's result stands: it has finished).
        let deadline = ContinuousClock.now + .seconds(2)
        while collected.withLock({ $0.openPipes > 0 }), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let (output, errors) = collected.withLock { ($0.output, $0.errors) }
        return Output(status: process.terminationStatus, output: output,
                      errors: String(decoding: errors, as: UTF8.self))
    }
}
