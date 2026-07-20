import SwiftUI

/// Per-Host onboarding (#14): the preflight checklist with fix-it hints,
/// plus the TOFU fingerprint confirmation. Checks run automatically on
/// arrival; the goal is zero to green checkmarks without desktop docs.
struct HostOnboardingView: View {
    /// The Host catalog, for the Edit sheet.
    let catalog: HostStore
    @State private var store: HostOnboardingStore
    @State private var isEditing = false
    @State private var isConfirmingHostKeyReplacement = false

    init(host: Host, catalog: HostStore) {
        self.catalog = catalog
        _store = State(initialValue: HostOnboardingStore(host: host))
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Address", value: addressLine)
                LabeledContent("Session", value: sessionLine)
                LabeledContent(
                    "Auth",
                    value: store.host.authMethod == .deviceKey ? "Device Key" : "Password")
            }

            Section {
                ForEach(PreflightCheck.allCases, id: \.self) { check in
                    PreflightCheckRow(check: check, status: status(for: check))
                }
            } header: {
                HStack {
                    Text("Preflight")
                    if store.phase == .running {
                        ProgressView()
                            .controlSize(.mini)
                            .padding(.leading, 4)
                    }
                }
            } footer: {
                if let info = store.serverInfo {
                    Text("herdr \(info.version) · protocol \(info.protocolVersion)")
                }
            }

            Section {
                Button {
                    Task { await store.runChecks() }
                } label: {
                    Label("Run Checks Again", systemImage: "arrow.clockwise")
                }
                .disabled(store.phase == .running)
            }

            if store.pendingHostKeyReplacement != nil {
                Section {
                    Button("Trust New Host Key", systemImage: "key.horizontal", role: .destructive) {
                        isConfirmingHostKeyReplacement = true
                    }
                } footer: {
                    Text("Only continue after verifying the new fingerprint with the Host owner.")
                }
            }
        }
        .navigationTitle(store.host.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            HostFormView(store: catalog, editing: store.host)
        }
        .alert(
            "Trust this Host?",
            isPresented: fingerprintAlertPresented,
            presenting: store.pendingFingerprint
        ) { _ in
            Button("Trust") { store.confirmFingerprint(trusted: true) }
            Button("Don't Trust", role: .cancel) { store.confirmFingerprint(trusted: false) }
        } message: { candidate in
            Text(
                "First connection to \(candidate.host):\(String(candidate.port)).\n\n"
                    + "Key fingerprint:\n\(candidate.fingerprint.displayString)\n\n"
                    + "Verify it matches the Host's key before trusting.")
        }
        .confirmationDialog(
            "Replace the trusted Host key?",
            isPresented: $isConfirmingHostKeyReplacement,
            titleVisibility: .visible
        ) {
            Button("Trust New Key", role: .destructive) {
                Task { await store.trustPresentedHostKey() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let replacement = store.pendingHostKeyReplacement {
                Text(
                    "Trusted: \(replacement.known.displayString)\n\n"
                        + "Presented: \(replacement.presented.displayString)\n\n"
                        + "A changed key can indicate a reinstalled Host or an attack.")
            }
        }
        .task {
            if store.phase == .idle {
                await store.runChecks()
            }
        }
    }

    /// Presentation tracks the pending candidate; dismissal is decided by
    /// the buttons (or the store's own timeout), never by the binding, so a
    /// dismiss-then-answer race cannot double-resolve the decision.
    private var fingerprintAlertPresented: Binding<Bool> {
        Binding(
            get: { store.pendingFingerprint != nil },
            set: { _ in })
    }

    private var addressLine: String {
        "\(store.host.username)@\(store.host.address):\(String(store.host.port))"
    }

    private var sessionLine: String {
        if case .namedSession(let name) = store.host.socketLocation {
            return name
        }
        return "default"
    }

    private func status(for check: PreflightCheck) -> PreflightCheckStatus? {
        store.report?[check]
    }
}

private struct PreflightCheckRow: View {
    let check: PreflightCheck
    /// nil while no report exists yet (first run still in flight).
    let status: PreflightCheckStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                statusIcon
                Text(check.title)
            }
            if case .failed(let hint) = status {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .blocked:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        case nil:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
        }
    }
}
