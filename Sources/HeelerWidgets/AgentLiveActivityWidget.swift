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
                hostID: context.attributes.hostID,
                hostSnapshot: LiveActivityHostSnapshotStore().read())
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
            Color(uiColor: UIColor.label.resolvedColor(
                with: UITraitCollection(userInterfaceStyle: .dark)))
        }
    }

    static func secondary(on surface: AgentActivitySurface) -> Color {
        switch surface {
        case .lockScreen:
            Color(uiColor: .secondaryLabel)
        case .island:
            Color(uiColor: UIColor.secondaryLabel.resolvedColor(
                with: UITraitCollection(userInterfaceStyle: .dark)))
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
        .activityBackgroundTint(AgentActivityLockScreenChrome.backgroundTint)
        .activitySystemActionForegroundColor(
            Color(uiColor: AgentActivityLockScreenChrome.actionColor))
    }
}

enum AgentActivityLockScreenChrome {
    static let backgroundTint: Color? = nil

    /// Keep this semantic color unresolved so an existing Live Activity can
    /// follow system appearance changes when ActivityKit refreshes it.
    static let actionColor = UIColor.label
}

struct AgentActivityLockScreenView: View {
    let presentation: AgentActivityPresentation
    let hostID: String
    let isStale: Bool
    let hostName: String?

    init(
        presentation: AgentActivityPresentation, hostID: String, isStale: Bool,
        hostSnapshot: LiveActivityHostSnapshot? = LiveActivityHostSnapshotStore().read()
    ) {
        self.presentation = presentation
        self.hostID = hostID
        self.isStale = isStale
        hostName = presentation.lockScreenHostName(hostID: hostID, snapshot: hostSnapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let hostName {
                Text(hostName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AgentActivitySemanticStyle.secondary(on: .lockScreen))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: AgentActivityRowMetrics.lockScreenHeaderHeight, alignment: .leading)
            }
            ForEach(visibleAgents, id: \.paneID) { @Sendable [rowMinimumHeight] agent in
                AgentActivityLinkedRow(
                    hostID: hostID,
                    agent: agent,
                    surface: .lockScreen,
                    minimumHeight: rowMinimumHeight)
            }
            if visibleAgents.isEmpty {
                Text(AgentActivityCopy.lockScreenCounts(presentation.counts))
                    .font(.caption)
                    .foregroundStyle(AgentActivitySemanticStyle.secondary(on: .lockScreen))
                    .lineLimit(1)
            }
            if let caption = presentation.lockScreenTrailingCaption(
                isStale: isStale, hasHeader: hostName != nil
            ) {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(AgentActivitySemanticStyle.secondary(on: .lockScreen))
            }
            #if DEBUG
                if let reason = AgentActivityDecryptor.lastFailureReason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(AgentActivitySemanticStyle.secondary(on: .lockScreen))
                        .lineLimit(3)
                }
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, AgentActivityRowMetrics.lockScreenBannerVerticalPadding)
        .widgetURL(AgentActivityLink.consoleURL(hostID: hostID))
    }

    private var visibleAgents: [AgentActivityDetails.AgentDetail] {
        presentation.lockScreenAgents(isStale: isStale, hasHeader: hostName != nil)
    }

    private var rowMinimumHeight: CGFloat {
        AgentActivityRowMetrics.lockScreenMinimumHeight(agentCount: visibleAgents.count)
    }
}

// MARK: - Dynamic Island

enum AgentActivityIsland {
    static func make(
        presentation: AgentActivityPresentation, hostID: String,
        hostSnapshot: LiveActivityHostSnapshot? = LiveActivityHostSnapshotStore().read()
    ) -> DynamicIsland {
        let island = AgentActivityIslandPresentation(
            presentation: presentation, hostID: hostID, hostSnapshot: hostSnapshot)
        return DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                AgentActivityIslandHeadline(presentation: island)
            }
            DynamicIslandExpandedRegion(.trailing) {
                AgentActivityIslandHeaderTrailing(presentation: island)
                    .frame(
                        maxWidth: .infinity, minHeight: AgentActivityIslandMetrics.headerHeight,
                        alignment: .trailing)
            }
            DynamicIslandExpandedRegion(.bottom) {
                AgentActivityIslandRows(presentation: presentation, hostID: hostID)
            }
        } compactLeading: {
            AgentActivityCompactLeading(presentation: island)
        } compactTrailing: {
            AgentActivityCompactTrailing(presentation: island)
        } minimal: {
            AgentActivityMinimal(presentation: island)
        }
        .contentMargins(
            [.leading, .trailing], AgentActivityIslandMetrics.expandedSideMargin, for: .expanded)
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
}

