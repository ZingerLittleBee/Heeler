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

    /// Headline: the first envelope row's task title (its kind when the
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

    /// The agent whose task title is the headline: rows arrive in envelope
    /// order (pinned eligible first, then status rank).
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

    /// Lock-screen rows. The first row carries the full hierarchy while
    /// secondary rows render compactly, leaving room for five fresh rows.
    func lockScreenAgents(isStale: Bool) -> [AgentActivityDetails.AgentDetail] {
        let total = counts.total
        guard total > 0 else { return [] }
        let visible = min(total, isStale ? 4 : 5)
        return Array(agents.prefix(visible))
    }

    /// Inventory beyond the drawn lock-screen rows. Zero in counts-only.
    func lockScreenOverflowCount(isStale: Bool) -> Int {
        let shown = lockScreenAgents(isStale: isStale)
        guard !shown.isEmpty else { return 0 }
        return max(0, counts.total - shown.count)
    }

    /// Trailing caption2 on the lock screen: overflow, stale notice, or both.
    func lockScreenTrailingCaption(isStale: Bool) -> String? {
        let overflow = lockScreenOverflowCount(isStale: isStale)
        let staleCaption = "May be out of date"
        if isStale {
            if overflow > 0 {
                return "+\(overflow) more · \(staleCaption)"
            }
            return staleCaption
        }
        if overflow > 0 {
            return "+\(overflow) more"
        }
        return nil
    }
}

/// Synchronous render-time helper. Failures degrade to counts-only so a
/// view body never has to throw (nil envelope, locked Keychain before
/// first unlock, unknown kid, decrypt or payload error).
enum AgentActivityDecryptor {
    static func presentation(
        for state: AgentActivityAttributes.ContentState,
        store: NotificationKeyStore = NotificationKeyStore(),
        mirror: NotificationKeyMirror = NotificationKeyMirror()
    ) -> AgentActivityPresentation {
        #if DEBUG
            lastFailureReason = nil
        #endif
        guard let envelope = state.envelope,
            let data = try? JSONEncoder().encode(envelope),
            let kid = SealedEnvelopeCodec.peekKeyID(in: data)
        else {
            breadcrumb("no envelope or unreadable kid")
            return .countsOnly(counts: state.counts)
        }

        // The Keychain is unreachable in the locked lock-screen rendering
        // context (errSecNotAvailable); the app-group mirror is maintained
        // for exactly that gap, so a kid missing from whichever Keychain
        // records did load falls through to it as well.
        let records = (try? store.allRecords()) ?? []
        guard
            let record = records.first(where: { $0.keyID == kid })
                ?? mirror.read().first(where: { $0.keyID == kid })
        else {
            breadcrumb("kid \(kid) not among \(records.map(\.keyID)) nor mirrored")
            return .countsOnly(counts: state.counts)
        }
        let opened: AgentActivityDetails
        do {
            opened = try AgentActivityEnvelope.open(data, using: record.key)
        } catch {
            breadcrumb("open failed: \(error)")
            return .countsOnly(counts: state.counts)
        }

        return .detailed(details: opened, counts: state.counts)
    }

    /// Debug-only: why the last `presentation(for:)` in this process fell
    /// back to counts-only, for on-lock-screen diagnosis of device-only
    /// failures. Rendered by the lock-screen view in Debug builds.
    #if DEBUG
        nonisolated(unsafe) static var lastFailureReason: String?
    #endif

    /// Debug-only render-time trace into the shared app-group container, so
    /// a countsOnly fallback on a physical device can name its cause
    /// (`devicectl device copy from --domain-type appGroupDataContainer`).
    private static func breadcrumb(_ reason: String) {
        #if DEBUG
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: NotificationKeyStore.sharedAccessGroup)
            lastFailureReason = "\(reason) | group: \(container == nil ? "nil" : "ok")"
            guard let url = container else { return }
            let line = "\(Date()) \(reason)\n"
            let file = url.appendingPathComponent("activity-decrypt-debug.txt")
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: file)
            }
        #endif
    }
}

enum AgentActivityCopy {
    static let genericAppName = "Heeler"
    // Governs the Dynamic Island expanded rows (headline + rowLimit - 1);
    // the lock screen sizes itself via `lockScreenAgents` instead.
    static let rowLimit = 3
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

    /// First non-zero count in attention order: blocked, done, working.
    var attentionStatusItem: (status: String, count: Int)? {
        if blocked > 0 { return ("blocked", blocked) }
        if done > 0 { return ("done", done) }
        if working > 0 { return ("working", working) }
        return nil
    }
}
