import SwiftUI
import UIKit

/// Shared Catppuccin Mocha/Latte tokens for Antigravity CLI Swarm cards.
enum ChatSwarmPalette {
    private static let mauveWashUI = flavoured(mocha: 0xCBA6F7, latte: 0x8839EF)
    private static let mauveInkUI = flavoured(mocha: 0xCBA6F7, latte: 0x6C22C7)
    private static let sapphireInkUI = flavoured(mocha: 0x74C7EC, latte: 0x209FB5)

    static let accentInk = Color(uiColor: mauveInkUI)
    static let accentWash = Color(uiColor: mauveWashUI).opacity(0.15)
    static let coordinatorInk = Color(uiColor: sapphireInkUI)
    static let coordinatorWash = Color(uiColor: sapphireInkUI).opacity(0.14)

    static func stripBorder(for swarm: AgySwarmSnapshot) -> Color {
        if swarm.hasSystemAlerts {
            return Color(uiColor: AgentStatusPalette.red).opacity(0.34)
        }
        if swarm.hasActiveWorkers {
            return Color(uiColor: AgentStatusPalette.yellow).opacity(0.34)
        }
        return Color(uiColor: mauveWashUI).opacity(0.28)
    }

    static func memberStatusInk(_ status: AgySwarmSnapshot.MemberStatus) -> Color {
        switch status {
        case .working: Color(uiColor: AgentStatusPalette.yellowInk)
        case .waiting: Color(uiColor: AgentStatusPalette.mutedInk)
        case .error: Color(uiColor: AgentStatusPalette.redInk)
        case .killed: Color(uiColor: AgentStatusPalette.mutedInk).opacity(0.75)
        }
    }

