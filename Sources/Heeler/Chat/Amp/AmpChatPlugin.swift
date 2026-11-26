import CryptoKit
import Foundation

/// The local Amp CLI's plugin protocol. Each load has a fresh instance and
/// each focus change advances the revision, even when returning to a thread.
struct AmpPluginRecord: Codable, Equatable, Sendable {
    let version: Int
    var contentRevision: Int? = nil
    let pid: Int
    let start: String
    let uid: UInt32
    let instance: UUID

    var socket: String { "/tmp/heeler-amp-\(uid)/\(instance.uuidString.lowercased()).sock" }
}

struct AmpChatBinding: Codable, Equatable, Sendable {
    let version: Int
    let instance: UUID
    let revision: Int
    let thread: String?
    let pid: Int
    let start: String
}

struct AmpChatTarget: Equatable, Sendable {
    let record: AmpPluginRecord
    let binding: AmpChatBinding
}

struct AmpChatRequest: Encodable, Sendable {
    var version = 1
    let op: String
    var instance: String?
    var revision: Int?
    var thread: String?
    var offset: Int?
    var limit: Int?
    var fullText: Bool?
    var expandedCall: String?
    var requestID: UUID?
    var text: String?

    init(_ op: String, target: AmpChatTarget? = nil) {
        self.op = op
        instance = target?.record.instance.uuidString.lowercased()
        revision = target?.binding.revision
        thread = target?.binding.thread
    }
}

struct AmpChatReply: Decodable, Sendable {
    let binding: AmpChatBinding?
    let page: AmpChatPage?
    let sent: Bool?
    let error: String?
}

struct AmpChatPage: Decodable, Sendable {
    let offset: Int
    let total: Int
    let rows: [Row]

    struct Row: Codable, Equatable, Sendable {
        let id: String
        let role: String
        let createdAt: String?
        let end: String?
        var blocks: [Block]
    }

    struct Block: Codable, Equatable, Sendable {
        let type: String
        var text: String?
        let call: String?
        let name: String?
        let status: String?
        var truncated: Bool? = nil

        var outputPreview: ChatToolPreview {
            var preview = ChatToolPreview(capping: text ?? "")
            if truncated == true { preview.isTruncated = true }
            return preview
        }
    }
}

enum AmpChatProblem: Error, Equatable, Sendable {
    case missing, update, reload, noThread, changed, incompatible, unidentified, conflict, unreachable

    var explanation: String {
        switch self {
        case .missing: String(localized: "Install Heeler’s plugin on the Host to read and reply to the thread open in this Amp terminal.")
        case .update: String(localized: "Update Heeler’s Amp plugin on this Host to read complete messages and tool output.")
        case .reload: String(localized: "In the Amp terminal, press Ctrl+O, search for reload, and choose Plugins › Reload. Then check again here.")
        case .noThread: String(localized: "Start or open a thread in this Amp terminal. Chat will follow it here.")
        case .changed: String(localized: "The Amp terminal changed threads or reloaded its plugin. Check the current conversation before sending.")
        case .incompatible: String(localized: "This Amp plugin uses a different protocol version.")
        case .unidentified: String(localized: "Heeler could not identify the foreground Amp process and its configuration on this Host.")
        case .conflict: String(localized: "A different file already occupies the plugin path. Check it on the Host before installing.")
        case .unreachable: String(localized: "Heeler could not reach the Amp plugin over SSH. Check that Amp is running and the SSH server allows Unix socket forwarding.")
        }
    }
}

protocol AmpChatHost: Sendable {
    func exchangeAmpChat(_ request: AmpChatRequest, record: AmpPluginRecord) async throws -> AmpChatReply
    func installAmpChatPlugin(in directory: String, replacing previous: Data?) async throws
}

extension AmpChatHost {
    func exchangeAmpChat(_ request: AmpChatRequest, record: AmpPluginRecord) async throws -> AmpChatReply {
        throw AmpChatProblem.unreachable
    }
    func installAmpChatPlugin(in directory: String, replacing previous: Data?) async throws { throw AmpChatProblem.unreachable }
}

struct AmpPluginLocation: Identifiable, Equatable, Sendable {
    var id: String { "\(pid):\(start):\(directory)" }
    let pid: Int
    let start: String
    let home: String
    let directory: String
    var recordPath: String { "\(home)/.local/state/heeler/amp/\(pid).json" }
    var pluginPath: String { "\(directory)/heeler-chat.js" }

