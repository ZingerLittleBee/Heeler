import Foundation

/// A Devin terminal starts an ACP child. Only its open lock, owned by that PID,
/// names what is open. Leftover locks and other sessions in the same cwd do not.
enum DevinSession {
    static func id(_ value: String) -> String? {
        guard (1...128).contains(value.utf8.count),
              value.wholeMatch(of: /[a-zA-Z0-9][a-zA-Z0-9_-]*/) != nil else { return nil }
        return value
    }

    /// New Agent can choose a dedicated writer on a POSIX Host. An explicit
    /// preset, command, environment or resume invocation belongs to its user.
    static func localLaunch(_ request: AgentLaunchRequest, platform: HostPlatform?) -> AgentLaunchRequest {
        guard platform == .posix, request.kind == "devin", request.arguments.isEmpty,
              request.environment.isEmpty else { return request }
        var launch = request
        launch.arguments = ["--process-model=in-process"]
        return launch
    }

    static let arguments = ["acp", "--process-model=in-process", "--cloud", "--process-model=daemon", "daemon"]

    static func target(root: String, members: [String], facts: [String: HostProcessReader.Facts],
                       directory: String, scope: String, files: ChatHostFiles) async throws -> DroidDialogTarget? {
        guard let client = facts[root], client.name == "devin", case .value(let birth) = client.start,
              case .value(let args) = client.arguments, args.isDisjoint(with: ["acp", "--cloud", "daemon", "--process-model=daemon"]),
              RemoteFilePath.isAcceptable(directory) else { return nil }
        let children = members.filter { facts[$0]?.parent == root && facts[$0]?.name == "devin" }
        let startup = DroidDialogTarget(scope: scope, pid: root, start: birth, directory: directory, sessionID: nil)
        guard !children.isEmpty else { return startup }
        guard children.count == 1, let pid = children.first, let writer = facts[pid],
              case .value(let arguments) = writer.arguments, arguments.contains("acp"), arguments.contains("--process-model=in-process"),
              case .value(let paths) = writer.openFiles, case .value(let writerBirth) = writer.start else { return nil }
        let locks = Set(paths.filter { $0.contains("/devin/cli/session_locks/") && $0.hasSuffix(".lock") })
        guard !locks.isEmpty else { return startup }
        guard locks.count == 1, let lock = locks.first, RemoteFilePath.isAcceptable(lock) else { return nil }
        let name = (lock as NSString).lastPathComponent
        let folder = (lock as NSString).deletingLastPathComponent
        guard folder.hasSuffix("/devin/cli/session_locks"), let session = id(String(name.dropLast(5))) else { return nil }
        let owner = try await files.read(.init(path: lock, offset: 0, maxBytes: 64))
        guard owner.data == Data((pid + "\n").utf8) else { return nil }
        return .init(scope: scope + "/" + root + "/" + birth, pid: pid, start: writerBirth, directory: directory,
                     sessionID: session, transcriptFolder: (folder as NSString).deletingLastPathComponent)
    }
}

struct DevinSessionQuery: Encodable, Sendable {
    struct MessageText: Encodable, Sendable {
        var id, sha256: String
        /// Offset in Unicode scalars, the unit of Python's string slices.
        var start: Int
    }

    var session: String
    var root: String
    var offset: Int?
    var limit: Int
    var expanded = false
    var earlierWork = false
    var messageText: MessageText?

    func script() throws -> Data {
        guard DevinSession.id(session) != nil, RemoteFilePath.isAcceptable(root), root.hasSuffix("/devin/cli"),
              let file = Bundle.main.url(forResource: "read-session", withExtension: "py", subdirectory: "devin")
        else { throw TransportError.hostStoreUnreadable(detail: "Invalid Devin session store") }
        let argument = try JSONEncoder().encode(self).base64EncodedString()
        var script = Data("python3 - '\(argument)' <<'HEELER_DEVIN_STORE'\n".utf8)
        script.append(try Data(contentsOf: file))
        script.append(Data("\nHEELER_DEVIN_STORE\n".utf8))
        return script
    }
}

struct DevinSessionPage: Decodable, Sendable {
    var offset, total: Int
    var title, model: String?
    var rows: [Row]
    var textChunk: String?

    struct EarlierWork: Codable, Equatable, Sendable {
        var offset: UInt64
        var row: Row
    }

    struct Row: Codable, Equatable, Sendable {
        struct FullText: Codable, Equatable, Sendable {
            var length: Int
            var sha256: String
        }

        struct ShellExit: Codable, Equatable, Sendable {
            var code: Int
            /// Number of output scalars before Devin's final exit line.
            var outputLength: Int
        }

        var id, role, text: String
        var truncated: Bool
        var fullText: FullText?
        var shellExit: ShellExit?
        var calls: [Call]
        var resultFor, finish, timestamp: String?
        var title, model, agentID: String?
        var success: Bool?
        var childReports: [String: String]?
        var earlierWork: [EarlierWork]?
    }

    struct Call: Codable, Equatable, Sendable {
        var id, name: String
        var arguments: Arguments
        var complete: Bool
    }

    struct Question: Codable, Equatable, Sendable {
        struct Option: Codable, Equatable, Sendable { var label: String; var description: String? }
        var header: String?
        var question: String
        var options: [Option]
    }

    struct Arguments: Codable, Equatable, Sendable {
        var file_path, path, content, old_string, new_string, command, description, prompt, plan, subagent_type: String?
        var questions: [Question]?
        var shell_id, agent_id, task, title: String?
        var is_background: Bool?
        var timeout: Int?
    }
}

protocol DevinChatReading: Sendable {
    func queryDevin(_ query: DevinSessionQuery) async throws -> DevinSessionPage
}

extension DevinChatReading {
    func queryDevin(_ query: DevinSessionQuery) async throws -> DevinSessionPage {
        throw TransportError.hostFeatureUnavailable(feature: String(localized: "Devin Chat"))
    }
}