enum AgentActivityIslandMetrics {
    static let compactMark: CGFloat = 13
    static let compactSpacing: CGFloat = 4
    static let compactTileHeight: CGFloat = 20
    static let minimalMark: CGFloat = 9
    static let minimalSingleMark: CGFloat = 15
    static let minimalTileWidth: CGFloat = 24
    static let minimalTileHeight: CGFloat = 22
    static let hostTileHeight: CGFloat = 18
    static let rowGlyph: CGFloat = 13
    /// Each row glyph is centered in a column this wide, so glyph centers
    /// and text edges share one line.
    static let markerColumn: CGFloat = 19
    /// Matches the gap between a row's marker and its text.
    static let markerSpacing: CGFloat = 7
    /// Shared by the expanded leading and trailing regions so their contents
    /// sit on one center line beside the camera.
    static let headerHeight: CGFloat = 20
    /// The system clips expanded content to the island's shape inset about
    /// 15 pt, whose 27 pt corners cut into the default 18 pt side margins: the
    /// header glyph lost its top-left edge and the last trailing digit its
    /// right half. Measured on an iPhone 17 Pro simulator (iOS 27).
    static let expandedSideMargin: CGFloat = 25
    static let rowSpacing: CGFloat = 2
    /// Line heights of the `.caption` first line and `.caption2` later lines.
    static let rowFirstLineHeight: CGFloat = 16
    static let rowLineHeight: CGFloat = 13
    static let overflowCaptionHeight: CGFloat = 12
    /// Height the expanded island leaves for the rows and their overflow
    /// caption. Measured on an iPhone 17 Pro simulator (iOS 27): the rows
    /// start 46 pt below the island's top edge (system inset, header, and the
    /// gap under it) and the system clips content 13 pt above the bottom
    /// edge, which sits at most 160 pt down. A smaller bottom content margin
    /// shortens the island without moving that clip.
    static let rowsHeightBudget: CGFloat = 100

    /// A row's text height. The island has no room for the lock screen's
    /// padded 44 pt cards, so rows hug their lines; a one-line row still
    /// keeps the dense target as its pitch.
    static func rowHeight(for agent: AgentActivityDetails.AgentDetail) -> CGFloat {
        let lines = AgentActivityFields.rows(for: agent).count
        return max(
            AgentActivityRowMetrics.denseMinimumHeight - rowSpacing,
            rowFirstLineHeight + CGFloat(max(0, lines - 1)) * rowLineHeight)
    }
}

extension View {
    /// The expanded island cannot grow past 160 pt, and its glyphs and row
    /// budget are sized for the default text size, so larger Dynamic Type
    /// sizes stop there instead of pushing rows under the clip.
    func islandTypeSize() -> some View {
        dynamicTypeSize(...DynamicTypeSize.large)
    }
}

/// Status shapes, so the tally never relies on color alone: an exclamation
/// mark asks for the user, a check mark has a result to read, an open ring is
/// still running.
struct AgentActivityStatusGlyph: View {
    let status: String
    let size: CGFloat
    var surface: AgentActivitySurface = .island

