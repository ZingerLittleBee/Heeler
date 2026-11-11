import SwiftUI

/// Host detail's Claude Code hooks on a tmux Host (ADR 0044): each
/// configuration root, and the change that adds or removes Heeler's hooks,
/// shown before it is written.
struct ClaudeCodeHooksSection: View {
    @State private var flow: ClaudeCodeHooksFlow

    init(flow: ClaudeCodeHooksFlow) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        Section {
            switch flow.phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .task { await flow.load() }
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .accessibilityIdentifier("hosts.detail.claudeCodeHooks.failure")
                Button("Try Again") { Task { await flow.load() } }
            case .loaded:
                ForEach(flow.roots) { @Sendable root in
                    MainActorContent { ClaudeCodeHooksRootRow(root: root, flow: flow) }
                }
                if flow.accountsUnreadable {
                    Text("Heeler couldn't read this Host's Accounts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Claude Code Hooks")
        } footer: {
            Text("Claude Code Agents Heeler starts report their status already. Adding the hooks does the same for ones you start yourself.")
        }
    }
}

private struct ClaudeCodeHooksRootRow: View {
    let root: ClaudeCodeHooksFlow.Root
    let flow: ClaudeCodeHooksFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                if case .read(let presence) = flow.states[root.id] {
                    Text(Self.status(presence))
                        .accessibilityIdentifier("hosts.detail.claudeCodeHooks.status")
                }
            } label: {
                if let name = root.accountName {
                    Text(verbatim: name)
                } else {
                    Text("Default")
                }
                Text(verbatim: root.path)
                    .font(.footnote.monospaced())
            }
            content
        }
        .accessibilityIdentifier("hosts.detail.claudeCodeHooks.root")
    }

    @ViewBuilder private var content: some View {
        switch flow.states[root.id] ?? .reading {
        case .reading, .writing:
            ProgressView()
        case .read(let presence):
            HStack {
                if presence != .on {
                    Button("Add Hooks") { Task { await flow.review(root, adding: true) } }
                        .accessibilityIdentifier("hosts.detail.claudeCodeHooks.add")
                }
                if presence != .off {
                    Button("Remove Hooks", role: .destructive) { Task { await flow.review(root, adding: false) } }
                        .accessibilityIdentifier("hosts.detail.claudeCodeHooks.remove")
                }
            }
            .buttonStyle(.borderless)
        case .review(let change, let adding):
            HarnessConfigChangeLines(path: change.path, lines: change.shownLines)
            if adding, let folder = flow.scriptFolder {
                HarnessConfigFolderLines(
                    path: folder,
                    filePaths: [
                        RemoteFilePath.join(folder, ClaudeCodeHooks.scriptName),
                        RemoteFilePath.join(folder, ClaudeCodeHooks.launchSettingsName),
                    ])
            }
            HStack {
                Button("Apply This Change") { Task { await flow.accept(root) } }
                    .accessibilityIdentifier("hosts.detail.claudeCodeHooks.apply")
                Spacer()
                Button("Cancel", role: .cancel) { Task { await flow.dismiss(root) } }
            }
            .buttonStyle(.borderless)
        case .refused(let message), .failed(let message):
            Text(message)
                .font(.footnote)
                .accessibilityIdentifier("hosts.detail.claudeCodeHooks.failure")
            Button("OK") { Task { await flow.dismiss(root) } }
                .buttonStyle(.borderless)
        }
    }

    private static func status(_ presence: ClaudeCodeHooks.Presence?) -> String {
        switch presence {
        case .on: String(localized: "On")
        case .partly: String(localized: "Incomplete")
        case .off: String(localized: "Off")
        case nil: String(localized: "Unknown")
        }
    }
}
