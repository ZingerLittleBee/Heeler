import SwiftUI

/// One Hosts list row (ADR 0047, ADR 0058): a Host, read from the Servers that
/// are on. While any Server is connected, the Host is connected; otherwise the
/// Server that most needs the user decides where the row is filed and what it
/// says. Each Server keeps its own state color on its badge.
struct HostMachineRowPresentation: Equatable {
    /// A Server that is on.
    struct Server: Equatable, Identifiable {
        /// Its catalog record.
        let id: Host.ID
        let label: String
        let tone: HostConnectionTone
        let offersRetry: Bool
        /// The user's own retry is dialing.
        let isDialing: Bool

        /// Lower ranks stay visible first when a Host has more Servers than a
        /// compact list row renders inline.
        fileprivate var attentionRank: Int {
            switch tone {
            case .unavailable: 0
            case .warning, .reconnecting: 1
            case .pending: 2
            case .connected, .paused: 3
            }
        }
    }

    let name: String
    let group: HostHealthGroup
    let tone: HostConnectionTone
    /// Under the name: how the Host is reached while all is well, otherwise
    /// the state of the Server that most needs the user.
    let detail: String
    /// A stopped Server's reason reads in red.
    let isProblem: Bool
    /// The best latency among the connected Servers.
    let trailing: String?
    /// Empty for a Host with no Server on.
    let servers: [Server]

    /// The records a Retry dials: every Server that stopped.
    var retryIDs: [Host.ID] { servers.filter(\.offersRetry).map(\.id) }

    /// `detail`, omitted when it would only repeat an unnamed Host's `name`.
    var subtitle: String? { detail == name ? nil : detail }

    init(
        machine: HostMachine,
        statuses: [Host.ID: EventsSessionStatus] = [:],
        standingFailures: [Host.ID: TransportError] = [:],
        latencies: [Host.ID: Duration] = [:],
        syncIssues: [Host.ID: String] = [:],
        canRetry: Bool = true
    ) {
        name = machine.name
        let rows = machine.servers.map { record in
            let status = statuses[record.id]
            let standingFailure = standingFailures[record.id]
            return (
                record: record,
                row: HostRowPresentation(
                    host: record, status: status, standingFailure: standingFailure,
                    latency: latencies[record.id], syncIssue: syncIssues[record.id], canRetry: canRetry),
                isServerFailure: (status?.failure ?? standingFailure)?.isServerFailure == true
            )
        }
        servers = rows.map { record, row, _ in
            Server(
                id: record.id, label: record.serverKey?.badgeLabel ?? record.serverKind.badgeName,
                tone: row.tone, offersRetry: row.offersRetry, isDialing: row.isDialing)
        }
        // Any connected Server proves the Host is connected (ADR 0058), with
        // one out of sync ahead of the healthy; when none is connected, a
        // failure of the Host's connection leads one of a single Server.
        let connectedRows = rows.filter { $0.row.group == .connected }
        let lead = (connectedRows.isEmpty ? rows : connectedRows).min { lhs, rhs in
            (lhs.row.group.rawValue, lhs.isServerFailure ? 1 : 0, lhs.row.tone == .connected ? 1 : 0)
                < (rhs.row.group.rawValue, rhs.isServerFailure ? 1 : 0, rhs.row.tone == .connected ? 1 : 0)
        }?.row
        guard let lead else {
            group = .notConnected
            tone = .paused
            detail = machine.connectionSummary
            isProblem = false
            trailing = nil
            return
        }
        group = lead.group
        tone = lead.tone
        isProblem = lead.isProblem
        if lead.group == .connected {
            detail = lead.tone == .connected ? machine.connectionSummary : lead.detail
            let measured = connectedRows.compactMap { latencies[$0.record.id] }
            trailing = measured.min().map(HostLatencyFormatting.formatted) ?? lead.trailing
        } else {
            detail = lead.detail
            trailing = nil
        }
    }
}

