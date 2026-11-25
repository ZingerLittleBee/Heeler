import ActivityKit
import CoreText
import SwiftUI
import UIKit
import WidgetKit

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

    static let hostTile = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x41 / 255, green: 0x41 / 255, blue: 0x46 / 255, alpha: 1)
            : UIColor(red: 0xe1 / 255, green: 0xdf / 255, blue: 0xe0 / 255, alpha: 1)
    })

    static let glyphCut = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x1e / 255, green: 0x1e / 255, blue: 0x22 / 255, alpha: 1)
            : .white
    })
}

struct AgentActivityLockScreenView: View {
    private static let tileHeight: CGFloat = 64

    let hostID: String
    let isStale: Bool
    private let hostName: String?
    private let hostLabel: String?
    private let lockScreen: AgentActivityLockScreenPresentation

    init(
        presentation: AgentActivityPresentation, hostID: String, isStale: Bool,
        hostSnapshot: LiveActivityHostSnapshot? = LiveActivityHostSnapshotStore().read()
    ) {
        self.hostID = hostID
        self.isStale = isStale
        let host = AgentActivityIslandPresentation(
            presentation: presentation, hostID: hostID, hostSnapshot: hostSnapshot)
        hostName = host.hostName
        hostLabel = host.hostLabel
        lockScreen = AgentActivityLockScreenPresentation(presentation: presentation, isStale: isStale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if !lockScreen.tiles.isEmpty {
                    columns(lockScreen.tiles) { agent, insets in
                        AgentActivityLinked(
                            hostID: hostID, agent: agent, surface: .lockScreen,
                            minimumHeight: Self.tileHeight
                        ) {
                            tile(for: agent)
                                .padding(insets)
                        }
                    }
                } else if !lockScreen.countColumns.isEmpty {
                    columns(lockScreen.countColumns) { column, insets in
                        VStack(alignment: .leading, spacing: 3) {
                            statusLine(column.status)
                            Text(column.count, format: .number.grouping(.never))
                                .font(.system(size: 28, weight: .medium))
                                .tracking(-1)
                                .frame(height: 34)
                        }
                        .padding(insets)
                    }
                }
            }
            .opacity(isStale ? 0.5 : 1)
            .padding(.bottom, 11)

            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 1)
                .accessibilityHidden(true)

