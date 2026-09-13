import SwiftUI

/// Problems with saving, shown at the end of both Agent List Fields screens.
/// An unreadable catalog is announced before any edit, with the one way out:
/// Reset Saved Fields discards it after confirmation.
struct AgentLayoutErrorView: View {
    let editor: AgentListFieldsEditor
    @State private var confirmingReset = false

    var body: some View {
        if editor.isCatalogUnreadable {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AgentListFieldsCopy.unreadableCatalog)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.agentList.unreadable")
                    Button("Reset Saved Fields", role: .destructive) {
                        confirmingReset = true
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("settings.agentList.reset")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .confirmationDialog(
                "Reset saved Agent List Fields?", isPresented: $confirmingReset, titleVisibility: .visible
            ) {
                Button("Reset Saved Fields", role: .destructive) { editor.resetSavedFields() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(AgentListFieldsCopy.resetConfirmation)
            }
        }
        if let message = editor.errorMessage {
            Section {
                Text(verbatim: message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.agentList.error")
            }
        }
    }
}
