import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity for one Host. Lock-screen banner is a uniform agent list
/// under a ~160pt budget: four rows when everything fits, three plus
/// "+N more" otherwise. Rows arrive pre-sorted most-urgent first; Host
/// identity is never rendered. Every agent row is a deep link into that
/// agent's detail; taps outside a row land on the Console.
struct AgentLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            AgentActivityLockScreenView(
                presentation: AgentActivityDecryptor.presentation(for: context.state),
                hostID: context.attributes.hostID
            )
            .activityBackgroundTint(AgentActivityChrome.backgroundTint)
            .activitySystemActionForegroundColor(AgentActivityChrome.systemAction)
        } dynamicIsland: { context in
            AgentActivityIsland.make(
                presentation: AgentActivityDecryptor.presentation(for: context.state),
                hostID: context.attributes.hostID)
        }
    }
}

// MARK: - Lock screen

struct AgentActivityLockScreenView: View {
    let presentation: AgentActivityPresentation
    let hostID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(presentation.lockScreenAgents.dropFirst(), id: \.paneID) { agent in
                AgentActivityLinkedRow(hostID: hostID, agent: agent)
            }
            if presentation.lockScreenOverflowCount > 0 {
                Text("+\(presentation.lockScreenOverflowCount) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            #if DEBUG
                if let reason = AgentActivityDecryptor.lastFailureReason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            #endif
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .widgetURL(AgentActivityLink.consoleURL(hostID: hostID))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(lockScreenAccessibilityLabel)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            headline
            Spacer(minLength: 8)
            AgentActivityCountChips(counts: presentation.counts)
        }
    }

