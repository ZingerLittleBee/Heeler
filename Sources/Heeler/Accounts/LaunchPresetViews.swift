import SwiftUI

/// What a preset starts, in a line or two: its harness, Account, arguments
/// and how many variables it sets.
struct LaunchPresetSummary: View {
    let preset: LaunchPreset

    static func lines(for preset: LaunchPreset) -> [String] {
        var lines = [preset.kind.displayName + (preset.accountDirectory.map { " · \($0)" } ?? "")]
        let arguments = preset.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        var detail: [String] = []
        if !arguments.isEmpty { detail.append(arguments) }
        switch preset.environment.count {
        case 0: break
        case 1: detail.append("1 variable")
        case let count: detail.append("\(count) variables")
        }
        if !detail.isEmpty { lines.append(detail.joined(separator: " · ")) }
        return lines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(Self.lines(for: preset).enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(index == 0 ? .subheadline : .caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Edits one Launch Preset: its name, harness, Account, arguments and any
/// environment variables. Save stays off while the preset has a problem.
struct LaunchPresetEditor: View {
    let store: LaunchPresetStore
    let console: ConsoleStore
    @State private var draft: LaunchPreset
    @State private var usesOtherFolder: Bool
    @Environment(\.dismiss) private var dismiss
    private let isNew: Bool

    init(preset: LaunchPreset?, store: LaunchPresetStore, console: ConsoleStore) {
        self.store = store
        self.console = console
        isNew = preset == nil
        let draft = preset ?? LaunchPreset(name: "", kind: .claude)
        _draft = State(initialValue: draft)
        _usesOtherFolder = State(
            initialValue: draft.accountDirectory.map { directory in
                !console.presetAccountChoices(for: draft.kind).contains { $0.directory == directory }
            } ?? false)
    }

    private var problem: String? { store.problem(with: draft) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("preset.name")
                Picker("Harness", selection: $draft.kind) {
                    ForEach(SupportedAgentKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .onChange(of: draft.kind) {
                    draft.accountDirectory = nil
                    usesOtherFolder = false
                }
            } footer: {
                Text("New Agent offers the preset on Hosts where this harness is installed.")
            }

            accountSection

            Section {
                AgentArgumentsField(text: $draft.arguments, placeholder: "--dangerously-skip-permissions")
            } header: {
                Text("Arguments")
            } footer: {
                Text("Placed before any arguments typed in New Agent. Quotes and backslash escapes are supported.")
            }

            Section {
                ForEach($draft.environment.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        TextField("NAME", text: $draft.environment[index].name)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Text("=").foregroundStyle(.secondary)
                        TextField("value", text: $draft.environment[index].value)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .onDelete { draft.environment.remove(atOffsets: $0) }
                Button("Add Variable", systemImage: "plus") {
                    draft.environment.append(.init(name: "", value: ""))
                }
                .accessibilityIdentifier("preset.addVariable")
            } header: {
                Text("Environment")
            } footer: {
                Text("Set in the Agent’s shell. ~ and $HOME are each Host’s home folder. A variable here wins over the Account’s.")
            }

            if let problem, !draft.name.isEmpty {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(isNew ? "New Preset" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if (try? store.save(draft)) != nil { dismiss() }
                }
                .disabled(problem != nil)
                .accessibilityIdentifier("preset.save")
            }
        }
        .task {
            await console.loadAllHostAccounts()
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        let choices = console.presetAccountChoices(for: draft.kind)
        Section {
            Picker("Account", selection: accountSelection(choices)) {
                Text("Default").tag(AccountChoice.defaultAccount)
                ForEach(choices) { choice in
                    Text("\(choice.name) · \(choice.directory)").tag(AccountChoice.folder(choice.directory))
                }
                Text("Other Folder…").tag(AccountChoice.other)
            }
            .accessibilityIdentifier("preset.account")
            if usesOtherFolder {
                TextField("~/.\(draft.kind.rawValue)-work", text: otherFolder)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("Account")
        } footer: {
            if let variable = draft.kind.configDirectoryVariable {
                Text("Sets \(variable) to the Account’s folder. Add Accounts in each Host’s Accounts so Usage and Chat find them too.")
            } else {
                Text("Name \(draft.kind.displayName)’s folder variable in a Host’s Accounts to launch one of its Accounts.")
            }
        }
    }

    private enum AccountChoice: Hashable {
        case defaultAccount
        case folder(String)
        case other
    }

    private func accountSelection(_ choices: [ConsoleStore.PresetAccountChoice]) -> Binding<AccountChoice> {
        Binding(
            get: {
                if usesOtherFolder { return .other }
                guard let directory = draft.accountDirectory else { return .defaultAccount }
                return choices.contains { $0.directory == directory } ? .folder(directory) : .other
            },
            set: { choice in
                switch choice {
                case .defaultAccount:
                    usesOtherFolder = false
                    draft.accountDirectory = nil
                case .folder(let directory):
                    usesOtherFolder = false
                    draft.accountDirectory = directory
                case .other:
                    usesOtherFolder = true
                }
            })
    }

    private var otherFolder: Binding<String> {
        Binding(
            get: { draft.accountDirectory ?? "" },
            set: { text in
                let folder = text.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.accountDirectory = folder.isEmpty ? nil : folder
            })
    }
}
