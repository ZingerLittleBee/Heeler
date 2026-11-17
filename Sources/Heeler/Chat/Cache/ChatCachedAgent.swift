import Foundation

/// A saved Chat entry point, not a claim that its Agent is still running.
/// Only identity, conversation binding and display context survive relaunch.
struct ChatCachedAgent: Codable, Equatable, Sendable {
    let hostID: UUID
    let paneID: String
    let terminalID: String
    let workspaceID: String
    let tabID: String
    let kind: String
    let name: String?
    let title: String
    let terminalTitle: String?
    let terminalTitleStripped: String?
    let paneTitle: String?
    var agentSession: AgentSessionInfo?
    let tokens: [String: String]
    /// A client-resolved conversation title (such as Antigravity CLI's
    /// `.pbtxt` annotation title) kept until SFTP resolves the live session.
    var conversationTitle: String?
    let cwd: String
    let foregroundCwd: String?
    let workspaceLabel: String?
    let tabLabel: String?
    let paneLabel: String?
    let tabPosition: Int?
    let workspaceTabCount: Int
    let snapshotOrder: Int?

    init(_ agent: ConsoleAgent, conversationTitle: String? = nil) {
        hostID = agent.hostID
        paneID = agent.agent.paneID
        terminalID = agent.agent.terminalID
        workspaceID = agent.agent.workspaceID
        tabID = agent.agent.tabID
        kind = agent.agent.kind
        name = agent.agent.name
        title = agent.agent.title
        terminalTitle = agent.agent.terminalTitle
        terminalTitleStripped = agent.agent.terminalTitleStripped
        paneTitle = agent.agent.paneTitle
        agentSession = agent.agent.agentSession
        tokens = agent.agent.tokens
        self.conversationTitle = conversationTitle
        cwd = agent.agent.cwd
        foregroundCwd = agent.directory
        workspaceLabel = agent.workspaceLabel
        tabLabel = agent.tabLabel
        paneLabel = agent.paneLabel
        tabPosition = agent.tabPosition
        workspaceTabCount = agent.workspaceTabCount
        snapshotOrder = agent.snapshotOrder
    }

    private enum CodingKeys: String, CodingKey {
        case hostID, paneID, terminalID, workspaceID, tabID, kind, name, title
        case terminalTitle, terminalTitleStripped, paneTitle, agentSession, tokens, conversationTitle
        case cwd, foregroundCwd, workspaceLabel, tabLabel, paneLabel
        case tabPosition, workspaceTabCount, snapshotOrder
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try container.decode(UUID.self, forKey: .hostID)
        paneID = try container.decode(String.self, forKey: .paneID)
        terminalID = try container.decode(String.self, forKey: .terminalID)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        tabID = try container.decode(String.self, forKey: .tabID)
        kind = try container.decode(String.self, forKey: .kind)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        title = try container.decode(String.self, forKey: .title)
        terminalTitle = try container.decodeIfPresent(String.self, forKey: .terminalTitle)
        terminalTitleStripped = try container.decodeIfPresent(String.self, forKey: .terminalTitleStripped)
        paneTitle = try container.decodeIfPresent(String.self, forKey: .paneTitle)
        agentSession = try container.decodeIfPresent(AgentSessionInfo.self, forKey: .agentSession)
        tokens = try container.decodeIfPresent([String: String].self, forKey: .tokens) ?? [:]
        conversationTitle = try container.decodeIfPresent(String.self, forKey: .conversationTitle)
        cwd = try container.decode(String.self, forKey: .cwd)
        foregroundCwd = try container.decodeIfPresent(String.self, forKey: .foregroundCwd)
        workspaceLabel = try container.decodeIfPresent(String.self, forKey: .workspaceLabel)
        tabLabel = try container.decodeIfPresent(String.self, forKey: .tabLabel)
        paneLabel = try container.decodeIfPresent(String.self, forKey: .paneLabel)
        tabPosition = try container.decodeIfPresent(Int.self, forKey: .tabPosition)
        workspaceTabCount = try container.decode(Int.self, forKey: .workspaceTabCount)
        snapshotOrder = try container.decodeIfPresent(Int.self, forKey: .snapshotOrder)
    }

    func consoleAgent(for host: Host) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id, hostName: host.hostName,
            agent: Agent(
                terminalID: terminalID, kind: kind, title: title, status: .unknown,
                workspaceID: workspaceID, tabID: tabID, paneID: paneID, cwd: cwd,
                revision: 0, name: name,
                terminalTitle: terminalTitle, terminalTitleStripped: terminalTitleStripped,
                paneTitle: paneTitle, agentSession: agentSession, tokens: tokens,
                foregroundCwd: foregroundCwd),
            workspaceLabel: workspaceLabel, repositoryCheckout: nil,
            backend: host.serverKind.agentBackend,
            hostUsername: host.username, tabLabel: tabLabel, tabPosition: tabPosition,
            workspaceTabCount: workspaceTabCount, snapshotOrder: snapshotOrder,
            paneLabel: paneLabel)
    }

    func isValid(for host: Host) -> Bool {
        guard hostID == host.id, !paneID.isEmpty,
            let program = ChatProgram(rawValue: kind),
            case .bound(let reference) = ConversationReference.resolve(agentSession)
        else { return false }
        return reference.program == program
    }
}

