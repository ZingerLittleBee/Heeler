import SwiftUI

/// Both pages live inside the tools dock's measured system-keyboard footprint.
/// Page changes never update the keyboard inset or recreate the Composer.
struct AgentControlKeyboard: View {
    let isEnabled: Bool
    let keyboardControl: TerminalKeyboardControl
    let send: (AgentQuickKey) -> Void
    @State private var page: Page = .agent
    @GestureState private var horizontalDrag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Page: Int {
        case agent
        case terminal
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    pageButton(.agent, title: "Agent", label: "Agent controls page")
                    HStack(spacing: 5) {
                        Circle().fill(page == .agent ? Color.accentColor : .secondary.opacity(0.4))
                        Circle().fill(page == .terminal ? Color.accentColor : .secondary.opacity(0.4))
                    }
                    .frame(width: 15, height: 5)
                    .accessibilityHidden(true)
                    pageButton(.terminal, title: "Terminal", label: "Terminal keyboard page")
                }
                .frame(height: 26)

                GeometryReader { viewport in
                    HStack(spacing: 0) {
                        AgentQuickKeyPad(isEnabled: isEnabled, send: send)
                            .frame(width: viewport.size.width, height: viewport.size.height)
                            .accessibilityElement(children: .contain)
                            .accessibilityHidden(page != .agent)
                            .allowsHitTesting(page == .agent)
                        AgentFullTerminalKeyboard(
                            isEnabled: isEnabled, keyboardControl: keyboardControl, send: send)
                            .frame(width: viewport.size.width, height: viewport.size.height)
                            .accessibilityElement(children: .contain)
                            .accessibilityHidden(page != .terminal)
                            .allowsHitTesting(page == .terminal)
                    }
                    .offset(x: pageOffset(width: viewport.size.width))
                    .frame(width: viewport.size.width, height: viewport.size.height, alignment: .leading)
                    .contentShape(.rect)
                    .clipped()
                    // Once a horizontal swipe wins, it must cancel the key
                    // underneath it rather than type while changing pages.
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 16)
                            .updating($horizontalDrag) { value, translation, _ in
                                guard abs(value.translation.width) > abs(value.translation.height)
                                else { return }
                                translation = value.translation.width
                            }
                            .onEnded { value in
                                guard abs(value.translation.width) > abs(value.translation.height),
                                      abs(value.translation.width) >= min(60, viewport.size.width * 0.2)
                                else { return }
                                selectPage(value.translation.width < 0 ? .terminal : .agent)
                            })
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .onChange(of: page) { _, _ in clearModifiers() }
        .onDisappear { clearModifiers() }
    }

    private func pageButton(_ destination: Page, title: String, label: String) -> some View {
        Button {
            selectPage(destination)
        } label: {
            Text(title)
                .font(.caption.weight(page == destination ? .semibold : .regular))
                .foregroundStyle(page == destination ? Color.primary : .secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(page == destination ? .isSelected : [])
        .accessibilityHint("Swipe horizontally to switch keyboard pages")
    }

    private func selectPage(_ destination: Page) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { page = destination }
    }

    private func pageOffset(width: CGFloat) -> CGFloat {
        let resting = page == .agent ? CGFloat.zero : -width
        return min(0, max(-width, resting + horizontalDrag))
    }

    private func clearModifiers() {
        keyboardControl.setModifierArmed([.control, .option, .shift], armed: false)
    }
}

private struct AgentQuickKeyPad: View {
    let isEnabled: Bool
    let send: (AgentQuickKey) -> Void