/// The content column of a Hosts list row beside its leading `HostStatusGlyph`
/// and any trailing action: Host name, optional route/status subtitle, and
/// Server badges stacked on the left, with latency always vertically centered
/// on the right.
struct HostMachineRowContent: View {
    let presentation: HostMachineRowPresentation
    var unseen: [String] = []
    /// After the name: Plugin or Helper updates wait on this Host.
    var updateTag: HostUpdatesSnapshot.Tag?
    var showsTrailing = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 6) {
                        titleText
                        if let updateTag { HostUpdateTag(tag: updateTag) }
                    }
                    if let subtitle = presentation.subtitle {
                        subtitleText(subtitle)
                    }
                }
                HostServerChips(servers: presentation.servers, unseen: unseen)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            if showsTrailing, let trailing = presentation.trailing {
                trailingText(trailing)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var titleText: some View {
        Text(presentation.name)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.primary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            .truncationMode(.middle)
    }

    private func trailingText(_ trailing: String) -> some View {
        let compact = trailing.replacingOccurrences(of: " ms", with: "\u{200A}ms")
        return Text(compact)
            .font(.caption2)
            .tracking(-0.3)
            .foregroundStyle(Color(uiColor: .tertiaryLabel))
            .lineLimit(1)
            .accessibilityLabel(trailing)
    }

    private func subtitleText(_ subtitle: String) -> some View {
        let maxLines =
            if presentation.isProblem {
                dynamicTypeSize.isAccessibilitySize ? 3 : 2
            } else {
                dynamicTypeSize.isAccessibilitySize ? 2 : 1
            }
        return Text(subtitle)
            .font(.footnote)
            .foregroundStyle(presentation.isProblem ? Color.errorInk : Color.secondary)
            .lineLimit(maxLines)
            .truncationMode(presentation.isProblem ? .tail : .middle)
            .fixedSize(horizontal: false, vertical: presentation.isProblem)
    }
}

/// Compact strip of Server badges on every Host row: a badge for each Server
/// that is on (including a single `Herdr TUI`, `herdr-core`, or `tmux` Server),
/// a muted badge when none is on, and dashed tint badges for newly discovered
/// Servers that are still off.
struct HostServerChips: View {
    let servers: [HostMachineRowPresentation.Server]
    /// Labels of the Servers found on the Host that the user has not seen.
    let unseen: [String]

    /// Maximum active Server badges rendered inline before summarizing the rest
    /// so a Host with many named sessions or sockets stays compact.
    private static let serverLimit = 4
    /// How many found Servers the row names before it counts the rest: the
    /// row points at news, and Host detail lists it.
    private static let unseenLimit = 2

    private var visibleServers: [HostMachineRowPresentation.Server] {
        guard servers.count > Self.serverLimit else { return servers }
        let indexed = Array(servers.enumerated())
        let prioritized = indexed.sorted { lhs, rhs in
            (lhs.element.attentionRank, lhs.offset) < (rhs.element.attentionRank, rhs.offset)
        }
        let kept = Set(prioritized.prefix(Self.serverLimit).map(\.offset))
        return indexed.filter { kept.contains($0.offset) }.map(\.element)
    }

    private var overflowServerCount: Int {
        max(0, servers.count - Self.serverLimit)
    }

    /// The chips in words. A Hosts list row is one VoiceOver stop, so it reads
    /// them as its value: where only a colored mark shows a state, a word does.
    var spokenSummary: String {
        var parts = servers.map { String(localized: "\($0.label), \($0.tone.spokenState)") }
        if servers.isEmpty { parts.append(String(localized: "No servers on")) }
        parts += unseen.prefix(Self.unseenLimit).map { String(localized: "\($0), found, not on") }
        if unseen.count > Self.unseenLimit {
            parts.append(String(localized: "\(unseen.count - Self.unseenLimit) more found"))
        }
        return parts.joined(separator: "; ")
    }