    @ViewBuilder
    private var headline: some View {
        if let first = presentation.lockScreenAgents.first {
            AgentActivityLinkedRow(hostID: hostID, agent: first)
        } else {
            Text(presentation.headerTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
    }

    private var lockScreenAccessibilityLabel: String {
        var parts = [
            presentation.lockScreenAgents.first.map(Self.narration(for:))
                ?? presentation.headerTitle
        ]
        parts.append(contentsOf: presentation.counts.chipItems.map { "\($0.count) \($0.status)" })
        for agent in presentation.lockScreenAgents.dropFirst() {
            parts.append(Self.narration(for: agent))
        }
        if presentation.lockScreenOverflowCount > 0 {
            parts.append("\(presentation.lockScreenOverflowCount) more")
        }
        return parts.joined(separator: ", ")
    }

    private static func narration(for agent: AgentActivityDetails.AgentDetail) -> String {
        var row = "\(agent.displayName), \(agent.status)"
        if let title = agent.displayTitle {
            row += ", \(title)"
        }
        return row
    }
}

// MARK: - Dynamic Island

enum AgentActivityIsland {
    static func make(presentation: AgentActivityPresentation, hostID: String) -> DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.center) {
                if let primary = presentation.primaryAgent {
                    AgentActivityLinked(hostID: hostID, paneID: primary.paneID) {
                        AgentActivityHeadlineView(agent: primary)
                    }
                } else {
                    Text(presentation.headerTitle)
                        .font(.headline)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                }
            }
            DynamicIslandExpandedRegion(.bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(presentation.secondaryAgents, id: \.paneID) { agent in
                        AgentActivityLinkedRow(hostID: hostID, agent: agent)
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
            AgentActivityConsoleLinked(hostID: hostID) {
                AgentActivityCompactLeading(counts: presentation.counts)
            }
        } compactTrailing: {
            AgentActivityConsoleLinked(hostID: hostID) {
                Text("\(presentation.counts.total)")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .accessibilityLabel("\(presentation.counts.total) agents")
            }
        } minimal: {
            AgentActivityConsoleLinked(hostID: hostID) {
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

/// Applies the Console deep link inside a `body` so the MainActor-isolated
/// `widgetURL` is reachable from the nonisolated DynamicIsland builders.
private struct AgentActivityConsoleLinked<Content: View>: View {
    let hostID: String
    @ViewBuilder let content: Content

    var body: some View {
        content.widgetURL(AgentActivityLink.consoleURL(hostID: hostID))
    }
}

/// Wraps row content in a deep link to that agent's detail; falls back to
/// plain content when the URL cannot be built (never expected).
private struct AgentActivityLinked<Content: View>: View {
    let hostID: String
    let paneID: String
    @ViewBuilder let content: Content

    var body: some View {
        if let url = AgentActivityLink.agentURL(hostID: hostID, paneID: paneID) {
            Link(destination: url) { content }
        } else {
            content
        }
    }
}

private struct AgentActivityLinkedRow: View {
    let hostID: String
    let agent: AgentActivityDetails.AgentDetail

    var body: some View {
        AgentActivityLinked(hostID: hostID, paneID: agent.paneID) {
            AgentActivityRowView(agent: agent)
        }
    }
}

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

/// The headline: two lines mirroring the herdr sidebar's hierarchy —
/// status dot plus the task title on top, the agent's identity (its herdr
/// name, kind when unnamed, exactly like the TUI) indented beneath. A
/// missing title promotes the identity to the top line alone.
private struct AgentActivityHeadlineView: View {
    let agent: AgentActivityDetails.AgentDetail

    private var ink: Color { AgentActivityStatusStyle.ink(for: agent.status) }
    private var isBlocked: Bool { agent.status == "blocked" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Circle()
                    .fill(ink)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(agent.displayTitle ?? agent.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isBlocked ? ink : Color.primary)
                    .lineLimit(1)
            }
            if agent.displayTitle != nil {
                Text(agent.displayName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 15)
            }
        }
    }
}

/// One agent row: the same two-line rule as the headline, smaller type —
/// task title on top, identity (name, kind when unnamed) indented beneath.
/// Status is painted, not narrated as an event — a done row is the current
/// state, not "just finished".
private struct AgentActivityRowView: View {
    let agent: AgentActivityDetails.AgentDetail

    private var isBlocked: Bool { agent.status == "blocked" }
    private var ink: Color { AgentActivityStatusStyle.ink(for: agent.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Circle()
                    .fill(ink)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(agent.displayTitle ?? agent.displayName)
                    .font(.caption.weight(isBlocked ? .semibold : .regular))
                    .foregroundStyle(isBlocked ? ink : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if agent.displayTitle != nil {
                Text(agent.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 14)
            }
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

// MARK: - Previews

/// Style gallery: every lock-screen state without a device, a push, or a
/// live agent. Open this file's canvas in Xcode to review the banner.
#if DEBUG
    private func previewBanner(_ presentation: AgentActivityPresentation) -> some View {
        AgentActivityLockScreenView(
            presentation: presentation,
            hostID: "6D8EC348-4DAF-455C-BA8F-5FCC41799C0E"
        )
        .background(AgentActivityChrome.backgroundTint, in: RoundedRectangle(cornerRadius: 22))
        .environment(\.colorScheme, .dark)
        .padding()
    }

    private func previewAgent(
        _ status: String, kind: String, name: String? = nil, pane: String, title: String? = nil
    ) -> AgentActivityDetails.AgentDetail {
        AgentActivityDetails.AgentDetail(
            paneID: pane, kind: kind, name: name, status: status, title: title)
    }

    #Preview("Mixed statuses + overflow") {
        previewBanner(
            .detailed(
                details: AgentActivityDetails(
                    hostName: "mbp",
                    agents: [
                        previewAgent(
                            "blocked", kind: "claude", name: "reviewer", pane: "w1:p1",
                            title: "Approve the transport refactor plan"),
                        previewAgent(
                            "done", kind: "droid", name: "doc-writer", pane: "w1:p2",
                            title: "API reference draft finished"),
                        previewAgent(
                            "working", kind: "grok", name: "la-demo", pane: "w1:p3",
                            title: "Research ActivityKit budgets"),
                    ]),
                counts: .init(working: 3, blocked: 1, done: 2)))
    }

    #Preview("Single unnamed working") {
        previewBanner(
            .detailed(
                details: AgentActivityDetails(
                    hostName: "mbp",
                    agents: [
                        previewAgent(
                            "working", kind: "claude", pane: "w1:p1",
                            title: "◑ lockscreen-agent-live-activity")
                    ]),
                counts: .init(working: 1, blocked: 0, done: 0)))
    }

    #Preview("Two working, names") {
        previewBanner(
            .detailed(
                details: AgentActivityDetails(
                    hostName: "mbp",
                    agents: [
                        previewAgent(
                            "working", kind: "claude", pane: "w1:p1",
                            title: "Refactor the transport queue"),
                        previewAgent(
                            "working", kind: "grok", name: "la-demo", pane: "w1:p2",
                            title: "Write the landing copy"),
                    ]),
                counts: .init(working: 2, blocked: 0, done: 0)))
    }

    #Preview("Four rows, all fit") {
        previewBanner(
            .detailed(
                details: AgentActivityDetails(
                    hostName: "mbp",
                    agents: [
                        previewAgent(
                            "blocked", kind: "claude", name: "reviewer", pane: "w1:p1",
                            title: "Approve the transport refactor plan"),
                        previewAgent(
                            "working", kind: "claude", pane: "w1:p2",
                            title: "Refactor the transport queue"),
                        previewAgent(
                            "working", kind: "grok", name: "la-demo", pane: "w1:p3",
                            title: "Write the landing copy"),
                        previewAgent(
                            "working", kind: "codex", name: "fixer", pane: "w1:p4",
                            title: "Chase the flaky pairing test"),
                    ]),
                counts: .init(working: 3, blocked: 1, done: 0)))
    }

    #Preview("Counts only (undecryptable)") {
        previewBanner(.countsOnly(counts: .init(working: 2, blocked: 1, done: 0)))
    }
#endif
