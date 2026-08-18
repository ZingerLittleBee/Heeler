import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity for one Host. Lock-screen banner is an aggregate (header,
/// at most two rows, overflow), not a list — ~160pt budget.
struct AgentLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            AgentActivityLockScreenView(
                presentation: AgentActivityDecryptor.presentation(for: context.state)
            )
            .activityBackgroundTint(AgentActivityChrome.backgroundTint)
            .activitySystemActionForegroundColor(AgentActivityChrome.systemAction)
        } dynamicIsland: { context in
            AgentActivityIsland.make(
                presentation: AgentActivityDecryptor.presentation(for: context.state))
        }
    }
}

// MARK: - Lock screen

struct AgentActivityLockScreenView: View {
    let presentation: AgentActivityPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !presentation.visibleAgents.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(presentation.visibleAgents, id: \.paneID) { agent in
                        AgentActivityRowView(agent: agent)
                    }
                }
            }
            if presentation.overflowCount > 0 {
                Text("+\(presentation.overflowCount) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(lockScreenAccessibilityLabel)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            headerTitle
            Spacer(minLength: 8)
            AgentActivityCountChips(counts: presentation.counts)
        }
    }

    @ViewBuilder
    private var headerTitle: some View {
        switch presentation {
        case .detailed:
            Text(presentation.headerTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .countsOnly:
            Text(presentation.headerTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
    }

    private var lockScreenAccessibilityLabel: String {
        var parts = [presentation.headerTitle]
        parts.append(contentsOf: presentation.counts.chipItems.map { "\($0.count) \($0.status)" })
        for agent in presentation.visibleAgents {
            var row = "\(agent.kind), \(agent.status)"
            if let title = agent.title {
                row += ", \(title)"
            }
            parts.append(row)
        }
        if presentation.overflowCount > 0 {
            parts.append("\(presentation.overflowCount) more")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Dynamic Island

enum AgentActivityIsland {
    static func make(presentation: AgentActivityPresentation) -> DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                expandedHeader(presentation)
            }
            DynamicIslandExpandedRegion(.center) {
                if let first = presentation.visibleAgents.first {
                    AgentActivityRowView(agent: first)
                }
            }
            DynamicIslandExpandedRegion(.bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    if let second = presentation.visibleAgents.dropFirst().first {
                        AgentActivityRowView(agent: second)
                    }
                    if presentation.overflowCount > 0 {
                        Text("+\(presentation.overflowCount) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    AgentActivityCountChips(counts: presentation.counts)
                }
            }
        } compactLeading: {
            AgentActivityCompactLeading(counts: presentation.counts)
        } compactTrailing: {
            Text("\(presentation.counts.total)")
                .font(.body.weight(.semibold).monospacedDigit())
                .accessibilityLabel("\(presentation.counts.total) agents")
        } minimal: {
            Text("\(presentation.counts.total)")
                .font(
                    .body.weight(presentation.counts.blocked > 0 ? .bold : .semibold)
                        .monospacedDigit()
                )
                .foregroundStyle(
                    presentation.counts.blocked > 0
                        ? AgentActivityStatusStyle.ink(for: "blocked")
                        : Color.primary
                )
                .accessibilityLabel("\(presentation.counts.total) agents")
        }
    }

    @ViewBuilder
    private static func expandedHeader(_ presentation: AgentActivityPresentation) -> some View {
        switch presentation {
        case .detailed:
            Text(presentation.headerTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        case .countsOnly:
            Text(presentation.headerTitle)
                .font(.headline)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
    }
}

private struct AgentActivityCompactLeading: View {
    let counts: AgentActivityAttributes.ContentState.Counts

    var body: some View {
        if counts.blocked > 0 {
            Text("\(counts.blocked)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(AgentActivityStatusStyle.ink(for: "blocked"))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    AgentActivityStatusStyle.ink(for: "blocked").opacity(0.22),
                    in: Capsule())
                .accessibilityLabel("\(counts.blocked) blocked")
        } else {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.bold))
                .foregroundStyle(AgentActivityStatusStyle.ink(for: "working"))
                .accessibilityLabel("Working")
        }
    }
}

// MARK: - Shared pieces

private struct AgentActivityCountChips: View {
    let counts: AgentActivityAttributes.ContentState.Counts

    var body: some View {
        HStack(spacing: 5) {
            ForEach(counts.chipItems, id: \.status) { item in
                Text("\(item.count) \(item.status)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AgentActivityStatusStyle.ink(for: item.status))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        AgentActivityStatusStyle.ink(for: item.status).opacity(0.16),
                        in: Capsule())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            counts.chipItems.map { "\($0.count) \($0.status)" }.joined(separator: ", "))
    }
}

/// One agent row. Status is painted, not narrated as an event — a done
/// row is the current state, not "just finished".
private struct AgentActivityRowView: View {
    let agent: AgentActivityDetails.AgentDetail

    private var isBlocked: Bool { agent.status == "blocked" }
    private var ink: Color { AgentActivityStatusStyle.ink(for: agent.status) }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(ink)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(agent.kind)
                .font(.caption.weight(isBlocked ? .semibold : .regular))
                .foregroundStyle(isBlocked ? ink : .primary)
                .lineLimit(1)
            if let title = agent.title {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(isBlocked ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, isBlocked ? 3 : 0)
        .padding(.horizontal, isBlocked ? 6 : 0)
        .background {
            if isBlocked {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ink.opacity(0.16))
            }
        }
    }
}

/// Mocha (dark) inks from the app's Catppuccin status palette. Live
/// Activities sit on the dark tint below, so the light-mode latte inks
/// would disappear; the widget does not import app-only files.
enum AgentActivityStatusStyle {
    static func ink(for status: String) -> Color {
        switch status {
        case "blocked": Color(red: 243 / 255, green: 139 / 255, blue: 168 / 255)
        case "done": Color(red: 166 / 255, green: 227 / 255, blue: 161 / 255)
        case "working": Color(red: 249 / 255, green: 226 / 255, blue: 175 / 255)
        default: Color(red: 166 / 255, green: 173 / 255, blue: 200 / 255)
        }
    }
}

/// Deliberate lock-screen chrome: Catppuccin Mocha mantle behind the
/// banner, Mocha text on the system End/expand controls.
enum AgentActivityChrome {
    static let backgroundTint = Color(red: 24 / 255, green: 24 / 255, blue: 37 / 255)
    static let systemAction = Color(red: 205 / 255, green: 214 / 255, blue: 244 / 255)
}