    var body: some View {
        Group {
            switch status {
            case "blocked":
                Image(systemName: "exclamationmark.circle.fill").resizable().scaledToFit()
            case "done":
                Image(systemName: "checkmark.circle.fill").resizable().scaledToFit()
            case "working":
                openRing
            default:
                Circle().padding(size * 0.23)
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(AgentActivityStatusStyle.ink(for: status, on: surface))
        .accessibilityHidden(true)
    }

    /// Drawn rather than a symbol: a Live Activity cannot spin, so the ring
    /// stays open to read as unfinished at rest.
    private var openRing: some View {
        let lineWidth = size * 0.14
        let ink = AgentActivityStatusStyle.ink(for: status, on: surface)
        return ZStack {
            Circle().stroke(ink.opacity(0.28), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(ink, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}

struct AgentActivityIslandMark: View {
    let mark: AgentActivityIslandPresentation.Mark
    let size: CGFloat

    var body: some View {
        if mark.isOverflow {
            Image(systemName: "plus")
                .font(.system(size: size * 0.9, weight: .bold))
                .frame(width: size, height: size)
                .foregroundStyle(AgentActivityStatusStyle.ink(for: "unknown", on: .island))
        } else {
            AgentActivityStatusGlyph(status: mark.status, size: size)
        }
    }
}

struct AgentActivityCompactLeading: View {
    let presentation: AgentActivityIslandPresentation

    var body: some View {
        HStack(spacing: AgentActivityIslandMetrics.compactSpacing) {
            if let label = presentation.hostLabel {
                AgentActivityHostTile(label: label, height: AgentActivityIslandMetrics.compactTileHeight)
            }
            ForEach(Array(presentation.marks.prefix(2))) { @Sendable mark in
                AgentActivityIslandMark(mark: mark, size: AgentActivityIslandMetrics.compactMark)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .islandTypeSize()
    }
}

struct AgentActivityCompactTrailing: View {
    let presentation: AgentActivityIslandPresentation

    var body: some View {
        HStack(spacing: AgentActivityIslandMetrics.compactSpacing) {
            ForEach(Array(presentation.marks.dropFirst(2))) { @Sendable mark in
                AgentActivityIslandMark(mark: mark, size: AgentActivityIslandMetrics.compactMark)
            }
        }
        .accessibilityHidden(true)
        .islandTypeSize()
    }
}

struct AgentActivityMinimal: View {
    let presentation: AgentActivityIslandPresentation

    var body: some View {
        Group {
            if presentation.hasMultipleHosts, let label = presentation.hostLabel {
                AgentActivityHostTile(
                    label: label,
                    status: presentation.minimalTileStatus,
                    width: AgentActivityIslandMetrics.minimalTileWidth,
                    height: AgentActivityIslandMetrics.minimalTileHeight)
            } else {
                AgentActivityMinimalMarks(marks: presentation.marks)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .islandTypeSize()
    }
}

private struct AgentActivityMinimalMarks: View {
    let marks: [AgentActivityIslandPresentation.Mark]

    var body: some View {
        let size = marks.count == 1
            ? AgentActivityIslandMetrics.minimalSingleMark : AgentActivityIslandMetrics.minimalMark
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                ForEach(Array(marks.prefix(2))) { @Sendable mark in
                    AgentActivityIslandMark(mark: mark, size: size)
                }
            }
            if marks.count > 2 {
                HStack(spacing: 2) {
                    ForEach(Array(marks.dropFirst(2).prefix(2))) { @Sendable mark in
                        AgentActivityIslandMark(mark: mark, size: size)
                    }
                }
            }
        }
    }
}

struct AgentActivityHostTile: View {
    let label: String
    var status: String?
    var width: CGFloat? = nil
    var height: CGFloat = AgentActivityIslandMetrics.hostTileHeight

    var body: some View {
        ZStack {
            Text(label)
                .font(.system(size: min(11, height * 0.62), weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .padding(.horizontal, width == nil ? 3 : 0)
            if status == "done" {
                Image(systemName: "checkmark")
                    .font(.system(size: height * 0.34, weight: .bold))
                    .foregroundStyle(AgentActivityStatusStyle.ink(for: "done", on: .island))
                    .offset(x: height * 0.32, y: -height * 0.28)
            }
        }
        .frame(width: width ?? min(24, max(height, CGFloat(label.count * 7 + 6))), height: height)
        .foregroundStyle(status == "blocked" ? Color.black : AgentActivitySemanticStyle.primary(on: .island))
        .background(tileBackground)
        .overlay(tileBorder)
        .clipShape(RoundedRectangle(cornerRadius: height * 0.31, style: .continuous))
    }

    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: height * 0.31, style: .continuous)
            .fill(status == "blocked"
                ? AgentActivityStatusStyle.ink(for: "blocked", on: .island)
                : status == nil ? Color.white.opacity(0.14) : Color.clear)
    }

    private var tileBorder: some View {
        RoundedRectangle(cornerRadius: height * 0.31, style: .continuous)
            .stroke(status == "working" || status == "done"
                ? AgentActivityStatusStyle.ink(for: status ?? "unknown", on: .island)
                : Color.clear, lineWidth: 1)
    }
}

struct AgentActivityIslandHeadline: View {
    let presentation: AgentActivityIslandPresentation

    var body: some View {
        HStack(spacing: 6) {
            if presentation.hasMultipleHosts, let label = presentation.hostLabel {
                AgentActivityHostTile(label: label)
            }
            if let hostName = presentation.hostName {
                Text(hostName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AgentActivitySemanticStyle.primary(on: .island))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, minHeight: AgentActivityIslandMetrics.headerHeight, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.hostName ?? presentation.accessibilityLabel)
        .islandTypeSize()
    }
}

struct AgentActivityIslandHeaderTrailing: View {
    let presentation: AgentActivityIslandPresentation

    var body: some View {
        HStack(spacing: AgentActivityIslandMetrics.compactSpacing) {
            ForEach(presentation.marks) { @Sendable mark in
                AgentActivityIslandMark(mark: mark, size: 10)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentActivityCopy.lockScreenCounts(presentation.counts))
        .islandTypeSize()
    }
}

/// Expanded bottom region: as many Agent rows as the island's height allows.
struct AgentActivityIslandRows: View {
    let presentation: AgentActivityPresentation
    let hostID: String

    var body: some View {
        VStack(alignment: .leading, spacing: AgentActivityIslandMetrics.rowSpacing) {
            ForEach(presentation.expandedAgents, id: \.paneID) { @Sendable agent in
                AgentActivityLinkedRow(
                    hostID: hostID,
                    agent: agent,
                    surface: .island,
                    minimumHeight: AgentActivityIslandMetrics.rowHeight(for: agent))
            }
            if presentation.expandedAgents.isEmpty,
                !AgentActivityCopy.lockScreenCounts(presentation.counts).isEmpty
            {
                Text(AgentActivityCopy.lockScreenCounts(presentation.counts))
                    .font(.caption)
                    .foregroundStyle(AgentActivitySemanticStyle.secondary(on: .island))
                    .lineLimit(1)
            }
            if presentation.overflowCount > 0 {
                Text("+\(presentation.overflowCount) more")
                    .font(.caption2)
                    .foregroundStyle(AgentActivitySemanticStyle.secondary(on: .island))
                    .padding(
                        .leading,
                        AgentActivityIslandMetrics.markerColumn
                            + AgentActivityIslandMetrics.markerSpacing)
                    .frame(height: AgentActivityIslandMetrics.overflowCaptionHeight)
            }
        }
        .islandTypeSize()
    }
}

enum AgentActivityNarration {
    static func rowLabel(
        for agent: AgentActivityDetails.AgentDetail, on surface: AgentActivitySurface = .island
    ) -> String {
        let rows = AgentActivityFields.rows(for: agent).map { $0.map(\.text).joined() }
        let status = AgentActivityCopy.lockScreenStatus(agent.status)
        return (rows.filter { !$0.isEmpty } + [status]).joined(separator: ", ")
    }
}

// MARK: - Shared pieces

enum AgentActivityRowMetrics {
    /// Apple's default iOS control size when the presentation has room.
    static let comfortableMinimumHeight: CGFloat = 44
    /// Apple's documented minimum iOS control size for dense layouts.
    static let denseMinimumHeight: CGFloat = 28

    static func lockScreenMinimumHeight(agentCount: Int) -> CGFloat {
        agentCount <= 2 ? comfortableMinimumHeight : denseMinimumHeight
    }

    /// Vertical padding `AgentActivityRowView` adds on each edge of a
    /// configured lock-screen entry.
    static let configuredRowVerticalPadding: CGFloat = 1

    /// Vertical padding of the whole lock-screen banner.
    static let lockScreenBannerVerticalPadding: CGFloat = 6
    static let lockScreenHeaderHeight: CGFloat = 20
    /// Rendered height of the trailing caption2 line (overflow / stale).
    static let lockScreenCaptionHeight: CGFloat = 14
    /// ActivityKit's lock-screen presentation height limit.
    static let lockScreenHeightBudget: CGFloat = 160

    /// A configured entry renders its lines plus that padding: about 30 pt for
    /// two rows and 43.5 pt for three, both taller than the dense target. The
    /// fitting budgets this height and the row is held to it, so 31 pt and
    /// 44 pt. Legacy entries are unpadded and fit the dense target.
    static func minimumHeight(for agent: AgentActivityDetails.AgentDetail) -> CGFloat {
        guard agent.rows != nil else { return denseMinimumHeight }
        let lines = AgentActivityFields.rows(for: agent).count
        guard lines > 0 else { return denseMinimumHeight }
        return max(
            denseMinimumHeight,
            AgentActivityIslandMetrics.rowFirstLineHeight
                + CGFloat(lines - 1) * AgentActivityIslandMetrics.rowLineHeight
                + configuredRowVerticalPadding * 2)
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
            .accessibilityLabel(AgentActivityNarration.rowLabel(for: agent, on: surface))
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
            minimumHeight: surface == .island
                ? minimumHeight
                : max(minimumHeight, AgentActivityRowMetrics.minimumHeight(for: agent))
        ) {
            AgentActivityRowView(agent: agent, surface: surface)
        }
    }
}

/// The same rendered field rows used by the Console, with a status marker
/// that remains visible even when every configured field is empty.
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
            AgentActivityStatusGlyph(
                status: agent.status, size: AgentActivityIslandMetrics.rowGlyph, surface: surface
            )
            .frame(width: AgentActivityIslandMetrics.markerColumn)
            .padding(.top, 1.5)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(
                    Array(AgentActivityFields.rows(for: agent).enumerated()), id: \.offset
                ) { @Sendable index, row in
                    Text(AgentActivityFields.attributedText(row, rowIndex: index, surface: surface))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(AgentActivityCopy.lockScreenStatus(agent.status))
                .font(.caption)
                .foregroundStyle(AgentActivitySemanticStyle.secondary(on: surface))
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(
            .vertical,
            agent.rows == nil || surface == .island
                ? 0 : AgentActivityRowMetrics.configuredRowVerticalPadding)
        .layoutPriority(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentActivityNarration.rowLabel(for: agent, on: surface))
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
        let island = AgentActivityIslandPresentation(
            presentation: .countsOnly(counts: counts), hostID: "preview",
            hostSnapshot: LiveActivityHostSnapshot(v: 1, hosts: [.init(id: "preview", name: "Laptop", label: "L")]))
        return HStack(spacing: 0) {
            AgentActivityCompactLeading(presentation: island)
            // Stands in for the camera housing between the two sides.
            Color.clear.frame(width: 126)
            AgentActivityCompactTrailing(presentation: island)
        }
        .padding(.horizontal, 11)
        .frame(height: 37)
        .background(Color.black, in: Capsule())
        .environment(\.colorScheme, colorScheme)
        .padding()
    }

    private func previewIslandMinimal(
        counts: AgentActivityAttributes.ContentState.Counts,
        colorScheme: ColorScheme = .light
    ) -> some View {
        let island = AgentActivityIslandPresentation(
            presentation: .countsOnly(counts: counts), hostID: "preview",
            hostSnapshot: LiveActivityHostSnapshot(v: 1, hosts: [.init(id: "preview", name: "Laptop", label: "L")]))
        return AgentActivityMinimal(presentation: island)
            .frame(width: 37, height: 37)
            .background(Color.black, in: Circle())
            .environment(\.colorScheme, colorScheme)
            .padding()
    }

    private func previewIslandExpanded(
        _ presentation: AgentActivityPresentation,
        colorScheme: ColorScheme = .light
    ) -> some View {
        let hostName: String
        if case .detailed(let details, _) = presentation {
            hostName = details.hostName
        } else {
            hostName = "Laptop"
        }
        let island = AgentActivityIslandPresentation(
            presentation: presentation, hostID: "6D8EC348-4DAF-455C-BA8F-5FCC41799C0E",
            hostSnapshot: LiveActivityHostSnapshot(v: 1, hosts: [
                .init(id: "6D8EC348-4DAF-455C-BA8F-5FCC41799C0E", name: hostName, label: "L"),
                .init(id: "other", name: "Oak4d", label: "O"),
            ]))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                AgentActivityIslandHeadline(presentation: island)
                AgentActivityIslandHeaderTrailing(presentation: island)
            }
            AgentActivityIslandRows(
                presentation: presentation, hostID: "6D8EC348-4DAF-455C-BA8F-5FCC41799C0E")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(width: 371)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 40, style: .continuous))
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

    #Preview("P9b Compact all three statuses") {
        previewIslandCompact(counts: .init(working: 3, blocked: 1, done: 1))
    }

    #Preview("P10 Minimal blocked (Light island)") {
        previewIslandMinimal(counts: .init(working: 2, blocked: 1, done: 0))
    }

    #Preview("P10b Minimal working only") {
        previewIslandMinimal(counts: .init(working: 2, blocked: 0, done: 0))
    }

    #Preview("P11 Expanded mixed (Light island)") {
        previewIslandExpanded(AgentActivityPreviewFixtures.expandedMixed)
    }
#endif
