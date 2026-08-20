import Foundation

public struct SSHEndpoint: Sendable, Equatable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16 = 22) {
        self.host = host
        self.port = port
    }
}

public struct SSHHostKey: Sendable, Equatable {
    public let algorithm: String
    public let key: Data

    public init(algorithm: String, key: Data) {
        self.algorithm = algorithm
        self.key = key
    }
}

public struct SSHExecResult: Sendable, Equatable {
    public let stdout: Data
    public let stderr: Data
    public let exitStatus: Int32
    public let reachedEOF: Bool

    public init(stdout: Data, stderr: Data, exitStatus: Int32, reachedEOF: Bool) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
        self.reachedEOF = reachedEOF
    }
}

/// Synchronously signs the SSH authentication challenge supplied by libssh2.
/// The private key remains owned by the caller; the package receives only the
/// resulting signature bytes.
public typealias SSHSigningClosure = @Sendable (Data) throws -> Data

public enum SSHError: Error, Sendable, Equatable {
    case invalidEndpoint
    case connectionFailed
    case algorithmNegotiationFailed
    case authenticationFailed
    case timedOut
    case cancelled
    case channelFailed
    case forwardingDenied
    case targetUnreachable
    case streamLocalOpenFailed
    case unexpectedEOF
    case responseTooLarge(limit: Int)
    case sftpUnavailable
    case sftpFailure(status: UInt64)
    case connectionInvalidated
}


/// The POSIX file kind encoded in SFTP permission bits when the server sends
/// them. A missing permission attribute leaves the kind unknown.
public enum SSHSFTPFileType: Sendable, Equatable {
    /// A regular file.
    case file
    /// A directory.
    case directory
    /// A symbolic link.
    case symlink
    /// A FIFO, device, socket, or server-specific file kind.
    case other
}
/// Attributes the SFTP server returned for one remote path.
public struct SSHSFTPAttributes: Sendable, Equatable {
    public let size: UInt64?
    /// POSIX mode bits, excluding the file-kind bits for compatibility with
    /// callers that compare this value to a permission mode such as `0o600`.
    public let permissions: UInt32?
    /// The server-reported modification time, when it sent one.
    public let modificationDate: Date?
    /// The file kind derived from the server's full POSIX mode, when present.
    public let fileType: SSHSFTPFileType?

    /// Whether the server identified this entry as a directory.
    public var isDirectory: Bool { fileType == .directory }
}

/// One named entry returned from an SFTP directory listing.
public struct SSHSFTPDirectoryEntry: Sendable, Equatable {
    /// The direct child's unescaped remote filename.
    public let name: String
    /// Attributes returned in the same SFTP directory response as `name`.
    public let attributes: SSHSFTPAttributes
}
