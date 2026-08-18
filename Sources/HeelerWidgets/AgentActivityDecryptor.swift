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

    /// Registered Host name (envelope host only as fallback), or the
    /// generic app name when details are unavailable. Never a Host or
    /// agent name in `countsOnly`.
    var headerTitle: String {
        switch self {
        case .detailed(let details, _):
            return details.hostName
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

    /// Rows the lock screen and expanded island actually draw.
    var visibleAgents: [AgentActivityDetails.AgentDetail] {
        Array(agents.prefix(AgentActivityCopy.rowLimit))
    }

    /// Remaining eligible agents beyond the drawn rows, using the full
    /// inventory in `counts` (the envelope list is capped at 5). Zero in
    /// counts-only: there are no rows to overflow from.
    var overflowCount: Int {
        let shown = visibleAgents.count
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

        var details = opened
        details.hostName = AgentActivityHostTitle.resolved(
            registeredName: record.hostName, envelopeName: opened.hostName)
        return .detailed(details: details, counts: state.counts)
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
