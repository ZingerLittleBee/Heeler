import SwiftUI

/// Chat's tools dock: the terminal's Skills and Snippets panes, and an Agent
/// page whose keys reach the Agent's program through `agent.send_keys`.
/// No Appearance tab and no terminal keyboard: Chat draws no terminal.
struct AgentChatToolsKeyboard: View {
    let insertText: (String) -> Void
    /// Nil hides the Skills tab, as on the terminal.
    let skills: TerminalSkillsContext?
    let snippets: SnippetStore
    let manageSnippets: () -> Void
    let agentKeys: ChatAgentKeysStore
    let height: CGFloat
    @State private var selectedTab: TerminalKeysTab = .controls

    private var tabs: [TerminalKeysTab] {
        TerminalKeysTab.allCases.filter { tab in
            switch tab {
            case .controls, .snippets: true
            case .skills: skills != nil
            case .appearance: false
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .controls:
                    ChatAgentKeysPage(store: agentKeys)
                case .skills:
                    if let skills {
                        SkillsKeyboardPane(
                            store: skills.store,
                            onInsert: { skill in
                                insertText(skill.chatInsertionText)
                                selectedTab = .controls
                            },
                            onViewContent: skills.viewContent)
                    }
                case .snippets:
                    SnippetsKeyboardPane(
                        store: snippets,
                        onSend: { snippet in
                            insertText(snippet.body)
                            selectedTab = .controls
                        },
                        onManage: manageSnippets)
                case .appearance:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            ToolsKeyboardTabBar(tabs: tabs, selection: $selectedTab)
        }
        .frame(height: height)
        .clipped()
        .background(Color(uiColor: .systemBackground).ignoresSafeArea(edges: .bottom))
        .onChange(of: selectedTab) { _, tab in
            guard tab == .skills, let skills else { return }
            Task { await skills.store.loadIfNeeded() }
        }
    }
}

/// The Blocked card's keys, for any time: they go to the Agent's program,
/// not into the Composer.
private struct ChatAgentKeysPage: View {
    let store: ChatAgentKeysStore

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Text(store.failure ?? "Keys go straight to the Agent")
                    .font(.caption)
                    .foregroundStyle(store.failure == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 26)
                AgentQuickKeyPad(isEnabled: true) { store.press($0) }
            }
            .frame(width: min(geometry.size.width, InputChromeLayout.maxKeyboardContentWidth))
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
