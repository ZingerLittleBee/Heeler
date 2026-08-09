import SwiftUI

enum AgentComposerKeyboardPresentation: Equatable {
    case hidden
    case system
    case tools
}

struct AgentComposerKeyboardLayout: Equatable {
    let contentInset: CGFloat
    let toolsHeight: CGFloat
    let availableToolsHeight: CGFloat

    init(
        currentHeight: CGFloat,
        lastPresentedHeight: CGFloat,
        presentation: AgentComposerKeyboardPresentation
    ) {
        availableToolsHeight = lastPresentedHeight
        switch presentation {
        case .hidden:
            contentInset = currentHeight
            toolsHeight = 0
        case .system:
            contentInset = max(currentHeight, lastPresentedHeight)
            toolsHeight = 0
        case .tools:
            contentInset = lastPresentedHeight
            toolsHeight = lastPresentedHeight
        }
    }
}

/// The native, local-first input surface beneath the live terminal. Drafting
/// stays on device; Send emits one `agent.prompt` request, while explicit
/// tool-keyboard controls send terminal sequences through Attach.
struct AgentComposerView: View {
    let store: AgentComposerStore
    let status: AgentStatus
    let switcher: TerminalAgentSwitcher
    let keyboardHandoff: TerminalKeyboardHandoff
    let keysContext: TerminalKeysContext
    let keyboardHeight: CGFloat
    @Binding var keyboardPresentation: AgentComposerKeyboardPresentation
    let quickKeysEnabled: Bool
    let sendQuickKey: (AgentQuickKey) -> Void
    @FocusState private var isInputFocused: Bool

