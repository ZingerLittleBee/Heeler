import SwiftUI

struct DroidHookSheet: View {
    let host: String
    let configure: @MainActor (DroidChatHook.Action) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isInstalling = false
    @State private var installed = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(host)
                    Text(verbatim: "~/.factory/hooks/heeler-droid.py")
                        .font(.footnote.monospaced()).textSelection(.enabled)
                    Text(verbatim: "~/.factory/settings.json")
                        .font(.footnote.monospaced()).textSelection(.enabled)
                } footer: {
                    Text("Heeler adds its Python 3 hook to this SSH account’s Droid settings. The hook names the conversation open in each terminal and reports when a turn starts or ends.")
                }
                if installed {
                    Text("Restart or resume Droid in the terminal, then return to Chat.")
                    Button("Remove Hook from Droid Settings") { apply(.removeRegistration) }
                        .disabled(isInstalling)
                } else {
                    Text(verbatim: DroidChatHook.entries.map(\.event).joined(separator: ", "))
                        .font(.footnote.monospaced())
                    Button("Install Droid Hook") { apply(.register) }.disabled(isInstalling)
                }
                if isInstalling { ProgressView() }
                if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
            }
            .navigationTitle("Droid Chat Hook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.disabled(isInstalling) }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isInstalling)
    }

    private func apply(_ action: DroidChatHook.Action) {
        isInstalling = true
        errorMessage = nil
        Task {
            defer { isInstalling = false }
            do {
                try await configure(action)
                installed = action == .register
            } catch {
                errorMessage = (error as? TransportError)?.presentation.message ?? error.localizedDescription
            }
        }
    }
}
