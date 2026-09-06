import SwiftUI

struct AgentLayoutTokensView: View {
    let editor: AgentListFieldsEditor
    let hostID: Host.ID
    let kind: String?
    let rowIndex: Int
    var hostName: String = ""
    @State private var customName = ""

    private var rows: [AgentRow] {
        let layout = editor.layout(for: hostID)
        return kind.map { layout.rowsByAgent[$0] ?? [] } ?? layout.rows
    }
    private var tokens: AgentRow { rows.indices.contains(rowIndex) ? rows[rowIndex] : [] }

    var body: some View {
        List {
            Section {
                ForEach(Array(tokens.indices), id: \.self) { index in
                    Text(verbatim: tokens[index].token.rawValue)
                }
                .onDelete(perform: deleteHandler)
                .onMove(perform: moveHandler)
            } header: {
                Text("Fields")
            } footer: {
                Text("Status fields are accepted but shown in the status column. Edit to delete or reorder fields.")
            }
            if editor.isEditing {
                Section {
                    Menu("Add Field", systemImage: "plus") {
                        ForEach(AgentRowToken.builtins, id: \.self) { token in
                            Button(token.rawValue) { mutate { $0.append(.init(token)) } }
                        }
                    }
                    TextField("$custom_name", text: $customName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Add Custom Field") {
                        guard let token = customToken else { return }
                        mutate { $0.append(.init(token)) }
                        if editor.errorMessage == nil { customName = "" }
                    }
                    .disabled(customToken == nil)
                } footer: {
                    Text("Custom names start with $ and contain 1–32 letters, digits, underscores or hyphens. Values come from herdr plugins and display as plain text.")
                }
                .disabled(tokens.count >= AgentRowLayout.maximumTokensPerRow || !rows.indices.contains(rowIndex))
            }
            AgentLayoutErrorView(editor: editor)
        }
        .navigationTitle("Row \(rowIndex + 1)")
        .toolbar {
            if editor.isEditing { EditButton() }
        }
    }

    private var customToken: AgentRowToken? {
        guard customName.hasPrefix("$") else { return nil }
        return AgentRowToken(rawValue: customName)
    }

    private var deleteHandler: ((IndexSet) -> Void)? {
        guard editor.isEditing else { return nil }
        return { offsets in mutate { $0.remove(atOffsets: offsets) } }
    }

    private var moveHandler: ((IndexSet, Int) -> Void)? {
        guard editor.isEditing else { return nil }
        return { offsets, destination in mutate { $0.move(fromOffsets: offsets, toOffset: destination) } }
    }

    private func mutate(_ change: (inout AgentRow) -> Void) {
        var next = rows
        guard next.indices.contains(rowIndex) else { return }
        change(&next[rowIndex])
        editor.setRows(next, kind: kind, for: hostID)
    }
}
