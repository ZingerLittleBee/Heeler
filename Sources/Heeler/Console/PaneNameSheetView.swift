import SwiftUI

/// Sets or clears the local pane name for one session (#290): a trimmed,
/// non-empty name sticks; an empty submit clears it back to the default
/// label. Unlike RenameSheetView there is no server validation — the name
/// never leaves the device.
struct PaneNameSheetView: View {
    let currentName: String?
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input: String

    init(currentName: String?, save: @escaping (String) -> Void) {
        self.currentName = currentName
        self.save = save
        _input = State(initialValue: currentName ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. backend fix", text: $input)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text(
                        "A name for this session, shown in the Agent list. "
                        + "Leave it empty to clear the name and fall back to "
                        + "the workspace label.")
                }
            }
            .navigationTitle("Name Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(input)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}