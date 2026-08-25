import SwiftUI

/// The explicit Skill picker, presented as a sheet from the Composer's More
/// menu. It reads the same `SkillsPaneStore` as the tools keyboard's Skills
/// pane — one catalogue, one load, one set of failure states — and adds the
/// search field the keyboard pane cannot host. Tapping a Skill inserts its
/// invocation into the draft without sending it, then closes the picker.
struct SkillsPickerView: View {
    let store: SkillsPaneStore
    let onInsert: (AgentSkill) -> Void
    /// Fetches the skill's full document for View Content. The picker owns
    /// that sheet itself: the screen's own skill sheet cannot present while
    /// this one is up.
    let readSkill: (AgentSkill) async throws -> String

    @State private var query = ""
    @State private var viewingSkill: AgentSkill?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Skills")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "Search Skills")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task { await store.loadIfNeeded() }
        .sheet(item: $viewingSkill) { skill in
            SkillContentSheet(skill: skill) { try await readSkill(skill) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.skills.isEmpty {
            emptyContent
        } else {
            resultsList
        }
    }

    /// Before the first list arrives: a spinner, the failure with a retry,
    /// or the honest "nothing installed" answer.
    @ViewBuilder
    private var emptyContent: some View {
        switch store.phase {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Skills Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await store.refresh() } }
                    .buttonStyle(.borderedProminent)
            }
        case .loaded:
            ContentUnavailableView {
                Label("No Skills", systemImage: "sparkles")
            } description: {
                Text("No skills found for this agent.")
            }
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        let results = store.matching(query)
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List {
                section(titled: "Project", skills: results.filter { $0.scope == .project })
                section(titled: "Global", skills: results.filter { $0.scope == .global })
            }
            .refreshable { await store.refresh() }
        }
    }

    @ViewBuilder
    private func section(titled title: String, skills: [AgentSkill]) -> some View {
        if !skills.isEmpty {
            Section(title) {
                ForEach(skills) { skill in
                    row(for: skill)
                }
            }
        }
    }

    private func row(for skill: AgentSkill) -> some View {
        Button {
            onInsert(skill)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.command)
                    .font(.body.weight(.medium))
                    .fontDesign(.monospaced)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let description = skill.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(skill.name)
        .accessibilityHint("Inserts \(skill.command) without sending it")
        .contextMenu {
            Button("View Content", systemImage: "doc.text") {
                viewingSkill = skill
            }
            Button("Insert", systemImage: "text.insert") {
                onInsert(skill)
                dismiss()
            }
        } preview: {
            SkillDetailPreview(skill: skill)
        }
    }
}
