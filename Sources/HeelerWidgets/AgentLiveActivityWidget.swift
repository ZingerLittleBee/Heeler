import ActivityKit
import CoreText
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
        let expanded = AgentActivityIslandExpanded(presentation: presentation)
        return DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                AgentActivityIslandHeadline(presentation: island)
            }
            DynamicIslandExpandedRegion(.trailing) {
                AgentActivityIslandAgentTotal(total: expanded.total)
                    .frame(
                        maxWidth: .infinity, minHeight: AgentActivityIslandMetrics.headerHeight,
                        alignment: .trailing)
            }
            DynamicIslandExpandedRegion(.bottom) {
                AgentActivityIslandCards(expanded: expanded, hostID: hostID)
            }
        } compactLeading: {
            AgentActivityCompactSide(presentation: island, edge: .leading)
        } compactTrailing: {
            AgentActivityCompactSide(presentation: island, edge: .trailing)
        } minimal: {
            AgentActivityMinimal(presentation: island)
        }
        .contentMargins(
            [.leading, .trailing], AgentActivityIslandMetrics.expandedSideMargin, for: .expanded)
        .keylineTint(presentation.counts.blocked > 0
            ? AgentActivityStatusStyle.ink(for: "blocked", on: .island).opacity(0.55) : nil)
        .widgetURL(AgentActivityLink.consoleURL(hostID: hostID))
    }
}

enum AgentActivityIslandMetrics {
    static let rowGlyph: CGFloat = 13
    /// Each row glyph is centered in a column this wide, so glyph centers
    /// and text edges share one line.
    static let markerColumn: CGFloat = 19
    /// Shared by the expanded leading and trailing regions so their contents
    /// sit on one center line beside the camera.
    static let headerHeight: CGFloat = 20
    /// B2 sets the cards 22 pt in from the island's sides and the header a
    /// further 4 pt, where the island's corners no longer clip it.
    static let expandedSideMargin: CGFloat = 22
    static let expandedHeaderInset: CGFloat = 4
    static let cardHeight: CGFloat = 66
    static let cardSpacing: CGFloat = 8
    /// The box iOS gives the minimal view (measured on iOS 27.2: a 20 pt
    /// view gets 20 × 20 pt; one that measures its slot gets about 10 pt).
    static let minimalBox: CGFloat = 20
    /// Line heights of the `.caption` first line and `.caption2` later lines.
    static let rowFirstLineHeight: CGFloat = 16
    static let rowLineHeight: CGFloat = 13

    /// The phone's width in portrait, which sets the compact side limit.
    @MainActor static var portraitScreenWidth: CGFloat {
        let bounds = UIScreen.main.bounds
        return min(bounds.width, bounds.height)
    }
}

/// Island colors from the B2 and Island Scenarios drawings, on the island's
/// black in either appearance.
enum AgentActivityIslandColor {
    /// Mocha base: the mark inside a filled status circle.
    static let ink = Color(red: 0x1e / 255, green: 0x1e / 255, blue: 0x2e / 255)
    static let hostLetter = Color(red: 0xae / 255, green: 0xae / 255, blue: 0xb2 / 255)
    static let hostTile = Color(red: 0x3a / 255, green: 0x3a / 255, blue: 0x3c / 255)
    static let secondary = Color(red: 0x8e / 255, green: 0x8e / 255, blue: 0x93 / 255)
    static let task = Color(red: 0x9a / 255, green: 0x9a / 255, blue: 0xa0 / 255)
    static let card = Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255)
    static let blockedCard = Color(red: 0x3a / 255, green: 0x1f / 255, blue: 0x29 / 255)
}

extension View {
    /// The island's glyphs and text are drawn to fixed sizes that fill its
    /// slots, so larger Dynamic Type sizes stop at the default.
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

/// The island's drawn status marks. `filled` (compact and minimal) puts
/// Blocked and Done in a filled circle, with the count in place of the mark
/// when one is given; `card` (expanded) draws Done as a bare check.
struct AgentActivityIslandGlyph: View {
    enum Style { case filled, card }

    let status: String
    let diameter: CGFloat
    var style: Style = .filled
    var count: Int? = nil

