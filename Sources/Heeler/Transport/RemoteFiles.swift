import Foundation

/// One entry of a remote directory listing, or the stat of a single path.
struct RemoteFileEntry: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable {
        case file
        case directory
        case symlink
        case other
    }

    let name: String        // last path component
    let path: String        // absolute remote path
    let kind: Kind
    let sizeBytes: UInt64?  // nil when the server omitted it
    let modified: Date?     // nil when the server omitted it

    var id: String { path }
}

/// A whole-file read plus the identity needed for conflict detection on save.
struct RemoteFileSnapshot: Sendable, Equatable {
    let path: String
    let data: Data
    let modified: Date?
    let sizeBytes: UInt64
}

enum RemoteFileError: Error, Equatable {
    case notFound(path: String)
    case permissionDenied(path: String)
    case tooLarge(path: String, sizeBytes: UInt64, limit: Int)
    case failure(message: String)
}
