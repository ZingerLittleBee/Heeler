import Foundation

@testable import Heeler

/// A path-keyed Host file system with the SFTP semantics Chat relies on:
/// stat follows symlinks and reports nil for a missing path, listings report
/// lstat kinds and filter like the package's `SSHSFTPEntryQuery`, and ranged
/// reads answer `length: nil` for a missing file and empty data at or past
/// its end. Every mutation advances a whole-second modification clock.
actor VirtualHostFiles {
    enum Operation: Hashable, Sendable {
        case status, list, read, home
    }

    private enum Node {
        case file(Data)
        case directory
        case symlink(String)
    }

    let homeDirectory: String
    private var nodes: [String: Node] = ["/": .directory]
    private var modificationTimes: [String: UInt32] = [:]
    private var clock: UInt32 = 1_780_000_000
    private var faults: [Operation: [any Error]] = [:]
    /// Faults for one path, taken before any for the operation as a whole.
    private var pathFaults: [Operation: [(path: String, error: any Error)]] = [:]
    private var readLimit: Int?

    private(set) var reads: [RemoteFileRange] = []
    private(set) var listings: [RemoteFileListingRequest] = []
    private(set) var statuses: [String] = []

    init(home: String = "/home/dev") {
        homeDirectory = home
        nodes[home] = .directory
        var parent = (home as NSString).deletingLastPathComponent
        while parent != "/" {
            nodes[parent] = .directory
            parent = (parent as NSString).deletingLastPathComponent
        }
    }

    // MARK: Mutation

    func write(_ data: Data, at path: String) {
        makeParents(of: path)
        nodes[path] = .file(data)
        touch(path)
    }

    func write(_ text: String, at path: String) {
        write(Data(text.utf8), at: path)
    }

    func append(_ data: Data, to path: String) {
        guard case .file(let existing) = nodes[path] else {
            write(data, at: path)
            return
        }
        nodes[path] = .file(existing + data)
        touch(path)
    }

    func append(_ text: String, to path: String) {
        append(Data(text.utf8), to: path)
    }

    /// Replaces a file's bytes without moving its modification time, as a
    /// rewrite within the same second would.
    func replaceKeepingTime(_ data: Data, at path: String) {
        nodes[path] = .file(data)
    }

    func makeDirectory(_ path: String) {
        makeParents(of: path)
        nodes[path] = .directory
        touch(path)
    }

    func symlink(_ path: String, to target: String) {
        makeParents(of: path)
        nodes[path] = .symlink(target)
        touch(path)
    }

    func remove(_ path: String) {
        nodes[path] = nil
        modificationTimes[path] = nil
    }

    func contents(of path: String) -> Data? {
        guard case .file(let data) = nodes[path] else { return nil }
        return data
    }

    /// Caps every read at `bytes`, as a server sending short reads would.
    func setReadLimit(_ bytes: Int?) {
        readLimit = bytes
    }

    func failNext(_ operation: Operation, with error: any Error, count: Int = 1) {
        faults[operation, default: []] += Array(repeating: error, count: count)
    }

    /// Fails the next `count` stats or reads of `path` alone.
    func failNext(_ operation: Operation, path: String, with error: any Error, count: Int = 1) {
        pathFaults[operation, default: []] += Array(repeating: (path, error), count: count)
    }

    // MARK: Operations

    func home() throws -> String {
        try throwFault(.home)
        return homeDirectory
    }

    func fileStatus(atPath path: String) throws -> RemoteFileStatus? {
        try throwFault(.status, path: path)
        statuses.append(path)
        guard let (resolved, node) = resolve(path) else { return nil }
        return status(of: node, at: resolved)
    }

    func listFiles(_ request: RemoteFileListingRequest) throws -> RemoteFileListing? {
        try throwFault(.list)
        listings.append(request)
        guard let (directory, node) = resolve(request.directory), case .directory = node else {
            return nil
        }
        let prefix = directory == "/" ? "/" : directory + "/"
        let names = nodes.keys
            .filter { $0.hasPrefix(prefix) && $0 != directory }
            .map { String($0.dropFirst(prefix.count)) }
            .filter { !$0.contains("/") }
            .sorted()
        let scanned = Array(names.prefix(request.maximumScanned))
        var matches: [RemoteFileEntry] = []
        for name in scanned {
            let path = prefix + name
            guard let node = nodes[path] else { continue }
            let entry = RemoteFileEntry(name: name, status: status(of: node, at: path))
            guard matchesRequest(entry, request) else { continue }
            matches.append(entry)
        }
        return RemoteFileListing(
            entries: Array(matches.prefix(request.maximumEntries)),
            truncated: matches.count > request.maximumEntries,
            scanIncomplete: names.count > request.maximumScanned)
    }

    func readRange(_ range: RemoteFileRange) throws -> RemoteFileSlice {
        try throwFault(.read, path: range.path)
        reads.append(range)
        guard let (_, node) = resolve(range.path), case .file(let data) = node else {
            return RemoteFileSlice(data: Data(), length: nil)
        }
        let length = UInt64(data.count)
        guard range.offset < length, range.maxBytes > 0 else {
            return RemoteFileSlice(data: Data(), length: length)
        }
        let start = Int(range.offset)
        let count = min(range.maxBytes, readLimit ?? .max, data.count - start)
        return RemoteFileSlice(data: data.subdata(in: start..<(start + count)), length: length)
    }

    func clearRecords() {
        reads = []
        listings = []
        statuses = []
    }

    nonisolated func hostFiles() -> ChatHostFiles {
        ChatHostFiles(
            status: { try await self.fileStatus(atPath: $0) },
            list: { try await self.listFiles($0) },
            read: { try await self.readRange($0) },
            home: { try await self.home() })
    }

    // MARK: Helpers

    private func throwFault(_ operation: Operation, path: String? = nil) throws {
        if let path, var pending = pathFaults[operation], let index = pending.firstIndex(where: { $0.path == path }) {
            let error = pending.remove(at: index).error
            pathFaults[operation] = pending
            throw error
        }
        guard var pending = faults[operation], !pending.isEmpty else { return }
        let error = pending.removeFirst()
        faults[operation] = pending
        throw error
    }

    private func touch(_ path: String) {
        clock += 1
        modificationTimes[path] = clock
    }

    private func makeParents(of path: String) {
        var parent = (path as NSString).deletingLastPathComponent
        var missing: [String] = []
        while parent != "/", nodes[parent] == nil {
            missing.append(parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
        for directory in missing.reversed() {
            nodes[directory] = .directory
            touch(directory)
        }
    }

    /// Follows symlinks (relative targets resolve against the link's
    /// directory) up to a small depth, as a server's STAT would.
    private func resolve(_ path: String, depth: Int = 0) -> (String, Node)? {
        guard depth < 8, let node = nodes[path] else { return nil }
        guard case .symlink(let target) = node else { return (path, node) }
        let absolute = target.hasPrefix("/")
            ? target
            : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target)
        return resolve(absolute, depth: depth + 1)
    }

    private func status(of node: Node, at path: String) -> RemoteFileStatus {
        let time = modificationTimes[path]
        switch node {
        case .file(let data):
            return RemoteFileStatus(kind: .regular, size: UInt64(data.count), modificationTime: time)
        case .directory:
            return RemoteFileStatus(kind: .directory, size: 4_096, modificationTime: time)
        case .symlink(let target):
            return RemoteFileStatus(kind: .symlink, size: UInt64(target.utf8.count), modificationTime: time)
        }
    }

    private func matchesRequest(_ entry: RemoteFileEntry, _ request: RemoteFileListingRequest) -> Bool {
        if !request.kinds.isEmpty {
            guard let kind = entry.status.kind, request.kinds.contains(kind) else { return false }
        }
        if let prefix = request.namePrefix, !entry.name.hasPrefix(prefix) { return false }
        if !request.nameSuffixes.isEmpty,
            !request.nameSuffixes.contains(where: { entry.name.hasSuffix($0) })
        {
            return false
        }
        if let contains = request.nameContains, !entry.name.contains(contains) { return false }
        return true
    }
}