    private static let rows: [[AgentQuickKey]] = [
        [.escape, .tab, .backspace],
        [.left, .up, .right],
        [.shiftTab, .down, .enter],
    ]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Self.rows.indices, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(Self.rows[row], id: \.self) { key in
                        AgentTerminalKeyCap(
                            title: key.title ?? "", systemImage: key.systemImageName,
                            label: key.accessibilityLabel, isEnabled: isEnabled
                        ) { send(key) }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

private struct AgentFullTerminalKeyboard: View {
    let isEnabled: Bool
    let keyboardControl: TerminalKeyboardControl
    let send: (AgentQuickKey) -> Void
    @State private var showsSymbols = false
    @State private var showsFunctionKeys = false

    private var modifiers: TerminalKeyModifiers { keyboardControl.pendingModifiers }

    var body: some View {
        GeometryReader { geometry in
            // Six rows share exactly the available page height, including in
            // landscape. No intrinsic key size may grow the surrounding dock.
            let rowHeight = max(0, (geometry.size.height - 12 - 5 * 4) / 6)
            VStack(spacing: 4) {
                utilityRow
                    .frame(height: rowHeight)
                numberRow
                    .frame(height: rowHeight)
                characterRow(showsSymbols ? "-/\\:;()$&@" : "qwertyuiop")
                    .frame(height: rowHeight)
                characterRow(showsSymbols ? "[]=+#%^*{}" : "asdfghjkl")
                    .padding(.horizontal, showsSymbols ? 0 : geometry.size.width * 0.035)
                    .frame(height: rowHeight)
                HStack(spacing: 4) {
                    modifierKey(.shift, title: "Shift", image: "shift", label: "Shift modifier")
                    ForEach(Array(showsSymbols ? ".,?!'`" : "zxcvbnm"), id: \.self) { character in
                        characterKey(character)
                    }
                    key(.backspace, image: "delete.left")
                }
                .frame(height: rowHeight)
                HStack(spacing: 4) {
                    modifierKey(.control, title: "Ctrl", label: "Control modifier")
                    modifierKey(.option, title: "Alt", label: "Option modifier")
                    AgentTerminalKeyCap(
                        title: "Fn", label: "Function key layer", isEnabled: isEnabled,
                        isSelected: showsFunctionKeys
                    ) { showsFunctionKeys.toggle() }
                    AgentTerminalKeyCap(
                        title: showsSymbols ? "ABC" : "#+=", label: "Symbol key layer",
                        isEnabled: isEnabled, isSelected: showsSymbols
                    ) { showsSymbols.toggle() }
                    characterKey(" ", title: "Space")
                        .frame(width: max(0, geometry.size.width - 12) * 0.14)
                    key(.left)
                    key(.down)
                    key(.up)
                    key(.right)
                    key(.enter, image: "return")
                }
                .frame(height: rowHeight)
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    private var utilityRow: some View {
        HStack(spacing: 4) {
            key(.escape)
            if showsFunctionKeys {
                ForEach(Array(TerminalFunctionKey.allCases.prefix(6)), id: \.self) { function in
                    key(.function(function))
                }
            } else {
                key(.tab)
                key(.home)
                key(.end)
                key(.pageUp, title: "PgUp")
                key(.pageDown, title: "PgDn")
                if showsSymbols {
                    key(.insert, title: "Ins")
                } else {
                    key(.forwardDelete, title: "Del")
                }
            }
        }
    }

    @ViewBuilder
    private var numberRow: some View {
        if showsFunctionKeys {
            HStack(spacing: 4) {
                key(.tab)
                ForEach(Array(TerminalFunctionKey.allCases.suffix(6)), id: \.self) { function in
                    key(.function(function))
                }
            }
        } else {
            characterRow("1234567890")
        }
    }

    private func characterRow(_ characters: String) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(characters), id: \.self) { character in
                characterKey(character)
            }
        }
    }

    private func characterKey(_ character: Character, title: String? = nil) -> some View {
        AgentTerminalKeyCap(
            title: title ?? modifiers.characterText(character),
            label: character == " " ? "Space" : modifiers.characterText(character),
            isEnabled: isEnabled
        ) { send(.character(character)) }
    }

    private func key(_ key: AgentQuickKey, title: String? = nil, image: String? = nil) -> some View {
        AgentTerminalKeyCap(
            title: title ?? key.title ?? "", systemImage: image ?? key.systemImageName,
            label: key.accessibilityLabel, isEnabled: isEnabled
        ) { send(key) }
    }

    private func modifierKey(
        _ modifier: TerminalKeyModifiers, title: String, image: String? = nil, label: String
    ) -> some View {
        AgentTerminalKeyCap(
            title: title, systemImage: image, label: label, isEnabled: isEnabled,
            isSelected: modifiers.contains(modifier)
        ) { keyboardControl.toggleModifier(modifier) }
        .accessibilityValue(modifiers.contains(modifier) ? "Armed" : "Not armed")
        .accessibilityHint("Applies to the next remote key; tap again to cancel")
    }
}

private struct AgentTerminalKeyCap: View {
    let title: String
    var systemImage: String? = nil
    let label: String
    let isEnabled: Bool
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Color.accentColor : Color(uiColor: .secondarySystemFill),
            in: .rect(cornerRadius: 7))
        .foregroundStyle(isSelected ? Color.white : .primary)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
