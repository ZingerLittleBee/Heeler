import SwiftUI
import UIKit

/// What runs beside the conversation, over the Composer: an Antigravity CLI
/// Swarm's row when the Agent runs one, then Chat's Background Work
/// (ADR 0024), up to three rows, running work first, then "+N more". Two
/// rows or more stand under a line that counts them by state and folds
/// them into itself, which the user's choice keeps. Each is one line while
/// the Composer is open or a Blocked card stands in its place, whatever
/// that choice. Every row opens its sheet; nothing here stops work. Empty
/// when there is nothing to list, so its height drops to zero.
struct ChatBackgroundWorkStrip: View {
    let work: ChatBackgroundWork
    let isHostConnected: Bool
    let isCondensed: Bool
    /// Whether finished rows still show once no unfinished Background Work
    /// remains (for example while the foreground turn is still running).
    var showsFinishedWork = true
    /// Whether the user folded the rows into the line that counts them.
    var isFolded = false
    var toggleFold: () -> Void = {}
    /// Opens the sheet at a row's id, or at no row.
    let open: (String?) -> Void
    /// The Agent's Swarm, which leads the strip.
    var swarm: AgySwarmSnapshot? = nil
    var openSwarm: () -> Void = {}

    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.themeColors) private var themeColors

    private var showsWork: Bool {
        !work.rows.isEmpty && (showsFinishedWork || work.hasUnfinished)
    }

    /// A lone row has no line to fold into.
    private var isFoldable: Bool { showsWork && work.rows.count > 1 }

    var body: some View {
        if swarm != nil || showsWork {
            let shape = RoundedRectangle(cornerRadius: isCondensed ? 14 : 16, style: .continuous)
            VStack(spacing: 0) {
                if let swarm {
                    // Folded work takes the Swarm to its one line with it.
                    ChatSwarmLiveBar(
                        swarm: swarm, isCondensed: isCondensed || (isFoldable && isFolded), open: openSwarm)
                }
                if showsWork {
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
            .clipShape(shape)
            // Glass in the theme's background, as the Composer's card under
            // it is: the conversation scrolling beneath shows through both.
            .themeGlass(in: shape, theme: themeColors)
            // The strip grows up from the Composer, so what it holds keeps
            // to its top edge: a row that comes or goes rides under the
            // line over it, not across it.
            .geometryGroup()
            // A row is a finger tall at least, and never squeezed to that.
            .fixedSize(horizontal: false, vertical: true)
            // The Composer card's inset, so the edges line up.
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
    }

    private func presentation(at now: Date) -> ChatBackgroundWorkPresentation {
        ChatBackgroundWorkPresentation(
            work: work, isHostConnected: isHostConnected, now: now, locale: locale, calendar: calendar)
    }

    /// The counting line in whichever part it plays, then the rows unless
    /// it stands for them. The line keeps its place across the fold, so
    /// folding moves the rows and not the line.
    private func content(_ presentation: ChatBackgroundWorkPresentation) -> some View {
        let isLed = swarm != nil
        let role: ChatBackgroundWorkSummaryLine.Role? =
            isCondensed ? .opensSheet : !isFoldable ? nil : isFolded ? .unfolds : .folds
        return VStack(spacing: 0) {
            if let role, let summary = presentation.summary {
                ChatBackgroundWorkSummaryLine(summary: summary, role: role, isLed: isLed) {
                    if role == .opensSheet { open(nil) } else { toggleFold() }
                }
            }
            if role == nil || role == .folds {
                ChatBackgroundWorkRows(presentation: presentation, isLed: isLed || role != nil, open: open)
                    .transition(.opacity)
            }
        }
    }
}

enum ChatBackgroundWorkStyle {
    /// Where the user's choice to fold the strip's rows is kept, for every
    /// Agent's Chat.
    static let foldedDefaultsKey = "chat.background-work-folded"
    static let hint = String(localized: "Shows all background work.")
    /// How far a strip row stands in from the strip's edge.
    static let rowInset: CGFloat = 14
    /// Between a row's glyph and its text.
    static let glyphSpacing: CGFloat = 10
    /// A strip row's glyph column, before Dynamic Type scales it.
    static let glyphColumn: CGFloat = 16
}

/// Catppuccin Mocha/Latte tokens for Background Work, built on
/// `AgentStatusPalette` so working/done/failed mean the same thing here as
/// in the Console's Agent switcher.
enum ChatBackgroundWorkPalette {
    private static let blueInkUI = UIColor { traits in
        let rgb: UInt32 = traits.userInterfaceStyle == .dark ? 0x89B4FA : 0x1450C8
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1)
    }

    static let workflowTint = Color(uiColor: blueInkUI)

    static func statusInk(_ status: ChatBackgroundWorkPresentation.Status) -> Color {
        switch status {
        case .running: Color(uiColor: AgentStatusPalette.yellowInk)
        case .completed: Color(uiColor: AgentStatusPalette.greenInk)
        case .failed: Color(uiColor: AgentStatusPalette.redInk)
        case .stopped, .unconfirmed, .quiet: Color(uiColor: AgentStatusPalette.mutedInk)
        }
    }
}

/// A row of the strip over the Composer: a finger tall, and under a
/// hairline that starts where its text does unless it leads the strip.
struct ChatStripRow: ViewModifier {
    let glyphColumn: CGFloat
    let isDivided: Bool
    var minHeight: CGFloat = 44

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, ChatBackgroundWorkStyle.rowInset)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .contentShape(.rect)
            .chatRowDivider(
                isDivided,
                inset: ChatBackgroundWorkStyle.rowInset + glyphColumn + ChatBackgroundWorkStyle.glyphSpacing)
    }
}

