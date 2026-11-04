import Foundation

/// Finds a Grok Build session's transcript, `<group>/<id>/updates.jsonl`
/// under `~/.grok/sessions`. A custom `GROK_HOME` lives in the Agent's
/// environment, which herdr does not report, so it is not searched.
///
/// The group names the directory the session started in, so the Agent's
/// directories are tried first: the directory percent-encoded, or for a name
/// past 255 bytes a `<slug>-<16 hex>` group whose `.cwd` file names the
/// directory. A session forked into a worktree, or started there with
/// `/new`, files under the worktree's group while herdr still reports the
/// pane's directory, so the other groups follow, worktrees first, within a
/// budget. A file counts only when its head names the session: a fork's
/// copied records keep their parent's `eventId`, never its `sessionId`.
struct GrokTranscriptLocator: Sendable {
    enum Failure: Error, Equatable, Sendable {
        /// No group holds the session's file. `searchedAll` is false when a
        /// listing was cut short, the budget ran out, or the session's folder
        /// is there without its file yet: Grok writes it next.
        case notFound(searchedAll: Bool)
        /// The session's folder holds another session's records.
        case mismatched
    }

    /// The longest group name Grok writes before it falls back to a slug.
    static let maximumGroupNameBytes = 255
    /// The first record names the session within about 110 bytes.
    private static let headLength: UInt64 = 4 << 10

    let files: ChatHostFiles
    /// The most groups looked into per search, like Pi's `directoryBudget`.
    var groupBudget = 200

    func locate(sessionID: String, directories: [String]) async throws -> Result<String, Failure> {
        guard ConversationReference.lowercaseUUIDv7(sessionID) != nil else { return .failure(.mismatched) }
        let home = try await files.home()
        let root = RemoteFilePath.join(home, ".grok", "sessions")
        var tried = Set<String>()
        var searchedAll = true
        var sawMismatch = false

        /// Looks into one group; a result ends the search.
        func attempt(_ group: String) async throws -> Result<String, Failure>? {
            guard tried.insert(group).inserted else { return nil }
            let folder = RemoteFilePath.join(root, group, sessionID)
            guard RemoteFilePath.isAcceptable(folder) else { return nil }
            switch try await look(into: folder, sessionID: sessionID) {
            case .found(let path): return .success(path)
            case .notWritten: return .failure(.notFound(searchedAll: false))
            case .mismatched: sawMismatch = true
            case .absent: break
            }
            return nil
        }

        for directory in directories where RemoteFilePath.isAcceptable(directory) {
            if let group = Self.groupName(forDirectory: directory) {
                if let result = try await attempt(group) { return result }
                continue
            }
            let slug = Self.slug(forDirectory: directory)
            let listing = try await files.list(
                RemoteFileListingRequest(directory: root, kinds: [.directory], namePrefix: slug + "-"))
            searchedAll = searchedAll && Self.isComplete(listing)
            for entry in listing?.entries ?? [] where Self.isSlugGroup(entry.name, slug: slug) {
                guard try await cwdFile(of: RemoteFilePath.join(root, entry.name), names: directory) else { continue }
                // Grok keeps one group per directory.
                if let result = try await attempt(entry.name) { return result }
                break
            }
        }

        // Every other group, worktrees first.
        let listing = try await files.list(RemoteFileListingRequest(directory: root, kinds: [.directory]))
        searchedAll = searchedAll && Self.isComplete(listing)
        let names = (listing?.entries ?? []).map(\.name)
        let worktrees = Self.groupName(forDirectory: RemoteFilePath.join(home, ".grok", "worktrees") + "/")
        let isWorktree = { (name: String) in worktrees.map { name.hasPrefix($0) } ?? false }
        for name in names.filter(isWorktree) + names.filter({ !isWorktree($0) }) where !tried.contains(name) {
            guard tried.count < groupBudget else {
                searchedAll = false
                break
            }
            if let result = try await attempt(name) { return result }
        }
        return .failure(sawMismatch ? .mismatched : .notFound(searchedAll: searchedAll))
    }

