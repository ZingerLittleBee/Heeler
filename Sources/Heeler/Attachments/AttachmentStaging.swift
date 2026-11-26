import Foundation

struct AttachmentStageProgress: Sendable, Equatable {
    let transferredBytes: Int64
    let totalBytes: Int64

    init(transferredBytes: Int, totalBytes: Int) {
        self.init(transferredBytes: Int64(transferredBytes), totalBytes: Int64(totalBytes))
    }

    init(transferredBytes: Int64, totalBytes: Int64) {
        self.transferredBytes = transferredBytes
        self.totalBytes = totalBytes
    }

    var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(transferredBytes) / Double(totalBytes)))
    }
}

struct StagedImage: Sendable, Equatable {
    let path: String

    init(path: String) throws {
        guard StagedHostPath.isValid(path) else {
            throw AttachmentStagingError.invalidRemotePath
        }
        self.path = path
    }

    /// Test and transport implementation convenience. UI code treats the path
    /// as an opaque Host value and never opens it locally.
    var fileURL: URL {
        URL(fileURLWithPath: path)
    }

}

struct StagedFile: Sendable, Equatable {
    let path: String

    init(path: String) throws {
        guard StagedHostPath.isValid(path) else {
            throw AttachmentStagingError.invalidRemotePath
        }
        self.path = path
    }

    var fileURL: URL {
        URL(fileURLWithPath: path)
    }
}

private enum StagedHostPath {
    static func isValid(_ path: String) -> Bool {
        guard (path.hasPrefix("/") && path != "/") || RemoteHostPath.isWindowsAbsolute(path) else { return false }
        return path.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
                && scalar.properties.generalCategory != .control
        }
    }
}

enum AttachmentStagingError: Error, Sendable, Equatable {
    case invalidRemotePath
    case invalidPreparedSource
    case localReadFailed
    case remoteTemporaryDirectoryFailed
    case sftpUnavailable
    case permissionEnforcementFailed
    case byteCountMismatch
    case transferFailed
    /// Past what one `terminal.put` takes on a native Windows core Host.
    case exceedsCoreFileLimit
    case cancelled

    var isRetryable: Bool {
        switch self {
        case .transferFailed, .cancelled:
            true
        case .invalidRemotePath, .invalidPreparedSource, .localReadFailed,
            .remoteTemporaryDirectoryFailed, .sftpUnavailable,
            .permissionEnforcementFailed, .byteCountMismatch, .exceedsCoreFileLimit:
            false
        }
    }
}

/// Where a Rex Agent's attachment lands on a native Windows Host (ADR 0056's
/// update of 2026-11-25): SFTP opens `/C:/Users/me/...`, and the Agent reads
/// `C:\Users\me\...`.
enum WindowsStagePath {
    /// The per-connection folder under the account's temp folder, in the form
    /// SFTP opens; `home` is already in that form.
    static func parentDirectory(home: String, suffix: String) -> String {
        RemoteFilePath.join(home, "AppData", "Local", "Temp", "heeler.\(suffix)")
    }

    /// Eight lower-case letters and digits, as `mktemp`'s `heeler.XXXXXXXX`.
    static func randomSuffix() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<8).map { _ in alphabet.randomElement() ?? "x" })
    }

    /// `/C:/a/b` as `C:\a\b`; nil for anything that is not an SFTP drive path.
    static func windowsPath(fromSFTP path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let windows = String(path.dropFirst()).replacingOccurrences(of: "/", with: "\\")
        return RemoteHostPath.isWindowsAbsolute(windows) ? windows : nil
    }
}

/// One stage's steps on a native Windows Host, apart from the SFTP client that
/// runs them: a `heeler.<random>` folder made once per connection, a
/// `stage-<uuid>` folder in it, the file written as `.part`, its size checked,
/// and the `.part` renamed. `parent` is the folder kept for the connection; a
/// kept folder that is gone, cleaned away, is made again once.
struct WindowsStageUpload {
    /// What the steps ask of the Host's SFTP, each a path in the form SFTP opens.
    struct Files: Sendable {
        var makeDirectory: @Sendable (String) async throws -> Void
        /// Writes the file being staged to this path.
        var write: @Sendable (String) async throws -> Void
        var size: @Sendable (String) async throws -> UInt64?
        var rename: @Sendable (_ from: String, _ to: String) async throws -> Void
        var remove: @Sendable (String) async -> Void
    }

    var parent: String?

    /// Stages `filename` under `home`, in the form SFTP opens, and returns the
    /// path the Agent reads. A `.part` left by a failure is removed. A failure
    /// to make the per-connection folder, a size other than `byteCount` and a
    /// path that is no drive path each throw their own error; any other
    /// failure is the Files' own.
    mutating func stage(
        _ filename: String, byteCount: Int64, home: String, files: Files,
        suffix: @Sendable () -> String = { WindowsStagePath.randomSuffix() },
        stageID: @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) async throws -> String {
        var current = parent
        var stageDirectory = ""
        for attempt in 0..<2 {
            if current == nil {
                let made = WindowsStagePath.parentDirectory(home: home, suffix: suffix())
                do {
                    try await files.makeDirectory(made)
                } catch {
                    throw AttachmentStagingError.remoteTemporaryDirectoryFailed
                }
                current = made
            }
            guard let folder = current else { throw AttachmentStagingError.remoteTemporaryDirectoryFailed }
            stageDirectory = "\(folder)/stage-\(stageID())"
            do {
                try await files.makeDirectory(stageDirectory)
                parent = folder
                break
            } catch where attempt == 0 && parent != nil {
                // The kept folder may have been cleaned away; make another once.
                parent = nil
                current = nil
            }
        }
        let finalPath = "\(stageDirectory)/\(filename)"
        guard let windowsPath = WindowsStagePath.windowsPath(fromSFTP: finalPath) else {
            throw AttachmentStagingError.invalidRemotePath
        }
        let partPath = "\(finalPath).part"
        do {
            try await files.write(partPath)
            try Task.checkCancellation()
            guard try await files.size(partPath) == UInt64(byteCount) else {
                throw AttachmentStagingError.byteCountMismatch
            }
            try await files.rename(partPath, finalPath)
        } catch {
            await files.remove(partPath)
            throw error
        }
        return windowsPath
    }
}