/// What ends a strip row that opens a sheet.
struct ChatStripChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color(uiColor: .tertiaryLabel))
            .accessibilityHidden(true)
    }
}

private struct ChatBackgroundWorkRows: View {
    let presentation: ChatBackgroundWorkPresentation
    /// Whether the Swarm's row stands over these.
    let isLed: Bool
    let open: (String?) -> Void

    @ScaledMetric(relativeTo: .subheadline) private var glyphColumn = ChatBackgroundWorkStyle.glyphColumn

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(presentation.stripRows.enumerated()), id: \.element.id) { index, row in
                MainActorContent {
                    Button { open(row.id) } label: {
                        ChatBackgroundWorkRowLabel(row: row, glyphColumn: glyphColumn)
                            .modifier(ChatStripRow(glyphColumn: glyphColumn, isDivided: isLed || index > 0))
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
            if presentation.overflow > 0 {
                Button { open(nil) } label: {
                    HStack(spacing: 4) {
                        Text("+\(presentation.overflow) more")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tint)
                        Spacer(minLength: 0)
                        ChatStripChevron()
                    }
                    .padding(.leading, glyphColumn + ChatBackgroundWorkStyle.glyphSpacing)
                    .modifier(ChatStripRow(glyphColumn: glyphColumn, isDivided: true))
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("\(presentation.overflow) more")
                .accessibilityHint(ChatBackgroundWorkStyle.hint)
                .accessibilityIdentifier("chat.background-work.more")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Background work")
        .accessibilityIdentifier("chat.background-work")
    }
}

/// One row of the strip: its state as a glyph, what it is, its kind when
/// room allows, and its time, which moves in place.
private struct ChatBackgroundWorkRowLabel: View {
    let row: ChatBackgroundWorkPresentation.Row
    let glyphColumn: CGFloat

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var barWidth: CGFloat = 30

    var body: some View {
        HStack(alignment: .center, spacing: ChatBackgroundWorkStyle.glyphSpacing) {
            ChatBackgroundWorkGlyph(status: row.status, size: .regular)
                .frame(width: glyphColumn)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    title
                    HStack(spacing: 8) {
                        kind
                        meta
                    }
                }
                .padding(.vertical, 8)
                Spacer(minLength: 0)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: ChatBackgroundWorkStyle.glyphSpacing) {
                        title
                        Spacer(minLength: 0)
                        kind
                    }
                    title
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                meta
            }
        }
    }

    private var title: some View {
        Text(verbatim: row.stripHeadline)
            .font(.subheadline)
            .foregroundStyle(row.status == .completed || row.status == .stopped ? .secondary : .primary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
    }

    private var kind: some View {
        Text(verbatim: row.stripKind)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
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
                    .foregroundStyle(
                        row.status == .running ? ChatBackgroundWorkPalette.statusInk(.running) : .secondary)
            } else if let note = row.shortNote {
                Text(verbatim: note)
                    .font(.caption)
                    .foregroundStyle(ChatBackgroundWorkPalette.statusInk(row.status))
            }
        }
        .font(.system(.caption, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
    }
}

/// The line that counts the rows by state. Over them it is their heading
/// and folds them; in their place it shows their state as one glyph, and
/// either brings them back or, with no room for them, opens the sheet.
private struct ChatBackgroundWorkSummaryLine: View {
    enum Role {
        /// Over the rows, which it folds.
        case folds
        /// In the rows' place by the user's choice, which it undoes.
        case unfolds
        /// In the rows' place while the Composer is open or a Blocked card
        /// stands in its place.
        case opensSheet
    }

