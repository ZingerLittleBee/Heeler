import SwiftUI

struct VoiceInputLanguagesSection: View {
    let preset: VoiceInputPreset
    @Binding var languages: [String]

    var body: some View {
        Section {
            if preset == .siliconFlowCN {
                LabeledContent("Languages", value: "Automatic")
            } else if preset == .deepInfra {
                Picker("Language", selection: Binding(
                    get: { languages.first ?? "" },
                    set: { languages = $0.isEmpty ? [] : [$0] }
                )) {
                    Text("Automatic").tag("")
                    ForEach(VoiceInputLanguage.choices(for: preset), id: \.self) { code in
                        Text(VoiceInputLanguage.name(code)).tag(code)
                    }
                }
            } else {
                NavigationLink {
                    List {
                        Button {
                            languages = []
                        } label: {
                            choice("Automatic", selected: languages.isEmpty)
                        }
                        ForEach(VoiceInputLanguage.choices(for: preset), id: \.self) { code in
                            Button {
                                if languages.contains(code) { languages.removeAll { $0 == code } }
                                else { languages.append(code) }
                            } label: {
                                choice(VoiceInputLanguage.name(code), selected: languages.contains(code))
                            }
                            .accessibilityAddTraits(languages.contains(code) ? .isSelected : [])
                        }
                    }
                    .navigationTitle("Languages")
                } label: {
                    LabeledContent("Languages", value: languageSummary)
                }
                .accessibilityLabel("Languages")
                .accessibilityValue(languageSummary)
            }
        } footer: {
            switch preset {
            case .openAI:
                Text("Automatic detects what you speak. Choose languages to help recognize mixed speech.")
            case .deepInfra:
                Text("Use Automatic for mixed speech. This service accepts one language; results depend on its model.")
            case .siliconFlowCN:
                Text("This service does not document a language setting.")
            }
        }
    }

    private var languageSummary: String {
        languages.isEmpty ? "Automatic" : languages.map(VoiceInputLanguage.name).joined(separator: ", ")
    }

    private func choice(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            if selected { Image(systemName: "checkmark") }
        }
        .accessibilityValue(selected ? "Selected" : "")
    }
}

/// Custom's form fields. Several values become repeated multipart fields;
/// this editor never changes headers or the upload destination.
struct VoiceInputCustomFieldsSection: View {
    @Binding var fields: [VoiceInputCustomField]

    var body: some View {
        Section {
            ForEach($fields) { $field in
                NavigationLink {
                    VoiceInputCustomFieldEditor(field: $field)
                } label: {
                    LabeledContent {
                        Text(field.values.joined(separator: ", "))
                            .lineLimit(1)
                    } label: {
                        Text(field.name.isEmpty ? "New Field" : field.name)
                            .font(.body.monospaced())
                    }
                }
            }
            .onDelete { fields.remove(atOffsets: $0) }
            Button("Add Field", systemImage: "plus") {
                fields.append(.init())
            }
        } header: {
            Text("Advanced Request Fields")
        } footer: {
            Text("Use the service's exact form field names, such as language or languages[]. "
                + "Multiple values repeat that name. These fields override Prompt and the default response_format=json. "
                + "File and model cannot be changed here. Use API Key for authentication.")
        }
    }
}

private struct VoiceInputCustomFieldEditor: View {
    @Binding var field: VoiceInputCustomField

    var body: some View {
        Form {
            Section("Name") {
                TextField("Field Name", text: $field.name, prompt: Text("languages[]"))
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Section {
                ForEach(field.values.indices, id: \.self) { index in
                    TextField("Value \(index + 1)", text: value(at: index), axis: .vertical)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .onDelete { field.values.remove(atOffsets: $0) }
                Button("Add Value", systemImage: "plus") { field.values.append("") }
            } header: {
                Text("Values")
            } footer: {
                Text("For languages[], add zh and en as separate values. Enter numbers and booleans as text.")
            }
        }
        .navigationTitle("Request Field")
    }

    private func value(at index: Int) -> Binding<String> {
        Binding(
            get: { field.values.indices.contains(index) ? field.values[index] : "" },
            set: { value in
                // A removed row may finish editing as SwiftUI tears it down.
                guard field.values.indices.contains(index) else { return }
                field.values[index] = value
            })
    }
}