    /// The group Grok files a directory's sessions under: every UTF-8 byte
    /// outside `A-Z a-z 0-9 - _ . ~` as uppercase `%XX` (Grok's
    /// `encode_cwd_dirname`). Nil past 255 bytes, where Grok names the group
    /// `<slug>-<16 hex>` instead.
    static func groupName(forDirectory cwd: String) -> String? {
        var name: [UInt8] = []
        for byte in cwd.utf8 {
            if isUnreserved(byte) {
                name.append(byte)
            } else {
                name += [UInt8(ascii: "%"), hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0x0F)]]
            }
            if name.count > maximumGroupNameBytes { return nil }
        }
        return String(decoding: name, as: UTF8.self)
    }

    /// The slug of a long directory's group: its last component lowercased,
    /// each run of anything but ASCII letters and digits one `-`, trimmed of
    /// `-`, then cut to 40, so a cut can end on `-`; `workspace` when empty.
    static func slug(forDirectory cwd: String) -> String {
        let leaf = cwd.split(separator: "/").last.map(String.init) ?? "workspace"
        var slug = ""
        var afterDash = false
        for scalar in leaf.lowercased().unicodeScalars {
            if isASCIIAlphanumeric(scalar) {
                slug.unicodeScalars.append(scalar)
                afterDash = false
            } else if !afterDash {
                slug.append("-")
                afterDash = true
            }
        }
        let cut = String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40))
        return cut.isEmpty ? "workspace" : cut
    }

    /// The value of the first `"sessionId"` in a file's first bytes, which
    /// every record carries near its start. Nil when the head holds none
    /// whole yet.
    static func sessionID(inHead head: Data) -> String? {
        guard let key = head.range(of: Data(#""sessionId":""#.utf8)) else { return nil }
        let value = head[key.upperBound...]
        guard let end = value.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: value[..<end], as: UTF8.self)
    }

    /// `<root>/<group>` for a transcript at `<root>/<group>/<id>/updates.jsonl`.
    static func groupDirectory(ofTranscript path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).dropLast(2).joined(separator: "/")
    }

    // MARK: Helpers

    private enum Look {
        case found(String)
        /// The session's folder without a file that names a session yet.
        case notWritten
        case mismatched
        case absent
    }

    /// What the session's folder in one group holds. Its folder is looked
    /// for first, so a group without it costs one stat.
    private func look(into folder: String, sessionID: String) async throws -> Look {
        guard let status = try await files.status(folder), status.kind == nil || status.kind == .directory else {
            return .absent
        }
        let path = RemoteFilePath.join(folder, "updates.jsonl")
        guard let file = try await files.status(path), file.kind == nil || file.kind == .regular,
            file.size != 0,
            let head = try await files.read(
                path: path, from: 0, to: min(Self.headLength, file.size ?? Self.headLength),
                chunk: Int(Self.headLength)),
            let id = Self.sessionID(inHead: head)
        else { return .notWritten }
        return id == sessionID ? .found(path) : .mismatched
    }

    /// Whether a slug group's `.cwd`, which Grok writes without a newline,
    /// holds exactly `directory`. One byte more is read, so a longer file
    /// fails.
    private func cwdFile(of group: String, names directory: String) async throws -> Bool {
        let expected = Data(directory.utf8)
        let data = try await files.read(
            path: RemoteFilePath.join(group, ".cwd"), from: 0, to: UInt64(expected.count + 1),
            chunk: expected.count + 1)
        return data == expected
    }

    private static func isComplete(_ listing: RemoteFileListing?) -> Bool {
        !(listing?.truncated ?? false) && !(listing?.scanIncomplete ?? false)
    }

    /// `<slug>-` then 16 lowercase hex digits, the start of a BLAKE3 hash.
    private static func isSlugGroup(_ name: String, slug: String) -> Bool {
        let prefix = slug + "-"
        guard name.hasPrefix(prefix) else { return false }
        let hash = name.utf8.dropFirst(prefix.utf8.count)
        return hash.count == 16
            && hash.allSatisfy {
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
            }
    }

    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."),
            UInt8(ascii: "~"):
            true
        default: false
        }
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
        default: false
        }
    }
}
