import Foundation

/// A package-owned long-lived direct-streamlocal channel.
///
/// Native pointers remain inside `SessionDriver`. Each read and write takes a
/// short turn on that driver, so an idle stream never monopolizes the SSH
/// session while ordinary channels make progress.
///
/// That holds in one direction only. An ordinary RPC — `execute`,
/// `executeResponseLine`, `exchangeStreamLocal` — takes the same operation
/// mutex and holds it for its entire round trip, so a read here queues behind
/// one until it completes or its own deadline ends it. The effect is delay
/// rather than failure: the stream is not torn down, it simply makes no
/// progress meanwhile. See #130.
public final class SSHStreamLocalChannel: Sendable {
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
