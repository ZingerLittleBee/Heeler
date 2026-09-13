import SwiftUI

/// Picks one field for a row slot and saves it at once. Every row offers
/// herdr fields, Heeler fields, and custom `$` plugin fields.
struct AgentListFieldsAddFieldSheet: View {
    let editor: AgentListFieldsEditor
    let destination: AgentListFieldsEditorDestination
    var hostName: String = ""
    @Environment(\.dismiss) private var dismiss
    @State private var customName = ""

    private var rows: [AgentRow] { editor.layout(for: destination.hostID).rows }
    private var tokens: AgentRow { AgentLayoutTokensEditing.row(destination.rowIndex, in: rows) }
    private var canAddField: Bool {
        editor.syncStates[destination.hostID] != .syncing
            && AgentLayoutTokensEditing.canAddField(to: tokens, rows: rows, rowIndex: destination.rowIndex)
    }
    private var availableHerdrFields: [AgentRowToken] {
        AgentLayoutTokensEditing.availableBuiltins(in: tokens, from: AgentRowToken.herdrBuiltins)
    }
    private var availableHeelerFields: [AgentRowToken] {
        AgentLayoutTokensEditing.availableHeelerFields(in: tokens)
    }
    private var subtitle: String {
        AgentLayoutTokensEditing.navigationSubtitle(hostName: hostName, rowIndex: destination.rowIndex)
    }

    var body: some View {
        NavigationStack {
            List {
                if availableHerdrFields.isEmpty && availableHeelerFields.isEmpty {
                    Section {
                        Text("Every built-in field is already in this row.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if !availableHerdrFields.isEmpty {
                        Section {
                            ForEach(availableHerdrFields, id: \.self) { token in
                                fieldButton(for: token)
                            }
                        } header: {
                            Text("herdr fields")
                        }
                    }
                    if !availableHeelerFields.isEmpty {
                        Section {
                            ForEach(availableHeelerFields, id: \.self) { token in
                                fieldButton(for: token)
                            }
                        } header: {
                            Text("Heeler fields")
                        } footer: {
                            Text("These fields exist only in Heeler.")
                        }
                    }
                }
                Section {
                    TextField("$custom_name", text: $customName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .fontDesign(.monospaced)
                    Button("Add Custom Field") {
                        guard let token = AgentLayoutTokensEditing.customToken(
                            from: customName, alreadyIn: tokens)
                        else { return }
                        add(token)
                    }
                    .disabled(
                        AgentLayoutTokensEditing.customToken(from: customName, alreadyIn: tokens) == nil
                            || !canAddField)
                } header: {
                    Text("Custom field")
                } footer: {
                    Text("Custom names start with $ and contain 1–32 letters, digits, underscores or hyphens. Values come from herdr plugins and display as plain text.")
                }
                Section {
                    EmptyView()
                } footer: {
                    Text(AgentLayoutTokensEditing.addFieldFooter(rowIndex: destination.rowIndex))
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle("Add to Row \(destination.rowIndex + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                // Host and slot context under the title, not as a list section
                // that would push the fields down the page.
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Add to Row \(destination.rowIndex + 1)")
                            .font(.headline)
                        if !subtitle.isEmpty {
                            Text(verbatim: subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .disabled(!canAddField)
        }
    }

    /// Plain, not tinted: the row reads as content with one blue affordance.
    private func fieldButton(for token: AgentRowToken) -> some View {
        Button {
            add(token)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: token.rawValue)
                        .fontDesign(.monospaced)
                        .foregroundStyle(Color.primary)
                    Text(AgentLayoutTokensEditing.description(for: token))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.tint)
                    .imageScale(.large)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(token.rawValue), \(AgentLayoutTokensEditing.description(for: token))")
        .accessibilityAddTraits(.isButton)
    }

    /// Closes after a saved change and after a refused one, whose message
    /// waits on the page behind the sheet; a no-op keeps the sheet open.
    private func add(_ token: AgentRowToken) {
        let added = AgentLayoutTokensEditing.add(
            token, editor: editor, hostID: destination.hostID, rowIndex: destination.rowIndex)
        if added || editor.errorMessage != nil {
            dismiss()
        }
    }
}
