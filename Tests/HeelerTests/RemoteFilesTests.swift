import HeelerSSH
import Testing

@testable import Heeler

struct RemoteFilesTests {
    @Test("SFTP statuses retain file-specific failures")
    func mapsSFTPStatusesToRemoteFileErrors() {
        let path = "/workspace/README.md"

        #expect(
            HeelerSSHTransport.remoteFileErrorForTesting(
                path: path,
                error: SSHError.sftpFailure(status: 2)) as? RemoteFileError
                == .notFound(path: path))
        #expect(
            HeelerSSHTransport.remoteFileErrorForTesting(
                path: path,
                error: SSHError.sftpFailure(status: 10)) as? RemoteFileError
                == .notFound(path: path))
        #expect(
            HeelerSSHTransport.remoteFileErrorForTesting(
                path: path,
                error: SSHError.sftpFailure(status: 3)) as? RemoteFileError
                == .permissionDenied(path: path))
        #expect(
            HeelerSSHTransport.remoteFileErrorForTesting(
                path: path,
                error: SSHError.sftpFailure(status: 4)) as? RemoteFileError
                == .failure(message: "SFTP status 4."))
    }

    @Test("directory entries keep dotfiles and sort directories before files")
    func sortsRemoteDirectoryEntries() {
        let entries = [
            RemoteFileEntry(
                name: "Zebra.swift",
                path: "/workspace/Zebra.swift",
                kind: .file,
                sizeBytes: nil,
                modified: nil),
            RemoteFileEntry(
                name: "zoo",
                path: "/workspace/zoo",
                kind: .directory,
                sizeBytes: nil,
                modified: nil),
            RemoteFileEntry(
                name: ".editorconfig",
                path: "/workspace/.editorconfig",
                kind: .file,
                sizeBytes: nil,
                modified: nil),
            RemoteFileEntry(
                name: "Projects",
                path: "/workspace/Projects",
                kind: .directory,
                sizeBytes: nil,
                modified: nil),
            RemoteFileEntry(
                name: "alpha.swift",
                path: "/workspace/alpha.swift",
                kind: .file,
                sizeBytes: nil,
                modified: nil),
        ]

        #expect(
            HeelerSSHTransport.sortedRemoteFileEntriesForTesting(entries).map(\.name)
                == ["Projects", "zoo", ".editorconfig", "alpha.swift", "Zebra.swift"])
    }
}