    private var isToolsKeyboardPresented: Bool {
        keyboardPresentation == .tools
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                statusLabel
                    .padding(.horizontal, 16)

                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(
                            "Message Agent",
                            text: Binding(
                                get: { store.draft },
                                set: { store.replaceDraft(with: $0) }),
                            axis: .vertical
                        )
                        .lineLimit(1...5)
                        .textFieldStyle(.plain)
                        .frame(minHeight: 36, alignment: .topLeading)
                        .focused($isInputFocused)
                        .accessibilityLabel("Message the Agent")

                        if let failure = latestFailure {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(failure.detail, systemImage: "exclamationmark.triangle")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .lineLimit(2)
                                HStack(spacing: 8) {
                                    Button("Retry") {
                                        Task { await store.retry(failure.id) }
                                    }
                                    Button("Edit Draft") {
                                        store.withdrawToDraft(failure.id)
                                        isInputFocused = true
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Button("Send", systemImage: "arrow.up") {
                                Task { await store.send() }
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.circle)
                            .labelStyle(.iconOnly)
                            .font(.footnote.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                            .disabled(!store.canSend)
                            .accessibilityHint("Delivers the complete draft to the Agent")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                    TerminalAgentSwitcherRow(
                        switcher: focusPreservingSwitcher,
                        isKeyboardUp: isKeyboardPresented,
                        toggleKeyboard: dismissOrPresentKeyboard,
                        isToolsKeyboardPresented: isToolsKeyboardPresented,
                        switchKeyboard: keyboardSwitchAction)
                }
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.secondary.opacity(0.16), lineWidth: 1)
                }
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 8)

        }
        .onAppear {
            guard let selectedID = switcher.selectedID,
                  keyboardHandoff.consume(selectedID)
            else { return }
            keyboardPresentation = .system
            isInputFocused = true
        }
        .onChange(of: isInputFocused) { _, isFocused in
            if isFocused {
                keyboardPresentation = .system
            } else if keyboardPresentation != .tools {
                keyboardPresentation = .hidden
            }
        }
    }

    private var isKeyboardPresented: Bool {
        isInputFocused || isToolsKeyboardPresented
    }

    private var keyboardSwitchAction: (() -> Void)? {
        guard keyboardHeight > 0 else { return nil }
        return { switchKeyboard() }
    }

    private func dismissOrPresentKeyboard() {
        if isToolsKeyboardPresented {
            keyboardPresentation = .hidden
        } else {
            isInputFocused.toggle()
        }
    }

    private func switchKeyboard() {
        if isToolsKeyboardPresented {
            keyboardPresentation = .system
            isInputFocused = true
        } else {
            keyboardPresentation = .tools
            isInputFocused = false
        }
    }

    private var focusPreservingSwitcher: TerminalAgentSwitcher {
        TerminalAgentSwitcher(
            items: switcher.items,
            selectedID: switcher.selectedID
        ) { id in
            if isInputFocused {
                keyboardHandoff.arm(for: id)
            }
            switcher.onSelect(id)
        }
    }

    private var latestFailure: (id: AgentComposerStore.Message.ID, detail: String)? {
        guard let message = store.messages.last,
              case .failed(let detail) = message.state
        else { return nil }
        return (message.id, detail)
    }

    private var statusLabel: some View {
        HStack(spacing: 4) {
            if status == .working {
                SolvingOrbView(size: 10)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(Color(status.inkUIColor))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            Text(status.rawValue.capitalized)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(Color(status.inkUIColor))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent status")
        .accessibilityValue(status.rawValue.capitalized)
    }
}

struct AgentToolsKeyboard: View {
    let store: AgentComposerStore
    let context: TerminalKeysContext
    let height: CGFloat
    let quickKeysEnabled: Bool
    let sendQuickKey: (AgentQuickKey) -> Void
    @State private var selectedTab: TerminalKeysTab = .controls

    private var tabs: [TerminalKeysTab] {
        TerminalKeysTab.allCases.filter {
            $0 != .skills || context.skills != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .controls:
                    AgentQuickKeyPad(
                        isEnabled: quickKeysEnabled,
                        send: sendQuickKey)
                case .skills:
                    if let skills = context.skills {
                        SkillsKeyboardPane(
                            store: skills.store,
                            onInsert: { skill in
                                store.insertIntoDraft(skill.insertionText)
                                selectedTab = .controls
                            },
                            onViewContent: skills.viewContent)
                    }
                case .snippets:
                    SnippetsKeyboardPane(
                        store: context.settings.snippets,
                        onSend: { snippet in
                            store.insertIntoDraft(snippet.body)
                            selectedTab = .controls
                        },
                        onManage: context.manageSnippets)
                case .appearance:
                    TerminalAppearancePane(
                        themes: context.settings.themes,
                        zoom: context.settings.zoom,
                        fonts: context.settings.fonts)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Image(systemName: tab.systemImageName)
                            .font(.body)
                            .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(
                                selectedTab == tab ? Color(uiColor: .secondarySystemFill) : .clear,
                                in: .rect(cornerRadius: 8))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.accessibilityLabel)
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
        }
        .frame(height: height)
        .background(Color(uiColor: .systemBackground))
        .onChange(of: selectedTab) { _, tab in
            guard tab == .skills, let skills = context.skills else { return }
            Task { await skills.store.loadIfNeeded() }
        }
    }
}

private struct AgentQuickKeyPad: View {
    let isEnabled: Bool
    let send: (AgentQuickKey) -> Void

    private static let rows: [[AgentQuickKey]] = [
        [.escape, .tab, .shiftTab],
        [.left, .up, .right],
        [.backspace, .down, .enter],
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Self.rows.indices, id: \.self) { rowIndex in
                HStack(spacing: 8) {
                    ForEach(Self.rows[rowIndex], id: \.self) { key in
                        Button {
                            send(key)
                        } label: {
                            keyLabel(for: key)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .background(
                            Color(uiColor: .secondarySystemFill),
                            in: .rect(cornerRadius: 8))
                        .disabled(!isEnabled)
                        .opacity(isEnabled ? 1 : 0.45)
                        .accessibilityLabel(key.accessibilityLabel)
                        .accessibilityHint("Sends this key directly to the Agent")
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func keyLabel(for key: AgentQuickKey) -> some View {
        if let systemImageName = key.systemImageName {
            Image(systemName: systemImageName)
                .font(.system(size: 13, weight: .medium))
        } else if let title = key.title {
            Text(title)
                .font(.caption.weight(.medium))
        }
    }
}