            footer
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(AgentActivitySemanticStyle.primary(on: .lockScreen))
        .padding(.top, 15)
        .padding(.horizontal, 17)
        .padding(.bottom, 11)
        .dynamicTypeSize(...DynamicTypeSize.large)
        .widgetURL(AgentActivityLink.consoleURL(hostID: hostID))
    }

    private func columns<Item, Content: View>(
        _ items: [Item], @ViewBuilder content: @escaping (Item, EdgeInsets) -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { entry in
                let isFirst = entry.offset == 0
                let insets = EdgeInsets(
                    top: 0, leading: isFirst ? 0 : 16, bottom: 0, trailing: isFirst ? 13 : 0)
                content(entry.element, insets)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) {
                        if !isFirst {
                            Rectangle()
                                .fill(Color(uiColor: .separator))
                                .frame(width: 1)
                                .accessibilityHidden(true)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
    }

    private func statusLine(_ status: String) -> some View {
        HStack(spacing: 6) {
            AgentActivityIslandGlyph(status: status, diameter: 13, style: .card, surface: .lockScreen)
            Text(AgentActivityCopy.lockScreenStatus(status))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AgentActivityStatusStyle.ink(for: status, on: .lockScreen))
                .lineLimit(1)
        }
        .frame(height: 16)
    }

    private func tile(for agent: AgentActivityDetails.AgentDetail) -> some View {
        let text = AgentActivityLockScreenPresentation.TileText(agent: agent)
        return VStack(alignment: .leading, spacing: 0) {
            statusLine(agent.status)
            if let task = text.task {
                Text(verbatim: task)
                    .font(.system(size: 18, weight: .semibold))
                    .tracking(-0.55)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: 21)
                    .padding(.top, 7)
                    .padding(.bottom, 4)
            }
            if let byline = text.byline {
                Text(verbatim: byline)
                    .font(.system(size: 12))
                    .foregroundStyle(AgentActivitySemanticStyle.secondary(on: .lockScreen))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: 16)
            }
        }
        .frame(height: Self.tileHeight, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                if let hostLabel {
                    Text(verbatim: hostLabel)
                        .font(.system(size: 10, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .frame(width: 17, height: 17)
                        .background(AgentActivityLockScreenChrome.hostTile, in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityHidden(true)
                }
                if let hostName {
                    Text(verbatim: hostName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .tracking(-0.12)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Group {
                switch lockScreen.footer {
                case .total(let total):
                    Text(verbatim: total)
                        .font(.system(size: 12))
                case .phrases(let phrases):
                    HStack(spacing: 10) {
                        ForEach(phrases, id: \.self) { phrase in
                            Text(verbatim: phrase)
                        }
                    }
                    .font(.system(size: 11.5))
                }
            }
            .foregroundStyle(AgentActivitySemanticStyle.secondary(on: .lockScreen))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .layoutPriority(1)
        }
        .frame(height: 20)
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

/// The island's drawn status marks. `filled` (compact and minimal) puts
/// Blocked and Done in a filled circle, with the count in place of the mark
/// when one is given; `card` (expanded) draws Done as a bare check.
struct AgentActivityIslandGlyph: View {
    enum Style { case filled, card }

    let status: String
    let diameter: CGFloat
    var style: Style = .filled
    var count: Int? = nil
    var surface: AgentActivitySurface = .island

    var body: some View {
        let r = diameter / 2
        let color = AgentActivityStatusStyle.ink(for: status, on: surface)
        let cut = surface == .lockScreen ? AgentActivityLockScreenChrome.glyphCut : AgentActivityIslandColor.ink
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
                    countText(count, size: count >= 10 ? r * 1.05 : r * 1.2, color: cut)
                } else if status == "done" {
                    Path { path in
                        path.move(to: CGPoint(x: r * 0.54, y: r * 1.03))
                        path.addLine(to: CGPoint(x: r * 0.86, y: r * 1.35))
                        path.addLine(to: CGPoint(x: r * 1.48, y: r * 0.71))
                    }
                    .stroke(
                        cut,
                        style: StrokeStyle(lineWidth: r * 0.24, lineCap: .round, lineJoin: .round))
                } else {
                    Capsule().fill(cut)
                        .frame(width: r * 0.28, height: r * 0.7)
                        .offset(y: -r * 0.23)
                    Circle().fill(cut)
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
    /// monospaced digits for counts, plus half a point SwiftUI's text layout
    /// adds beyond the font's advance, rounded up to whole pixels.
    static let font = Self(
        count: { text, unit in
            measured(text, UIFont.monospacedDigitSystemFont(ofSize: unit, weight: .semibold))
        },
        letter: { text, unit in measured(text, UIFont.systemFont(ofSize: unit, weight: .semibold)) })

    private static func measured(_ text: String, _ font: UIFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + 0.5
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
        Text(String(localized: "\(total) agents", comment: "Total number of Agents on a Host in a Live Activity."))
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

        static var singleAgent: AgentActivityPresentation {
            .detailed(details: .init(hostName: "Mac mini", agents: [
                taskAgent("working", pane: "w1:p1", name: "main", task: "Calibrate camera rig"),
            ]), counts: .init(working: 1, blocked: 0, done: 0))
        }

        static var oneOfEach: AgentActivityPresentation {
            .detailed(details: .init(hostName: "Laptop", agents: [
                taskAgent("blocked", pane: "w1:p1", name: "herdr", task: "Redesign live activity"),
                taskAgent("done", pane: "w1:p2", name: "arch", task: "Fix sshd forwarding", kind: "codex"),
                taskAgent("working", pane: "w1:p3", name: "docs", task: "Update changelog"),
            ]), counts: .init(working: 1, blocked: 1, done: 1))
        }

        static var sixAgents: AgentActivityPresentation {
            .detailed(details: .init(hostName: "Laptop", agents: oneOfEach.agents + [
                taskAgent("done", pane: "w1:p4", name: "api", task: "Add rate limits", kind: "codex"),
                taskAgent("done", pane: "w1:p5", name: "cli", task: "Bump version"),
            ]), counts: .init(working: 2, blocked: 1, done: 3))
        }

        static var threeBlocked: AgentActivityPresentation {
            .detailed(details: .init(hostName: "Laptop", agents: [
                taskAgent("blocked", pane: "w1:p1", name: "herdr", task: "Redesign live activity"),
                taskAgent("blocked", pane: "w1:p2", name: "reviewer", task: "Approve the refactor plan"),
                taskAgent("blocked", pane: "w1:p3", name: "docs", task: "Update changelog"),
            ]), counts: .init(working: 2, blocked: 3, done: 0))
        }

        static var longTasks: AgentActivityPresentation {
            .detailed(details: .init(hostName: "Laptop", agents: [
                taskAgent("blocked", pane: "w1:p1", name: "reviewer",
                    task: "Approve the transport refactor plan before the release branch is cut"),
                taskAgent("working", pane: "w1:p2", name: "fixer",
                    task: "Chase the flaky pairing test that fails only on CI", kind: "codex"),
            ]), counts: .init(working: 1, blocked: 1, done: 0))
        }

        private static func taskAgent(
            _ status: String, pane: String, name: String, task: String, kind: String = "claude"
        ) -> AgentActivityDetails.AgentDetail {
            .init(paneID: pane, kind: kind, status: status, title: nil,
                rows: [[.init(text: name, bold: true)], [.init(text: task)]])
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

    @MainActor private func previewLockScreenBanner(
        _ presentation: AgentActivityPresentation,
        colorScheme: ColorScheme = .dark,
        isStale: Bool = false
    ) -> some View {
        let hostID = "6D8EC348-4DAF-455C-BA8F-5FCC41799C0E"
        let hostName = presentation.lockScreenHostName(hostID: hostID, snapshot: nil) ?? "Mac mini"
        let snapshot = LiveActivityHostSnapshot(v: 1, hosts: [
            .init(id: hostID, name: hostName, label: String(hostName.prefix(1))),
            .init(id: "other", name: "Workstation", label: "W"),
        ])
        return AgentActivityLockScreenView(
            presentation: presentation, hostID: hostID, isStale: isStale, hostSnapshot: snapshot
        )
        .frame(width: 361)
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
                .init(id: "other", name: "Mac mini", label: "M"),
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

    #Preview("Lock Screen: One Agent") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.singleAgent)
    }

    #Preview("Lock Screen: One of each status") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.oneOfEach, colorScheme: .light)
    }

    #Preview("Lock Screen: Six Agents") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.sixAgents)
    }

    #Preview("Lock Screen: Three Blocked") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.threeBlocked)
    }

    #Preview("Lock Screen: Stale") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.oneOfEach, isStale: true)
    }

    #Preview("Lock Screen: Counts only, two statuses") {
        previewLockScreenBanner(.countsOnly(counts: .init(working: 2, blocked: 1, done: 0)))
    }

    #Preview("Lock Screen: Counts only, three statuses") {
        previewLockScreenBanner(.countsOnly(counts: .init(working: 12, blocked: 1, done: 4)))
    }

    #Preview("Lock Screen: Long tasks") {
        previewLockScreenBanner(AgentActivityPreviewFixtures.longTasks, colorScheme: .light)
    }

    #Preview("Configured fields (Expanded island)") {
        previewIslandExpanded(AgentActivityPreviewFixtures.configuredFields)
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
