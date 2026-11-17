import SwiftUI

/// One Host condition as a row in its Host's section, shared by the Agents
/// and Terminals lists so a Host reads the same in both. The header above
/// names the Host, so the row does not repeat it; VoiceOver still hears the
/// whole sentence. A row that navigates opens the Host in the Hosts tab.
struct ConsoleHostIssueRow: View {
    let issue: ConsoleHostStatusPresentation
    /// The section lists several Servers of its Host and names only the Host,
    /// so the row says the whole sentence, which names the Server too.
    let namesServer: Bool
    let onOpenHost: (Host.ID) -> Void

    init(
        issue: ConsoleHostStatusPresentation, namesServer: Bool = false,
        onOpenHost: @escaping (Host.ID) -> Void
    ) {
        self.issue = issue
        self.namesServer = namesServer
        self.onOpenHost = onOpenHost
    }

    var body: some View {
        if issue.navigates {
            Button { onOpenHost(issue.hostID) } label: { label }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityHint("Opens this Host's settings.")
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: issue.systemImage)
                .foregroundStyle(tint)
            Text(namesServer ? issue.message : issue.sectionMessage)
                .font(.footnote)
                .foregroundStyle(issue.isCritical ? Color.red : Color.secondary)
                .lineLimit(2)
                .accessibilityLabel(issue.message)
            Spacer(minLength: 0)
            if issue.navigates {
                ConsoleListRowChevron()
            }
        }
        .contentShape(Rectangle())
    }

    private var tint: Color {
        switch issue.severity {
        case .critical: .red
        case .warning: .orange
        case .informational: .secondary
        }
    }
}

/// The flat lists' Host conditions (#316), atop the list in both tabs:
/// one compact row for a single Host, and a summary once there are several,
/// so unreachable Hosts cannot push the inventory off screen. The summary
/// opens the Hosts in a bottom sheet rather than expanding in the list. It
/// sits on the page itself, not on a card, so it never reads as one of the
/// Terminals tab's Workspace cards; callers clear the row's background and
/// inset it to their content. The full sentence is what VoiceOver reads;
/// the connection sheet shows it too.
struct ConsoleHostIssueList: View {
    let issues: [ConsoleHostStatusPresentation]
    let onOpenHost: (Host.ID) -> Void
    /// Presents `ConsoleHostIssuesSheet` for the summary.
    let onShowAll: () -> Void
    /// The leading column every row shares, as wide as a terminal row's
    /// tile, and the gap after it: all text starts on one edge.
    static let iconColumn: CGFloat = 30
    static let iconGap: CGFloat = 12
    private static let summaryTitleFont = Font.subheadline.weight(.semibold)
    private static let summaryCountFont = Font.footnote
    private static let summaryLineSpacing: CGFloat = 4

    var body: some View {
        if let summary = ConsoleHostIssueSummary(issues: issues) {
            fixedHeight { summaryRow(summary) }
        } else if let issue = issues.first {
            fixedHeight { ConsoleHostIssueCompactRow(issue: issue, onOpenHost: onOpenHost) }
        }
    }