    var body: some View {
        let r = diameter / 2
        let color = AgentActivityStatusStyle.ink(for: status, on: .island)
        ZStack {
            switch status {
            case "working":
                let ring = style == .card ? (radius: r * 0.82, width: r * 0.3) : (radius: r * 0.84, width: r * 0.29)
                Circle().stroke(color.opacity(0.28), lineWidth: ring.width)
                    .frame(width: ring.radius * 2, height: ring.radius * 2)
                Circle().trim(from: 0, to: 0.7)
                    .stroke(color, style: StrokeStyle(lineWidth: ring.width, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: ring.radius * 2, height: ring.radius * 2)
                if let count {
                    countText(count, size: count >= 10 ? r : r * 1.15, color: color)
                }
            case "done" where style == .card:
                Path { path in
                    path.move(to: CGPoint(x: r * 0.3, y: r * 1.05))
                    path.addLine(to: CGPoint(x: r * 0.78, y: r * 1.53))
                    path.addLine(to: CGPoint(x: r * 1.73, y: r * 0.53))
                }
                .stroke(color, style: StrokeStyle(lineWidth: r * 0.32, lineCap: .round, lineJoin: .round))
            default:
                Circle().fill(color)
                if let count {
                    countText(count, size: count >= 10 ? r * 1.05 : r * 1.2, color: AgentActivityIslandColor.ink)
                } else if status == "done" {
                    Path { path in
                        path.move(to: CGPoint(x: r * 0.54, y: r * 1.03))
                        path.addLine(to: CGPoint(x: r * 0.86, y: r * 1.35))
                        path.addLine(to: CGPoint(x: r * 1.48, y: r * 0.71))
                    }
                    .stroke(
                        AgentActivityIslandColor.ink,
                        style: StrokeStyle(lineWidth: r * 0.24, lineCap: .round, lineJoin: .round))
                } else {
                    Capsule().fill(AgentActivityIslandColor.ink)
                        .frame(width: r * 0.28, height: r * 0.7)
                        .offset(y: -r * 0.23)
                    Circle().fill(AgentActivityIslandColor.ink)
                        .frame(width: r * 0.32, height: r * 0.32)
                        .offset(y: r * 0.44)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    private func countText(_ count: Int, size: CGFloat, color: Color) -> some View {
        Text(verbatim: String(count))
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// The Host letter: plain grey text at the numbers' size.
struct AgentActivityHostLetter: View {
    let letter: String
    let unit: CGFloat

    var body: some View {
        Text(verbatim: letter)
            .font(.system(size: unit, weight: .semibold))
            .foregroundStyle(AgentActivityIslandColor.hostLetter)
            .lineLimit(1)
            .fixedSize()
    }
}

/// One side of the compact island. When iOS limits the island's width (in
/// landscape on iOS 27) the island is an upright pill on the camera edge:
/// the minimal badge above the camera and the Host letter below it.
struct AgentActivityCompactSide: View {
    enum Edge { case leading, trailing }

    let presentation: AgentActivityIslandPresentation
    let edge: Edge
    var screenWidth: CGFloat?

    var body: some View {
        Group {
            if #available(iOS 27.0, *) {
                AgentActivityLimitedWidthSide(presentation: presentation, edge: edge) { full }
            } else {
                full
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHidden(edge == .trailing)
        .islandTypeSize()
    }

    private var full: AgentActivityCompactRow {
        AgentActivityCompactRow(
            layout: presentation.compact(
                screenWidth: screenWidth ?? AgentActivityIslandMetrics.portraitScreenWidth,
                textWidths: .font),
            edge: edge)
    }
}

extension AgentActivityIslandCompact.TextWidths {
    /// The widths the island's fonts draw: semibold system text, with
    /// monospaced digits for counts, rounded up to whole pixels.
    static let font = Self(
        count: { text, unit in
            measured(text, UIFont.monospacedDigitSystemFont(ofSize: unit, weight: .semibold))
        },
        letter: { text, unit in measured(text, UIFont.systemFont(ofSize: unit, weight: .semibold)) })

    private static func measured(_ text: String, _ font: UIFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        return (width * 3).rounded(.up) / 3
    }
}

@available(iOS 27.0, *)
private struct AgentActivityLimitedWidthSide<Full: View>: View {
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimited
    let presentation: AgentActivityIslandPresentation
    let edge: AgentActivityCompactSide.Edge
    @ViewBuilder let full: Full

    var body: some View {
        if !isLimited {
            full
        } else if edge == .leading {
            AgentActivityMinimalBadge(tallies: presentation.tallies)
        } else if let letter = presentation.hostLabel {
            AgentActivityHostLetter(letter: letter, unit: AgentActivityIslandCompact.Level.full.unit)
        }
    }
}

struct AgentActivityCompactRow: View {
    let layout: AgentActivityIslandCompact
    let edge: AgentActivityCompactSide.Edge

    var body: some View {
        content.frame(width: layout.sideWidth, alignment: edge == .leading ? .trailing : .leading)
    }

    /// The side's marks at their own size, before the shared width.
    var content: some View {
        let level = layout.level
        let items = edge == .leading ? layout.leading : layout.trailing
        return HStack(spacing: level.itemSpacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { @Sendable [level] entry in
                AgentActivityCompactItem(item: entry.element, level: level)
            }
            if edge == .trailing, let letter = layout.letter {
                AgentActivityHostLetter(letter: letter, unit: level.unit)
            }
        }
    }
}

private struct AgentActivityCompactItem: View {
    let item: AgentActivityIslandCompact.Item
    let level: AgentActivityIslandCompact.Level

    var body: some View {
        switch item {
        case .symbol(let status):
            AgentActivityIslandGlyph(status: status, diameter: level.symbol)
        case .count(let status, let count):
            countText(status, count)
        case .pair(let status, let count):
            HStack(spacing: level.symbolGap) {
                AgentActivityIslandGlyph(status: status, diameter: level.symbol)
                countText(status, count)
            }
        }
    }

    private func countText(_ status: String, _ count: Int) -> some View {
        Text(verbatim: String(count))
            .font(.system(size: level.unit, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(AgentActivityStatusStyle.ink(for: status, on: .island))
            .lineLimit(1)
            .fixedSize()
    }
}

struct AgentActivityMinimal: View {
    let presentation: AgentActivityIslandPresentation

    var body: some View {
        AgentActivityMinimalBadge(tallies: presentation.tallies)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
            .islandTypeSize()
    }
}

/// The first status in attention order with its count inside, filling the
/// minimal box; with more statuses it shrinks so a dot per other status fits
/// underneath.
struct AgentActivityMinimalBadge: View {
    let tallies: [AgentActivityIslandPresentation.Tally]

    var body: some View {
        let box = AgentActivityIslandMetrics.minimalBox
        ZStack {
            if let top = tallies.first {
                if tallies.count == 1 {
                    AgentActivityIslandGlyph(status: top.status, diameter: box, count: top.count)
                } else {
                    let dot = box * 0.2
                    let diameter = box - dot - box * 0.075
                    AgentActivityIslandGlyph(status: top.status, diameter: diameter, count: top.count)
                        .offset(y: -box / 2 + diameter / 2)
                    HStack(spacing: dot * 0.5) {
                        ForEach(tallies.dropFirst().map(\.status), id: \.self) { @Sendable status in
                            Circle()
                                .fill(AgentActivityStatusStyle.ink(for: status, on: .island))
                                .frame(width: dot, height: dot)
                        }
                    }
                    .offset(y: box / 2 - dot / 2)
                }
            }
        }
        .frame(width: box, height: box)
    }
}

struct AgentActivityIslandHeadline: View {
    let presentation: AgentActivityIslandPresentation

    var body: some View {
        HStack(spacing: 7) {
            if let label = presentation.hostLabel {
                Text(verbatim: label)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 17, height: 17)
                    .background(
                        AgentActivityIslandColor.hostTile,
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            if let hostName = presentation.hostName {
                Text(hostName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.leading, AgentActivityIslandMetrics.expandedHeaderInset)
        .frame(maxWidth: .infinity, minHeight: AgentActivityIslandMetrics.headerHeight, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.hostName ?? presentation.accessibilityLabel)
        .islandTypeSize()
    }
}

struct AgentActivityIslandAgentTotal: View {
    let total: Int

    var body: some View {
        Text(String(localized: "\(total) agents", comment: "Expanded Dynamic Island header: how many Agents the Host has."))
            .font(.system(size: 12.5))
            .foregroundStyle(AgentActivityIslandColor.secondary)
            .lineLimit(1)
            .padding(.trailing, AgentActivityIslandMetrics.expandedHeaderInset)
            .islandTypeSize()
    }
}

/// Expanded bottom region: B2's cards side by side, then the Agents left
/// out, by status.
struct AgentActivityIslandCards: View {
    let expanded: AgentActivityIslandExpanded
    let hostID: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            if !expanded.cards.isEmpty {
                HStack(spacing: AgentActivityIslandMetrics.cardSpacing) {
                    ForEach(expanded.cards, id: \.paneID) { @Sendable [hostID] agent in
                        AgentActivityLinked(
                            hostID: hostID, agent: agent, surface: .island,
                            minimumHeight: AgentActivityIslandMetrics.cardHeight
                        ) {
                            AgentActivityIslandCard(agent: agent)
                        }
                    }
                }
            }
            if !expanded.summary.isEmpty {
                AgentActivityIslandSummary(
                    summary: expanded.summary, isOverflow: expanded.isOverflow)
                    .padding(.trailing, AgentActivityIslandMetrics.expandedHeaderInset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .islandTypeSize()
    }
}

struct AgentActivityIslandCard: View {
    let agent: AgentActivityDetails.AgentDetail

    var body: some View {
        let rows = AgentActivityFields.rows(for: agent).map { $0.map(\.text).joined() }
        VStack(alignment: .leading, spacing: 0) {
            AgentActivityIslandGlyph(status: agent.status, diameter: 13, style: .card)
                .padding(.leading, -2.5)
            Text(rows.first ?? "")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.top, 2)
            if rows.count > 1 {
                Text(rows[1])
                    .font(.system(size: 10.5))
                    .foregroundStyle(AgentActivityIslandColor.task)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .padding(.top, 8.5)
        .frame(
            maxWidth: .infinity, minHeight: AgentActivityIslandMetrics.cardHeight,
            maxHeight: AgentActivityIslandMetrics.cardHeight, alignment: .topLeading)
        .background(
            agent.status == "blocked" ? AgentActivityIslandColor.blockedCard : AgentActivityIslandColor.card,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// "+1 ✓ +2 ◌ more" in status colors; counts-only, the same counts without
/// the plus signs or "more".
struct AgentActivityIslandSummary: View {
    let summary: [AgentActivityIslandPresentation.Tally]
    let isOverflow: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(summary.enumerated()), id: \.offset) { @Sendable [isOverflow] entry in
                HStack(spacing: 2) {
                    Text(verbatim: isOverflow ? "+\(entry.element.count)" : String(entry.element.count))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(AgentActivityStatusStyle.ink(for: entry.element.status, on: .island))
                    AgentActivityIslandGlyph(status: entry.element.status, diameter: 10, style: .card)
                }
                .padding(.leading, entry.offset == 0 ? 0 : 10)
            }
            if isOverflow {
                Text(String(localized: "more", comment: "Ends the expanded Dynamic Island's count of Agents without a card, as in “+1 ✓ +2 ◌ more”."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(AgentActivityIslandColor.secondary)
                    .padding(.leading, 5)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentActivityCopy.countPhrases(.init(
            working: summary.first { $0.status == "working" }?.count ?? 0,
            blocked: summary.first { $0.status == "blocked" }?.count ?? 0,
            done: summary.first { $0.status == "done" }?.count ?? 0)).joinedAsPhraseList)
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
struct AgentActivityLinked<Content: View>: View {
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
            AgentActivityCompactSide(presentation: island, edge: .leading, screenWidth: 430)
            // Stands in for the camera housing between the two sides.
            Color.clear.frame(width: 131)
            AgentActivityCompactSide(presentation: island, edge: .trailing, screenWidth: 430)
        }
        .padding(.horizontal, 9)
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
        let expanded = AgentActivityIslandExpanded(presentation: presentation)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                AgentActivityIslandHeadline(presentation: island)
                AgentActivityIslandAgentTotal(total: expanded.total)
            }
            AgentActivityIslandCards(
                expanded: expanded, hostID: "6D8EC348-4DAF-455C-BA8F-5FCC41799C0E")
        }
        .padding(.horizontal, AgentActivityIslandMetrics.expandedSideMargin)
        .padding(.vertical, 14)
        .frame(width: 408)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
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
