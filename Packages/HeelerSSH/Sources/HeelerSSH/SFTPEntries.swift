import Foundation

/// What kind of file system object an SFTP entry is.
public enum SSHSFTPEntryKind: Sendable, Hashable {
    case regular
    case directory
    case symlink
    case other
}

/// The metadata SFTP version 3 reports for one path.
///
/// Each field is optional because a server may omit any attribute. Version 3
/// carries no inode, so identity checks have to rest on content, and the
/// modification time is whole seconds since 1970.
public struct SSHSFTPFileStatus: Sendable, Equatable {
    /// Nil when the server omitted the permission bits that carry the type.
    public let kind: SSHSFTPEntryKind?
    public let size: UInt64?
    public let modificationTime: UInt32?

    public init(kind: SSHSFTPEntryKind?, size: UInt64?, modificationTime: UInt32?) {
        self.kind = kind
        self.size = size
        self.modificationTime = modificationTime
    }

    /// Reads the type from `permissions` (`S_IFMT` bits).
    init(permissions: UInt?, size: UInt64?, modificationTime: UInt?) {
        let kind: SSHSFTPEntryKind? = permissions.map { permissions in
            switch permissions & 0o170000 {
            case 0o100000: .regular
            case 0o040000: .directory
            case 0o120000: .symlink
            default: .other
            }
        }
        self.init(
            kind: kind,
            size: size,
            modificationTime: modificationTime.map { UInt32(truncatingIfNeeded: $0) })
    }
}

/// One name in a directory and the attributes readdir reported for it.
/// OpenSSH reports `lstat` attributes here, so a symlink reads as `.symlink`.
public struct SSHSFTPEntry: Sendable, Equatable {
    public let name: String
    public let status: SSHSFTPFileStatus

    public init(name: String, status: SSHSFTPFileStatus) {
        self.name = name
        self.status = status
    }
}

/// Which entries a listing keeps. Filtering happens while the directory is
/// read, so a directory of thousands of files costs memory only for the
/// entries that match.
public struct SSHSFTPEntryQuery: Sendable, Equatable {
    /// Hard ceilings on what a caller may ask for.
    public static let entryLimit = 1_000
    public static let scanLimit = 20_000

    /// Kinds to keep; empty keeps every kind. An entry whose kind the server
    /// did not report matches only an empty set.
    public var kinds: Set<SSHSFTPEntryKind>
    public var namePrefix: String?
    /// The name must end with one of these; empty accepts any ending.
    public var nameSuffixes: [String]
    public var nameContains: String?
    /// At most this many matches are returned (1...1,000).
    public var maximumEntries: Int
    /// The read stops after this many names (1...20,000).
    public var maximumScanned: Int

    public init(
        kinds: Set<SSHSFTPEntryKind> = [],
        namePrefix: String? = nil,
        nameSuffixes: [String] = [],
        nameContains: String? = nil,
        maximumEntries: Int = 500,
        maximumScanned: Int = 5_000
    ) {
        self.kinds = kinds
        self.namePrefix = namePrefix
        self.nameSuffixes = nameSuffixes
        self.nameContains = nameContains
        self.maximumEntries = min(max(maximumEntries, 1), Self.entryLimit)
        self.maximumScanned = min(max(maximumScanned, 1), Self.scanLimit)
    }

    /// Whether `entry` belongs in the listing. `.` and `..` never do.
    public func matches(_ entry: SSHSFTPEntry) -> Bool {
        let name = entry.name
        guard name != ".", name != ".." else { return false }
        if !kinds.isEmpty {
            guard let kind = entry.status.kind, kinds.contains(kind) else { return false }
        }
        if let namePrefix, !name.hasPrefix(namePrefix) { return false }
        if !nameSuffixes.isEmpty, !nameSuffixes.contains(where: { name.hasSuffix($0) }) {
            return false
        }
        if let nameContains, !name.contains(nameContains) { return false }
        return true
    }
}

/// The entries of one directory that matched a query.
public struct SSHSFTPEntryListing: Sendable, Equatable {
    /// Matches sorted by name, at most `maximumEntries` of them.
    public let entries: [SSHSFTPEntry]
    /// More entries matched than the query's `maximumEntries`.
    public let truncated: Bool
    /// The directory was not read to its end: the read stopped at
    /// `maximumScanned`, or the server sent a batch of names this client
    /// could not decode and the rest of that batch was lost.
    public let scanIncomplete: Bool

    public init(entries: [SSHSFTPEntry], truncated: Bool, scanIncomplete: Bool) {
        self.entries = entries
        self.truncated = truncated
        self.scanIncomplete = scanIncomplete
    }

    /// Sorts the matches by name and caps them at the query's limit.
    public init(matches: [SSHSFTPEntry], query: SSHSFTPEntryQuery, scanIncomplete: Bool) {
        let sorted = matches.sorted { $0.name < $1.name }
        self.init(
            entries: Array(sorted.prefix(query.maximumEntries)),
            truncated: sorted.count > query.maximumEntries,
            scanIncomplete: scanIncomplete)
    }
}