    let summary: ChatBackgroundWorkPresentation.Summary
    let role: Role
    /// Whether the Swarm's line stands over this one.
    let isLed: Bool
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var glyphColumn = ChatBackgroundWorkStyle.glyphColumn

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                // The rows under a heading each show their own. It shrinks
                // into the line's edge as the counts take its place, so
                // the two never cross.
                if role != .folds {
                    ChatBackgroundWorkGlyph(status: summary.status, size: .regular)
                        .frame(width: glyphColumn)
                        .padding(.trailing, ChatBackgroundWorkStyle.glyphSpacing)
                        .transition(.scale(scale: 0.01, anchor: .leading).combined(with: .opacity))
                }
                Text(counts)
                    .font(.footnote.monospacedDigit())
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Down where it unfolds, up where it folds, as every
                // disclosure here; right where it leaves for the sheet.
                ChatStripChevron()
                    .rotationEffect(.degrees(role == .unfolds ? 90 : role == .folds ? -90 : 0))
                    .padding(.leading, ChatBackgroundWorkStyle.glyphSpacing)
            }
            .modifier(ChatStripRow(glyphColumn: glyphColumn, isDivided: isLed, minHeight: role == .folds ? 36 : 44))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Background work")
        .accessibilityValue(spokenValue)
        .accessibilityHint(role == .opensSheet ? ChatBackgroundWorkStyle.hint : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(role == .opensSheet ? "chat.background-work.summary" : "chat.background-work.fold")
    }

    /// Each count in its state's ink: a failure red wherever the line
    /// stands, what runs read first while the line stands alone.
    private var counts: AttributedString {
        var line = AttributedString()
        for count in summary.counts {
            if !line.characters.isEmpty {
                var separator = AttributedString(" · ")
                separator.swiftUI.foregroundColor = .secondary
                line += separator
            }
            var part = AttributedString(count.text)
            part.swiftUI.foregroundColor =
                switch count.status {
                case .failed: ChatBackgroundWorkPalette.statusInk(.failed)
                case .running where role != .folds: .primary
                default: .secondary
                }
            line += part
        }
        return line
    }

    private var spokenValue: String {
        switch role {
        case .folds: [summary.accessibilityValue, String(localized: "Expanded")].joinedAsPhrases()
        case .unfolds: [summary.accessibilityValue, String(localized: "Collapsed")].joinedAsPhrases()
        case .opensSheet: summary.accessibilityValue
        }
    }
}

/// Continuously turning status arc driven by Core Animation on the render
/// server (`0` `@MainActor` wakeups per second), `Equatable` so 1-second strip
/// timer ticks never rebuild or reset the rotation.
struct ChatBackgroundWorkSpinningArc: View, Equatable {
    var size: CGFloat = 13
    var lineWidth: CGFloat = 2

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.size == rhs.size && lhs.lineWidth == rhs.lineWidth
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isSpinning = false

    private var shouldSpin: Bool {
        !reduceMotion && scenePhase == .active
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(lineWidth: lineWidth)
                .opacity(0.24)
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(reduceMotion ? -45 : (isSpinning ? 360 : 0)))
                .animation(
                    isSpinning
                        ? .linear(duration: 1.1).repeatForever(autoreverses: false)
                        : .default,
                    value: isSpinning)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear {
            if shouldSpin, !isSpinning {
                isSpinning = true
            }
        }
        .onDisappear {
            if isSpinning {
                isSpinning = false
            }
        }
        .onChange(of: shouldSpin) { _, active in
            if isSpinning != active {
                isSpinning = active
            }
        }
    }
}

/// A piece of work's state as one glyph, in `AgentStatusPalette`: an arc
/// that turns while it runs, then a tick, a cross, a stop, or a clock for
/// work no read vouches for.
struct ChatBackgroundWorkGlyph: View {
    enum Size {
        /// A Workflow's agent.
        case small
        /// A strip row.
        case regular
        /// A sheet row.
        case large

        var font: Font {
            switch self {
            case .small: .caption
            case .regular: .subheadline
            case .large: .callout
            }
        }

        var arc: CGFloat {
            switch self {
            case .small: 13
            case .regular: 15
            case .large: 17
            }
        }
    }

    let status: ChatBackgroundWorkPresentation.Status
    var size: Size = .small

    var body: some View {
        Group {
            switch status {
            case .running:
                ChatBackgroundWorkSpinningArc(size: size.arc, lineWidth: 2)
                    .equatable()
                    // Sits on the line as a symbol does, not on its foot.
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - size.arc * 0.16 }
            case .unconfirmed, .quiet:
                Image(systemName: "clock")
            case .completed:
                Image(systemName: "checkmark")
                    .fontWeight(.bold)
            case .failed:
                Image(systemName: "xmark")
                    .fontWeight(.bold)
            case .stopped:
                Image(systemName: "stop.circle")
            }
        }
        .font(size.font)
        .foregroundStyle(ChatBackgroundWorkPalette.statusInk(status))
        .accessibilityHidden(true)
    }
}
