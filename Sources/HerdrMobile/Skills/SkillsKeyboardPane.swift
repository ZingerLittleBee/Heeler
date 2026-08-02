import SwiftUI

/// The Skills pane inside the Keys keyboard: the agent's slash-callable
/// skills as a scrolling two-line list — name on top, description below —
/// grouped Project first, Global second. Tapping one inserts `/name ` into
/// the terminal without sending it, the same contract as a Snippet.
///
/// No search field, for the same responder reason as the Snippets pane: a
/// text field inside a `UIInputView` would replace the keyboard it lives in.
struct SkillsKeyboardPane: View {
    let store: SkillsPaneStore
    let onInsert: (AgentSkill) -> Void

    var body: some View {
        // No `.task` here: the pager builds every pane the moment the
        // keyboard comes up, so appearance would probe eagerly. The keyboard
        // triggers `loadIfNeeded()` when this tab is actually selected.
        VStack(spacing: 0) {
            content
            Divider()
            refreshRow
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.skills.isEmpty {
            emptyContent
        } else {
            skillsList
        }
    }

    /// What fills the pane before the first list arrives: a spinner, an
    /// error, or the honest "nothing installed" answer.
    @ViewBuilder
    private var emptyContent: some View {
        switch store.phase {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 10) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await store.refresh() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            Text("No skills found for this agent.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var skillsList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                section(titled: "Project", skills: store.projectSkills)
                section(titled: "Global", skills: store.globalSkills)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private func section(titled title: String, skills: [AgentSkill]) -> some View {
        if !skills.isEmpty {
            Text(title)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ForEach(skills) { skill in
                SkillRowButton(skill: skill) { onInsert(skill) }
                Divider().padding(.leading, 16)
            }
        }
    }

    /// Pinned below the list for the same reasons as the Snippets manage
    /// row; doubles as the loading indicator during a manual refresh.
    private var refreshRow: some View {
        Button {
            Task { await store.refresh() }
        } label: {
            HStack {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.subheadline)
                if store.phase == .loading, !store.skills.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .disabled(store.phase == .loading)
    }
}

/// One skill as a row: its slash name on top, its description below when it
/// has one. A long press previews the full detail — the row truncates the
/// description to one line, and a sheet is not an option inside the keyboard
/// window.
struct SkillRowButton: View {
    let skill: AgentSkill
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.command)
                    .font(.subheadline.weight(.medium))
                    .fontDesign(.monospaced)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let description = skill.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(skill.name)
        .accessibilityHint("Inserts \(skill.command) without sending it")
        .contextMenu {
            Button("Insert", systemImage: "text.insert", action: action)
        } preview: {
            SkillDetailPreview(skill: skill)
        }
    }
}

/// The long-press preview: everything the two-line row had to cut.
struct SkillDetailPreview: View {
    let skill: AgentSkill

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(skill.command)
                .font(.headline)
                .fontDesign(.monospaced)
            Text(skill.scope == .project ? "Project" : "Global")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            if let description = skill.description {
                Divider()
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: 340, alignment: .leading)
    }
}
