import Foundation
import HeelerSSH

// Conversions between the package's SFTP types and the app's transport-neutral
// ones, so Chat code never imports the SSH library (ADR 0011).

extension RemoteFileKind {
    init(_ kind: SSHSFTPEntryKind) {
        switch kind {
        case .regular: self = .regular
        case .directory: self = .directory
        case .symlink: self = .symlink
        case .other: self = .other
        }
    }
}

extension SSHSFTPEntryKind {
    init(_ kind: RemoteFileKind) {
        switch kind {
        case .regular: self = .regular
        case .directory: self = .directory
        case .symlink: self = .symlink
        case .other: self = .other
        }
    }
}

extension RemoteFileStatus {
    init(_ status: SSHSFTPFileStatus) {
        self.init(
            kind: status.kind.map(RemoteFileKind.init),
            size: status.size,
            modificationTime: status.modificationTime)
    }
}

extension RemoteFileListing {
    init(_ listing: SSHSFTPEntryListing) {
        self.init(
            entries: listing.entries.map {
                RemoteFileEntry(name: $0.name, status: RemoteFileStatus($0.status))
            },
            truncated: listing.truncated,
            scanIncomplete: listing.scanIncomplete)
    }
}
