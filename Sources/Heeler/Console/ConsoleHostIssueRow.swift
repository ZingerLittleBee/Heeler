import SwiftUI

/// One Host condition as a row in its Host's section, shared by the Agents
/// and Terminals lists so a Host reads the same in both. The header above
/// names the Host, so the row does not repeat it; VoiceOver still hears the
/// whole sentence. A row that navigates opens the Host in the Hosts tab.
struct ConsoleHostIssueRow: View {
    let issue: ConsoleHostStatusPresentation
    let onOpenHost: (Host.ID) -> Void

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
            Text(issue.sectionMessage)
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
            .navigationTitle(ConsoleHostIssueSummary(issues: issues)?.title ?? "Hosts")
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
