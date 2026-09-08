import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

/// Live Activity for one Host. The lock-screen banner gives each visible
/// Agent its configured fields, with a height-limited set of Agent cards. Rows
/// arrive in the sender's pin-aware order and are rendered as given.
/// Agent rows deep-link to their detail while
/// the surrounding chrome opens the Console.
struct AgentLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            AgentActivityLockScreenContainer(
                presentation: AgentActivityDecryptor.presentation(for: context.state),
                hostID: context.attributes.hostID,
                isStale: context.isStale
            )
        } dynamicIsland: { context in
            AgentActivityIsland.make(
                presentation: AgentActivityDecryptor.presentation(for: context.state),
                hostID: context.attributes.hostID)
        }
    }
}

// MARK: - Surface seam

enum AgentActivitySurface {
    /// Lock Screen banner. Status colors remain dynamic so ActivityKit can
    /// resolve Latte in Light appearance and Mocha in Dark appearance.
    case lockScreen
    /// Compact, minimal, and expanded Dynamic Island. Always Mocha,
    /// resolved against a dark trait collection, ignoring ambient Light Mode.
    case island
}

enum AgentActivityStatusStyle {
    static func ink(for status: String, on surface: AgentActivitySurface) -> Color {
        Color(uiColor: resolvedUIColor(for: status, role: .ink, on: surface))
    }

    static func wash(for status: String, on surface: AgentActivitySurface) -> Color {
        Color(uiColor: resolvedUIColor(for: status, role: .wash, on: surface))
    }

    private enum Role { case ink, wash }

    private static func resolvedUIColor(
        for status: String, role: Role, on surface: AgentActivitySurface
    ) -> UIColor {
        let agentStatus = paletteStatus(for: status)
        let uiColor: UIColor
        switch role {
        case .ink: uiColor = agentStatus.inkUIColor
        case .wash: uiColor = agentStatus.tintUIColor
        }
        switch surface {
        case .lockScreen:
            return uiColor
        case .island:
            return uiColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        }
    }

    private static func paletteStatus(for status: String) -> AgentStatus {
        switch status {
        case "blocked", "done", "working":
            return AgentStatus(rawValue: status)
        default:
            return .unknown
        }
    }
}

enum AgentActivitySemanticStyle {
    static func primary(on surface: AgentActivitySurface) -> Color {
        switch surface {
        case .lockScreen:
            Color(uiColor: .label)
        case .island:
            Color.primary
        }
    }

    static func secondary(on surface: AgentActivitySurface) -> Color {
        switch surface {
        case .lockScreen:
            Color(uiColor: .secondaryLabel)
        case .island:
            Color.secondary
        }
    }
}

// MARK: - Lock screen

private struct AgentActivityLockScreenContainer: View {
    let presentation: AgentActivityPresentation
    let hostID: String
    let isStale: Bool

    var body: some View {
        AgentActivityLockScreenView(
            presentation: presentation,
            hostID: hostID,
            isStale: isStale
        )
        .foregroundStyle(AgentActivitySemanticStyle.primary(on: .lockScreen))
        .activityBackgroundTint(Color(uiColor: AgentActivityLockScreenChrome.backgroundColor))
        .activitySystemActionForegroundColor(
            Color(uiColor: AgentActivityLockScreenChrome.actionColor))
    }
}

enum AgentActivityLockScreenChrome {
    /// Keep these semantic colors unresolved so ActivityKit can apply the
    /// system appearance when its host provides the correct trait collection.
    static let backgroundColor = UIColor.systemBackground
    static let actionColor = UIColor.label
}

struct AgentActivityLockScreenView: View {
    let presentation: AgentActivityPresentation
    let hostID: String
    let isStale: Bool

