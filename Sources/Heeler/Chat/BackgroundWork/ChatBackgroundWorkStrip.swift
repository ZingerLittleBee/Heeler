import SwiftUI
import UIKit

/// Chat's Background Work over the Composer (ADR 0024): up to three rows,
/// running work first, then "+N more"; one line while the Composer is open
/// or a Blocked card stands in its place. Every row opens the sheet that
/// lists it all; nothing here stops work. Empty when there is nothing to
/// list, so its height drops to zero.
struct ChatBackgroundWorkStrip: View {
    let work: ChatBackgroundWork
    let isHostConnected: Bool
    let isCondensed: Bool
    /// Whether finished rows still show once no unfinished Background Work
    /// remains (for example while the foreground turn is still running).
    var showsFinishedWork = true
    /// Opens the sheet at a row's id, or at no row.
    let open: (String?) -> Void

    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    private var showsStrip: Bool {
        !work.rows.isEmpty && (showsFinishedWork || work.hasUnfinished)
    }

    var body: some View {
        if showsStrip {
            // Only a running row's time moves, so only then does it tick.
            if presentation(at: .now).ticks {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    content(presentation(at: context.date))
                }
            } else {
                content(presentation(at: .now))
            }
        }
    }

    private func presentation(at now: Date) -> ChatBackgroundWorkPresentation {
        ChatBackgroundWorkPresentation(
            work: work, isHostConnected: isHostConnected, now: now, locale: locale, calendar: calendar)
    }

    @ViewBuilder
    private func content(_ presentation: ChatBackgroundWorkPresentation) -> some View {
        Group {
            if isCondensed, let summary = presentation.summary {
                ChatBackgroundWorkSummaryLine(summary: summary, open: { open(nil) })
            } else {
                ChatBackgroundWorkRows(presentation: presentation, open: open)
            }
        }
        // The Composer card's inset, so the edges line up.
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}

enum ChatBackgroundWorkStyle {
    /// Activity card silhouette shared by the strip and sheet cards.
    static let card = RoundedRectangle(cornerRadius: 16, style: .continuous)
    static let hint = String(localized: "Shows all background work.")
}

/// Shared Catppuccin Mocha/Latte tokens for Background Work activity cards,
/// built on `AgentStatusPalette` so working/done/failed mean the same thing
/// here as in the Console's Agent switcher.
enum ChatBackgroundWorkPalette {
    private static let mauveWashUI = flavoured(mocha: 0xCBA6F7, latte: 0x8839EF)
    private static let mauveInkUI = flavoured(mocha: 0xCBA6F7, latte: 0x6C22C7)
    private static let blueWashUI = flavoured(mocha: 0x89B4FA, latte: 0x1E66F5)
    private static let blueInkUI = flavoured(mocha: 0x89B4FA, latte: 0x1450C8)

    static let workflowTint = Color(uiColor: blueInkUI)

