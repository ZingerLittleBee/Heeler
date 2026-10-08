import CryptoKit
import Foundation

/// Identifies one conversation's cached entries: the Host, the herdr session
/// on it, and the program's own session id.
struct ChatCacheKey: Hashable, Codable, Sendable {
    let hostID: UUID
    /// `""` for the default herdr session, `name:<n>` or `path:<p>`
    /// otherwise, so two herdr sessions on one Host never share entries.
    let herdrSession: String
    let program: ChatProgram
    let conversationID: String

    init(hostID: UUID, herdrSession: String, program: ChatProgram, conversationID: String) {
        self.hostID = hostID
        self.herdrSession = herdrSession
        self.program = program
        self.conversationID = conversationID
    }

    init(hostID: UUID, socketLocation: HerdrSocketLocation, reference: ConversationReference) {
        let session =
            switch socketLocation {
            case .defaultSession: ""
            case .namedSession(let name): "name:\(name)"
            case .absolutePath(let path): "path:\(path)"
            }
        self.init(
            hostID: hostID, herdrSession: session, program: reference.program,
            conversationID: reference.sessionID)
    }

    /// The document's file name: a digest, so no session name, path or id
    /// appears on disk.
    var storageName: String {
        let fields = [
            "chat-cache-key-v1", hostID.uuidString.lowercased(), herdrSession, program.rawValue,
            conversationID,
        ]
        let digest = SHA256.hash(data: Data(fields.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// What Chat saved of one conversation: the entries it last showed, without
/// tool output (fetched again on expand), and enough to tell whether they
/// still describe the file on the Host.
struct ChatCacheDocument: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var key: ChatCacheKey
    /// Bumped by an adapter whose normalization changed; an older document
    /// is discarded rather than mixed with new entries.
    var adapterRevision: Int
    var transcriptPath: String
    /// The transcript's first bytes when the entries were read. A file whose
    /// start differs is another conversation under the same name.
    var head: Data
    /// The earliest source byte the entries represent.
    var coverageStart: UInt64
    /// Where reading had got to: the entries are complete up to this byte.
    /// A later tail window that starts past it leaves a gap, so the entries
    /// join it only once older pages close that gap.
    var coverageEnd: UInt64
    var reachedStart: Bool
    var title: String?
    var entries: [ChatEntry]
    var savedAt: Date
    /// The Background Work listed when saved, and the latest message it is
    /// listed against, which a later window carries in when this document
    /// joins it. Nil in documents saved before Chat listed it.
    var backgroundWork: [ChatBackgroundWorkItem]?
    var latestPromptOffset: UInt64?
    /// The turns the entries open, so a reopened conversation folds the
    /// ones above its live window. Nil in documents saved before Chat
    /// recorded them.
    var turns: [ChatTurn]?

    init(
        key: ChatCacheKey, adapterRevision: Int, transcriptPath: String, head: Data,
        coverageStart: UInt64, coverageEnd: UInt64, reachedStart: Bool, title: String?,
        entries: [ChatEntry], savedAt: Date, backgroundWork: [ChatBackgroundWorkItem]? = nil,
        latestPromptOffset: UInt64? = nil, turns: [ChatTurn]? = nil
    ) {
        formatVersion = Self.currentFormatVersion
        self.key = key
        self.adapterRevision = adapterRevision
        self.transcriptPath = transcriptPath
        self.head = head
        self.coverageStart = coverageStart
        self.coverageEnd = coverageEnd
        self.reachedStart = reachedStart
        self.title = title
        self.entries = entries
        self.savedAt = savedAt
        self.backgroundWork = backgroundWork
        self.latestPromptOffset = latestPromptOffset
        self.turns = turns
    }
}

enum ChatCacheLoadResult: Equatable, Sendable {
    case hit(ChatCacheDocument)
    case miss
    /// The document exists but cannot be read now, such as while the device
    /// is locked. It is kept.
    case unavailable
}

struct ChatCachePolicy: Equatable, Sendable {
    /// Decimal bytes, as Settings formats them.
    var totalBudget: Int64 = 300_000_000
    /// Pruning stops once usage falls to this.
    var lowWater: Int64 = 270_000_000
    var maxAge: TimeInterval = 30 * 86_400
    /// A larger document keeps only its newest entries that fit.
    var maxDocumentBytes = 16_000_000
}

/// Where Chat keeps conversations between visits, so a Chat opens instantly
/// and stays readable offline.
protocol ChatTranscriptCache: Sendable {
    func load(_ key: ChatCacheKey) async -> ChatCacheLoadResult
    func save(_ document: ChatCacheDocument) async
    func remove(_ key: ChatCacheKey) async
    func loadAgentDirectory(for host: Host) async -> [ChatCachedAgent]
    func saveAgentDirectory(_ agents: [ChatCachedAgent], for host: Host) async
    /// Deletes every Host's documents except these Hosts', and refuses later
    /// saves for any other Host, so a save racing a Host's removal cannot
    /// bring its messages back.
    func retainHosts(_ hostIDs: Set<UUID>) async
    func removeAll() async
    func diskUsage() async -> Int64
    func prune() async
}

extension ChatTranscriptCache {
    func loadAgentDirectory(for host: Host) async -> [ChatCachedAgent] { [] }
    func saveAgentDirectory(_ agents: [ChatCachedAgent], for host: Host) async {}
}

/// A cache that lives only as long as the process: the default for demo
/// mode and tests, which build Console stores inside the app's container.
actor VolatileChatTranscriptCache: ChatTranscriptCache {
    private var documents: [ChatCacheKey: ChatCacheDocument] = [:]
    private var agentDirectories: [UUID: ChatAgentDirectory] = [:]
    private var allowedHosts: Set<UUID>?

    init() {}

    func load(_ key: ChatCacheKey) -> ChatCacheLoadResult {
        documents[key].map(ChatCacheLoadResult.hit) ?? .miss
    }

    func save(_ document: ChatCacheDocument) {
        if let allowedHosts, !allowedHosts.contains(document.key.hostID) { return }
        documents[document.key] = document
    }

    func remove(_ key: ChatCacheKey) {
        documents[key] = nil
    }

    func loadAgentDirectory(for host: Host) async -> [ChatCachedAgent] {
        agentDirectories[host.id]?.entries(for: host) ?? []
    }

    func saveAgentDirectory(_ agents: [ChatCachedAgent], for host: Host) async {
        if let allowedHosts, !allowedHosts.contains(host.id) { return }
        agentDirectories[host.id] = ChatAgentDirectory(agents, for: host)
    }

    func retainHosts(_ hostIDs: Set<UUID>) {
        allowedHosts = hostIDs
        documents = documents.filter { hostIDs.contains($0.key.hostID) }
        agentDirectories = agentDirectories.filter { hostIDs.contains($0.key) }
    }

    func removeAll() {
        documents = [:]
        agentDirectories = [:]
    }

    func diskUsage() -> Int64 { 0 }

    func prune() {}
}
