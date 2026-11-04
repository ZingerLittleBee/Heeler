import SwiftUI

/// "Find on Local Network": Bonjour `_ssh._tcp` machines. Picking one
/// resolves it to an IP address and port.
struct LocalMachinePickerView: View {
    let onPick: (ResolvedMachine) -> Void

    @State private var model: LocalMachinePickerModel
    @Environment(\.dismiss) private var dismiss

    init(
        model: LocalMachinePickerModel = LocalMachinePickerModel(),
        onPick: @escaping (ResolvedMachine) -> Void
    ) {
        _model = State(initialValue: model)
        self.onPick = onPick
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = model.searchError {
                    Section { Text(error.message).foregroundStyle(.secondary) }
                } else {
                    Section {
                        if model.machines.isEmpty {
                            if model.isSearching {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Looking for machines…").foregroundStyle(.secondary)
                                }
                            } else {
                                Text("No machines found").foregroundStyle(.secondary)
                            }
                        }
                        ForEach(model.machines) { machine in
                            Button {
                                Task {
                                    if let resolved = await model.resolve(machine) {
                                        onPick(resolved)
                                        dismiss()
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(machine.name)
                                    Spacer()
                                    if model.resolvingID == machine.id { ProgressView() }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.resolvingID != nil)
                        }
                    } footer: {
                        Text(
                            "Machines that offer SSH on this network. Heeler saves the IP address, "
                                + "so the Route still works away from this network's name service.")
                    }
                }
                if let error = model.resolveError {
                    Section { Text(error.message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Local Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { model.start() }
        .onDisappear { model.stop() }
    }
}

private struct LocalMachinePickerSheet: ViewModifier {
    @Binding var isPresented: Bool
    let onPick: (ResolvedMachine) -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            LocalMachinePickerView(onPick: onPick)
        }
    }
}

extension View {
    /// Presents the picker `HostRouteFields` asks for. Apply it to the whole
    /// Form, for the reason `overlayPeerPicker` is.
    func localMachinePicker(
        isPresented: Binding<Bool>, onPick: @escaping (ResolvedMachine) -> Void
    ) -> some View {
        modifier(LocalMachinePickerSheet(isPresented: isPresented, onPick: onPick))
    }
}
