import Foundation

enum PiTranscriptUnavailable: Error, Equatable, Sendable {
    case notFound(searchedAll: Bool)
    /// The reported path holds nothing yet: Pi and OMP name a session's
    /// file when it starts and write it with the first reply.
    case notWritten
    case mismatched
    case unsupportedVersion(Int)
}

/// Pi and OMP integrations normally report the exact session file. Older
/// integrations may report its UUID instead: search only the program's own
/// session root, validating the header rather than choosing the newest file.
struct PiTranscriptLocator: Sendable {
    let files: ChatHostFiles
    var directoryBudget = 200

    func locate(reference: ConversationReference, directories: [String]) async throws
        -> Result<String, PiTranscriptUnavailable>
    {
        guard reference.program == .pi || reference.program == .omp else { return .failure(.mismatched) }
        if reference.sessionID.hasPrefix("/") {
            guard RemoteFilePath.isAcceptable(reference.sessionID), reference.sessionID.hasSuffix(".jsonl") else {
                return .failure(.mismatched)
            }
            return try await verify(path: reference.sessionID, sessionID: nil)
        }
        guard let id = ConversationReference.canonicalUUID(reference.sessionID) else { return .failure(.mismatched) }
        let home = try await files.home()
        let root = RemoteFilePath.join(home, reference.program == .pi ? ".pi" : ".omp", "agent", "sessions")
        var queue = directories.filter(RemoteFilePath.isAcceptable).map { directory in
            RemoteFilePath.join(root, Self.projectKey(directory))
        }
        // OMP also uses home-relative keys in recent releases.
        if reference.program == .omp {
            for directory in directories where directory.hasPrefix(home + "/") {
                let relative = String(directory.dropFirst(home.count + 1))
                queue.append(RemoteFilePath.join(root, "-" + Self.encoded(relative)))
            }
        }
        let projects = try await files.list(
            RemoteFileListingRequest(directory: root, kinds: [.directory], maximumEntries: directoryBudget))
        queue += (projects?.entries ?? []).map { RemoteFilePath.join(root, $0.name) }
        var visited = Set<String>()
        var searchedAll = !(projects?.truncated ?? false) && !(projects?.scanIncomplete ?? false)
        var mismatch = false
        for directory in queue where visited.insert(directory).inserted {
            guard visited.count <= directoryBudget else {
                searchedAll = false
                break
            }
            let listing = try await files.list(
                RemoteFileListingRequest(
                    directory: directory, kinds: [.regular], nameSuffixes: ["_\(id).jsonl", "\(id).jsonl"],
                    maximumEntries: 20))
            searchedAll = searchedAll && !(listing?.truncated ?? false) && !(listing?.scanIncomplete ?? false)
            for entry in listing?.entries ?? [] {
                let path = RemoteFilePath.join(directory, entry.name)
                guard RemoteFilePath.isAcceptable(path) else { continue }
                switch try await verify(path: path, sessionID: id) {
                case .success: return .success(path)
                case .failure(.mismatched): mismatch = true
                case .failure(.unsupportedVersion(let version)): return .failure(.unsupportedVersion(version))
                case .failure(.notFound), .failure(.notWritten): break
                }
            }
        }
        return .failure(mismatch ? .mismatched : .notFound(searchedAll: searchedAll))
    }

    /// The session id the header names, read from a file's first bytes:
    /// the conversation's identity across rewrites of the header and of
    /// the title slot before it. Nil when the header is not in them whole.
    static func sessionID(inHead head: Data) -> String? {
        for line in JSONLLineFramer.lines(in: head).prefix(2) {
            guard let record = try? JSONDecoder().decode(JSONValue.self, from: line.data) else { return nil }
            if record["type"]?.stringValue == "title" { continue }
            guard record["type"]?.stringValue == "session" else { return nil }
            return record["id"]?.stringValue
        }
        return nil
    }

    static func projectKey(_ directory: String) -> String {
        "--" + encoded(String(directory.dropFirst())) + "--"
    }

    private static func encoded(_ path: String) -> String {
        path.map { $0 == "/" || $0 == "\\" || $0 == ":" ? "-" : String($0) }.joined()
    }

    /// `sessionID` is nil for a path herdr reported, which may not be
    /// written yet.
    private func verify(path: String, sessionID: String?) async throws -> Result<String, PiTranscriptUnavailable> {
        let status = try await files.status(path)
        if sessionID == nil, status == nil || (status?.kind == .regular && status?.size == 0) {
            return .failure(.notWritten)
        }
        guard let status, status.kind == .regular, (status.size ?? 0) > 0,
            let head = try await files.read(path: path, from: 0, to: 64 << 10, chunk: 64 << 10)
        else { return .failure(.notFound(searchedAll: true)) }
        // OMP 18 writes a fixed-width title slot before the session header.
        for line in JSONLLineFramer.lines(in: head).prefix(2) {
            guard let record = try? JSONDecoder().decode(JSONValue.self, from: line.data) else {
                return .failure(.mismatched)
            }
            if record["type"]?.stringValue == "title" { continue }
            guard record["type"]?.stringValue == "session",
                let id = record["id"]?.stringValue.flatMap(ConversationReference.canonicalUUID),
                sessionID == nil || sessionID == id
            else { return .failure(.mismatched) }
            // Tree ids and parents were introduced in v2; v1 cannot be
            // projected safely by the tree reducer.
            guard case .number(let number)? = record["version"], number == 2 || number == 3 else {
                let version: Int
                if case .number(let number)? = record["version"], number.isFinite, (0...1_000).contains(number) {
                    version = Int(number)
                } else {
                    version = 1
                }
                return .failure(.unsupportedVersion(version))
            }
            return .success(path)
        }
        return .failure(.mismatched)
    }
}
