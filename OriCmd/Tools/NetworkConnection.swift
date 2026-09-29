import Foundation
import Network
import NetFS
import os

/// Mounts network shares (smb://, afp://, nfs://, WebDAV) like Finder's
/// "Connect to Server"; macOS asks for credentials when needed.
nonisolated enum NetworkConnection {
    /// Returns the mount point of the share. Cancelling the task cancels the mount.
    static func mount(_ url: URL) async throws -> URL {
        let request = OSAllocatedUnfairLock<AsyncRequestID?>(uncheckedState: nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var requestID: AsyncRequestID?
                let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, nil, nil, &requestID, DispatchQueue.global()) {
                    status, _, mountPoints in
                    let paths = (mountPoints as? [String]) ?? []
                    if status == 0, let path = paths.first {
                        continuation.resume(returning: URL(filePath: path))
                    } else if status == ECANCELED || status == Int32(userCanceledErr) {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO))
                    }
                }
                if status != 0 {
                    continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO))
                } else {
                    request.withLockUnchecked { $0 = requestID }
                }
            }
        } onCancel: {
            if let requestID = request.withLockUnchecked({ $0 }) {
                NetFSMountURLCancel(requestID)
            }
        }
    }

    /// Failures macOS reports itself while mounting (its "There was a problem connecting
    /// to the server" or the login failure).
    static let errorsShownBySystem: Set<POSIXErrorCode> = [
        .ETIMEDOUT, .ECONNREFUSED, .EHOSTDOWN, .EHOSTUNREACH, .ENETUNREACH, .EAUTH, .ENEEDAUTH,
    ]

    /// Whether the server of `url` accepts a connection on its protocol's port within
    /// a few seconds. A wrong address fails here at once, instead of after the long
    /// wait of the mount (and the system's own error message).
    static func serverAnswers(_ url: URL, within timeout: TimeInterval = 5) async -> Bool {
        guard let host = url.host(), !host.isEmpty else { return true }
        // A single-label name ("WINBOX") may be a NetBIOS name the mount resolves and
        // this check cannot: it is left to the mount.
        guard host.contains(".") || host.contains(":") || host == "localhost" else { return true }
        let ports = url.port.flatMap { UInt16(exactly: $0) }.map { [$0] } ?? defaultPorts(for: url.scheme?.lowercased() ?? "")
        guard !ports.isEmpty else { return true }
        return await withTaskGroup(of: Bool.self) { group in
            for port in ports {
                group.addTask { await answers(host: host, port: port, within: timeout) }
            }
            for await answered in group where answered {
                group.cancelAll()
                return true
            }
            return false
        }
    }

    private static func defaultPorts(for scheme: String) -> [UInt16] {
        switch scheme {
        case "smb", "cifs": [445, 139]
        case "afp": [548]
        case "nfs": [2049]
        case "http", "webdav": [80]
        case "https", "webdavs": [443]
        default: []
        }
    }

    /// Whether `host` accepts a connection on `port`. A name that cannot be resolved
    /// counts as answering: the mount knows more ways to find a server than this check.
    /// Cancelling stops the attempt (the other port answered).
    private static func answers(host: String, port: UInt16, within timeout: TimeInterval) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let finished = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let finish: @Sendable (Bool) -> Void = { answered in
                    guard finished.withLock({ done in defer { done = true }; return !done }) else { return }
                    connection.cancel()
                    continuation.resume(returning: answered)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(true)
                    case .waiting(.dns), .failed(.dns): finish(true)
                    // Refused or no route: Network keeps waiting to retry.
                    case .waiting, .failed, .cancelled: finish(false)
                    default: break
                    }
                }
                connection.start(queue: .global())
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}
