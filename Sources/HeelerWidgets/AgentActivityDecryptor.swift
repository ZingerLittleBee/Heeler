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

    func lockScreenHostName(hostID: String, snapshot: LiveActivityHostSnapshot?) -> String? {
        if let name = snapshot?.name(forHostID: hostID), !name.isEmpty { return name }
        if case .detailed(let details, _) = self, !details.hostName.isEmpty {
            return details.hostName
        }
        return nil
    }

    var agents: [AgentActivityDetails.AgentDetail] {
        switch self {
        case .detailed(let details, _):
            return details.agents
        case .countsOnly:
            return []
        }
    }

    /// Rows drawn in the expanded Dynamic Island, under its status header:
    /// as many of the first `rowLimit` Agents as fit, with the overflow
    /// caption when some are left out, in the height the island leaves them.
    var expandedAgents: [AgentActivityDetails.AgentDetail] {
        let metrics = AgentActivityIslandMetrics.self
        let candidates = Array(agents.prefix(AgentActivityCopy.rowLimit))
        for shown in stride(from: candidates.count, through: 1, by: -1) {
            let prefix = Array(candidates.prefix(shown))
            let rowHeight = prefix.reduce(0) { $0 + metrics.rowHeight(for: $1) }
            let lines = CGFloat(counts.total > shown ? shown + 1 : shown)
            let captionHeight = counts.total > shown ? metrics.overflowCaptionHeight : 0
            let height = rowHeight + captionHeight + (lines - 1) * metrics.rowSpacing
            if height <= metrics.rowsHeightBudget { return prefix }
        }
        return Array(candidates.prefix(1))
    }

    /// Remaining eligible agents beyond the expanded rows, using the full
    /// inventory in `counts` (the envelope list is capped at 5). Zero in
    /// counts-only: there is nothing to overflow from.
    var overflowCount: Int {
        let shown = expandedAgents.count
        guard shown > 0 else { return 0 }
        return max(0, counts.total - shown)
    }

    /// Reserve the Host heading before fitting complete linked Agent entries.
    func lockScreenAgents(
        isStale: Bool, hasHeader: Bool = true
    ) -> [AgentActivityDetails.AgentDetail] {
        let total = counts.total
        guard total > 0 else { return [] }
        let candidates = Array(agents.prefix(min(total, 4)))
        guard !candidates.isEmpty else { return [] }
        for shown in stride(from: candidates.count, through: 1, by: -1) {
            let prefix = Array(candidates.prefix(shown))
            let target = AgentActivityRowMetrics.lockScreenMinimumHeight(agentCount: shown)
            let rowHeight = prefix.reduce(0) {
                $0 + max(target, AgentActivityRowMetrics.minimumHeight(for: $1))
            }
            let captionHeight = isStale || total > shown
                ? AgentActivityRowMetrics.lockScreenCaptionHeight : 0
            let padding = AgentActivityRowMetrics.lockScreenBannerVerticalPadding * 2
            let headerHeight = hasHeader ? AgentActivityRowMetrics.lockScreenHeaderHeight : 0
            if rowHeight + padding + captionHeight + headerHeight
                <= AgentActivityRowMetrics.lockScreenHeightBudget
            {
                return prefix
            }
        }
        return Array(candidates.prefix(1))
    }

    /// Inventory beyond the drawn lock-screen rows. Zero in counts-only.
    func lockScreenOverflowCount(isStale: Bool, hasHeader: Bool = true) -> Int {
        let shown = lockScreenAgents(isStale: isStale, hasHeader: hasHeader)
        guard !shown.isEmpty else { return 0 }
        return max(0, counts.total - shown.count)
    }

    /// Trailing caption2 on the lock screen: overflow, stale notice, or both.
    func lockScreenTrailingCaption(isStale: Bool, hasHeader: Bool = true) -> String? {
        let overflow = lockScreenOverflowCount(isStale: isStale, hasHeader: hasHeader)
        switch (isStale, overflow > 0) {
        case (true, true): return String(localized: "+\(overflow) more · May be out of date")
        case (true, false): return String(localized: "May be out of date")
        case (false, true): return String(localized: "+\(overflow) more")
        case (false, false): return nil
        }
    }
}