    /// The list below stays put while Hosts connect: the height comes from
    /// two hidden lines in the summary's fonts, and the row only overlays
    /// them, so no condition can make it taller. It still follows the text
    /// size.
    private func fixedHeight(@ViewBuilder row: () -> some View) -> some View {
        VStack(spacing: Self.summaryLineSpacing) {
            Text(verbatim: " ").font(Self.summaryTitleFont)
            Text(verbatim: " ").font(Self.summaryCountFont)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .hidden()
        .overlay { row() }
    }

    private func summaryRow(_ summary: ConsoleHostIssueSummary) -> some View {
        Button(action: onShowAll) {
            HStack(spacing: Self.iconGap) {
                // A tile as on terminal rows, centered on the text beside it;
                // its color is the worst state's, so no badge is needed.
                TerminalTile(systemImage: "server.rack", tint: summary.tone.tint)
                VStack(alignment: .leading, spacing: Self.summaryLineSpacing) {
                    Text(summary.title)
                        .font(Self.summaryTitleFont)
                        .foregroundStyle(Color.primary)
                    ConsoleHostIssueCountLine(counts: summary.counts)
                        .font(Self.summaryCountFont)
                        .foregroundStyle(Color.secondary)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                ConsoleListRowChevron()
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary.title), \(summary.detail)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Lists these Hosts.")
    }
}

/// The summary's counts on one line, the most serious first. Those that do
/// not fit fold into "+2", never splitting "1 connecting" or wrapping onto a
/// line the row has no room for; the sheet and VoiceOver have them all.
private struct ConsoleHostIssueCountLine: View {
    let counts: [ConsoleHostIssueSummary.Count]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: counts.count, to: 0, by: -1)), id: \.self) { @Sendable shown in
                MainActorContent { line(showing: shown) }
            }
        }
    }

    private func line(showing shown: Int) -> some View {
        HStack(spacing: 12) {
            ForEach(counts.prefix(shown), id: \.text) { @Sendable count in
                HStack(spacing: 5) {
                    Circle()
                        .fill(count.tone.tint)
                        .frame(width: 6, height: 6)
                    Text(count.text)
                }
            }
            if shown < counts.count {
                Text(verbatim: "+\(counts.count - shown)")
            }
        }
    }
}

/// The Hosts behind the flat lists' summary, in a sheet. A Host that cannot
/// connect pushes the connection detail its own row would open; any other
/// navigable condition opens the Host in the Hosts tab.
struct ConsoleHostIssuesSheet<Detail: View & SendableMetatype>: View {
    let issues: [ConsoleHostStatusPresentation]
    /// Hosts the connection detail explains, which push it.
    let explained: Set<Host.ID>
    /// The presenting Console's: inside the sheet, the size class describes
    /// the sheet, not the screen.
    let sheetPresentation: ConsoleSheetPresentation
    let onOpenHost: (Host.ID) -> Void
    @ViewBuilder let detail: (Host.ID) -> Detail

