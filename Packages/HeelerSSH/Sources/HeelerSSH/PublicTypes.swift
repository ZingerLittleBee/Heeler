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

public enum SSHError: Error, Sendable, Equatable {
    case invalidEndpoint
    case connectionFailed
    case algorithmNegotiationFailed
    case authenticationFailed
    case timedOut
    case cancelled
    case channelFailed
    case connectionInvalidated
}