struct AgentActivityIslandPresentation: Equatable, Sendable {
    struct Mark: Equatable, Sendable, Identifiable {
        enum Kind: Equatable, Sendable {
            case status(String)
            case overflow
        }

        let id: Int
        let kind: Kind

        var status: String {
            if case .status(let status) = kind { return status }
            return "unknown"
        }

        var isOverflow: Bool {
            if case .overflow = kind { return true }
            return false
        }
    }

    let counts: AgentActivityAttributes.ContentState.Counts
    let marks: [Mark]
    let hostName: String?
    let hostLabel: String?
    let hasMultipleHosts: Bool

    init(
        presentation: AgentActivityPresentation,
        hostID: String,
        hostSnapshot: LiveActivityHostSnapshot?
    ) {
        counts = presentation.counts
        marks = Self.makeMarks(counts)
        hasMultipleHosts = (hostSnapshot?.hosts.count ?? 0) >= 2
        if hasMultipleHosts, let label = hostSnapshot?.label(forHostID: hostID), !label.isEmpty {
            hostLabel = label
        } else {
            hostLabel = nil
        }
        hostName = presentation.lockScreenHostName(hostID: hostID, snapshot: hostSnapshot)
    }

    var accessibilityLabel: String {
        var phrases = AgentActivityCopy.countPhrases(counts)
        if hasMultipleHosts, let hostName { phrases.insert(hostName, at: 0) }
        return phrases.joined(separator: String(
            localized: ", ",
            comment: "Separates the phrases of a list, as in “Ran 2 commands, Edited 2 files”."))
    }

    var minimalTileStatus: String? {
        guard hasMultipleHosts, hostLabel != nil else { return nil }
        return counts.attentionItems.first?.status
    }

    private static func makeMarks(_ counts: AgentActivityAttributes.ContentState.Counts) -> [Mark] {
        let limit = 4
        var result: [Mark] = []
        var remaining = limit
        for item in counts.attentionItems where remaining > 0 {
            let visible = min(item.count, remaining)
            for _ in 0..<visible {
                result.append(.init(id: result.count, kind: .status(item.status)))
            }
            remaining -= visible
        }
        if counts.total > limit {
            result[limit - 1] = .init(id: limit - 1, kind: .overflow)
        }
        return result
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
    // Governs the Dynamic Island expanded rows; the lock screen sizes itself
    // via `lockScreenAgents` instead.
    static let rowLimit = 3

    /// "2 blocked": a count and its status, in the language the widget
    /// renders in. The status stays a wire token for colors and glyphs; one
    /// this build does not know reads as the Host sent it.
    static func count(_ count: Int, status: String) -> String {
        switch status {
        case "blocked": String(localized: "\(count) blocked")
        case "working":
            String(localized: "\(count) working", comment: "Count of a Host's Agents by status, including Live Activity summaries and accessibility labels.")
        case "done":
            String(localized: "\(count) done", comment: "Count of a Host's Agents by status, including Live Activity summaries and accessibility labels.")
        case "idle": String(localized: "\(count) idle")
        default: "\(count) \(status)"
        }
    }

    static func lockScreenStatus(_ status: String) -> String {
        switch status {
        case "blocked":
            String(localized: "Needs you", comment: "Live Activity Agent status. The Agent is blocked waiting for the user's input; also used for an Agent error.")
        case "working": String(localized: "Working")
        case "done": String(localized: "Agent status Done", defaultValue: "Done")
        default: status
        }
    }

    static func lockScreenCounts(_ counts: AgentActivityAttributes.ContentState.Counts) -> String {
        countPhrases(counts).joined(separator: " · ")
    }

    static func countPhrases(_ counts: AgentActivityAttributes.ContentState.Counts) -> [String] {
        counts.chipItems.map { item in
            switch item.status {
            case "blocked":
                String(localized: "\(item.count) needs you", comment: "Live Activity count of Agents waiting for the user's input. Singular: 1 needs you; plural: 2 need you.")
            default:
                count(item.count, status: item.status)
            }
        }
    }
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

    /// Non-zero counts in attention order: blocked, done, working.
    var attentionItems: [(status: String, count: Int)] {
        var items: [(String, Int)] = []
        if blocked > 0 { items.append(("blocked", blocked)) }
        if done > 0 { items.append(("done", done)) }
        if working > 0 { items.append(("working", working)) }
        return items
    }
}
