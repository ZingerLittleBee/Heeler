import SwiftUI

struct AmpPluginInstallSheet: View {
    struct Request: Identifiable {
        let place: AmpPluginLocation
        let updating: Bool
        var id: String { place.id }
    }

    let host: String
    let account: String?
    let place: AmpPluginLocation
    let updating: Bool
    let connection: AmpChatConnection
    let installed: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var writing = false
    @State private var finished = false
    @State private var failure: String?
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("SSH Host", value: host)
                    if let account, !account.isEmpty { LabeledContent("Account", value: account) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Plugin Directory").font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: place.directory + "/").font(.footnote.monospaced()).textSelection(.enabled)
                    }
                } footer: {
                    Text("Amp sessions using this account and configuration share one installation.")
                }
                Section {
                    if finished {
                        Label(updating ? String(localized: "Plugin Updated on Host") : String(localized: "Plugin Installed on Host"),
                              systemImage: "checkmark.circle")
                        Text(AmpChatProblem.reload.explanation)
                    } else if writing {
                        ProgressView()
                    } else {
                        Button(updating ? String(localized: "Update on This Host") : String(localized: "Install on This Host")) {
                            writing = true
                            Task {
                                defer { writing = false }
                                do {
                                    try await connection.install(place, updating: updating)
                                    finished = true
                                    detent = .large
                                    failure = nil
                                    installed()
                                } catch { failure = (error as? AmpChatProblem)?.explanation ?? AmpChatProblem.unreachable.explanation }
                            }
                        }
                        .accessibilityIdentifier("chat.amp.confirm")
                        if let failure { Text(failure) }
                    }
                }
            }
            .navigationTitle(updating ? String(localized: "Update Amp Plugin") : String(localized: "Install Amp Plugin"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(writing) } }
        }
        .interactiveDismissDisabled(writing)
        .presentationDetents([.medium, .large], selection: $detent)
    }
}
