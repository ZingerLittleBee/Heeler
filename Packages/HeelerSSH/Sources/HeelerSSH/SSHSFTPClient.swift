import Foundation
import Synchronization

/// One SFTP subsystem channel owned by an authenticated SSH connection.
///
/// The surface is intentionally limited to Heeler's atomic file-staging needs.
/// Native handles and remote paths never leave `SessionDriver` diagnostics.
public final class SSHSFTPClient: Sendable {
    private let id: UInt64
    private let driver: SessionDriver
    private let closed = Mutex(false)

    init(id: UInt64, driver: SessionDriver) {
        self.id = id
        self.driver = driver
    }

    public func createDirectory(
        at path: String,
        permissions: UInt32,
        timeout: Duration
    ) async throws {
        try await driver.createSFTPDirectory(
            id: id,
            path: path,
            permissions: permissions,
            timeout: timeout)
    }

    public func attributes(at path: String, timeout: Duration) async throws
        -> SSHSFTPAttributes
    {
        try await driver.sftpAttributes(id: id, path: path, timeout: timeout)
    }

    public func setPermissions(
        _ permissions: UInt32,
        at path: String,
        timeout: Duration
    ) async throws {
        try await driver.setSFTPPermissions(
            id: id,
            path: path,
            permissions: permissions,
            timeout: timeout)
    }

    /// Reads one complete optional file without exposing a native read handle.
    /// A missing file is the expected `nil` case; every other SFTP status is
    /// surfaced as a path-free `SSHError`.
    public func readFileIfPresent(
        at path: String,
        timeout: Duration
    ) async throws -> Data? {
        try await driver.readSFTPFileIfPresent(
            id: id,
            path: path,
            timeout: timeout)
    }

    public func openFileForWriting(
        at path: String,
        permissions: UInt32,
        timeout: Duration
    ) async throws -> SSHSFTPFile {
        try await driver.openSFTPFileForWriting(
            sftpID: id,
            path: path,
            permissions: permissions,
            timeout: timeout)
    }

    public func removeFile(at path: String, timeout: Duration) async throws {
        try await driver.removeSFTPFile(id: id, path: path, timeout: timeout)
    }

    /// Removes one exact operation-owned path during failure compensation.
    /// This call ignores caller cancellation, verifies that the path is absent,
    /// and remains bounded by `timeout`.
    public func removeFileForCompensation(
        at path: String,
        timeout: Duration
    ) async throws {
        try await driver.removeSFTPFileForCompensation(
            id: id,
            path: path,
            timeout: timeout)
    }

    public func renameFileAtomically(
        from sourcePath: String,
        to destinationPath: String,
        timeout: Duration
    ) async throws {
        try await driver.renameSFTPFileAtomically(
            id: id,
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            timeout: timeout)
    }

    /// Closes only this SFTP subsystem channel. Idempotent.
    public func close(timeout: Duration) async throws {
        let shouldClose = closed.withLock { closed in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        try await driver.closeSFTP(id: id, timeout: timeout)
    }

    deinit {
        let shouldClose = closed.withLock { closed in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        let id = id
        let driver = driver
        Task { try? await driver.closeSFTP(id: id, timeout: .seconds(2)) }
    }
}

/// One write-only SFTP file handle.
public final class SSHSFTPFile: Sendable {
    private let sftpID: UInt64
    private let fileID: UInt64
    private let driver: SessionDriver
    private let closed = Mutex(false)

    init(sftpID: UInt64, fileID: UInt64, driver: SessionDriver) {
        self.sftpID = sftpID
        self.fileID = fileID
        self.driver = driver
    }

    public func write(_ data: Data, timeout: Duration) async throws {
        try await driver.writeSFTPFile(
            sftpID: sftpID,
            fileID: fileID,
            data: data,
            timeout: timeout)
    }

    /// Closes only this file handle. Idempotent.
    public func close(timeout: Duration) async throws {
        let shouldClose = closed.withLock { closed in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        try await driver.closeSFTPFile(
            sftpID: sftpID,
            fileID: fileID,
            timeout: timeout)
    }

    deinit {
        let shouldClose = closed.withLock { closed in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        let sftpID = sftpID
        let fileID = fileID
        let driver = driver
        Task {
            try? await driver.closeSFTPFile(
                sftpID: sftpID,
                fileID: fileID,
                timeout: .seconds(2))
        }
    }
}
