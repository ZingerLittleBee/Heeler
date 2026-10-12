import HeelerSSH
import Testing

@testable import Heeler

@Suite("Remote files for Chat")
struct RemoteFilesTests {
    @Test(arguments: [
        "/Users/developer/.claude/projects/-Users-developer/e951205e.jsonl",
        "/home/dev/.codex/sessions/2026/10/06/rollout-x.jsonl",
        "/",
        "/a//b/",
        "/a/.hidden/..b/c..",
    ])
    func acceptsAbsolutePathsWithoutDotComponents(path: String) {
        #expect(RemoteFilePath.isAcceptable(path))
    }

    @Test(arguments: [
        "",
        "relative/path.jsonl",
        "~/.claude/projects",
        "/a/../etc/passwd",
        "/a/./b",
        "/a/..",
        "/a/b\u{0}c",
        "/a/b\nc",
        "/a/\u{7F}",
    ])
    func rejectsRelativeTraversingOrControlPaths(path: String) {
        #expect(!RemoteFilePath.isAcceptable(path))
    }

    @Test func rejectsPathsLongerThanTheHostLimit() {
        let atLimit = "/" + String(repeating: "a", count: 4_095)
        #expect(RemoteFilePath.isAcceptable(atLimit))
        #expect(!RemoteFilePath.isAcceptable(atLimit + "a"))
    }

    @Test func joinAddsOneSeparatorPerComponent() {
        #expect(RemoteFilePath.join("/home/dev", ".claude", "projects") == "/home/dev/.claude/projects")
        #expect(RemoteFilePath.join("/", "tmp") == "/tmp")
        #expect(RemoteFilePath.join("/home/dev/") == "/home/dev/")
    }

    @Test func packageStatusAndListingMapOntoTransportTypes() {
        let status = RemoteFileStatus(
            SSHSFTPFileStatus(kind: .symlink, size: 12, modificationTime: 1_780_000_000))
        #expect(status == RemoteFileStatus(kind: .symlink, size: 12, modificationTime: 1_780_000_000))
        #expect(RemoteFileStatus(SSHSFTPFileStatus(kind: nil, size: nil, modificationTime: nil))
            == RemoteFileStatus(kind: nil, size: nil))

        let listing = RemoteFileListing(
            SSHSFTPEntryListing(
                entries: [
                    SSHSFTPEntry(
                        name: "a.jsonl",
                        status: SSHSFTPFileStatus(kind: .regular, size: 3, modificationTime: 7)),
                ],
                truncated: true,
                scanIncomplete: false))
        #expect(listing.entries == [
            RemoteFileEntry(
                name: "a.jsonl",
                status: RemoteFileStatus(kind: .regular, size: 3, modificationTime: 7)),
        ])
        #expect(listing.truncated)
        #expect(!listing.scanIncomplete)

        for kind in [RemoteFileKind.regular, .directory, .symlink, .other] {
            #expect(RemoteFileKind(SSHSFTPEntryKind(kind)) == kind)
        }
    }
}
