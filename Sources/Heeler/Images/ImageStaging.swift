import Foundation

struct ImageStageProgress: Sendable, Equatable {
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
        guard Self.isValidAbsoluteHostPath(path) else {
            throw ImageStagingError.invalidRemotePath
        }
        self.path = path
    }

    /// Test and transport implementation convenience. UI code treats the path
    /// as an opaque Host value and never opens it locally.
    var fileURL: URL {
        URL(fileURLWithPath: path)
    }

    private static func isValidAbsoluteHostPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/" else { return false }
        return path.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
                && scalar.properties.generalCategory != .control
        }
    }
}

enum ImageStagingError: Error, Sendable, Equatable {
    case invalidRemotePath
    case invalidPreparedImage
    case localReadFailed
    case remoteTemporaryDirectoryFailed
    case sftpUnavailable
    case permissionEnforcementFailed
    case byteCountMismatch
    case transferFailed
    case cancelled

    var isRetryable: Bool {
        switch self {
        case .transferFailed, .cancelled:
            true
        case .invalidRemotePath, .invalidPreparedImage, .localReadFailed,
            .remoteTemporaryDirectoryFailed, .sftpUnavailable,
            .permissionEnforcementFailed, .byteCountMismatch:
            false
        }
    }
}