/// A Workspace's git checkout as the Host's last snapshot reported it. Saved
/// entries carry no checkout of their own, so this places them By Workspace
/// as the live Agents were placed, even where the entries of a checkout are
/// not saved.
struct ChatCachedWorkspace: Codable, Equatable, Sendable {
    let id: String
    let label: String?
    let checkout: RepositoryCheckout
    /// The branch the latest Changes read of the checkout found, which
    /// titles it in a repository's card until a read of this launch lands.
    var branch: CheckoutHead.Branch? = nil

    /// Each Workspace among `agents` that reported a checkout, by id so an
    /// unchanged snapshot saves nothing. A checkout keeps the branch
    /// `previous` holds for its path.
    static func structure(of agents: [ConsoleAgent], keeping previous: [Self]) -> [Self] {
        var seen: Set<String> = []
        return agents.compactMap { agent -> Self? in
            guard let checkout = agent.repositoryCheckout, seen.insert(agent.agent.workspaceID).inserted
            else { return nil }
            let branch = previous.first { $0.checkout.checkoutPath == checkout.checkoutPath }?.branch
            return Self(id: agent.agent.workspaceID, label: agent.workspaceLabel, checkout: checkout, branch: branch)
        }.sorted { $0.id < $1.id }
    }
}

/// A Host id alone is insufficient: a Host whose herdr session, account, or
/// machine changed must not revive another server's saved pane-to-
/// conversation bindings. The machine is the host key the device trusts for
/// the Host (ADR 0022), since every Route must present it; a directory or
/// Host without one falls back to the primary route, as directories were
/// compared before Routes.
struct ChatAgentDirectory: Codable, Equatable, Sendable {
    /// What a directory gives the Console: the saved entries, the Workspace
    /// structure they were listed in, and the Host's last plugin sidebar
    /// snapshot.
    struct Contents: Equatable, Sendable {
        var agents: [ChatCachedAgent] = []
        var workspaces: [ChatCachedWorkspace] = []
        var sidebarSnapshot: AgentRowLayoutSnapshot? = nil
    }

    var formatVersion = 1
    let host: HostIdentity
    let agents: [ChatCachedAgent]
    /// Nil in directories saved before the structure was kept.
    let workspaces: [ChatCachedWorkspace]?
    /// Nil when the Host has no plugin snapshot or before snapshots were kept.
    let sidebarSnapshot: AgentRowLayoutSnapshot?

    struct HostIdentity: Codable, Equatable, Sendable {
        let id: UUID
        let address: String
        let port: Int
        let username: String
        let sessionName: String
        let jumpAddress: String
        let jumpPort: Int
        let jumpUsername: String
        /// SHA-256 digests of the host keys trusted for the Host when saved,
        /// sorted. Nil in directories saved before Routes or before the Host
        /// had a key of its own.
        let hostKeys: [Data]?
        /// The socket of the Host's Herdr Endpoint, which names the herdr
        /// server as `sessionName` does for herdr's own layout. Nil for the
        /// default socket and in directories saved before endpoints.
        let herdrSocketPath: String?

        init(_ host: Host, hostKeys: Set<Data>) {
            let route = host.primaryRoute
            id = host.id
            address = route.address
            port = route.port
            username = host.username
            sessionName = host.sessionName
            jumpAddress = route.jumpAddress
            jumpPort = route.jumpPort
            jumpUsername = host.jumpUsername(on: route)
            self.hostKeys = hostKeys.isEmpty ? nil : hostKeys.sorted { $0.lexicographicallyPrecedes($1) }
            herdrSocketPath = host.herdrEndpoint?.socketPath
        }

        /// Whether a directory saved under this identity belongs to `current`.
        /// Routes may change freely while a trusted key is shared: a Host
        /// can trust a key per algorithm, and adding one keeps the others.
        func admits(_ current: HostIdentity) -> Bool {
            guard id == current.id, username == current.username,
                sessionName == current.sessionName,
                herdrSocketPath == current.herdrSocketPath
            else { return false }
            if let saved = hostKeys, let trusted = current.hostKeys {
                return !Set(saved).isDisjoint(with: trusted)
            }
            return address == current.address && port == current.port
                && jumpAddress == current.jumpAddress && jumpPort == current.jumpPort
                && jumpUsername == current.jumpUsername
        }
    }

    init(_ contents: Contents, for host: Host, hostKeys: Set<Data>) {
        self.host = HostIdentity(host, hostKeys: hostKeys)
        agents = contents.agents.filter { $0.isValid(for: host) }
        workspaces = contents.workspaces
        sidebarSnapshot = contents.sidebarSnapshot
    }

    func belongs(to host: Host, hostKeys: Set<Data>) -> Bool {
        formatVersion == 1 && self.host.admits(HostIdentity(host, hostKeys: hostKeys))
    }

    func contents(for host: Host, hostKeys: Set<Data>) -> Contents {
        guard belongs(to: host, hostKeys: hostKeys) else { return Contents() }
        return Contents(
            agents: agents.filter { $0.isValid(for: host) },
            workspaces: workspaces ?? [],
            sidebarSnapshot: sidebarSnapshot)
    }

    /// The digests of the host keys the device trusts for `hostID`, read
    /// from this device's TOFU store; nothing is asked of the Host.
    static func trustedHostKeys(for hostID: UUID, in knownHosts: any KnownHostsStore) async -> Set<Data> {
        let key = HostKeyTrust.hostKey(hostID)
        return Set(await knownHosts.fingerprints(host: key.host, port: key.port).map(\.digest))
    }
}
