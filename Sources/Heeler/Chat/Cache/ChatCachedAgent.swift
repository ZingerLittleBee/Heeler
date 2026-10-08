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

/// A Host id alone is insufficient: editing its endpoint or herdr session
/// must not revive another server's saved pane-to-conversation bindings.
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

        init(_ host: Host) {
            id = host.id
            address = host.address
            port = host.port
            username = host.username
            sessionName = host.sessionName
            jumpAddress = host.jumpAddress
            jumpPort = host.jumpPort
            jumpUsername = host.resolvedJumpUsername
        }
    }

    init(_ agents: [ChatCachedAgent], for host: Host) {
        self.host = HostIdentity(host)
        self.agents = agents.filter { $0.isValid(for: host) }
    }

    func entries(for host: Host) -> [ChatCachedAgent] {
        guard formatVersion == 1, self.host == HostIdentity(host) else { return [] }
        return agents.filter { $0.isValid(for: host) }
    }
}
