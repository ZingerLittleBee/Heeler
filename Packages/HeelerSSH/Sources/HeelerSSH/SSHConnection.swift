import Foundation

public final class SSHConnection: Sendable {
    public let hostKey: SSHHostKey

    private let driver: SessionDriver

    private init(driver: SessionDriver, hostKey: SSHHostKey) {
        self.driver = driver
        self.hostKey = hostKey
    }

    public static func connect(
        to endpoint: SSHEndpoint,
        timeout: Duration
    ) async throws -> SSHConnection {
        let driver = SessionDriver()
        let hostKey = try await driver.handshake(endpoint: endpoint, timeout: timeout)
        return SSHConnection(driver: driver, hostKey: hostKey)
    }

    public func authenticate(
        username: String,
        password: String,
        timeout: Duration
    ) async throws {
        try await driver.authenticate(
            username: username,
            password: password,
            timeout: timeout)
    }

    public func authenticate(
        username: String,
        publicKey: Data,
        signer: @escaping SSHSigningClosure,
        timeout: Duration
    ) async throws {
        try await driver.authenticate(
            username: username,
            publicKey: publicKey,
            signer: signer,
            timeout: timeout)
    }

    public func execute(
        _ command: String,
        input: Data = Data(),
        timeout: Duration
    ) async throws -> SSHExecResult {
        try await driver.execute(command: command, input: input, timeout: timeout)
    }

    /// Opens one direct-streamlocal channel, writes one request, reads one
    /// newline-terminated response, and closes the channel. Every call owns a
    /// fresh channel to preserve one-request-per-socket protocols.
    public func exchangeStreamLocal(
        socketPath: String,
        request: Data,
        maximumResponseBytes: Int = 1_048_576,
        timeout: Duration
    ) async throws -> Data {
        try await driver.exchangeStreamLocal(
            socketPath: socketPath,
            request: request,
            maximumResponseBytes: maximumResponseBytes,
            timeout: timeout)
    }

    public func close(timeout: Duration) async throws {
        try await driver.close(timeout: timeout)
    }

    deinit {
        let driver = driver
        Task { await driver.invalidate() }
    }
}
