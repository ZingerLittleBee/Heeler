import SwiftUI

/// Problems with saving, shown at the end of both Agent List Fields screens
/// as cards on the page's own surface. An unreadable catalog is announced
/// before any edit, with the one way out: Reset Saved Fields discards it
/// after confirmation. Color carries the severity in the icon and the
/// button, not in the copy, so the notice reads as a calm explanation.
struct AgentLayoutErrorView: View {
    let editor: AgentListFieldsEditor
    @State private var confirmingReset = false

    var body: some View {
        if editor.isCatalogUnreadable {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(AgentListFieldsCopy.unreadableCatalogTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    Text(AgentListFieldsCopy.unreadableCatalog)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.agentList.unreadable")
                    Button("Reset Saved Fields", role: .destructive) {
                        confirmingReset = true
                    }
                    .buttonStyle(.bordered)
                    .font(.subheadline.weight(.medium))
                    .padding(.top, 4)
                    .accessibilityIdentifier("settings.agentList.reset")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(AgentListFieldsChrome.noticeInsets)
                .listRowSeparator(.hidden)
                .agentListHostSurface(isFirst: true, isLast: true)
            }
            .listSectionSeparator(.hidden)
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
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(verbatim: message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.agentList.error")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(AgentListFieldsChrome.noticeInsets)
                .listRowSeparator(.hidden)
                .agentListHostSurface(isFirst: true, isLast: true)
            }
            .listSectionSeparator(.hidden)
        }
    }
}