    static func memberStatusWash(_ status: AgySwarmSnapshot.MemberStatus) -> Color {
        switch status {
        case .working: Color(uiColor: AgentStatusPalette.yellow).opacity(0.15)
        case .waiting: Color(uiColor: AgentStatusPalette.muted).opacity(0.16)
        case .error: Color(uiColor: AgentStatusPalette.red).opacity(0.15)
        case .killed: Color(uiColor: AgentStatusPalette.muted).opacity(0.12)
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

/// Dedicated Swarm Live Bar floating above the Composer:
/// - Resting: 2-row glass card showing Swarm title, member status dots, `#seq`
///   post count, and a 1-line live board/activity ticker.
/// - Condensed (keyboard up or Blocked card shown): 1-line summary bar.
/// Tapping anywhere opens `ChatSwarmSheet`.
struct ChatSwarmLiveBar: View {
    let swarm: AgySwarmSnapshot
    let isCondensed: Bool
    let open: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var glyphColumn: CGFloat = 18

    private static let hint = String(localized: "Opens the swarm board and member status.")

    var body: some View {
        Group {
            if isCondensed {
                condensedBar
            } else {
                expandedBar
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var expandedBar: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 8) {
                    leadingGlyph
                        .frame(width: glyphColumn)

                    Text(verbatim: swarm.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    trailingMeta
                }

                if let ticker = swarm.tickerText {
                    Text(verbatim: ticker)
                        .font(.caption)
                        .foregroundStyle(
                            swarm.hasSystemAlerts
                                ? ChatBackgroundWorkPalette.statusInk(.failed)
                                : .secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .padding(.leading, glyphColumn + 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                ChatBackgroundWorkStyle.card
                    .fill(.regularMaterial)
                    .overlay {
                        if swarm.hasSystemAlerts {
                            ChatBackgroundWorkStyle.card.fill(
                                LinearGradient(
                                    colors: [Color(uiColor: AgentStatusPalette.red).opacity(0.08), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom))
                        } else if swarm.hasActiveWorkers {
                            ChatBackgroundWorkStyle.card.fill(
                                LinearGradient(
                                    colors: [Color(uiColor: AgentStatusPalette.yellow).opacity(0.07), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom))
                        } else {
                            ChatBackgroundWorkStyle.card.fill(
                                LinearGradient(
                                    colors: [ChatSwarmPalette.accentWash.opacity(0.45), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom))
                        }
                    }
            }
            .overlay {
                ChatBackgroundWorkStyle.card
                    .stroke(ChatSwarmPalette.stripBorder(for: swarm), lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Swarm: \(swarm.displayTitle)"))
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint(Self.hint)
        .accessibilityAddTraits(swarm.hasActiveWorkers ? [.isButton, .updatesFrequently] : .isButton)
        .accessibilityAction(.default, open)
        .accessibilityIdentifier("chat.swarm.bar")
    }

    private var condensedBar: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                leadingGlyph
                    .frame(width: glyphColumn)

                Text(verbatim: condensedSummaryText)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(swarm.hasActiveWorkers || swarm.hasSystemAlerts ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !swarm.taskWorkers.isEmpty {
                    ChatSwarmMemberDots(workers: swarm.taskWorkers)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: ChatBackgroundWorkStyle.card)
            .overlay {
                ChatBackgroundWorkStyle.card
                    .stroke(ChatSwarmPalette.stripBorder(for: swarm), lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Swarm: \(swarm.displayTitle)"))
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint(Self.hint)
        .accessibilityAddTraits(swarm.hasActiveWorkers ? [.isButton, .updatesFrequently] : .isButton)
        .accessibilityAction(.default, open)
        .accessibilityIdentifier("chat.swarm.summary")
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        if swarm.hasSystemAlerts {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.failed))
                .accessibilityHidden(true)
        } else if swarm.hasActiveWorkers {
            ChatBackgroundWorkSpinningArc(size: 13, lineWidth: 2)
                .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.running))
        } else {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ChatSwarmPalette.accentInk)
                .accessibilityHidden(true)
        }
    }

    private var trailingMeta: some View {
        HStack(spacing: 6) {
            if !swarm.taskWorkers.isEmpty {
                ChatSwarmMemberDots(workers: swarm.taskWorkers)
            }
            if swarm.postCount > 0 {
                Text(verbatim: "#\(swarm.postCount)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var condensedSummaryText: String {
        var parts: [String] = [swarm.displayTitle]
        let activeCount = swarm.activeTaskWorkers.count
        if swarm.hasSystemAlerts {
            parts.append(String(localized: "Needs attention"))
        } else if activeCount > 0 {
            parts.append(String(localized: "\(activeCount) active"))
        } else if !swarm.waitingTaskWorkers.isEmpty {
            parts.append(String(localized: "Idle"))
        }
        if swarm.postCount > 0 {
            parts.append("#\(swarm.postCount)")
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilitySummary: String {
        var clauses: [String] = []
        let activeCount = swarm.activeTaskWorkers.count
        let waitingCount = swarm.waitingTaskWorkers.count
        if activeCount > 0 {
            clauses.append(String(localized: "\(activeCount) active"))
        }
        if waitingCount > 0 {
            clauses.append(String(localized: "\(waitingCount) waiting"))
        }
        if swarm.postCount > 0 {
            clauses.append("#\(swarm.postCount)")
        }
        if let ticker = swarm.tickerText {
            clauses.append(ticker)
        }
        return clauses.joined(separator: ", ")
    }
}

/// Compact capsule showing each non-killed task worker as a status dot
/// (`●` yellow = working, `●` red = error, `○` muted = waiting).
struct ChatSwarmMemberDots: View {
    let workers: [AgySwarmSnapshot.Member]

    private var liveWorkers: [AgySwarmSnapshot.Member] {
        let nonKilled = workers.filter { !$0.isKilled }
        return nonKilled.isEmpty ? workers : nonKilled
    }

    var body: some View {
        let shown = Array(liveWorkers.prefix(8))
        let overflow = max(0, liveWorkers.count - shown.count)
        if !shown.isEmpty {
            HStack(spacing: 4) {
                ForEach(shown) { member in
                    dot(for: member)
                }
                if overflow > 0 {
                    Text(verbatim: "+\(overflow)")
                        .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6.5)
            .padding(.vertical, 3.5)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func dot(for member: AgySwarmSnapshot.Member) -> some View {
        switch member.status {
        case .working:
            Circle()
                .fill(Color(uiColor: AgentStatusPalette.yellow))
                .frame(width: 6.5, height: 6.5)
        case .error:
            Circle()
                .fill(Color(uiColor: AgentStatusPalette.red))
                .frame(width: 6.5, height: 6.5)
        case .waiting:
            Circle()
                .strokeBorder(Color(uiColor: AgentStatusPalette.mutedInk).opacity(0.75), lineWidth: 1.4)
                .frame(width: 6.5, height: 6.5)
        case .killed:
            Circle()
                .fill(Color(uiColor: AgentStatusPalette.muted).opacity(0.45))
                .frame(width: 5.5, height: 5.5)
        }
    }
}
