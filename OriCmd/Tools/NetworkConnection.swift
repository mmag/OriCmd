import Foundation
import NetFS

/// Mounts network shares (smb://, afp://, nfs://, WebDAV) like Finder's
/// "Connect to Server"; macOS asks for credentials when needed.
nonisolated enum NetworkConnection {
    /// Returns the mount point of the share.
    static func mount(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            var requestID: AsyncRequestID?
            let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, nil, nil, &requestID, DispatchQueue.global()) {
                status, _, mountPoints in
                let paths = (mountPoints as? [String]) ?? []
                if status == 0, let path = paths.first {
                    continuation.resume(returning: URL(filePath: path))
                } else {
                    continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO))
                }
            }
            if status != 0 {
                continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO))
            }
        }
    }
}
