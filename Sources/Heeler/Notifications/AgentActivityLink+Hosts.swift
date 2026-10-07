import Foundation

extension AgentActivityLink.Target {
    /// The Agent this link opens among the saved `hosts`, or nil for the
    /// Console: the link names no pane, or no single Host answers to it.
    func agent(in hosts: [Host]) -> AgentNotificationTarget? {
        guard let paneID, let hostID = host.resolvedID(in: hosts) else { return nil }
        return AgentNotificationTarget(hostID: hostID, paneID: paneID)
    }
}

extension AgentActivityLink.HostReference {
    /// Heeler's own links carry the id. Another app's link is looked up among
    /// the Hosts on its herdr session, since pane ids repeat across sessions:
    /// by address, and by name only when no address matches, both ignoring
    /// case. Two Hosts answering the same way is no answer, never a guess.
    fileprivate func resolvedID(in hosts: [Host]) -> Host.ID? {
        switch self {
        case .id(let id):
            return id
        case .lookup(let value, let session):
            let socket = session.map(HerdrSocketLocation.namedSession) ?? .defaultSession
            let onSession = hosts.filter { $0.socketLocation == socket }
            let byAddress = onSession.filter { Self.matches($0.address, value) }
            let found =
                byAddress.isEmpty ? onSession.filter { Self.matches($0.name, value) } : byAddress
            return found.count == 1 ? found.first?.id : nil
        }
    }

    private static func matches(_ field: String, _ value: String) -> Bool {
        field.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(value) == .orderedSame
    }
}
