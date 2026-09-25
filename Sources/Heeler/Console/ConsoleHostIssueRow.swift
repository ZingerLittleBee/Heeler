import SwiftUI

/// One Host condition as a list row, shared by the Agents and Terminals
/// lists so a Host reads the same in both. A row that navigates opens the
/// Host in the Hosts tab.
struct ConsoleHostIssueRow: View {
    let issue: ConsoleHostStatusPresentation
    let onOpenHost: (Host.ID) -> Void

    var body: some View {
        if issue.navigates {
            Button { onOpenHost(issue.hostID) } label: { label }
                .buttonStyle(.plain)
                .accessibilityHint("Opens this Host's settings.")
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: issue.systemImage)
                .foregroundStyle(tint)
            Text(issue.message)
                .font(.footnote)
                .foregroundStyle(issue.isCritical ? Color.red : Color.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            if issue.navigates {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
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

    var body: some View {
        if let summary = ConsoleHostIssueSummary(issues: issues) {
            summaryRow(summary)
        } else if let issue = issues.first {
            ConsoleHostIssueCompactRow(issue: issue, onOpenHost: onOpenHost)
        }
    }

    private func summaryRow(_ summary: ConsoleHostIssueSummary) -> some View {
        Button(action: onShowAll) {
            HStack(spacing: Self.iconGap) {
                // A tile as on terminal rows, centered on the text beside it;
                // its color is the worst state's, so no badge is needed.
                TerminalTile(systemImage: "server.rack", tint: summary.tone.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                    // Chips wrap whole, never splitting "1 connecting".
                    ChipWrap(spacing: 12, lineSpacing: 2) {
                        ForEach(summary.counts, id: \.text) { count in
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(count.tone.tint)
                                    .frame(width: 6, height: 6)
                                Text(count.text)
                            }
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 12)
            }
            .padding(.vertical, 12)
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

/// The Hosts behind the flat lists' summary, in a bottom sheet. A Host that
/// cannot connect pushes the connection detail its own row would open; any
/// other navigable condition opens the Host in the Hosts tab.
struct ConsoleHostIssuesSheet<Detail: View>: View {
    let issues: [ConsoleHostStatusPresentation]
    /// Hosts the connection detail explains, which push it.
    let explained: Set<Host.ID>
    let onOpenHost: (Host.ID) -> Void
    @ViewBuilder let detail: (Host.ID) -> Detail

    @State private var path: [Host.ID] = []

    var body: some View {
        NavigationStack(path: $path) {
            List(issues) { issue in
                if explained.contains(issue.hostID) {
                    NavigationLink(value: issue.hostID) { row(issue) }
                } else if issue.navigates {
                    Button { onOpenHost(issue.hostID) } label: {
                        HStack {
                            row(issue)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens this Host in the Hosts tab.")
                } else {
                    row(issue)
                }
            }
            // Rows start under the title, not a section header's gap below.
            .contentMargins(.top, 4, for: .scrollContent)
            .navigationTitle(ConsoleHostIssueSummary(issues: issues)?.title ?? "Hosts")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Host.ID.self) { detail($0) }
        }
        .presentationDetents([.fraction(0.6), .large])
        .presentationDragIndicator(.visible)
        // A Host that connects again has nothing left to explain.
        .onChange(of: explained) { _, explained in
            path.removeAll { !explained.contains($0) }
        }
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
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 12)
                .opacity(issue.navigates ? 1 : 0)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(issue.message)
    }
}