    var body: some View {
        ZStack {
            Color(uiColor: AgentActivityLockScreenChrome.backgroundColor)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                ForEach(visibleAgents.dropFirst(), id: \.paneID) { agent in
                    AgentActivityLinkedRow(
                        hostID: hostID,
                        agent: agent,
                        surface: .lockScreen,
                        minimumHeight: rowMinimumHeight)
                }
                if let caption = presentation.lockScreenTrailingCaption(isStale: isStale) {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(AgentActivitySemanticStyle.secondary(on: .lockScreen))
                }
                #if DEBUG
                    if let reason = AgentActivityDecryptor.lastFailureReason {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(
                                AgentActivitySemanticStyle.secondary(on: .lockScreen)
                            )
                            .lineLimit(3)
                    }
                #endif
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .widgetURL(AgentActivityLink.consoleURL(hostID: hostID))
    }

    private var visibleAgents: [AgentActivityDetails.AgentDetail] {
        presentation.lockScreenAgents(isStale: isStale)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            headline
            Spacer(minLength: 8)
            AgentActivityCountChips(counts: presentation.counts, surface: .lockScreen)
        }
    }

    @ViewBuilder
    private var headline: some View {
        if let first = visibleAgents.first {
            AgentActivityLinkedRow(
                hostID: hostID,
                agent: first,
                surface: .lockScreen,
                minimumHeight: rowMinimumHeight)
        } else {
            Text(presentation.headerTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AgentActivitySemanticStyle.primary(on: .lockScreen))
                .lineLimit(1)
        }
    }

    private var rowMinimumHeight: CGFloat {
        AgentActivityRowMetrics.lockScreenMinimumHeight(agentCount: visibleAgents.count)
    }
}

// MARK: - Dynamic Island

enum AgentActivityIsland {
    static func make(presentation: AgentActivityPresentation, hostID: String) -> DynamicIsland {
        DynamicIsland {
            DynamicIslandExpandedRegion(.center) {
                if let primary = presentation.primaryAgent {
                    AgentActivityLinkedRow(
                        hostID: hostID,
                        agent: primary,
                        surface: .island,
                        minimumHeight: AgentActivityRowMetrics.minimumHeight(for: primary)
                    )
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
                        AgentActivityLinkedRow(
                            hostID: hostID,
                            agent: agent,
                            surface: .island,
                            minimumHeight: AgentActivityRowMetrics.minimumHeight(for: agent))
                    }
                    if presentation.overflowCount > 0 {
                        Text("+\(presentation.overflowCount) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    AgentActivityCountChips(
                        counts: presentation.counts, surface: .island, chipWashOpacity: 0.16)
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
                        ? AgentActivityStatusStyle.ink(for: "blocked", on: .island)
                        : Color.primary
                )
                .accessibilityLabel(minimalAccessibilityLabel(counts: presentation.counts))
        }
        .keylineTint(islandKeylineTint(counts: presentation.counts))
        .widgetURL(AgentActivityLink.consoleURL(hostID: hostID))
    }

    private static func islandKeylineTint(
        counts: AgentActivityAttributes.ContentState.Counts
    ) -> Color {
        if counts.blocked > 0 {
            return AgentActivityStatusStyle.ink(for: "blocked", on: .island)
        }
        return AgentActivityStatusStyle.ink(for: "unknown", on: .island)
    }

    private static func minimalAccessibilityLabel(
        counts: AgentActivityAttributes.ContentState.Counts
    ) -> String {
        var label = "\(counts.total) agents"
        if counts.blocked > 0 {
            label += ", \(counts.blocked) blocked"
        }
        return label
    }
}

private struct AgentActivityCompactLeading: View {
    let counts: AgentActivityAttributes.ContentState.Counts

    var body: some View {
        if let item = counts.attentionStatusItem {
            Text("\(item.count)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(AgentActivityStatusStyle.ink(for: item.status, on: .island))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    AgentActivityStatusStyle.wash(for: item.status, on: .island).opacity(0.22),
                    in: Capsule())
                .accessibilityLabel("\(item.count) \(item.status)")
        }
    }
}

enum AgentActivityNarration {
    static func rowLabel(for agent: AgentActivityDetails.AgentDetail) -> String {
        let rows = AgentActivityFields.rows(for: agent).map { $0.map(\.text).joined() }
        return (rows.filter { !$0.isEmpty } + [agent.status]).joined(separator: ", ")
    }
}

// MARK: - Shared pieces

enum AgentActivityRowMetrics {
    /// Apple's default iOS control size when the presentation has room.
    static let comfortableMinimumHeight: CGFloat = 44
    /// Apple's documented minimum iOS control size for dense layouts.
    static let denseMinimumHeight: CGFloat = 28

