import SwiftUI

/// Edit Host: its name, account, Routes and authentication. A save reaches
/// every record of the Host, one for each Server that is on (ADR 0047); its
/// Servers are turned on and off in Host detail, never here, and a Host is
/// added by `NewHostWizardView`. The password goes straight to the Keychain
/// via `HostStore`.
struct HostFormView: View {
    let store: HostStore
    /// One of the Host's records, under the name the Host goes by
    /// (`HostMachine.formRecord`).
    let editing: Host

    @State private var draft: HostDraft
    @State private var saveFailed = false
    /// The route page on screen: Add Route's, or a listed route's.
    @State private var routePath: [HostRoutePage] = []
    /// Reorder and delete controls for the Routes list, from its header.
    @State private var isEditingRoutes = false
    @Environment(\.dismiss) private var dismiss

    init(store: HostStore, editing: Host) {
        self.store = store
        self.editing = editing
        _draft = State(initialValue: HostDraft(host: editing))
    }

    var body: some View {
        NavigationStack(path: $routePath) {
            Form {
                formSections
            }
            .environment(\.editMode, .constant(isEditingRoutes ? .active : .inactive))
            .onChange(of: draft.routes.count) { _, count in
                if count < 2 { isEditingRoutes = false }
            }
            .navigationDestination(for: HostRoutePage.self) { page in
                switch page {
                case .route(let routeID):
                    HostRouteFormView(draft: $draft, routeID: routeID, otherHosts: otherHosts)
                case .newRoute:
                    NewHostRouteView(draft: $draft, otherHosts: otherHosts)
                }
            }
            .navigationTitle("Edit Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!draft.canSave(editing: editing))
                }
            }
            .alert("Could not save the Host", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    /// Split out of `body` so the type checker sees two smaller
    /// expressions instead of one very long modifier chain.
    @ViewBuilder
    private var formSections: some View {
        Section("Host") {
            TextField("Name (optional)", text: $draft.name)
            TextField("User", text: $draft.username)
                .textContentType(.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }

        routesSection

        HostAuthenticationSection(
            authMethod: $draft.authMethod, password: $draft.password,
            passwordPrompt: String(localized: "Password (blank keeps current)"))
    }

    /// Every route, one row each opening its own page, then Add Route.
    private var routesSection: some View {
        Section {
            ForEach(draft.routes) { @Sendable [routeCount = draft.routes.count] route in
                NavigationLink(value: HostRoutePage.route(route.id)) {
                    HostRouteRow(route: route)
                }
                .deleteDisabled(routeCount < 2)
            }
            .onDelete { draft.removeRoutes(atOffsets: $0) }
            .onMove { draft.moveRoutes(fromOffsets: $0, toOffset: $1) }
            if !isEditingRoutes {
                addRouteButton
            }
        } header: {
            HStack {
                Text("Routes")
                Spacer()
                if draft.routes.count > 1 {
                    Button(isEditingRoutes ? "Done" : "Edit") {
                        withAnimation { isEditingRoutes.toggle() }
                    }
                    .font(.subheadline)
                    .textCase(nil)
                    .accessibilityLabel(isEditingRoutes ? String(localized: "Done Editing Routes") : String(localized: "Edit Routes"))
                }
            }
        } footer: {
            if draft.routes.isEmpty {
                Text(
                    String(localized: "Add the address Heeler connects to: directly, over an overlay network, or through a Jump Host."))
            } else if draft.routes.count > 1 {
                Text(
                    String(localized: "Heeler tries every route when it connects, and every server on the Host uses the first that reaches it. Routes over this device's own network start first, and Heeler moves to one of them when it comes into reach."))
            } else {
                Text(
                    String(localized: "Add another way to reach this Host, such as its LAN address at home and an overlay network or Jump Host elsewhere."))
            }
        }
    }

    private var addRouteButton: some View {
        Button {
            routePath.append(.newRoute)
        } label: {
            Label("Add Route", systemImage: "plus")
        }
    }

    /// The Host being edited, in each of its records, is not another Host for
    /// the peer picker to tag.
    private var otherHosts: [Host] {
        guard let machine = store.machine(containing: editing.id) else { return store.hosts }
        return store.hosts.filter { !machine.contains($0.id) }
    }

    private func save() {
        guard draft.canSave(editing: editing), let host = draft.makeHost(id: editing.id) else { return }
        do {
            try store.updateHost(with: host, password: draft.passwordUpdate)
        } catch {
            saveFailed = true
            return
        }
        dismiss()
    }
}
