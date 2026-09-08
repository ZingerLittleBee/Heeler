import SwiftUI

struct AgentLayoutErrorView: View {
    let editor: AgentListFieldsEditor

    var body: some View {
        if let message = editor.errorMessage {
            Section {
                Text(verbatim: message)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("settings.agentList.error")
            }
        }
    }
}
