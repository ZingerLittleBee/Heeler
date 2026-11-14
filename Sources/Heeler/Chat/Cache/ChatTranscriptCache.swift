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

    /// `coreScope` is `coreScope(session:coreID:)` on a herdr-core Host, which
    /// keeps its entries apart from another core's on the same Host.
    init(
        hostID: UUID, socketLocation: HerdrSocketLocation, reference: ConversationReference,
        coreScope: String? = nil
    ) {
        let session =
            switch socketLocation {
            case .defaultSession: ""
            case .namedSession(let name): "name:\(name)"
            case .absolutePath(let path): "path:\(path)"
            }
        self.init(
            hostID: hostID, herdrSession: coreScope ?? session, program: reference.program,
            conversationID: reference.sessionID)
    }

    /// A core session name holds no `:` (`HerdrCoreSessionName`), and no Herdr
    /// TUI session starts with `core:`, so no two of these name the same thing.
    static func coreScope(session: String, coreID: String) -> String {
        "core:\(HerdrCoreSessionName.normalized(session)):\(coreID)"
    }

    static func tmuxScope(socketName: String, instanceID: String) -> String {
        "tmux:\(TmuxSocketName.normalized(socketName)):\(instanceID)"
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
    /// The app localization the entries' own words are in. Reducers word
    /// notices, tool rows and Background Work as they read, so a document
    /// saved under another language is discarded rather than shown beside
    /// what the live window reads now. Nil in documents saved before Chat
    /// recorded it, which predate Heeler's translations and are English.
    var localization: String?

    /// The localization this launch words entries in.
    static var currentLocalization: String {
        Bundle.main.preferredLocalizations.first ?? untranslatedLocalization
    }

    /// The localization of documents that record none.
    static let untranslatedLocalization = "en"

    init(
        key: ChatCacheKey, adapterRevision: Int, transcriptPath: String, head: Data,
        coverageStart: UInt64, coverageEnd: UInt64, reachedStart: Bool, title: String?,
        entries: [ChatEntry], savedAt: Date, backgroundWork: [ChatBackgroundWorkItem]? = nil,
        latestPromptOffset: UInt64? = nil, turns: [ChatTurn]? = nil,
        localization: String? = ChatCacheDocument.currentLocalization
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
        self.localization = localization
    }

    /// Whether the entries are worded in `localization`.
    func isWorded(in localization: String) -> Bool {
        (self.localization ?? Self.untranslatedLocalization) == localization
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
    func loadAgentDirectory(for host: Host) async -> ChatAgentDirectory.Contents
    func saveAgentDirectory(_ contents: ChatAgentDirectory.Contents, for host: Host) async
    /// False only when a saved directory exists and no longer belongs to
    /// `host`, such as after the user trusted a replaced host key: the same
    /// Host record may now reach another machine.
    func agentDirectoryBelongs(to host: Host) async -> Bool
    /// Deletes every Host's documents except these Hosts', and refuses later
    /// saves for any other Host, so a save racing a Host's removal cannot
    /// bring its messages back.
    func retainHosts(_ hostIDs: Set<UUID>) async
    func removeAll() async
    func diskUsage() async -> Int64
    func prune() async
}

extension ChatTranscriptCache {
    func loadAgentDirectory(for host: Host) async -> ChatAgentDirectory.Contents { .init() }
    func saveAgentDirectory(_ contents: ChatAgentDirectory.Contents, for host: Host) async {}
    func agentDirectoryBelongs(to host: Host) async -> Bool { true }
}

/// A cache that lives only as long as the process: the default for demo
/// mode and tests, which build Console stores inside the app's container.
actor VolatileChatTranscriptCache: ChatTranscriptCache {
    private var documents: [ChatCacheKey: ChatCacheDocument] = [:]
    private var agentDirectories: [UUID: ChatAgentDirectory] = [:]
    private var allowedHosts: Set<UUID>?
    private let knownHosts: any KnownHostsStore

    init(knownHosts: any KnownHostsStore = InMemoryKnownHostsStore()) {
        self.knownHosts = knownHosts
    }

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

    func loadAgentDirectory(for host: Host) async -> ChatAgentDirectory.Contents {
        let hostKeys = await ChatAgentDirectory.trustedHostKeys(for: host.id, in: knownHosts)
        return agentDirectories[host.id]?.contents(for: host, hostKeys: hostKeys) ?? .init()
    }

    func saveAgentDirectory(_ contents: ChatAgentDirectory.Contents, for host: Host) async {
        let hostKeys = await ChatAgentDirectory.trustedHostKeys(for: host.id, in: knownHosts)
        if let allowedHosts, !allowedHosts.contains(host.id) { return }
        agentDirectories[host.id] = ChatAgentDirectory(contents, for: host, hostKeys: hostKeys)
    }

    func agentDirectoryBelongs(to host: Host) async -> Bool {
        let hostKeys = await ChatAgentDirectory.trustedHostKeys(for: host.id, in: knownHosts)
        return agentDirectories[host.id]?.belongs(to: host, hostKeys: hostKeys) ?? true
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