    var body: some View {
        ChipWrap(spacing: 4, lineSpacing: 4) {
            if servers.isEmpty {
                HostServerChip(label: String(localized: "No servers on"), tone: nil)
            }
            ForEach(visibleServers) { @Sendable server in
                HostServerChip(label: server.label, tone: server.tone)
            }
            if overflowServerCount > 0 {
                HostServerChip(label: String(localized: "+\(overflowServerCount) more"), tone: nil)
            }
            ForEach(unseen.prefix(Self.unseenLimit), id: \.self) { @Sendable label in
                HostFoundServerChip(label: label)
            }
            if unseen.count > Self.unseenLimit {
                HostFoundServerChip(label: String(localized: "\(unseen.count - Self.unseenLimit) more"))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct HostServerChip: View {
    let label: String
    let tone: HostConnectionTone?

    private var needsAttention: Bool {
        switch tone {
        case .unavailable, .warning, .reconnecting: true
        case .connected, .pending, .paused, nil: false
        }
    }

    private var labelColor: Color {
        switch tone {
        case .connected: Self.connectedLabel
        case .warning, .reconnecting: Self.warningLabel
        case .unavailable: Self.unavailableLabel
        case .pending: Color.secondary
        case .paused, nil: Color(uiColor: .tertiaryLabel)
        }
    }

    private var fillStyle: Color {
        switch tone {
        case .connected: Self.connectedFill
        case .warning, .reconnecting: Self.warningFill
        case .unavailable: Self.unavailableFill
        case .pending: Color(uiColor: .tertiarySystemFill)
        case .paused, nil: Color(uiColor: .quaternarySystemFill)
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(needsAttention ? .semibold : .medium))
            .foregroundStyle(labelColor)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(fillStyle, in: Capsule())
    }

    private static let connectedLabel = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.systemGreen.withAlphaComponent(0.9)
            : UIColor(red: 0.09, green: 0.50, blue: 0.21, alpha: 1)
    })

    private static let connectedFill = Color(uiColor: UIColor { traits in
        UIColor.systemGreen.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.14 : 0.12)
    })

    private static let warningLabel = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.systemOrange.withAlphaComponent(0.95)
            : UIColor(red: 0.76, green: 0.38, blue: 0.0, alpha: 1)
    })

    private static let warningFill = Color(uiColor: UIColor { traits in
        UIColor.systemOrange.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.16 : 0.13)
    })

    private static let unavailableLabel = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.systemRed.withAlphaComponent(0.95)
            : UIColor(red: 0.82, green: 0.12, blue: 0.14, alpha: 1)
    })

    private static let unavailableFill = Color(uiColor: UIColor { traits in
        UIColor.systemRed.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.16 : 0.11)
    })
}

/// A Server found on the Host and off: dashed, to say it is not in yet.
private struct HostFoundServerChip: View {
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .fixedSize()
            Text(label)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Color.accentColor.opacity(0.08), in: Capsule())
        .overlay {
            Capsule().strokeBorder(.tint.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
    }
}

extension ServerKind {
    /// How a Server Kind reads on a Hosts list badge.
    var badgeName: String {
        switch self {
        case .herdrTUI: String(localized: "Herdr TUI")
        case .herdrCore: "Herdr Core"
        case .tmux: "Tmux"
        case .rex: "Rex"
        case .unconfirmed: String(localized: "Not confirmed")
        }
    }
}

extension HostServerKey {
    /// Compact badge label on the Hosts list: a named Herdr TUI session shows
    /// its session name directly without the `Herdr TUI` prefix, while
    /// `herdr-core` and `tmux` read as `Herdr Core` and `Tmux`.
    var badgeLabel: String {
        guard let distinguishingName else { return kind.badgeName }
        if kind == .herdrTUI { return distinguishingName }
        return "\(kind.badgeName) · \(distinguishingName)"
    }
}

extension HostConnectionTone {
    /// The state in a word, for VoiceOver where only a colored mark shows it.
    var spokenState: String {
        switch self {
        case .connected: String(localized: "connected")
        case .pending: String(localized: "connecting")
        case .paused: String(localized: "paused")
        case .reconnecting: String(localized: "reconnecting")
        case .warning: String(localized: "sync issue")
        case .unavailable: String(localized: "unavailable")
        }
    }
}