    static func lockScreenMinimumHeight(agentCount: Int) -> CGFloat {
        agentCount <= 3 ? comfortableMinimumHeight : denseMinimumHeight
    }

    static func minimumHeight(for agent: AgentActivityDetails.AgentDetail) -> CGFloat {
        AgentActivityFields.rows(for: agent).count > 2 ? 48 : denseMinimumHeight
    }
}

/// Wraps row content in a deep link to that Agent's detail. The outer
/// widgetURL remains the fallback for taps on the surrounding chrome.
private struct AgentActivityLinked<Content: View>: View {
    let hostID: String
    let agent: AgentActivityDetails.AgentDetail
    let surface: AgentActivitySurface
    let minimumHeight: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if let url = AgentActivityLink.agentURL(hostID: hostID, paneID: agent.paneID) {
            Link(destination: url) {
                content
                    .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tint(AgentActivitySemanticStyle.primary(on: surface))
            .accessibilityLabel(AgentActivityNarration.rowLabel(for: agent))
            .accessibilityHint("Opens this Agent in Heeler")
        } else {
            content
                .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
        }
    }
}

private struct AgentActivityLinkedRow: View {
    let hostID: String
    let agent: AgentActivityDetails.AgentDetail
    let surface: AgentActivitySurface
    let minimumHeight: CGFloat

    var body: some View {
        AgentActivityLinked(
            hostID: hostID,
            agent: agent,
            surface: surface,
            minimumHeight: max(minimumHeight, AgentActivityRowMetrics.minimumHeight(for: agent))
        ) {
            AgentActivityRowView(agent: agent, surface: surface)
        }
    }
}

private struct AgentActivityCountChips: View {
    let counts: AgentActivityAttributes.ContentState.Counts
    let surface: AgentActivitySurface
    var chipWashOpacity: Double = 0.15

    var body: some View {
        HStack(spacing: 5) {
            ForEach(counts.chipItems, id: \.status) { item in
                Text("\(item.count) \(item.status)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AgentActivityStatusStyle.ink(for: item.status, on: surface))
                    // Chips never compress or wrap; the row title truncates
                    // instead when all three statuses are present.
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        AgentActivityStatusStyle.wash(for: item.status, on: surface)
                            .opacity(chipWashOpacity),
                        in: Capsule())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            counts.chipItems.map { "\($0.count) \($0.status)" }.joined(separator: ", "))
    }
}

/// The same rendered field rows used by the Console, with a status dot that
/// remains visible even when every configured field is empty.
enum AgentActivityFields {
    static func rows(for agent: AgentActivityDetails.AgentDetail) -> [[AgentActivityDetails.Field]] {
        if let configured = agent.rows { return Array(configured.prefix(3)) }
        let kind = AgentNotificationIdentity.kindLabel(agent.kind)
        if let workspace = agent.displayWorkspace {
            return [[.init(text: workspace)], [.init(text: kind)]]
        }
        return [[.init(text: kind)]]
    }

    static func attributedText(
        _ fields: [AgentActivityDetails.Field], rowIndex: Int, surface: AgentActivitySurface
    ) -> AttributedString {
        var result = AttributedString()
        for field in fields {
            var span = AttributedString(field.text)
            let font: Font = rowIndex == 0 ? .caption : .caption2
            let weight: Font.Weight = if let bold = field.bold {
                bold ? .bold : .regular
            } else {
                rowIndex == 0 ? .semibold : .medium
            }
            span.font = font.weight(weight)
            span.foregroundColor = foreground(for: field, rowIndex: rowIndex, surface: surface)
            result.append(span)
        }
        return result
    }

