import Foundation

/// The Host file operations Chat reads transcripts through.
///
/// Like `SessionFileReader`, each closure is bound late: it reaches whichever
/// transport the Host has installed when it runs, so a reconnect never leaves
/// an open Chat holding a dead transport. Errors are the transport's Chat
/// errors (`.hostFileTimedOut`, `.hostFileUnreadable`), never a redial.
struct ChatHostFiles: Sendable {
    /// Stats a path, following symlinks; nil when it does not exist.
    let status: @Sendable (_ path: String) async throws -> RemoteFileStatus?
    /// Lists a directory's matching entries; nil when it does not exist.
    let list: @Sendable (_ request: RemoteFileListingRequest) async throws -> RemoteFileListing?
    let read: @Sendable (_ range: RemoteFileRange) async throws -> RemoteFileSlice
    let home: @Sendable () async throws -> String

    init(
        status: @escaping @Sendable (_ path: String) async throws -> RemoteFileStatus?,
        list: @escaping @Sendable (_ request: RemoteFileListingRequest) async throws -> RemoteFileListing?,
        read: @escaping @Sendable (_ range: RemoteFileRange) async throws -> RemoteFileSlice,
        home: @escaping @Sendable () async throws -> String
    ) {
        self.status = status
        self.list = list
        self.read = read
        self.home = home
    }

    /// Reads `[start, end)` in pieces of at most `chunk` bytes. Nil when the
    /// file is gone; shorter than asked when the file ends first.
    func read(path: String, from start: UInt64, to end: UInt64, chunk: Int) async throws -> Data? {
        var data = Data()
        var offset = start
        while offset < end {
            let slice = try await read(
                RemoteFileRange(
                    path: path, offset: offset,
                    maxBytes: Int(min(UInt64(chunk), end - offset))))
            guard slice.length != nil else { return nil }
            guard !slice.data.isEmpty else { break }
            data.append(slice.data)
            offset += UInt64(slice.data.count)
        }
        return data
    }

    /// The file's first line, read in growing pieces up to `limit` bytes.
    /// Nil when the file is gone; `.tooLong` when no newline came within
    /// the limit; `.unterminated` for a file that ends without one.
    func firstLine(of path: String, initialBytes: Int, limit: Int) async throws -> FirstLine? {
        var length = initialBytes
        while true {
            guard let data = try await read(path: path, from: 0, to: UInt64(length), chunk: 256 << 10)
            else { return nil }
            if let newline = data.firstIndex(of: 0x0A) {
                return .line(data[data.startIndex..<newline])
            }
            if data.count < length { return .unterminated }
            if length >= limit { return .tooLong }
            length = min(limit, length * 8)
        }
    }

    enum FirstLine: Equatable, Sendable {
        case line(Data)
        case unterminated
        case tooLong
    }
}