    @State private var path: [Host.ID] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack(path: $path) {
            List(issues) { @Sendable issue in
                MainActorContent {
                    if explained.contains(issue.hostID) {
                        NavigationLink(value: issue.hostID) { row(issue) }
                    } else if issue.navigates {
                        Button { onOpenHost(issue.hostID) } label: {
                            HStack {
                                row(issue)
                                // Drawn as the list draws the pushing rows' own,
                                // so every row in the sheet discloses alike, and
                                // theirs sits this far in from the row's edge.
                                Image(systemName: "chevron.forward")
                                    .font(.body.weight(.semibold))
                                    .imageScale(.small)
                                    .foregroundStyle(disclosureInk)
                                    .padding(.trailing, 1.5)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .accessibilityHint("Opens this Host in the Hosts tab.")
                    } else {
                        row(issue)
                    }
                }
            }
            // Rows start under the title, not a section header's gap below.
            .contentMargins(.top, 4, for: .scrollContent)
            .consoleSheetPage()
            .navigationTitle(ConsoleHostIssueSummary(issues: issues)?.title ?? String(localized: "Hosts"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A form sheet has no grabber to pull down.
                if sheetPresentation == .form {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .navigationDestination(for: Host.ID.self) { detail($0) }
        }
        .modifier(ConsoleStatusSheetPresentationModifier(presentation: sheetPresentation))
        // A Host that connects again has nothing left to explain.
        .onChange(of: explained) { _, explained in
            path.removeAll { !explained.contains($0) }
        }
    }

    /// The ink of the list's own disclosure chevrons, measured against
    /// them. The list draws `tertiaryLabel`, which an opaque form sheet
    /// shows as is; a glass sheet renders it vibrant, darker in light mode
    /// than any plain label style, so there a translucent label matches.
    private var disclosureInk: Color {
        guard sheetPresentation != .form else { return Color(uiColor: .tertiaryLabel) }
        return Color(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(white: 1, alpha: 0.28) : UIColor(white: 0, alpha: 0.36)
            })
    }

    private func row(_ issue: ConsoleHostStatusPresentation) -> some View {
        HStack(spacing: ConsoleHostIssueList.iconGap) {
            HostStatusGlyph(tone: issue.tone)
            VStack(alignment: .leading, spacing: 2) {
                // Full strength: every Host here has a problem, so the
                // list's dimming of not-ready names would only gray them all.
                Text(issue.hostName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(issue.status)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(issue.message)
    }
}

/// One Host condition on a single line: the Host's glyph and name, as on
/// its section header, and a few words of status.
struct ConsoleHostIssueCompactRow: View {
    let issue: ConsoleHostStatusPresentation
    let onOpenHost: (Host.ID) -> Void

    var body: some View {
        if issue.navigates {
            Button { onOpenHost(issue.hostID) } label: { label }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityHint("Shows this Host's connection details.")
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: ConsoleHostIssueList.iconGap) {
            // In the summary tile's column, so names start where its title
            // does.
            HostStatusGlyph(tone: issue.tone)
                .frame(width: ConsoleHostIssueList.iconColumn)
            Text(issue.hostName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(HostReadiness(text: issue.status, tone: issue.tone).nameEmphasis.color)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(issue.status)
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
            // Every row keeps the chevron's width, so statuses line up.
            ConsoleListRowChevron()
                .opacity(issue.navigates ? 1 : 0)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(issue.message)
    }
}

/// The chevron a Console list row draws for itself when it opens a sheet or
/// another tab instead of pushing, in the list's own disclosure color. Only
/// where the list's NavigationLink rows show theirs; see
/// `consoleListShowsDisclosure`.
struct ConsoleListRowChevron: View {
    @Environment(\.consoleListShowsDisclosure) private var showsDisclosure

    var body: some View {
        if showsDisclosure {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
                .frame(width: 12)
                .accessibilityHidden(true)
        }
    }
}

extension EnvironmentValues {
    /// Whether a Console list's NavigationLink rows show disclosure
    /// chevrons, as a collapsed split view's pushing list does. An expanded
    /// split view's sidebar marks the selected row instead, so a drawn
    /// chevron there would be the list's only one. The sidebar's own size
    /// class is compact either way, so the split view's owner says which.
    @Entry var consoleListShowsDisclosure = true
}

/// Bottom-trailing floating Host status tile for the Agents list's `.flat` and
/// `.byWorkspace` presentations: expands briefly when a Host enters an issue
/// state (or escalates to a failure), then settles into a compact squircle
/// tile with a linear bottom status bar so it never collides with circular
/// Agent Status Rings or displaces list rows.
struct ConsoleHostIssueCornerBadge: View {
    let issues: [ConsoleHostStatusPresentation]
    let onOpenHost: (Host.ID) -> Void
    let onShowAll: () -> Void
    var autoCollapseDelay: Duration = .seconds(3)
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    @State private var isExpanded: Bool
    @State private var seenAttentionKeys: Set<ConsoleHostIssueCornerPresentation.AttentionKey> = []
    @State private var collapseGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cornerRadius: CGFloat = 12
    private static let tileSide: CGFloat = 38
    private static let hitTargetOutset: CGFloat = 3

    init(
        issues: [ConsoleHostStatusPresentation],
        onOpenHost: @escaping (Host.ID) -> Void,
        onShowAll: @escaping () -> Void,
        autoCollapseDelay: Duration = .seconds(3),
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.issues = issues
        self.onOpenHost = onOpenHost
        self.onShowAll = onShowAll
        self.autoCollapseDelay = autoCollapseDelay
        self.sleep = sleep
        _isExpanded = State(initialValue: !issues.isEmpty)
    }

    private var presentation: ConsoleHostIssueCornerPresentation? {
        ConsoleHostIssueCornerPresentation(issues: issues)
    }

    var body: some View {
        let current = presentation
        let attentionKeys = current?.attentionKeys ?? []
        Group {
            if let current {
                button(for: current)
                    .transition(
                        .scale(scale: 0.86, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .onChange(of: attentionKeys, initial: true) { _, next in
            guard !next.isEmpty else {
                seenAttentionKeys = []
                isExpanded = false
                collapseGeneration += 1
                return
            }
            let hasNewAttention = !next.subtracting(seenAttentionKeys).isEmpty
            seenAttentionKeys = next
            if hasNewAttention {
                expandTemporarily()
            }
        }
        .task(id: collapseGeneration) {
            guard isExpanded, collapseGeneration > 0 else { return }
            do {
                try await sleep(autoCollapseDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) {
                isExpanded = false
            }
        }
    }

    private func button(for current: ConsoleHostIssueCornerPresentation) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return Button {
            handleTap(current.action)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(iconColor(for: current.tone))
                    .frame(width: 18, height: 18)
                if isExpanded {
                    expandedLabel(for: current)
                        .transition(.opacity)
                }
            }
            .offset(y: -1)
            .padding(.leading, 10)
            .padding(.trailing, isExpanded ? 12 : 10)
            .padding(.vertical, isExpanded ? 8 : 0)
            .frame(minWidth: Self.tileSide, minHeight: Self.tileSide)
            .frame(maxWidth: isExpanded ? 260 : nil)
            .overlay(alignment: .bottom) {
                ConsoleHostIssueBottomBar(tone: current.tone, animates: current.animatesBar)
                    .padding(.horizontal, 5)
                    .padding(.bottom, 3)
            }
            .background(.regularMaterial, in: shape)
            .overlay {
                shape.strokeBorder(.primary.opacity(0.14), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 4)
            .overlay(alignment: .topTrailing) {
                if let badge = current.badgeText(isExpanded: isExpanded) {
                    Text(verbatim: badge)
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(badgeColor(for: current.tone), in: Capsule())
                        .offset(x: 5, y: -5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(Self.hitTargetOutset)
            .contentShape(Rectangle())
        }
        .buttonStyle(ConsoleHostIssueCornerButtonStyle())
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(current.accessibilityLabel)
        .accessibilityHint(current.accessibilityHint ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("agents.hostIssues.badge")
    }

    private func expandedLabel(for current: ConsoleHostIssueCornerPresentation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(verbatim: current.expandedTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let status = current.expandedStatus {
                Text(verbatim: "· \(status)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }

    private func handleTap(_ action: ConsoleHostIssueCornerPresentation.Action) {
        switch action {
        case .showAll:
            onShowAll()
        case .openHost(let hostID):
            onOpenHost(hostID)
        case .toggleExpanded:
            if isExpanded {
                collapseGeneration += 1
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
                    isExpanded = false
                }
            } else {
                expandTemporarily()
            }
        }
    }

    private func expandTemporarily() {
        collapseGeneration += 1
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) {
            isExpanded = true
        }
    }

    private func iconColor(for tone: HostConnectionTone) -> Color {
        switch tone {
        case .unavailable: .red
        case .paused: .secondary
        case .connected, .pending, .reconnecting, .warning: .primary
        }
    }

    private func badgeColor(for tone: HostConnectionTone) -> Color {
        switch tone {
        case .unavailable: .red
        case .paused: .secondary
        case .connected, .pending, .reconnecting, .warning: .orange
        }
    }
}

private struct ConsoleHostIssueCornerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

/// The linear bottom status strip on `ConsoleHostIssueCornerBadge`: slides
/// back and forth from the clock while a Host is actively connecting or
/// reconnecting (without leaking a repeating SwiftUI animation), and stays
/// solid on a stationary failure or pause.
private struct ConsoleHostIssueBottomBar: View {
    let tone: HostConnectionTone
    let animates: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let height: CGFloat = 2.5
    private static let cycleSeconds: Double = 1.6

    private var barColor: Color {
        switch tone {
        case .unavailable: .red.opacity(0.9)
        case .paused, .connected: .secondary.opacity(0.55)
        case .pending, .reconnecting, .warning: .orange.opacity(0.9)
        }
    }

    var body: some View {
        if animates && !reduceMotion {
            TimelineView(.animation) { context in
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let thumbWidth = max(width * 0.52, min(width, 10))
                    let travel = max(width - thumbWidth, 0)
                    let phase =
                        context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: Self.cycleSeconds) / Self.cycleSeconds
                    let progress = 0.5 * (1 - cos(2 * .pi * phase))
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(barColor.opacity(0.22))
                        Capsule()
                            .fill(barColor)
                            .frame(width: thumbWidth)
                            .offset(x: travel * progress)
                    }
                    .clipShape(Capsule())
                }
            }
            .frame(height: Self.height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            Capsule()
                .fill(barColor)
                .frame(height: Self.height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
