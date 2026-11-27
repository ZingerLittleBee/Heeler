import Foundation

/// Droid files sessions under ~/.factory/sessions/<project>/<uuid>.jsonl.
/// A resumed session may still be filed under its original project.
struct DroidTranscriptLocator {
    let files: ChatHostFiles
    var projectLimit = 200

    static func sessionID(inHead head: Data) -> String? {
        struct Header: Decodable {
            let type, id: String
        }
        let line = head.prefix { $0 != 0x0A }
        guard let header = try? JSONDecoder().decode(Header.self, from: line),
              header.type == "session_start" else { return nil }
        return ConversationReference.canonicalUUID(header.id)
    }

    static func reportedFolder(file: String, sessionID: String) -> String? {
        let parts = file.split(separator: "/")
        guard RemoteFilePath.isAcceptable(file), parts.count >= 4, parts[parts.count - 3] == "sessions",
              parts.last == Substring(sessionID + ".jsonl"), !file.hasSuffix("/") else { return nil }
        return String(file.dropLast(sessionID.utf8.count + ".jsonl".count + 1))
    }

    func locate(sessionID: String, directories: [String], reportedFolder: String? = nil) async throws -> String {
        guard let id = ConversationReference.canonicalUUID(sessionID) else {
            throw ChatSourceUnavailable(reason: .unidentifiedSession(.droid))
        }
        if let reportedFolder {
            let path = RemoteFilePath.join(reportedFolder, id + ".jsonl")
            guard Self.reportedFolder(file: path, sessionID: id) == reportedFolder else {
                throw ChatSourceUnavailable(reason: .mismatched)
            }
            guard let status = try await files.status(path), status.kind == .regular else {
                throw ChatSourceUnavailable(reason: .notFound(searchedAll: true))
            }
            let line = try await files.firstLine(of: path, initialBytes: 1024, limit: 64 << 10)
            guard case .line(let header)? = line, Self.sessionID(inHead: header) == id else {
                throw ChatSourceUnavailable(reason: .mismatched)
            }
            return path
        }
        let home = try await files.home()
        let roots = try await files.configRoots(for: .droid, defaultRoot: RemoteFilePath.join(home, ".factory"))
        var searchedAll = true
        var mismatched = false
        let found = try await ChatHostFiles.firstAnswer(across: roots) { config -> String? in
            let sessions = RemoteFilePath.join(config, "sessions")
            var tried: Set<String> = []
            func check(_ project: String) async throws -> String? {
                let path = RemoteFilePath.join(sessions, project, id + ".jsonl")
                guard project.utf8.count <= 255, !project.contains("/"),
                      RemoteFilePath.isAcceptable(path), tried.insert(project).inserted,
                      let status = try await files.status(path), status.kind == .regular else { return nil }
                let firstLine = try await files.firstLine(of: path, initialBytes: 1024, limit: 64 << 10)
                guard case .line(let header)? = firstLine else { return nil }
                guard Self.sessionID(inHead: header) == id else {
                    mismatched = true
                    return nil
                }
                return path
            }
            for directory in directories where RemoteFilePath.isAcceptable(directory) {
                if let path = try await check(directory.replacingOccurrences(of: "/", with: "-")) { return path }
            }
            let listing = try await files.list(.init(directory: sessions, kinds: [.directory], maximumEntries: projectLimit))
            if listing?.truncated == true || listing?.scanIncomplete == true { searchedAll = false }
            for project in listing?.entries ?? [] {
                if let path = try await check(project.name) { return path }
            }
            return nil
        }
        guard let found else {
            throw ChatSourceUnavailable(reason: mismatched ? .mismatched : .notFound(searchedAll: searchedAll))
        }
        return found
    }
}

protocol DroidForegroundReading: Sendable {
    func foregroundDroid(pid: String, start: String, home: String, cwd: String) async throws -> DroidForegroundSession?
}

extension DroidForegroundReading {
    func foregroundDroid(pid: String, start: String, home: String, cwd: String) async throws -> DroidForegroundSession? { nil }
}

/// Herdr 0.9.5 can keep the original herdr:droid ID through /new or /resume.
/// Read Factory's own process-scoped lifecycle records on the Host. Only
/// the foreground UUID and its validated transcript directory leave the Host.
struct DroidForegroundSession: Decodable, Sendable {
    let session, file, controller, controllerStart: String

    static func script(pid: String, start: String, home: String, cwd: String) -> Data {
        let arguments = [pid, start, home, cwd].map(HostHelperScript.quote).joined(separator: " ")
        guard let url = Bundle.main.url(forResource: "foreground-session", withExtension: "py", subdirectory: "droid"),
              let python = try? String(contentsOf: url, encoding: .utf8) else { return Data() }
        return Data(("exec python3 - " + arguments + " <<'HEELER_DROID'\n" + python + "\nHEELER_DROID\n").utf8)
    }
}
