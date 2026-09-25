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

/// The flat lists' Host conditions (#316), as one card atop the list in
/// both tabs: one compact row per Host, and behind a single summary once
/// there are several, so unreachable Hosts cannot push the inventory off
/// screen. The card draws itself, so it reads the same in the Agents tab's
/// plain list and the Terminals tab's grouped one; callers clear the row's
/// background and inset it. The full sentence is what VoiceOver reads; the
/// connection sheet shows it too.
struct ConsoleHostIssueList: View {
    let issues: [ConsoleHostStatusPresentation]
    /// The page's own card color, so the card reads as one of its cards.
    let fill: Color
    let onOpenHost: (Host.ID) -> Void

    static let cornerRadius: CGFloat = 20
    /// Past the glyph and its gap, where a row's text starts.
    private static let textInset: CGFloat = 28

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let summary = ConsoleHostIssueSummary(issues: issues) {
                summaryRow(summary)
                if isExpanded {
                    ForEach(issues) { issue in
                        separator
                        ConsoleHostIssueCompactRow(issue: issue, onOpenHost: onOpenHost)
                    }
                }
            } else {
                ForEach(Array(issues.enumerated()), id: \.element.id) { index, issue in
                    if index > 0 { separator }
                    ConsoleHostIssueCompactRow(issue: issue, onOpenHost: onOpenHost)
                }
            }
        }
        .padding(.horizontal, 16)
        .background(fill, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
    }

    private func summaryRow(_ summary: ConsoleHostIssueSummary) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    HostStatusGlyph(tone: summary.tone)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(summary.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                        // Chips wrap whole, never splitting "1 connecting".
                        ChipWrap(spacing: 12, lineSpacing: 4) {
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
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary.title), \(summary.detail)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Hides these Hosts." : "Lists these Hosts.")
    }

    private var separator: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(height: 1 / displayScale)
            .padding(.leading, Self.textInset)
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
        HStack(spacing: 8) {
            HostStatusGlyph(tone: issue.tone)
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
