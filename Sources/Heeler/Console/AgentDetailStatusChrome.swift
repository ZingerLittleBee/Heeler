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
    /// The conversation's model and permission mode, from Chat's transcript.
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
        let showsSession = (session?.showsAnything ?? false) || (session != nil && sessionControls != nil)
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
                AgentSessionSettingsLabel(settings: session, controls: sessionControls)
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

    var showsAnything: Bool { (model?.isEmpty == false) || notablePermissionMode != nil }

    /// `claude-opus-5-5[1m]` → `Opus 5.5`, the way Claude Code's footer names it;
    /// a model outside that pattern keeps its id.
    static func modelTitle(_ id: String) -> String {
        let bare = { (id: String) in id.lowercased().split(separator: "[").first.map(String.init) ?? id }
        if let choice = modelChoices.first(where: { bare($0.id) == bare(id) }) { return choice.title }
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
    var setPermissionMode: @MainActor (String) -> Void
    var setModel: @MainActor (String) -> Void
    var setEffort: @MainActor (String) -> Void
}

extension AgentSessionSettings {
    /// The modes Shift+Tab cycles through, in Claude Code's order.
    static let permissionChoices = ["default", "acceptEdits", "plan", "bypassPermissions"]

    /// Claude Code's model aliases, which each Host resolves to its own
    /// configured model. Custom `modelPicker` entries are not read from the Host.
    static let modelChoices: [(id: String, title: String)] = [
        ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku"), ("fable", "Fable"),
    ]

    /// The levels `/effort` takes (2.1.319); a model without one refuses it on screen.
    static let effortChoices = ["low", "medium", "high", "xhigh", "max"]

    /// Whether the recorded model is the one `choice` switches to.
    static func model(_ model: String?, is choice: String) -> Bool {
        guard let model, !model.isEmpty else { return false }
        let bare = { (id: String) in String(id.lowercased().split(separator: "[").first ?? "") }
        if bare(model) == bare(choice) { return true }
        return bare(modelTitle(model)).hasPrefix(choice + " ") || bare(modelTitle(model)) == choice
    }
}

/// Permission mode first (it is the one that can hurt), then the model.
/// With controls, each opens a menu that switches it.
struct AgentSessionSettingsLabel: View {
    let settings: AgentSessionSettings
    var controls: AgentSessionControls? = nil
    @State private var confirmsBypass = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let mode = settings.notablePermissionMode ?? (controls == nil ? nil : "default") {
                permission(mode)
            }
            if let model = settings.model, !model.isEmpty {
                modelLabel(model)
            }
        }
        .help([settings.notablePermissionMode, settings.modelLine].compactMap { $0 }.joined(separator: " · "))
        .confirmationDialog("Skip every permission prompt?", isPresented: $confirmsBypass, titleVisibility: .visible) {
            Button("Bypass Permissions", role: .destructive) { controls?.setPermissionMode("bypassPermissions") }
        } message: {
            Text("The Agent runs every tool without asking until you switch back.")
        }
    }

    @ViewBuilder
    private func permission(_ mode: String) -> some View {
        let text = Text(verbatim: (mode == "plan" ? "⏸ " : "⏵⏵ ") + AgentSessionSettings.permissionTitle(mode))
            .font(.caption2.weight(.medium))
            .foregroundStyle(permissionInk(mode))
            .fixedSize()
        if let controls {
            Menu {
                ForEach(AgentSessionSettings.permissionChoices, id: \.self) { @Sendable choice in
                    MainActorContent {
                        Button {
                            if choice == "bypassPermissions" { confirmsBypass = true } else { controls.setPermissionMode(choice) }
                        } label: {
                            if choice == mode {
                                Label(AgentSessionSettings.permissionTitle(choice), systemImage: "checkmark")
                            } else {
                                Text(AgentSessionSettings.permissionTitle(choice))
                            }
                        }
                    }
                }
            } label: {
                text.frame(minHeight: 28).contentShape(Rectangle())
            }
            .disabled(!controls.isEnabled)
            .accessibilityLabel("Permission mode")
            .accessibilityValue(AgentSessionSettings.permissionTitle(mode))
            .accessibilityIdentifier("agent-status-permission")
        } else {
            text
                .accessibilityLabel("Permission mode")
                .accessibilityValue(AgentSessionSettings.permissionTitle(mode))
                .accessibilityIdentifier("agent-status-permission")
        }
    }

    @ViewBuilder
    private func modelLabel(_ model: String) -> some View {
        let text = Text(verbatim: settings.modelLine ?? AgentSessionSettings.modelTitle(model))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize()
        if let controls {
            Menu {
                Section("Model") {
                    ForEach(AgentSessionSettings.modelChoices, id: \.id) { @Sendable choice in
                        MainActorContent {
                            Button {
                                controls.setModel(choice.id)
                            } label: {
                                if AgentSessionSettings.model(model, is: choice.id) {
                                    Label(choice.title, systemImage: "checkmark")
                                } else {
                                    Text(choice.title)
                                }
                            }
                        }
                    }
                }
                Section("Effort") {
                    ForEach(AgentSessionSettings.effortChoices, id: \.self) { @Sendable level in
                        MainActorContent {
                            Button {
                                controls.setEffort(level)
                            } label: {
                                if settings.effort == level {
                                    Label(level, systemImage: "checkmark")
                                } else {
                                    Text(level)
                                }
                            }
                        }
                    }
                }
            } label: {
                text.frame(minHeight: 28).contentShape(Rectangle())
            }
            // A menu opening upward from the status line reverses its items;
            // fixed keeps Model above Effort, the order they are chosen in.
            .menuOrder(.fixed)
            .disabled(!controls.isEnabled)
            .accessibilityLabel("Model")
            .accessibilityValue(settings.modelLine ?? model)
            .accessibilityIdentifier("agent-status-model")
        } else {
            text
                .accessibilityLabel("Model")
                .accessibilityValue(settings.modelLine ?? model)
                .accessibilityIdentifier("agent-status-model")
        }
    }

    /// Red only for the mode that skips every prompt; red means risk here.
    private func permissionInk(_ mode: String) -> Color {
        switch mode {
        case "bypassPermissions", "dontAsk": Color(AgentStatusPalette.redInk)
        case "acceptEdits": Color(AgentStatusPalette.yellowInk)
        default: Color.secondary
        }
    }
}

extension AgentSessionSettings {
    /// The mode Claude Code's footer shows (`⏵⏵ bypass permissions on`,
    /// `⏸ plan mode on`, …; 2.1.319); none shown is `default`. Only the
    /// bottom rows are read, so a transcript quoting the words does not count.
    static func permissionMode(onScreen screen: ANSIScreen) -> String {
        let footer = screen.rows.suffix(6).map(\.text).joined(separator: "\n").lowercased()
        if footer.contains("bypass permissions on") { return "bypassPermissions" }
        if footer.contains("accept edits on") { return "acceptEdits" }
        if footer.contains("plan mode on") { return "plan" }
        if footer.contains("auto mode on") { return "auto" }
        return "default"
    }
}
