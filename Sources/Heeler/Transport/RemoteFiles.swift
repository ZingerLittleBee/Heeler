import Foundation

/// The operating system family a Host's SSH server runs on. Chat reads Agent
/// transcripts through POSIX paths only, so it needs to know before offering
/// itself; the transport learns the answer while it connects.
enum HostPlatform: Sendable, Equatable {
    case posix
    case nativeWindows
}

/// What kind of file system object a Host path is.
enum RemoteFileKind: Sendable, Hashable {
    case regular
    case directory
    case symlink
    case other
}

/// The metadata SFTP reports for one Host path. Any field may be missing
/// when the server omits it. There is no inode, so a follower checks file
/// identity by content, and the modification time is whole seconds.
struct RemoteFileStatus: Sendable, Equatable {
    let kind: RemoteFileKind?
    let size: UInt64?
    let modificationTime: UInt32?

    init(kind: RemoteFileKind?, size: UInt64?, modificationTime: UInt32? = nil) {
        self.kind = kind
        self.size = size
        self.modificationTime = modificationTime
    }
}

/// One name in a Host directory, with the attributes the listing reported.
/// A symlink lists as `.symlink`; `fileStatus(atPath:)` follows it.
struct RemoteFileEntry: Sendable, Equatable {
    let name: String
    let status: RemoteFileStatus

    init(name: String, status: RemoteFileStatus) {
        self.name = name
        self.status = status
    }
}

/// Which entries of one directory a listing keeps. The Host filters while it
/// reads, so a directory of thousands of rollouts costs only the matches.
struct RemoteFileListingRequest: Sendable, Equatable {
    let directory: String
    /// Kinds to keep; empty keeps every kind.
    let kinds: Set<RemoteFileKind>
    let namePrefix: String?
    /// The name must end with one of these; empty accepts any ending.
    let nameSuffixes: [String]
    let nameContains: String?
    /// At most this many matches come back, sorted by name.
    let maximumEntries: Int
    /// The read stops after this many names.
    let maximumScanned: Int

    init(
        directory: String,
        kinds: Set<RemoteFileKind> = [],
        namePrefix: String? = nil,
        nameSuffixes: [String] = [],
        nameContains: String? = nil,
        maximumEntries: Int = 500,
        maximumScanned: Int = 5_000
    ) {
        self.directory = directory
        self.kinds = kinds
        self.namePrefix = namePrefix
        self.nameSuffixes = nameSuffixes
        self.nameContains = nameContains
        self.maximumEntries = maximumEntries
        self.maximumScanned = maximumScanned
    }
}

/// The entries of one directory that matched a listing request.
struct RemoteFileListing: Sendable, Equatable {
    let entries: [RemoteFileEntry]
    /// More entries matched than the request's `maximumEntries`.
    let truncated: Bool
    /// The directory was not read to its end, so a missing match proves
    /// nothing.
    let scanIncomplete: Bool

    init(entries: [RemoteFileEntry], truncated: Bool = false, scanIncomplete: Bool = false) {
        self.entries = entries
        self.truncated = truncated
        self.scanIncomplete = scanIncomplete
    }
}

/// Rules for the paths Chat sends to a Host. A transcript path is built from
/// a home directory and identifiers the Agent reported, so it is checked in
/// the app before any channel opens: absolute, no `.` or `..` components,
/// no NUL or control characters.
enum RemoteFilePath {
    static func isAcceptable(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096 else { return false }
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return false
        }
        return !path.split(separator: "/", omittingEmptySubsequences: true)
            .contains(where: { $0 == "." || $0 == ".." })
    }

    /// Joins path components onto an absolute directory.
    static func join(_ directory: String, _ components: String...) -> String {
        var path = directory
        for component in components {
            if !path.hasSuffix("/") { path += "/" }
            path += component
        }
        return path
    }
}
