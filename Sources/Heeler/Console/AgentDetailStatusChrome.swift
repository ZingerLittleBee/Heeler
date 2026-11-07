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
    /// The conversation's permission mode, from Chat's transcript.
    var session: AgentSessionSettings? = nil
    var sessionControls: AgentSessionControls? = nil
    let chromeColorScheme: ColorScheme
    /// Set where an Unknown Agent has something to explain, on a core Host.
    @Environment(\.showAgentStatusExplanation) private var showStatusExplanation

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
        let showsSession = session?.notablePermissionMode != nil || (session != nil && sessionControls != nil)
        // No spacing of its own, so a divider sits closer to its neighbours
        // than the line's spacing would put it: the rule already separates
        // them, and the branch needs the width.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let title = status.displayTitle {
                statusLabel(title)
                    .fixedSize()
                if showsGit || showsSession { StatusLineDivider() }
            } else if let showStatusExplanation {
                unknownStatusButton(showStatusExplanation)
                    .fixedSize()
                if showsGit || showsSession { StatusLineDivider() }
            } else {
                // No status to show, but the line keeps its height, so the
                // controls below do not move when one arrives.
                Text(verbatim: "\u{200B}")
                    .font(.caption2.weight(.medium))
                    .accessibilityHidden(true)
            }
            if let session, showsSession {
                // Short and fixed: the branch (priority -1) truncates instead.
                AgentPermissionModeLabel(settings: session, controls: sessionControls)
                if showsGit { StatusLineDivider() }
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

    /// Reads as the status line's status, with room around it for a finger.
    private func unknownStatusButton(_ show: @escaping @MainActor @Sendable () -> Void) -> some View {
        Button(action: show) {
            HStack(spacing: 4) {
                Text("Unknown")
                Image(systemName: "info.circle")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .padding(.vertical, -10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Agent status")
        .accessibilityValue("Unknown")
        .accessibilityHint("Explains why")
        .accessibilityIdentifier("agent-status-explanation")
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

/// The model and permission mode a Claude conversation last recorded.
struct AgentSessionSettings: Equatable, Sendable {
    var model: String?
    var permissionMode: String?
    var effort: String? = nil

    /// `Fable 5.1 · high`: the model and the effort it last replied at.
    var modelLine: String? {
        guard let model, !model.isEmpty else { return nil }
        let title = Self.modelTitle(model)
        guard let effort, !effort.isEmpty else { return title }
        return "\(title) · \(effort)"
    }

    /// `default` is Claude Code's normal mode and says nothing worth the width.
    var notablePermissionMode: String? {
        guard let permissionMode, !permissionMode.isEmpty, permissionMode != "default" else { return nil }
        return permissionMode
    }

    /// `claude-opus-5-5[1m]` → `Opus 5.5`, the way Claude Code's footer names it;
    /// a model outside that pattern keeps its id.
    static func modelTitle(_ id: String) -> String {
        if let choice = modelChoices.first(where: { $0.id == id.lowercased() }) { return choice.title }
        let base = String(id.split(separator: "[").first ?? Substring(id))
        guard base.hasPrefix("claude-") else { return id }
        let words: [String] = base.dropFirst("claude-".count).split(separator: "-").map(String.init)
            .filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
        guard let family = words.first, family.allSatisfy(\.isLetter) else { return id }
        let version: String = words.dropFirst().joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }

    /// Short words the way Claude Code's own footer says them.
    static func permissionTitle(_ mode: String) -> String {
        switch mode {
        case "": "Permission"
        case "default": "manual"
        case "bypassPermissions": "bypass"
        case "acceptEdits": "accept edits"
        case "plan": "plan"
        case "dontAsk": "don't ask"
        case "auto": "auto"
        default: mode
        }
    }
}

/// What tapping the permission mode or the model does in Chat. Nil where
/// nothing can switch them (the terminal's status line, another program).
struct AgentSessionControls {
    /// Off while the Agent works: keys and `/model` would land in its turn.
    var isEnabled: Bool
    /// Includes the preflight reads and waiting for terminal confirmation.
    var isSwitchingPermissionMode = false
    /// A launch opt-in or current live bypass, not a recorded transcript mode.
    var allowsBypassPermissions = false
    var setPermissionMode: @MainActor (String) -> Void
    var setModel: @MainActor (String) -> Void
    var setEffort: @MainActor (String) -> Void
}

extension AgentSessionSettings {
    /// The modes Shift+Tab cycles through, in Claude Code's order.
    static let permissionChoices = ["default", "acceptEdits", "plan", "bypassPermissions", "auto"]

    /// Shortcuts, not a discovered catalog. Claude resolves these aliases using
    /// its own configuration; third-party mappings are configured outside Heeler.
    static let modelChoices: [(id: String, title: String)] = [
        ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku"), ("fable", "Fable"),
    ]

    /// A custom model ID does not prove which alias it maps to.
    static func model(_ model: String?, is choice: String) -> Bool {
        guard let model else { return false }
        let title = modelTitle(model).lowercased()
        return title == choice || title.hasPrefix(choice + " ")
    }

    /// What the screen says to a typed `/model` or `/effort`: the first
    /// `done` or `kept` line below the newest echo of the command. Read
    /// against the echo rather than by counting confirmations, which a full
    /// screen scrolls away as new ones arrive.
    struct Outcome: Equatable {
        var echoes = 0
        var result: Bool?
        var value: String?

        init(of command: String, done: String, kept: String, on screen: ANSIScreen) {
            let rows = screen.rows.map(\.text)
            let echoRows = rows.indices.filter { rows[$0].contains(command) }
            echoes = echoRows.count
            guard let last = echoRows.last else { return }
            for row in rows[(last + 1)...] {
                if let range = row.range(of: done) {
                    result = true
                    // Claude 2.1.318 appends a persistence notice to the name.
                    let confirmed = row[range.upperBound...].trimmingCharacters(in: .whitespaces)
                        .replacing(/\ and saved as your default for new sessions$/, with: "")
                    value = confirmed.isEmpty ? nil : confirmed
                    return
                }
                if row.contains(kept) { result = false; return }
            }
        }

        /// The answer to a command typed since `before`, once there is one.
        func answered(since before: Outcome) -> Bool? {
            echoes > before.echoes ? result : nil
        }
    }

    /// The levels `/effort` takes (2.1.319); a model without one refuses it on screen.
    static let effortChoices = ["low", "medium", "high", "xhigh", "max"]
}

/// Permission mode stays beside the Composer; model and effort live in the title.
struct AgentPermissionModeLabel: View {
    let settings: AgentSessionSettings
    var controls: AgentSessionControls? = nil
    @State private var confirmsBypass = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let mode = settings.notablePermissionMode ?? (controls == nil ? nil : settings.permissionMode ?? "") {
                permission(mode)
            }
        }
        .confirmationDialog("Skip every permission prompt?", isPresented: $confirmsBypass, titleVisibility: .visible) {
            Button("Bypass Permissions", role: .destructive) { controls?.setPermissionMode("bypassPermissions") }
        } message: {
            Text("The Agent runs every tool without asking until you switch back.")
        }
    }

    @ViewBuilder
    private func permission(_ mode: String) -> some View {
        let isSwitching = controls?.isSwitchingPermissionMode == true
        let prefix = mode.isEmpty && !isSwitching ? "" : (mode == "plan" ? "⏸\u{FE0E} " : "⏵⏵ ")
        let text = HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: prefix)
                .opacity(isSwitching ? 0 : 1)
                .overlay {
                    if isSwitching {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(permissionInk(mode))
                            .scaleEffect(0.65)
                            .accessibilityHidden(true)
                    }
                }
            Text(verbatim: AgentSessionSettings.permissionTitle(mode))
        }
            .font(.caption2.weight(.medium))
            .foregroundStyle(permissionInk(mode))
            .fixedSize()
        if let controls {
            Menu {
                Picker("Permission mode", selection: Binding(
                    get: { mode },
                    set: { choice in
                        if choice == "bypassPermissions" { confirmsBypass = true } else { controls.setPermissionMode(choice) }
                    })
                ) {
                    ForEach(AgentSessionSettings.permissionChoices.filter {
                        $0 != "bypassPermissions" || controls.allowsBypassPermissions
                    }, id: \.self) { choice in
                        Text(AgentSessionSettings.permissionTitle(choice)).tag(choice)
                    }
                }
                .labelsHidden()
            } label: {
                text.frame(minHeight: 28).contentShape(Rectangle())
            }
            .disabled(!controls.isEnabled)
            .accessibilityLabel("Permission mode")
            .accessibilityValue(isSwitching
                ? "Switching from \(AgentSessionSettings.permissionTitle(mode))"
                : AgentSessionSettings.permissionTitle(mode))
            .accessibilityIdentifier("agent-status-permission")
        } else {
            text
                .accessibilityLabel("Permission mode")
                .accessibilityValue(AgentSessionSettings.permissionTitle(mode))
                .accessibilityIdentifier("agent-status-permission")
        }
    }

    /// Claude Code 2.1.319's standard dark/light permission colors, separate
    /// from herdr's Agent lifecycle palette.
    private func permissionInk(_ mode: String) -> Color {
        let dark = colorScheme == .dark
        let rgb: UInt32
        switch mode {
        case "default": rgb = dark ? 0x999999 : 0x666666
        case "acceptEdits": rgb = dark ? 0xAF87FF : 0x8700FF
        case "plan": rgb = dark ? 0x48968C : 0x006666
        case "auto": rgb = dark ? 0xFFC107 : 0x966C1E
        case "bypassPermissions", "dontAsk": rgb = dark ? 0xFF6B80 : 0xAB2B3F
        default: return .secondary
        }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255)
    }
}

