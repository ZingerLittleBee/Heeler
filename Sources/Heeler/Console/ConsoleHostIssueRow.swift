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
