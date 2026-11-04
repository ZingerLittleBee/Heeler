import SwiftUI

/// Shared Agent Status + Tide git item + Checkout totals + Host telemetry
/// caption used by Composer and Direct Input. One presentation keeps
/// accessibility and visual treatment aligned.
struct AgentDetailStatusChrome: View {
    let status: AgentStatus
    let hostTelemetry: HostTelemetryPresentation?
    /// The Agent's Checkout, as a Tide git item and the totals its Agents
    /// list row shows.
    var changes: AgentDetailChanges? = nil
    let chromeColorScheme: ColorScheme

    var body: some View {
        let store = changes?.store
        // A divider only between two groups that both show, so a Checkout
        // not read yet, or a clean one, leaves no stray rule behind.
        let showsGit = store.map {
            TideGitItem(phase: $0.phase, timedOutKeepingContent: $0.timedOutKeepingContent) != nil
        } ?? false
        let showsTotals = store.map {
            ChangesBadge(phase: $0.phase, timedOutKeepingContent: $0.timedOutKeepingContent) != nil
        } ?? false
        // Only a line that shows the Checkout opens it.
        let open = showsGit || showsTotals ? changes?.open : nil
        // No spacing of its own, so a divider sits closer to its neighbours
        // than the line's spacing would put it: the rule already separates
        // them, and the branch needs the width.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let title = status.displayTitle {
                statusLabel(title)
                    .fixedSize()
                if showsGit { StatusLineDivider() }
            } else {
                // No status to show, but the line keeps its height, so the
                // controls below do not move when one arrives.
                Text(verbatim: "\u{200B}")
                    .font(.caption2.weight(.medium))
                    .accessibilityHidden(true)
            }
            // The Checkout's stretch, from the git item to the totals and
            // the gap between them, is what opens Changes; the status and
            // the latency are not.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if let store {
                    // Gives way first: only its branch shortens.
                    TideGitPrompt(store: store)
                        .modifier(OpensChanges(open: open))
                        .layoutPriority(-1)
                }
                Spacer(minLength: 24)
                if let store {
                    // Regular weight, as the latency beside it: the inks
                    // already make the totals stand out, and a heavier
                    // weight read larger.
                    ChangesRowTotals(
                        store: store, font: .caption2,
                        identifier: "agent-status-changes")
                    .modifier(OpensChanges(open: open))
                }
            }
            .modifier(OpensChangesOnTap(open: open))
            if let hostTelemetry {
                if showsTotals { StatusLineDivider() }
                hostTelemetryLabel(hostTelemetry)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .environment(\.colorScheme, chromeColorScheme)
        .modifier(AgentDetailChangesVisibility(changes: changes))
    }

    private func statusLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            if status == .working {
                SolvingOrbView(size: 10)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(Color(status.inkUIColor))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            Text(title)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(Color(status.inkUIColor))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent status")
        .accessibilityValue(title)
    }

    /// Deliberately quieter than Agent Status: it never changes color with the
    /// value and never animates, so a number that moves on its own cadence
    /// cannot pull attention away from the Agent the user came here for.
    private func hostTelemetryLabel(
        _ telemetry: HostTelemetryPresentation
    ) -> some View {
        Text(telemetry.title)
            .font(.caption2)
            .monospacedDigit()
            // One step brighter on dark themes: tertiary gray recedes into a
            // near-black surface faster than it does into a light one.
            .foregroundStyle(
                chromeColorScheme == .dark
                    ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(telemetry.accessibilityLabel)
            .accessibilityValue(telemetry.accessibilityValue)
    }
}

/// A hairline between two of the status line's groups, about as tall as
/// its capitals and centered on them, so adjacent groups read apart
/// without spending the width a separator glyph would.
private struct StatusLineDivider: View {
    @ScaledMetric(relativeTo: .caption2) private var height: CGFloat = 10

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(width: 1, height: height)
            .padding(.horizontal, 5)
            // Its bottom would sit on the baseline; lower it to the text's middle.
            .alignmentGuide(.firstTextBaseline) { $0.height * 0.85 }
            .accessibilityHidden(true)
    }
}

/// The Checkout's stretch of the line is one touch target, a few points
/// taller than its text without taking more room: the Tide git item and
/// the totals alone are too small to hit. Unconditional, so the line keeps
/// its identity when a read lands and the line starts opening Changes.
private struct OpensChangesOnTap: ViewModifier {
    let open: (() -> Void)?
    private static let slop: CGFloat = 6

    func body(content: Content) -> some View {
        content
            .padding(.vertical, Self.slop)
            .contentShape(.rect)
            .onTapGesture { open?() }
            .allowsHitTesting(open != nil)
            .padding(.vertical, -Self.slop)
    }
}

/// VoiceOver reaches Changes from the git item and the totals, each its
/// own element, rather than from one button that would swallow them.
private struct OpensChanges: ViewModifier {
    let open: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .accessibilityAddTraits(open == nil ? [] : .isButton)
            .accessibilityHint(open == nil ? "" : "Opens Changes")
            .accessibilityAction { open?() }
    }
}

/// The status line counts as a row showing its Agent while it is on screen,
/// so an exit from Working rereads the totals it shows even with the Agents
/// list off screen, as on iPhone.
private struct AgentDetailChangesVisibility: ViewModifier {
    let changes: AgentDetailChanges?
    @State private var shown: AgentDetailChanges?

    func body(content: Content) -> some View {
        content
            .onAppear { show(changes) }
            .onDisappear { show(nil) }
            .onChange(of: changes?.agent.id) { _, _ in show(changes) }
            .onChange(of: changes?.agent.directory == nil) { _, lacksDirectory in
                if !lacksDirectory, let changes {
                    changes.rows.agentReportedDirectory(changes.agent)
                }
            }
    }

    private func show(_ next: AgentDetailChanges?) {
        if let shown { shown.rows.rowDisappeared(shown.agent.id) }
        if let next { next.rows.rowAppeared(next.agent) }
        shown = next
    }
}
