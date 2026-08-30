import Foundation

/// Comparable desired Live Activity content for one Host, before sealing.
/// Counts cover the full eligible inventory; `agents` is already sorted and
/// capped (docs/agents/live-activity-contract.md).
struct AgentActivityDesire: Equatable, Sendable {
    var counts: AgentActivityAttributes.ContentState.Counts
    var hostName: String
    var agents: [AgentActivityDetails.AgentDetail]
}

/// Builds a Host's Live Activity `ContentState` from the Console's Agent
/// list: plaintext counts plus a sealed details envelope.
enum AgentActivityContentBuilder {
    static let maxTitleGraphemes = 80
    static let maxHostGraphemes = 80
    static let maxAgents = 5
    /// Base64url `ct` budget from the shared vector-file description, so the
    /// full APNs payload stays under 4096.
    static let maxCiphertextBytes = 2800

    /// Nil when no Agent is working, blocked, or done — the end signal.
    /// `pinnedPaneIDs` is most-recently-pinned first; pins reorder the
    /// eligible list and never change eligibility or counts.
    static func desire(
        from agents: [ConsoleAgent],
        hostName: String,
        pinnedPaneIDs: [String] = []
    ) -> AgentActivityDesire? {
        let eligible = agents.filter { isEligible($0.agent.status) }
        guard !eligible.isEmpty else { return nil }
        var working = 0
        var blocked = 0
        var done = 0
        for agent in eligible {
            switch agent.agent.status {
            case .working: working += 1
            case .blocked: blocked += 1
            case .done: done += 1
            default: break
            }
        }
        let details = Array(sorted(eligible, pinnedPaneIDs: pinnedPaneIDs).prefix(maxAgents))
            .map(detail(from:))
        return AgentActivityDesire(
            counts: .init(working: working, blocked: blocked, done: done),
            hostName: prefixGraphemes(hostName, max: maxHostGraphemes),
            agents: details)
    }

    /// Seals `desire` under the Host's Notification Key. Degrades in contract
    /// order when `ct` exceeds the budget: drop every title, then empty
    /// `agents`. `nonce` is injectable so tests can pin the ciphertext.
    static func content(
        for desire: AgentActivityDesire,
        key: Data,
        nonce: Data? = nil
    ) -> AgentActivityAttributes.ContentState? {
        var candidates = [desire]
        var withoutTitles = desire
        withoutTitles.agents = desire.agents.map { agent in
            var stripped = agent
            stripped.title = nil
            return stripped
        }
        if withoutTitles != desire { candidates.append(withoutTitles) }
        var emptyAgents = desire
        emptyAgents.agents = []
        if emptyAgents != withoutTitles { candidates.append(emptyAgents) }

        for candidate in candidates {
            guard let sealed = try? AgentActivityEnvelope.seal(
                AgentActivityDetails(hostName: candidate.hostName, agents: candidate.agents),
                using: key,
                nonce: nonce),
                let envelope = try? JSONDecoder().decode(
                    AgentActivityAttributes.ContentState.Envelope.self, from: sealed)
            else { continue }
            if envelope.ct.count <= maxCiphertextBytes || candidate.agents.isEmpty {
                return AgentActivityAttributes.ContentState(
                    counts: desire.counts, envelope: envelope)
            }
        }
        return nil
    }

    /// Convenience: desire + seal, or nil when there is nothing to show.
    static func make(
        agents: [ConsoleAgent],
        hostName: String,
        key: Data,
        nonce: Data? = nil,
        pinnedPaneIDs: [String] = []
    ) -> AgentActivityAttributes.ContentState? {
        guard let desire = desire(
            from: agents, hostName: hostName, pinnedPaneIDs: pinnedPaneIDs)
        else { return nil }
        return content(for: desire, key: key, nonce: nonce)
    }

    private static func isEligible(_ status: AgentStatus) -> Bool {
        status == .working || status == .blocked || status == .done
    }

    /// Pinned eligible agents first, by pin-list index (most recent = 0);
    /// the rest keep status rank then pane-id byte order. Unknown or
    /// ineligible pin ids are simply not in `agents`.
    private static func sorted(
        _ agents: [ConsoleAgent], pinnedPaneIDs: [String]
    ) -> [ConsoleAgent] {
        agents.sorted { lhs, rhs in
            let leftPin = pinnedPaneIDs.firstIndex(of: lhs.agent.paneID)
            let rightPin = pinnedPaneIDs.firstIndex(of: rhs.agent.paneID)
            switch (leftPin, rightPin) {
            case let (left?, right?):
                if left != right { return left < right }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            let left = lhs.agent.status.consoleSortBucket
            let right = rhs.agent.status.consoleSortBucket
            if left != right { return left < right }
            return lhs.agent.paneID.utf8.lexicographicallyPrecedes(rhs.agent.paneID.utf8)
        }
    }

    private static func detail(from agent: ConsoleAgent) -> AgentActivityDetails.AgentDetail {
        let kind = agent.agent.kind.isEmpty ? "unknown" : agent.agent.kind
        let trimmed = prefixGraphemes(agent.agent.title, max: maxTitleGraphemes)
        let name = agent.agent.name.map { prefixGraphemes($0, max: maxTitleGraphemes) }
        let workspace = agent.workspaceLabel.map {
            prefixGraphemes($0, max: maxTitleGraphemes)
        }
        return AgentActivityDetails.AgentDetail(
            paneID: agent.agent.paneID,
            kind: kind,
            name: name?.isEmpty == false ? name : nil,
            workspace: workspace?.isEmpty == false ? workspace : nil,
            status: agent.agent.status.rawValue,
            title: trimmed.isEmpty ? nil : trimmed)
    }

    static func prefixGraphemes(_ text: String, max: Int) -> String {
        if text.count <= max { return text }
        return String(text.prefix(max))
    }
}
