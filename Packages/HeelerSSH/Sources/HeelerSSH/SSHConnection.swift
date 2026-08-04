import Foundation

enum SSHConnectionTeardownStep: Sendable, Equatable {
    case targetSession
    case forwardingChannel
    case jumpSession
}

public final class SSHConnection: Sendable {
    public let hostKey: SSHHostKey

    private let driver: SessionDriver
    private let parent: SSHConnection?
    private let byteTransport: (any SSHByteTransport)?
    private let teardownObserver: (@Sendable (SSHConnectionTeardownStep) -> Void)?

    private init(
        driver: SessionDriver,
        hostKey: SSHHostKey,
        parent: SSHConnection? = nil,
        byteTransport: (any SSHByteTransport)? = nil,
        teardownObserver: (@Sendable (SSHConnectionTeardownStep) -> Void)? = nil
    ) {
        self.driver = driver
        self.hostKey = hostKey
        self.parent = parent
        self.byteTransport = byteTransport
        self.teardownObserver = teardownObserver
    }

    public static func connect(
        to endpoint: SSHEndpoint,
        timeout: Duration
    ) async throws -> SSHConnection {
        let driver = SessionDriver()
        let hostKey = try await driver.handshake(endpoint: endpoint, timeout: timeout)
        return SSHConnection(driver: driver, hostKey: hostKey)
    }

    /// Opens an SSH connection to `endpoint` through this authenticated Jump
    /// Host. The returned connection owns both hops and closes them in target,
    /// forwarding-channel, Jump Host order.
    public func connectThrough(
        to endpoint: SSHEndpoint,
        timeout: Duration
    ) async throws -> SSHConnection {
        try await connectThrough(
            to: endpoint,
            timeout: timeout,
            teardownObserver: nil)
    }

    func connectThrough(
        to endpoint: SSHEndpoint,
        timeout: Duration,
        teardownObserver: (@Sendable (SSHConnectionTeardownStep) -> Void)?
    ) async throws -> SSHConnection {
        let transport = try await driver.openDirectTCPIP(
            endpoint: endpoint,
            timeout: timeout)
        let targetDriver = SessionDriver()
        do {
            let hostKey = try await targetDriver.handshake(
                transport: transport,
                timeout: timeout)
            return SSHConnection(
                driver: targetDriver,
                hostKey: hostKey,
                parent: self,
                byteTransport: transport,
                teardownObserver: teardownObserver)
        } catch {
            await targetDriver.invalidate()
            transport.abort()
            try? await transport.close(timeout: .seconds(2))
            try? await close(timeout: .seconds(2))
            throw error
        }
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

    /// Opens one SSH session channel, sends exactly one newline-terminated
    /// input line, reads one bounded newline-terminated stdout response, and
    /// closes the channel. This is for forced-command request/response
    /// protocols whose process lifetime must not control the caller's bound.
    public func executeResponseLine(
        _ command: String,
        input: Data,
        maximumResponseBytes: Int,
        timeout: Duration
    ) async throws -> Data {
        try await driver.executeResponseLine(
            command: command,
            input: input,
            maximumResponseBytes: maximumResponseBytes,
            timeout: timeout)
    }

    /// Opens one SSH session channel, requests the configured PTY, and then
    /// executes `command` directly. No login shell or shell request is exposed
    /// to the caller's terminal stream.
    public func openPTY(
        command: String,
        terminal: String = "xterm-256color",
        columns: Int,
        rows: Int,
        timeout: Duration
    ) async throws -> SSHPTYChannel {
        try await driver.openPTY(
            command: command,
            terminal: terminal,
            columns: columns,
            rows: rows,
            timeout: timeout)
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

    /// Opens one long-lived direct-streamlocal channel. The returned handle
    /// owns only that channel; closing it leaves this SSH connection reusable
    /// when native teardown succeeds.
    public func openStreamLocal(
        socketPath: String,
        timeout: Duration
    ) async throws -> SSHStreamLocalChannel {
        try await driver.openStreamLocal(
            socketPath: socketPath,
            timeout: timeout)
    }

    /// Opens the package's deliberately small SFTP surface on one SSH session
    /// channel. Closing the returned client leaves this connection reusable.
    public func openSFTP(timeout: Duration) async throws -> SSHSFTPClient {
        try await driver.openSFTP(timeout: timeout)
    }

    /// Whether this session still has a live native connection that can
    /// safely admit another operation. An uncertain channel outcome makes
    /// this false before the app can reuse the connection.
    public var isConnected: Bool {
        get async { await driver.isReusable }
    }

#if DEBUG
    public func delayNextSFTPWriteForTesting(_ delay: Duration) async {
        await driver.delayNextSFTPWriteForTesting(delay)
    }

    public var isSFTPWriteDelayedForTesting: Bool {
        get async { await driver.isSFTPWriteDelayedForTesting }
    }

    public func holdNextSessionWaitForTesting(
        _ hold: @escaping @Sendable () async -> Void
    ) async {
        await driver.holdNextSessionWaitForTesting(hold)
    }
#endif

    public func close(timeout: Duration) async throws {
        var firstError: (any Error)?
        do {
            try await driver.close(timeout: timeout)
        } catch {
            firstError = error
        }
        if byteTransport != nil { teardownObserver?(.targetSession) }
        if let byteTransport {
            do {
                try await byteTransport.close(timeout: timeout)
            } catch {
                if firstError == nil { firstError = error }
            }
            teardownObserver?(.forwardingChannel)
        }
        if let parent {
            do {
                try await parent.close(timeout: timeout)
            } catch {
                if firstError == nil { firstError = error }
            }
            teardownObserver?(.jumpSession)
        }
        if let firstError { throw firstError }
    }

    deinit {
        let driver = driver
        let byteTransport = byteTransport
        let parent = parent
        Task {
            await driver.invalidate()
            byteTransport?.abort()
            if let parent { try? await parent.close(timeout: .seconds(2)) }
        }
    }
}
