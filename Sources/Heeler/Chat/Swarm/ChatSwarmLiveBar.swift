import SwiftUI
import UIKit

/// Shared Catppuccin Mocha/Latte tokens for the Antigravity CLI Swarm.
enum ChatSwarmPalette {
    private static let mauveWashUI = flavoured(mocha: 0xCBA6F7, latte: 0x8839EF)
    private static let mauveInkUI = flavoured(mocha: 0xCBA6F7, latte: 0x6C22C7)

    static let accentInk = Color(uiColor: mauveInkUI)
    static let accentWash = Color(uiColor: mauveWashUI).opacity(0.15)

    static func memberStatusInk(_ status: AgySwarmSnapshot.MemberStatus) -> Color {
        switch status {
        case .working: Color(uiColor: AgentStatusPalette.yellowInk)
        case .waiting: Color(uiColor: AgentStatusPalette.mutedInk)
        case .error: Color(uiColor: AgentStatusPalette.redInk)
        case .killed: Color(uiColor: AgentStatusPalette.mutedInk).opacity(0.75)
        }
    }

    private static func flavoured(mocha: UInt32, latte: UInt32) -> UIColor {
        UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? mocha : latte
            return UIColor(
                red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1)
        }
    }
}

/// The Swarm's row on the strip over the Composer
/// (`ChatBackgroundWorkStrip`), which it leads:
/// - Resting: its title, a dot for each worker and the `#seq` post count,
///   over one line of the board's latest.
/// - Condensed (keyboard up or Blocked card shown): one line.
/// Tapping it opens `ChatSwarmSheet`.
struct ChatSwarmLiveBar: View {
    fileprivate struct Summary: Equatable {
        let displayTitle: String
        let hasSystemAlerts: Bool
        let hasActiveWorkers: Bool
        let activeCount: Int
        let waitingCount: Int
        let postCount: Int
        let tickerText: String?
        let dotStatuses: [AgySwarmSnapshot.MemberStatus]

        init(swarm: AgySwarmSnapshot) {
            self.displayTitle = swarm.displayTitle
            self.hasSystemAlerts = swarm.hasSystemAlerts
            let workers = swarm.taskWorkers
            let active = workers.count { $0.status == .working }
            let waiting = workers.count { $0.status == .waiting }
            self.activeCount = active
            self.waitingCount = waiting
            self.hasActiveWorkers = active > 0
            self.postCount = swarm.postCount
            self.tickerText = swarm.tickerText
            let nonKilled = workers.filter { !$0.isKilled }
            let source = nonKilled.isEmpty ? workers : nonKilled
            self.dotStatuses = source.map(\.status)
        }
    }

    private let summary: Summary
    let isCondensed: Bool
    let open: () -> Void

    init(swarm: AgySwarmSnapshot, isCondensed: Bool, open: @escaping () -> Void) {
        self.summary = Summary(swarm: swarm)
        self.isCondensed = isCondensed
        self.open = open
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var glyphColumn = ChatBackgroundWorkStyle.glyphColumn

    private static let hint = String(localized: "Opens the swarm board and member status.")

    var body: some View {
        Button(action: open) {
            Group {
                if isCondensed {
                    condensedLabel
                } else {
                    restingLabel
                }
            }
            .modifier(ChatStripRow(glyphColumn: glyphColumn, isDivided: false))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Swarm: \(summary.displayTitle)"))
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint(Self.hint)
        .accessibilityAddTraits(summary.hasActiveWorkers ? [.isButton, .updatesFrequently] : .isButton)
        .accessibilityAction(.default, open)
        .accessibilityIdentifier(isCondensed ? "chat.swarm.summary" : "chat.swarm.bar")
    }

    private var restingLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: ChatBackgroundWorkStyle.glyphSpacing) {
                leadingGlyph
                    .frame(width: glyphColumn)

                Text(verbatim: summary.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 0)

                trailingMeta
            }

            if let ticker = summary.tickerText {
                Text(verbatim: ticker)
                    .font(.footnote)
                    .foregroundStyle(
                        summary.hasSystemAlerts
                            ? ChatBackgroundWorkPalette.statusInk(.failed)
                            : .secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .padding(.leading, glyphColumn + ChatBackgroundWorkStyle.glyphSpacing)
            }
        }
        .padding(.vertical, 10)
    }

    private var condensedLabel: some View {
        HStack(spacing: ChatBackgroundWorkStyle.glyphSpacing) {
            leadingGlyph
                .frame(width: glyphColumn)

            Text(verbatim: condensedSummaryText)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(summary.hasActiveWorkers || summary.hasSystemAlerts ? .primary : .secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            ChatSwarmStatusDots(statuses: summary.dotStatuses)

            ChatStripChevron()
        }
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        if summary.hasSystemAlerts {
            Image(systemName: "exclamationmark.triangle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.failed))
                .accessibilityHidden(true)
        } else if summary.hasActiveWorkers {
            ChatBackgroundWorkGlyph(status: .running, size: .regular)
        } else {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ChatSwarmPalette.accentInk)
                .accessibilityHidden(true)
        }
    }

    private var trailingMeta: some View {
        HStack(spacing: 8) {
            ChatSwarmStatusDots(statuses: summary.dotStatuses)
            if summary.postCount > 0 {
                Text(verbatim: "#\(summary.postCount)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ChatStripChevron()
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var condensedSummaryText: String {
        var parts: [String] = [summary.displayTitle]
        if summary.hasSystemAlerts {
            parts.append(String(localized: "Needs attention"))
        } else if summary.activeCount > 0 {
            parts.append(String(localized: "\(summary.activeCount) active"))
        } else if summary.waitingCount > 0 {
            parts.append(String(localized: "Idle"))
        }
        if summary.postCount > 0 {
            parts.append("#\(summary.postCount)")
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilitySummary: String {
        var clauses: [String] = []
        if summary.activeCount > 0 {
            clauses.append(String(localized: "\(summary.activeCount) active"))
        }
        if summary.waitingCount > 0 {
            clauses.append(String(localized: "\(summary.waitingCount) waiting"))
        }
        if summary.postCount > 0 {
            clauses.append("#\(summary.postCount)")
        }
        if let ticker = summary.tickerText {
            clauses.append(ticker)
        }
        return clauses.joined(separator: ", ")
    }
}

/// A dot for each task worker still in the Swarm: filled yellow while it
/// works, red on an error, a ring while it waits.
struct ChatSwarmStatusDots: View, Equatable {
    let statuses: [AgySwarmSnapshot.MemberStatus]

    var body: some View {
        let shown = Array(statuses.prefix(8))
        let overflow = max(0, statuses.count - shown.count)
        if !shown.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, status in
                    dot(for: status)
                }
                if overflow > 0 {
                    Text(verbatim: "+\(overflow)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func dot(for status: AgySwarmSnapshot.MemberStatus) -> some View {
        switch status {
        case .working:
            Circle()
                .fill(Color(uiColor: AgentStatusPalette.yellow))
                .frame(width: 7, height: 7)
        case .error:
            Circle()
                .fill(Color(uiColor: AgentStatusPalette.red))
                .frame(width: 7, height: 7)
        case .waiting:
            Circle()
                .strokeBorder(Color(uiColor: AgentStatusPalette.mutedInk).opacity(0.75), lineWidth: 1.5)
                .frame(width: 7, height: 7)
        case .killed:
            Circle()
                .fill(Color(uiColor: AgentStatusPalette.muted).opacity(0.45))
                .frame(width: 6, height: 6)
        }
    }
}