    static func bundledContents() throws -> Data {
        guard let url = Bundle.main.url(forResource: "heeler-chat", withExtension: "js", subdirectory: "amp") else {
            throw AmpChatProblem.incompatible
        }
        return try Data(contentsOf: url)
    }

    /// Only the exact previously distributed bundle can be updated in place.
    private static let previousSize = 8078
    private static let previousSHA256 = "54232295c840090fc03ee053adddfae2848e24ae95f89547a28d876514def9a8"

    func installation(_ files: ChatHostFiles) async throws -> (problem: AmpChatProblem, previous: Data?) {
        let filename = "heeler-chat.js"
        let listing: RemoteFileListing?
        do {
            listing = try await files.list(.init(directory: directory, namePrefix: filename))
        } catch TransportError.hostFileUnreadable(let status) where status == 2 || status == 10 {
            // Some SFTP servers report NO_SUCH_FILE or NO_SUCH_PATH for
            // OPENDIR when this account has never installed any Amp plugins.
            return (.missing, nil)
        }
        guard let file = listing?.entries.first(where: { $0.name == filename }) else {
            if listing?.truncated == true || listing?.scanIncomplete == true { return (.unidentified, nil) }
            return (.missing, nil)
        }
        let bundled = try Self.bundledContents()
        guard file.status.kind == .regular,
            file.status.size == UInt64(bundled.count) || file.status.size == UInt64(Self.previousSize)
        else { return (.conflict, nil) }
        let bytes = try await files.read(.init(path: pluginPath, offset: 0, maxBytes: max(bundled.count, Self.previousSize)))
        guard bytes.length == UInt64(bytes.data.count) else { return (.conflict, nil) }
        if bytes.data == bundled { return (.reload, nil) }
        if bytes.data.count == Self.previousSize,
            SHA256.hash(data: bytes.data).map({ String(format: "%02x", $0) }).joined() == Self.previousSHA256 {
            return (.update, bytes.data)
        }
        return (.conflict, nil)
    }

    static func foreground(_ info: PaneProcessInfo) -> Int? {
        let matches = (info.foregroundProcesses ?? []).filter {
            $0.pid > 0 && ($0.name == "amp" || $0.argv0?.split(separator: "/").last == "amp")
        }
        return matches.count == 1 ? matches.first?.pid : nil
    }

    init?(pid: Int, facts: HostProcessReader.Facts) {
        guard case .value(let start) = facts.start,
            case .value(let home) = facts.variables["HOME"], RemoteFilePath.isAcceptable(home)
        else { return nil }
        let root: String
        switch facts.variables["XDG_CONFIG_HOME"] {
        case .unset, .value(""): root = home + "/.config"
        case .value(let path) where RemoteFilePath.isAcceptable(path): root = path
        default: return nil
        }
        self.pid = pid
        self.start = start
        self.home = home
        directory = (root as NSString).appendingPathComponent("amp/plugins")
    }

    static func installScript(directory: String, contents: String, replacing previous: Data? = nil) throws -> Data {
        guard RemoteFilePath.isAcceptable(directory), directory.hasSuffix("/amp/plugins"),
            !contents.isEmpty else { throw AmpChatProblem.unidentified }
        let update = previous.map { bytes in
            """
            if [ ! -L "$dest" ] && [ -f "$dest" ] && printf '%s' \(HostHelperScript.quote(String(decoding: bytes, as: UTF8.self))) | cmp -s - "$dest"; then
                mv -f "$tmp" "$dir/"
                exit 0
            fi
            """
        } ?? ""
        let script = """
            set -eu
            umask 077
            dir=\(HostHelperScript.quote(directory))
            dest="$dir/heeler-chat.js"
            mkdir -p "$dir"
            stage=$(mktemp -d "$dir/.heeler-chat.XXXXXXXX")
            tmp="$stage/heeler-chat.js"
            trap 'rm -f "$tmp"; rmdir "$stage"' EXIT
            printf '%s' \(HostHelperScript.quote(contents)) > "$tmp"
            if ln "$tmp" "$dir" 2>/dev/null; then exit 0; fi
            if [ ! -L "$dest" ] && [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then exit 0; fi
            \(update)
            exit 73
            """
        return Data(script.utf8)
    }
}
