import Foundation

/// Render-time view of one Live Activity update: decrypted Host details, or
/// the plaintext counts when the envelope cannot be opened.
enum AgentActivityPresentation: Equatable, Sendable {
    case detailed(details: AgentActivityDetails, counts: AgentActivityAttributes.ContentState.Counts)
    case countsOnly(counts: AgentActivityAttributes.ContentState.Counts)

    var counts: AgentActivityAttributes.ContentState.Counts {
        switch self {
        case .detailed(_, let counts), .countsOnly(let counts):
            return counts
        }
    }

    /// Headline: the most urgent agent's task title (its kind when the
    /// title is missing), or the generic app name when details are
    /// unavailable. Host identity is never rendered.
    var headerTitle: String {
        switch self {
        case .detailed:
            guard let primary = primaryAgent else { return AgentActivityCopy.genericAppName }
            return primary.title ?? primary.kind
        case .countsOnly:
            return AgentActivityCopy.genericAppName
        }
    }

    var agents: [AgentActivityDetails.AgentDetail] {
        switch self {
        case .detailed(let details, _):
            return details.agents
        case .countsOnly:
            return []
        }
    }

    /// The agent whose task title is the headline: rows arrive pre-sorted
    /// blocked > done > working, so this is the most urgent one.
    var primaryAgent: AgentActivityDetails.AgentDetail? {
        agents.first
    }

    /// Rows drawn below the headline (the headline consumes the first
    /// agent).
    var secondaryAgents: [AgentActivityDetails.AgentDetail] {
        Array(agents.dropFirst().prefix(AgentActivityCopy.rowLimit - 1))
    }

    /// Remaining eligible agents beyond the headline and drawn rows, using
    /// the full inventory in `counts` (the envelope list is capped at 5).
    /// Zero in counts-only: there is nothing to overflow from.
    var overflowCount: Int {
        let shown = (primaryAgent == nil ? 0 : 1) + secondaryAgents.count
        guard shown > 0 else { return 0 }
        return max(0, counts.total - shown)
    }
}

/// Synchronous render-time helper. Failures degrade to counts-only so a
/// view body never has to throw (nil envelope, locked Keychain before
/// first unlock, unknown kid, decrypt or payload error).
enum AgentActivityDecryptor {
    static func presentation(
        for state: AgentActivityAttributes.ContentState,
        store: NotificationKeyStore = NotificationKeyStore()
    ) -> AgentActivityPresentation {
        guard let envelope = state.envelope,
            let data = try? JSONEncoder().encode(envelope),
            let kid = SealedEnvelopeCodec.peekKeyID(in: data)
        else {
            return .countsOnly(counts: state.counts)
        }

        let records: [NotificationKeyRecord]
        do {
            records = try store.allRecords()
        } catch {
            return .countsOnly(counts: state.counts)
        }

        guard let record = records.first(where: { $0.keyID == kid }),
            let opened = try? AgentActivityEnvelope.open(data, using: record.key)
        else {
            return .countsOnly(counts: state.counts)
        }

        return .detailed(details: opened, counts: state.counts)
    }
}

enum AgentActivityCopy {
    static let genericAppName = "Heeler"
    static let rowLimit = 2
}

extension AgentActivityAttributes.ContentState.Counts {
    /// Full eligible inventory carried in plaintext.
    var total: Int { working + blocked + done }

    /// Non-zero chips in contract urgency order (blocked, working, done).
    var chipItems: [(status: String, count: Int)] {
        var items: [(String, Int)] = []
        if blocked > 0 { items.append(("blocked", blocked)) }
        if working > 0 { items.append(("working", working)) }
        if done > 0 { items.append(("done", done)) }
        return items
    }
}