    static func foreground(
        for field: AgentActivityDetails.Field, rowIndex: Int, surface: AgentActivitySurface
    ) -> Color {
        if let hex = field.fg, let color = hexColor(hex) {
            return Color(uiColor: color).opacity(field.dim == true ? 0.6 : 1)
        }
        if field.dim == true {
            let color: UIColor = rowIndex == 0 ? .secondaryLabel : .tertiaryLabel
            return Color(uiColor: surface == .island
                ? color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)) : color)
        }
        return rowIndex == 0
            ? AgentActivitySemanticStyle.primary(on: surface)
            : AgentActivitySemanticStyle.secondary(on: surface)
    }

    private static func hexColor(_ value: String) -> UIColor? {
        guard value.first == "#", value.utf8.count == 4 || value.utf8.count == 7 else { return nil }
        let digits = value.dropFirst()
        guard digits.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        let expanded = digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : String(digits)
        guard let rgb = UInt32(expanded, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}

struct AgentActivityRowView: View {
    let agent: AgentActivityDetails.AgentDetail
    let surface: AgentActivitySurface

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(AgentActivityStatusStyle.ink(for: agent.status, on: surface))
                .frame(width: 7, height: 7)
                .padding(.top, 4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(AgentActivityFields.rows(for: agent).enumerated()), id: \.offset) { index, row in
                    Text(AgentActivityFields.attributedText(row, rowIndex: index, surface: surface))
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, agent.rows == nil ? 0 : 2)
        .layoutPriority(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentActivityNarration.rowLabel(for: agent))
    }
}

// MARK: - Previews

/// Style gallery: every lock-screen state without a device, a push, or a
/// live agent. Open this file's canvas in Xcode to review the banner.
#if DEBUG
    private func previewAgent(
        _ status: String, kind: String, workspace: String? = "Heeler", name: String? = nil,
        pane: String, title: String? = nil
    ) -> AgentActivityDetails.AgentDetail {
        AgentActivityDetails.AgentDetail(
            paneID: pane, kind: kind, name: name, workspace: workspace, status: status,
            title: title)
    }

    private enum AgentActivityPreviewFixtures {
        static let longGraphemeTitle = String(repeating: "锁", count: 80)
        static let longGraphemeName = String(repeating: "屏", count: 80)

        static var configuredFields: AgentActivityPresentation {
            let agents = (1...4).map { index in
                AgentActivityDetails.AgentDetail(
                    paneID: "w1:p\(index)", kind: "claude", workspace: "Heeler",
                    status: index == 1 ? "blocked" : "working", title: nil,
                    rows: [
                        [.init(text: "Heeler"), .init(text: " · "), .init(text: "Claude", dim: true)],
                        [.init(text: "Review sidebar fields")],
                        [.init(text: "~/Projects/Heeler", dim: true)],
                    ])
            }
            return .detailed(details: .init(hostName: "mbp", agents: agents),
                counts: .init(working: 3, blocked: 1, done: 0))
        }

