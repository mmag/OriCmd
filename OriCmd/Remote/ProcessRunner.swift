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

        let collected = OSAllocatedUnfairLock(initialState: (output: Data(), errors: Data()))
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            collected.withLock { $0.output.append(data) }
            if !data.isEmpty { onOutput?(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            collected.withLock { $0.errors.append(data) }
            if !data.isEmpty { onErrors?(data) }
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
        while process.isRunning {
            // Cancelled through the progress window, or the task was (Esc while listing).
            if progress?.isCancelled == true || Task.isCancelled {
                process.terminate()
                process.waitUntilExit()
                throw CancellationError()
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        let restOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let restErrors = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let (output, errors) = collected.withLock { ($0.output + restOutput, $0.errors + restErrors) }
        return Output(status: process.terminationStatus, output: output,
                      errors: String(decoding: errors, as: UTF8.self))
    }
}
