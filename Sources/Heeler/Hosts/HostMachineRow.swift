import SwiftUI

/// One Hosts list row (ADR 0047): a Host, read from the Servers that are on.
/// The one that most needs the user decides where the row is filed and what
/// it says; each keeps its own mark on its chip.
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
            (
                record: record,
                row: HostRowPresentation(
                    host: record, status: statuses[record.id], standingFailure: standingFailures[record.id],
                    latency: latencies[record.id], syncIssue: syncIssues[record.id], canRetry: canRetry)
            )
        }
        servers = rows.map { record, row in
            Server(
                id: record.id, label: record.serverKey?.label ?? record.serverKind.displayName,
                tone: row.tone, offersRetry: row.offersRetry, isDialing: row.isDialing)
        }
        // The first of the Servers in the group that comes first, one out of
        // sync ahead of the healthy.
        let lead = rows.map(\.row).min { lhs, rhs in
            (lhs.group.rawValue, lhs.tone == .connected ? 1 : 0)
                < (rhs.group.rawValue, rhs.tone == .connected ? 1 : 0)
        }
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
            let measured = rows.compactMap { record, row in
                row.group == .connected ? latencies[record.id] : nil
            }
            trailing = measured.min().map(HostLatencyFormatting.formatted) ?? lead.trailing
        } else {
            detail = lead.detail
            trailing = nil
        }
    }
}

/// The first line of a Hosts list row: the Host's state, name, and what is
/// under it.
struct HostMachineRowHeadline: View {
    let presentation: HostMachineRowPresentation

    var body: some View {
        HStack(spacing: 12) {
            HostStatusGlyph(tone: presentation.tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(presentation.detail)
                    .font(.subheadline)
                    .foregroundStyle(presentation.isProblem ? Color.red : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let trailing = presentation.trailing {
                Text(trailing)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The second line of a Hosts list row: a chip for each Server that is on,
/// then a dashed one for each Server found since and not shown yet.
struct HostServerChips: View {
    let servers: [HostMachineRowPresentation.Server]
    /// Labels of the Servers found on the Host that the user has not seen.
    let unseen: [String]

    /// How many found Servers the row names before it counts the rest: the
    /// row points at news, and Host detail lists it.
    private static let unseenLimit = 2

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
        ChipWrap(spacing: 5) {
            if servers.isEmpty {
                HostServerChip(label: String(localized: "No servers on"), isDimmed: true)
            }
            ForEach(servers) { @Sendable server in
                HostServerChip(label: server.label, tone: server.tone, isDimmed: server.tone != .connected)
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
    var tone: HostConnectionTone?
    let isDimmed: Bool

    var body: some View {
        HStack(spacing: 5) {
            if let tone {
                HostToneBadge(tone: tone)
                    .frame(width: 7, height: 7)
            }
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(isDimmed ? .secondary : .primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 22)
        .background(Color(.tertiarySystemFill).opacity(isDimmed ? 0.6 : 1), in: Capsule())
    }
}

/// A Server found on the Host and off: dashed, to say it is not in yet.
private struct HostFoundServerChip: View {
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "plus")
                .font(.caption2.weight(.semibold))
            Text(label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(.tint)
        .padding(.horizontal, 8)
        .frame(minHeight: 22)
        .overlay {
            Capsule().strokeBorder(.tint.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
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