        static var mixedOverflow: AgentActivityPresentation {
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
                        previewAgent(
                            "working", kind: "codex", name: "fixer", pane: "w1:p4",
                            title: "Chase the flaky pairing test"),
                        previewAgent(
                            "working", kind: "claude", pane: "w1:p5",
                            title: "Refactor the transport queue"),
                    ]),
                counts: .init(working: 4, blocked: 1, done: 1))
        }

        static var singleUnnamedIdentityOnly: AgentActivityPresentation {
            .detailed(
                details: AgentActivityDetails(
                    hostName: "mbp",
                    agents: [previewAgent("working", kind: "claude", pane: "w1:p1")]),
                counts: .init(working: 1, blocked: 0, done: 0))
        }

        static var fourRows: AgentActivityPresentation {
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
                counts: .init(working: 3, blocked: 1, done: 0))
        }

        static var countsOnly: AgentActivityPresentation {
            .countsOnly(counts: .init(working: 2, blocked: 1, done: 0))
        }

        static var longTitle: AgentActivityPresentation {
            .detailed(
                details: AgentActivityDetails(
                    hostName: "mbp",
                    agents: [
                        previewAgent(
                            "blocked", kind: "claude", name: "reviewer", pane: "w1:p1",
                            title: longGraphemeTitle),
                        previewAgent("working", kind: "grok", pane: "w1:p2", title: "Second row"),
                    ]),
                counts: .init(working: 1, blocked: 1, done: 1))
        }

        static var longNameWithTitle: AgentActivityPresentation {
            .detailed(
                details: AgentActivityDetails(
                    hostName: "mbp",
                    agents: [
                        previewAgent(
                            "blocked", kind: "claude", name: longGraphemeName, pane: "w1:p1",
                            title: "Approve the transport refactor plan"),
                    ]),
                counts: .init(working: 0, blocked: 1, done: 0))
        }

        static var longNameNoTitle: AgentActivityPresentation {
            .detailed(
                details: AgentActivityDetails(
                    hostName: "mbp",
                    agents: [
                        previewAgent(
                            "working", kind: "claude", name: longGraphemeName, pane: "w1:p1"),
                    ]),
                counts: .init(working: 1, blocked: 0, done: 0))
        }

        static var staleMaxHeight: AgentActivityPresentation {
            .detailed(
                details: AgentActivityDetails(
                    hostName: "mbp",
                    agents: [
                        previewAgent("blocked", kind: "claude", pane: "w1:p1", title: "First"),
                        previewAgent("done", kind: "droid", pane: "w1:p2", title: "Second"),
                        previewAgent("working", kind: "grok", pane: "w1:p3", title: "Third"),
                        previewAgent("working", kind: "codex", pane: "w1:p4", title: "Fourth"),
                        previewAgent("working", kind: "claude", pane: "w1:p5", title: "Fifth"),
                    ]),
                counts: .init(working: 3, blocked: 1, done: 1))
        }

        static var staleThreeRows: AgentActivityPresentation {
            .detailed(
                details: AgentActivityDetails(
                    hostName: "mbp",
                    agents: [
                        previewAgent("blocked", kind: "claude", pane: "w1:p1", title: "First"),
                        previewAgent("done", kind: "droid", pane: "w1:p2", title: "Second"),
                        previewAgent("working", kind: "grok", pane: "w1:p3", title: "Third"),
                    ]),
                counts: .init(working: 1, blocked: 1, done: 1))
        }

        static var expandedMixed: AgentActivityPresentation {
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
                counts: .init(working: 1, blocked: 1, done: 1))
        }
    }

    private func previewLockScreenBanner(
        _ presentation: AgentActivityPresentation,
        colorScheme: ColorScheme,
        isStale: Bool = false
    ) -> some View {
        AgentActivityLockScreenView(
            presentation: presentation,
            hostID: "6D8EC348-4DAF-455C-BA8F-5FCC41799C0E",
            isStale: isStale
        )
        .background(
            colorScheme == .light
                ? Color(white: 0.97)
                : Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .environment(\.colorScheme, colorScheme)
        .padding()
    }

    private func previewIslandCompact(
        counts: AgentActivityAttributes.ContentState.Counts,
        colorScheme: ColorScheme = .light
    ) -> some View {
        HStack {
            AgentActivityCompactLeading(counts: counts)
            Spacer()
            Text("\(counts.total)")
                .font(.body.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black)
        .environment(\.colorScheme, colorScheme)
        .padding()
    }

    private func previewIslandExpanded(
        _ presentation: AgentActivityPresentation,
        colorScheme: ColorScheme = .light
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let primary = presentation.primaryAgent {
                AgentActivityRowView(agent: primary, surface: .island)
            }
            ForEach(presentation.secondaryAgents, id: \.paneID) { agent in
                AgentActivityRowView(agent: agent, surface: .island)
            }
            if presentation.overflowCount > 0 {
                Text("+\(presentation.overflowCount) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            AgentActivityCountChips(
                counts: presentation.counts, surface: .island, chipWashOpacity: 0.16)
        }
        .padding()
        .background(Color.black)
        .environment(\.colorScheme, colorScheme)
        .padding()
    }

    #Preview("Configured fields (Light)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.configuredFields, colorScheme: .light)
    }

    #Preview("Configured fields (Dark, stale)") {
        previewLockScreenBanner(
            AgentActivityPreviewFixtures.configuredFields, colorScheme: .dark, isStale: true)
    }

    #Preview("Configured fields (Expanded island)") {
        previewIslandExpanded(AgentActivityPreviewFixtures.configuredFields)
    }

    #Preview("P1 Mixed + overflow (Light)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.mixedOverflow, colorScheme: .light)
    }

    #Preview("P1 Mixed + overflow (Dark)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.mixedOverflow, colorScheme: .dark)
    }

    #Preview("P2 Unnamed identity only (Light)") {
        previewLockScreenBanner(
            AgentActivityPreviewFixtures.singleUnnamedIdentityOnly, colorScheme: .light)
    }

    #Preview("P2 Unnamed identity only (Dark)") {
        previewLockScreenBanner(
            AgentActivityPreviewFixtures.singleUnnamedIdentityOnly, colorScheme: .dark)
    }

    #Preview("P3 Four rows (Light)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.fourRows, colorScheme: .light)
    }

    #Preview("P3 Four rows (Dark)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.fourRows, colorScheme: .dark)
    }

    #Preview("P4 Counts only (Light)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.countsOnly, colorScheme: .light)
    }

    #Preview("P4 Counts only (Dark)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.countsOnly, colorScheme: .dark)
    }

    #Preview("P5 Long title (Light)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.longTitle, colorScheme: .light)
    }

    #Preview("P5 Long title (Dark)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.longTitle, colorScheme: .dark)
    }

    #Preview("P5a Long name with title (Light)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.longNameWithTitle, colorScheme: .light)
    }

    #Preview("P5a Long name with title (Dark)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.longNameWithTitle, colorScheme: .dark)
    }

    #Preview("P5b Long name, no title (Light)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.longNameNoTitle, colorScheme: .light)
    }

    #Preview("P5b Long name, no title (Dark)") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.longNameNoTitle, colorScheme: .dark)
    }

    #Preview("P6 Stale max height (Light)") {
        previewLockScreenBanner(
            AgentActivityPreviewFixtures.staleMaxHeight, colorScheme: .light, isStale: true)
    }

    #Preview("P6 Stale max height (Dark)") {
        previewLockScreenBanner(
            AgentActivityPreviewFixtures.staleMaxHeight, colorScheme: .dark, isStale: true)
    }

    #Preview("P6b Stale three rows (Light)") {
        previewLockScreenBanner(
            AgentActivityPreviewFixtures.staleThreeRows, colorScheme: .light, isStale: true)
    }

    #Preview("P6b Stale three rows (Dark)") {
        previewLockScreenBanner(
            AgentActivityPreviewFixtures.staleThreeRows, colorScheme: .dark, isStale: true)
    }

    #Preview("P7 Compact blocked (Light island)") {
        previewIslandCompact(counts: .init(working: 2, blocked: 1, done: 0))
    }

    #Preview("P8 Compact done + working") {
        previewIslandCompact(counts: .init(working: 2, blocked: 0, done: 1))
    }

    #Preview("P9 Compact working only") {
        previewIslandCompact(counts: .init(working: 3, blocked: 0, done: 0))
    }

    #Preview("P10 Minimal blocked (Light island)") {
        Text("3")
            .font(.body.weight(.bold).monospacedDigit())
            .foregroundStyle(AgentActivityStatusStyle.ink(for: "blocked", on: .island))
            .padding()
            .background(Color.black)
            .environment(\.colorScheme, .light)
            .padding()
    }

    #Preview("P11 Expanded mixed (Light island)") {
        previewIslandExpanded(AgentActivityPreviewFixtures.expandedMixed)
    }
#endif
