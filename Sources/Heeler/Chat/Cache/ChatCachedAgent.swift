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
    let paneTitle: String?
    var agentSession: AgentSessionInfo?
    let cwd: String
    let foregroundCwd: String?
    let workspaceLabel: String?
    let tabLabel: String?
    let paneLabel: String?
    let tabPosition: Int?
    let workspaceTabCount: Int
    let snapshotOrder: Int?

    init(_ agent: ConsoleAgent) {
        hostID = agent.hostID
        paneID = agent.agent.paneID
        terminalID = agent.agent.terminalID
        workspaceID = agent.agent.workspaceID
        tabID = agent.agent.tabID
        kind = agent.agent.kind
        name = agent.agent.name
        title = agent.agent.title
        paneTitle = agent.agent.paneTitle
        agentSession = agent.agent.agentSession
        cwd = agent.agent.cwd
        foregroundCwd = agent.directory
        workspaceLabel = agent.workspaceLabel
        tabLabel = agent.tabLabel
        paneLabel = agent.paneLabel
        tabPosition = agent.tabPosition
        workspaceTabCount = agent.workspaceTabCount
        snapshotOrder = agent.snapshotOrder
    }

    func consoleAgent(for host: Host) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id, hostName: host.displayName,
            agent: Agent(
                terminalID: terminalID, kind: kind, title: title, status: .unknown,
                workspaceID: workspaceID, tabID: tabID, paneID: paneID, cwd: cwd,
                revision: 0, name: name, paneTitle: paneTitle, agentSession: agentSession,
                foregroundCwd: foregroundCwd),
            workspaceLabel: workspaceLabel, repositoryCheckout: nil,
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

/// A Host id alone is insufficient: a Host whose herdr session, account, or
/// machine changed must not revive another server's saved pane-to-
/// conversation bindings. The machine is the host key the device trusts for
/// the Host (ADR 0022), since every Route must present it; a directory or
/// Host without one falls back to the primary route, as directories were
/// compared before Routes.
struct ChatAgentDirectory: Codable, Equatable, Sendable {
    var formatVersion = 1
    let host: HostIdentity
    let agents: [ChatCachedAgent]

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
        }

        /// Whether a directory saved under this identity belongs to `current`.
        /// Routes may change freely while a trusted key is shared: a Host
        /// can trust a key per algorithm, and adding one keeps the others.
        func admits(_ current: HostIdentity) -> Bool {
            guard id == current.id, username == current.username,
                sessionName == current.sessionName else { return false }
            if let saved = hostKeys, let trusted = current.hostKeys {
                return !Set(saved).isDisjoint(with: trusted)
            }
            return address == current.address && port == current.port
                && jumpAddress == current.jumpAddress && jumpPort == current.jumpPort
                && jumpUsername == current.jumpUsername
        }
    }

    init(_ agents: [ChatCachedAgent], for host: Host, hostKeys: Set<Data>) {
        self.host = HostIdentity(host, hostKeys: hostKeys)
        self.agents = agents.filter { $0.isValid(for: host) }
    }

    func belongs(to host: Host, hostKeys: Set<Data>) -> Bool {
        formatVersion == 1 && self.host.admits(HostIdentity(host, hostKeys: hostKeys))
    }

    func entries(for host: Host, hostKeys: Set<Data>) -> [ChatCachedAgent] {
        guard belongs(to: host, hostKeys: hostKeys) else { return [] }
        return agents.filter { $0.isValid(for: host) }
    }

    /// The digests of the host keys the device trusts for `hostID`, read
    /// from this device's TOFU store; nothing is asked of the Host.
    static func trustedHostKeys(for hostID: UUID, in knownHosts: any KnownHostsStore) async -> Set<Data> {
        let key = HostKeyTrust.hostKey(hostID)
        return Set(await knownHosts.fingerprints(host: key.host, port: key.port).map(\.digest))
    }
}