extension AgentSessionSettings {
    /// Claude's compact welcome banner before its first message (2.1.291–319).
    /// Never infer a model from user-defined status lines or conversation text.
    static func welcomeModel(onScreen screen: ANSIScreen) -> String? {
        let rows = screen.rows.map(\.text)
        guard let header = rows.prefix(4).firstIndex(where: { $0.wholeMatch(of: /^\s*[▐▛█▌]+\s+Claude Code v[0-9.]+\s*$/) != nil }),
            rows.indices.contains(header + 1),
            let model = rows[header + 1].wholeMatch(of: /^\s*[▝▜█▀]+\s+(.+?)\s+·\s+.+$/)
        else { return nil }
        // An old banner above replies or slash commands is not current settings.
        let rest = rows.dropFirst(header + 3).prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("─") }
        guard rest.allSatisfy({
            $0.trimmingCharacters(in: .whitespaces).isEmpty
                || $0.wholeMatch(of: /^\s*◐ (low|medium|high|xhigh|max) · \/effort\s*$/) != nil
        }) else { return nil }
        return String(model.1)
    }

    /// The mode Claude Code's footer shows (`⏵⏵ bypass permissions on`,
    /// `⏸ plan mode on`, …; 2.1.319). A missing footer is unknown, not Manual.
    /// The footer lies below the input box's last rule, or without one the last
    /// line, so a reply quoting the words does not count.
    static func permissionMode(onScreen screen: ANSIScreen) -> String? {
        let rows = screen.rows.map(\.text)
        let isRule = { (row: String) in
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            return trimmed.count >= 10 && trimmed.allSatisfy { $0 == "─" || $0 == "━" }
        }
        let below = rows.lastIndex(where: isRule).map { Array(rows[($0 + 1)...]) }
            ?? rows.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map { [$0] } ?? []
        let footer = below.joined(separator: "\n").lowercased()
        if footer.contains("bypass permissions on") { return "bypassPermissions" }
        if footer.contains("accept edits on") { return "acceptEdits" }
        if footer.contains("plan mode on") { return "plan" }
        if footer.contains("auto mode on") { return "auto" }
        if footer.contains("manual mode on") || footer.contains("? for shortcuts") { return "default" }
        return nil
    }
}