    static let terminalBackground = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0, alpha: 0.34)
                : UIColor.secondarySystemFill.withAlphaComponent(0.65)
        })

    static let terminalBorder = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.08)
                : UIColor(white: 0, alpha: 0.08)
        })

    static func statusWash(_ status: ChatBackgroundWorkPresentation.Status) -> Color {
        switch status {
        case .running: Color(uiColor: AgentStatusPalette.yellow).opacity(0.15)
        case .completed: Color(uiColor: AgentStatusPalette.green).opacity(0.14)
        case .failed: Color(uiColor: AgentStatusPalette.red).opacity(0.14)
        case .stopped, .unconfirmed, .quiet: Color(uiColor: AgentStatusPalette.muted).opacity(0.16)
        }
    }

    static func statusInk(_ status: ChatBackgroundWorkPresentation.Status) -> Color {
        switch status {
        case .running: Color(uiColor: AgentStatusPalette.yellowInk)
        case .completed: Color(uiColor: AgentStatusPalette.greenInk)
        case .failed: Color(uiColor: AgentStatusPalette.redInk)
        case .stopped, .unconfirmed, .quiet: Color(uiColor: AgentStatusPalette.mutedInk)
        }
    }

    static func cardBorder(_ status: ChatBackgroundWorkPresentation.Status) -> Color {
        switch status {
        case .running: Color(uiColor: AgentStatusPalette.yellow).opacity(0.32)
        case .failed: Color(uiColor: AgentStatusPalette.red).opacity(0.30)
        case .completed, .stopped, .unconfirmed, .quiet: Color(uiColor: .separator).opacity(0.34)
        }
    }

    static func stripBorder(_ presentation: ChatBackgroundWorkPresentation) -> Color {
        if presentation.hasRunning {
            return Color(uiColor: AgentStatusPalette.yellow).opacity(0.34)
        }
        if presentation.hasFailed {
            return Color(uiColor: AgentStatusPalette.red).opacity(0.28)
        }
        return Color.secondary.opacity(0.18)
    }

    static func kindWash(_ kind: ChatBackgroundWorkItem.Kind) -> Color {
        switch kind {
        case .command: Color(uiColor: AgentStatusPalette.muted).opacity(0.16)
        case .subagent: Color(uiColor: mauveWashUI).opacity(0.14)
        case .workflow: Color(uiColor: blueWashUI).opacity(0.14)
        }
    }

    static func kindInk(_ kind: ChatBackgroundWorkItem.Kind) -> Color {
        switch kind {
        case .command: Color(uiColor: AgentStatusPalette.mutedInk)
        case .subagent: Color(uiColor: mauveInkUI)
        case .workflow: Color(uiColor: blueInkUI)
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

private struct ChatBackgroundWorkRows: View {
    let presentation: ChatBackgroundWorkPresentation
    let open: (String?) -> Void

    @ScaledMetric(relativeTo: .subheadline) private var glyphColumn: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if presentation.stripRows.count == 1, let only = presentation.stripRows.first {
                Button { open(only.id) } label: {
                    ChatBackgroundWorkSingleStripCard(row: only)
                        .padding(.vertical, 8)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(only.accessibilityLabel)
                .accessibilityHint(ChatBackgroundWorkStyle.hint)
                .accessibilityAddTraits(only.status == .running ? [.isButton, .updatesFrequently] : .isButton)
                .accessibilityIdentifier("chat.background-work.\(only.id)")
            } else {
                ForEach(Array(presentation.stripRows.enumerated()), id: \.element.id) { index, row in
                    MainActorContent {
                        if index > 0 {
                            Divider()
                                .opacity(0.45)
                        }
                        Button { open(row.id) } label: {
                            ChatBackgroundWorkRowLabel(row: row, glyphColumn: glyphColumn)
                                .padding(.vertical, 7)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.accessibilityLabel)
                        .accessibilityHint(ChatBackgroundWorkStyle.hint)
                        .accessibilityAddTraits(row.status == .running ? [.isButton, .updatesFrequently] : .isButton)
                        .accessibilityIdentifier("chat.background-work.\(row.id)")
                    }
                }
            }
            if presentation.overflow > 0 {
                Divider()
                    .opacity(0.45)
                Button { open(nil) } label: {
                    HStack(spacing: 4) {
                        Text("+\(presentation.overflow) more")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tint)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    }
                    .padding(.leading, glyphColumn + 8)
                    .padding(.vertical, 7)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("\(presentation.overflow) more")
                .accessibilityHint(ChatBackgroundWorkStyle.hint)
                .accessibilityIdentifier("chat.background-work.more")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background {
            ChatBackgroundWorkStyle.card
                .fill(.regularMaterial)
                .overlay {
                    if presentation.hasRunning {
                        ChatBackgroundWorkStyle.card.fill(
                            LinearGradient(
                                colors: [Color(uiColor: AgentStatusPalette.yellow).opacity(0.07), .clear],
                                startPoint: .top,
                                endPoint: .bottom))
                    }
                }
        }
        .overlay {
            ChatBackgroundWorkStyle.card
                .stroke(ChatBackgroundWorkPalette.stripBorder(presentation), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Background work")
        .accessibilityIdentifier("chat.background-work")
    }
}

/// Option 2's structured 2-tier strip card when a single background item is
/// listed: status & kind pills with elapsed time on top, human summary below.
private struct ChatBackgroundWorkSingleStripCard: View {
    let row: ChatBackgroundWorkPresentation.Row

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var barWidth: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        ChatBackgroundWorkStatusPill(status: row.status)
                        ChatBackgroundWorkKindChip(kind: row.kind, label: row.kindBadge)
                    }
                    ChatBackgroundWorkStatusPill(status: row.status)
                }
                Spacer(minLength: 4)
                trailingMeta
            }
            Text(verbatim: row.stripHeadline)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(row.status == .completed || row.status == .stopped ? .secondary : .primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        }
    }

    private var trailingMeta: some View {
        HStack(spacing: 6) {
            if let fraction = row.fraction {
                if row.status == .running {
                    ProgressView(
                        value: Double(min(fraction.done, fraction.total)),
                        total: Double(max(fraction.total, 1)))
                        .progressViewStyle(.linear)
                        .tint(ChatBackgroundWorkPalette.workflowTint)
                        .frame(width: barWidth)
                }
                Text(verbatim: "\(fraction.done)/\(fraction.total)")
                    .foregroundStyle(.secondary)
            }
            if let time = row.time {
                Text(verbatim: time)
                    .fontWeight(row.status == .running ? .semibold : .medium)
                    .foregroundStyle(
                        row.status == .running ? ChatBackgroundWorkPalette.statusInk(.running) : .secondary)
            } else if let note = row.shortNote {
                Text(verbatim: note)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }
}

/// One row in a multi-item strip: its state glyph, human-first headline, kind
/// chip when room allows, and moving tabular time.
private struct ChatBackgroundWorkRowLabel: View {
    let row: ChatBackgroundWorkPresentation.Row
    let glyphColumn: CGFloat

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var barWidth: CGFloat = 36

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ChatBackgroundWorkGlyph(status: row.status)
                .frame(width: glyphColumn)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    title
                    HStack(spacing: 6) {
                        ChatBackgroundWorkKindChip(kind: row.kind, label: row.kindBadge)
                        meta
                    }
                }
                Spacer(minLength: 0)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 6) {
                        title
                        ChatBackgroundWorkKindChip(kind: row.kind, label: row.kindBadge)
                    }
                    title
                }
                Spacer(minLength: 8)
                meta
            }
        }
    }

    private var title: some View {
        Text(verbatim: row.stripHeadline)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(row.status == .completed || row.status == .stopped ? .secondary : .primary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
    }

    /// Never wraps and keeps its digits' width, so a tick can't move the
    /// row or the conversation above it.
    private var meta: some View {
        HStack(spacing: 6) {
            if let fraction = row.fraction {
                if row.status == .running {
                    ProgressView(
                        value: Double(min(fraction.done, fraction.total)),
                        total: Double(max(fraction.total, 1)))
                        .progressViewStyle(.linear)
                        .tint(ChatBackgroundWorkPalette.workflowTint)
                        .frame(width: barWidth)
                }
                Text(verbatim: "\(fraction.done)/\(fraction.total)")
                    .foregroundStyle(.secondary)
            }
            if let time = row.time {
                Text(verbatim: time)
                    .fontWeight(row.status == .running ? .semibold : .regular)
                    .foregroundStyle(
                        row.status == .running ? ChatBackgroundWorkPalette.statusInk(.running) : .secondary)
            } else if let note = row.shortNote {
                Text(verbatim: note)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }
}

/// The rows condensed to one line, which opens the sheet.
private struct ChatBackgroundWorkSummaryLine: View {
    let summary: ChatBackgroundWorkPresentation.Summary
    let open: () -> Void

    @ScaledMetric(relativeTo: .subheadline) private var glyphColumn: CGFloat = 18

    private var borderColor: Color {
        switch summary.status {
        case .running: Color(uiColor: AgentStatusPalette.yellow).opacity(0.32)
        case .failed: Color(uiColor: AgentStatusPalette.red).opacity(0.28)
        default: Color.secondary.opacity(0.18)
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                ChatBackgroundWorkGlyph(status: summary.status)
                    .frame(width: glyphColumn)
                Text(verbatim: ChatBackgroundWorkPresentation.Row.singleLine(summary.text))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(summary.status == .running ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: ChatBackgroundWorkStyle.card)
            .overlay { ChatBackgroundWorkStyle.card.stroke(borderColor, lineWidth: 1) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Background work")
        .accessibilityValue(summary.accessibilityValue)
        .accessibilityHint(ChatBackgroundWorkStyle.hint)
        .accessibilityAddTraits(summary.status == .running ? [.isButton, .updatesFrequently] : .isButton)
        .accessibilityIdentifier("chat.background-work.summary")
    }
}

/// Capsule status badge in the top-left of an activity card (`Running`,
/// `Done`, `Failed`, `Stopped`, `Not updating`).
struct ChatBackgroundWorkStatusPill: View {
    let status: ChatBackgroundWorkPresentation.Status

    var body: some View {
        HStack(spacing: 5) {
            statusIcon
            Text(verbatim: status.badgeLabel)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(ChatBackgroundWorkPalette.statusInk(status))
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(ChatBackgroundWorkPalette.statusWash(status), in: Capsule())
        .fixedSize()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .running:
            ChatBackgroundWorkSpinningArc(size: 11, lineWidth: 1.9)
        case .unconfirmed, .quiet:
            Image(systemName: "clock")
                .font(.system(size: 9.5, weight: .semibold))
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 9.5, weight: .bold))
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .bold))
        case .stopped:
            Image(systemName: "stop.fill")
                .font(.system(size: 8.5, weight: .bold))
        }
    }
}

