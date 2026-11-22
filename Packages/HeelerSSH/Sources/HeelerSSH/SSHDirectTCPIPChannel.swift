import Foundation

/// A package-owned long-lived direct-tcpip channel: one TCP connection the
/// server makes on the client's behalf, beside the session's other channels.
///
/// It differs from `SSHStreamLocalChannel` only in where the server connects.
/// Native pointers remain inside `SessionDriver`, and each read and write
/// takes the same short turn on it, so many of these can be open at once
/// without any one of them holding the session. A Jump Host's forwarding
/// channel is not one of these: its pump owns its whole session.
public final class SSHDirectTCPIPChannel: Sendable {
    private let id: UInt64
    private let driver: SessionDriver

    init(id: UInt64, driver: SessionDriver) {
        self.id = id
        self.driver = driver
    }

    public func write(_ data: Data, timeout: Duration) async throws {
        try await driver.writeStreamLocal(
            id: id,
            data: data,
            timeout: timeout)
    }

    /// Reads the next available bytes, or nil after orderly remote EOF.
    public func read(
        maximumBytes: Int = 16 * 1024,
        timeout: Duration
    ) async throws -> Data? {
        try await driver.readStreamLocal(
            id: id,
            maximumBytes: maximumBytes,
            timeout: timeout)
    }

    /// Closes only this channel. Idempotent.
    public func close(timeout: Duration) async throws {
        try await driver.closeStreamLocal(id: id, timeout: timeout)
    }

    deinit {
        let id = id
        let driver = driver
        Task { try? await driver.closeStreamLocal(id: id, timeout: .seconds(2)) }
    }
}
