import Foundation

/// A package-owned SSH session channel with a PTY and one directly executed
/// remote command.
///
/// Native pointers remain inside `SessionDriver`. Reads, writes, and resizes
/// take short turns on the driver so the live terminal does not monopolize the
/// SSH session while other channels make progress.
///
/// Ordinary RPCs — `execute`, `executeResponseLine`, `exchangeStreamLocal` —
/// take the same turns after the channel is established. A live terminal keeps
/// moving while one of those waits for its remote response; a cancelled or
/// timed-out write either drains the packet it owns or invalidates the session
/// rather than leaving the next caller spun on a stranded send. See #130.
public final class SSHPTYChannel: Sendable {
    private let id: UInt64
    private let driver: SessionDriver

    init(id: UInt64, driver: SessionDriver) {
        self.id = id
        self.driver = driver
    }

    public func write(_ data: Data, timeout: Duration) async throws {
        try await driver.writePTY(id: id, data: data, timeout: timeout)
    }

    /// Reads merged terminal output, or nil after orderly remote EOF.
    public func read(
        maximumBytes: Int = 16 * 1024,
        timeout: Duration
    ) async throws -> Data? {
        try await driver.readPTY(id: id, maximumBytes: maximumBytes, timeout: timeout)
    }

    public func resize(columns: Int, rows: Int, timeout: Duration) async throws {
        try await driver.resizePTY(
            id: id,
            columns: columns,
            rows: rows,
            timeout: timeout)
    }

    /// Completes the close handshake and returns the remote status after
    /// `read` has reported EOF.
    public func exitStatus(timeout: Duration) async throws -> Int32 {
        try await driver.ptyExitStatus(id: id, timeout: timeout)
    }

    /// Closes only this channel. Idempotent.
    public func close(timeout: Duration) async throws {
        try await driver.closePTY(id: id, timeout: timeout)
    }

    deinit {
        let id = id
        let driver = driver
        Task { try? await driver.closePTY(id: id, timeout: .seconds(2)) }
    }
}