/// Compact semantic badge naming the background work's kind (`Command`,
/// `Subagent · research`, `Workflow · Verify`).
struct ChatBackgroundWorkKindChip: View {
    let kind: ChatBackgroundWorkItem.Kind
    let label: String

    var body: some View {
        Text(verbatim: label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(ChatBackgroundWorkPalette.kindInk(kind))
            .lineLimit(1)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2.5)
            .background(
                ChatBackgroundWorkPalette.kindWash(kind),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Continuously turning status arc driven by `TimelineView(.animation)` so
/// periodic 1-second timer ticks never reset or hitch the rotation.
struct ChatBackgroundWorkSpinningArc: View {
    var size: CGFloat = 13
    var lineWidth: CGFloat = 2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            arc(angle: .degrees(-45))
        } else {
            TimelineView(.animation) { context in
                let period = 1.1
                let turns = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                arc(angle: .degrees(turns * 360))
            }
        }
    }

    private func arc(angle: Angle) -> some View {
        ZStack {
            Circle()
                .stroke(lineWidth: lineWidth)
                .opacity(0.24)
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(angle)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Compact status glyph for condensed lines, multi-row strips, and Workflow
/// agent rows, painted in `AgentStatusPalette`.
struct ChatBackgroundWorkGlyph: View {
    let status: ChatBackgroundWorkPresentation.Status

    var body: some View {
        Group {
            switch status {
            case .running:
                ChatBackgroundWorkSpinningArc(size: 13, lineWidth: 2)
                    .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.running))
            case .unconfirmed, .quiet:
                Image(systemName: "clock")
                    .foregroundStyle(ChatBackgroundWorkPalette.statusInk(status))
            case .completed:
                Image(systemName: "checkmark")
                    .fontWeight(.bold)
                    .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.completed))
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.failed))
            case .stopped:
                Image(systemName: "stop.circle")
                    .foregroundStyle(ChatBackgroundWorkPalette.statusInk(.stopped))
            }
        }
        .font(.caption)
        .accessibilityHidden(true)
    }
}
