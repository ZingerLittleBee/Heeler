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

public struct SSHSFTPAttributes: Sendable, Equatable {
    public let size: UInt64?
    public let permissions: UInt32?
}

/// One entry of an SFTP directory listing. Only directories are surfaced;
/// regular files never leave `SessionDriver`.
public struct SSHSFTPDirectoryEntry: Sendable, Equatable, Hashable {
    public let name: String
    public let isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

/// Directories-only result of listing one remote directory. Entries arrive
/// sorted by name; `truncated` reports that more directories exist than fit
/// in `maximumEntries`.
public struct SSHSFTPDirectoryListing: Sendable, Equatable {
    /// Hard cap on surfaced entries: one screen of remote browsing, not a
    /// full recursive walk. The readdir loop stops appending past this.
    public static let maximumEntries = 500

    public let entries: [SSHSFTPDirectoryEntry]
    public let truncated: Bool

    public init(entries: [SSHSFTPDirectoryEntry], truncated: Bool) {
        self.entries = entries
        self.truncated = truncated
    }

    /// Filters raw readdir output down to the surfaced result: drops `.`
    /// and `..`, keeps directories only (dot-directories included), sorts
    /// by name, and caps at `maximumEntries`.
    public init(rawEntries: [(name: String, isDirectory: Bool)]) {
        var directories: [SSHSFTPDirectoryEntry] = []
        var truncated = false
        for raw in rawEntries {
            guard raw.name != ".", raw.name != "..", raw.isDirectory else {
                continue
            }
            if directories.count == Self.maximumEntries {
                truncated = true
                break
            }
            directories.append(
                SSHSFTPDirectoryEntry(name: raw.name, isDirectory: true))
        }
        self.entries = directories.sorted { $0.name < $1.name }
        self.truncated = truncated
    }
}
