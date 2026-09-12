import SwiftUI
import UIKit

/// The shared full keyboard used by Agent tools and Open Terminal's Keys dock.
/// Its six rows always fit the height supplied by the measured keyboard dock.
struct TerminalFullKeyboard: View {
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
                    TerminalKeyboardKeyCap(
                        title: "Fn", label: "Function key layer", isEnabled: isEnabled,
                        isSelected: showsFunctionKeys
                    ) { showsFunctionKeys.toggle() }
                    TerminalKeyboardKeyCap(
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
        TerminalKeyboardKeyCap(
            title: title ?? modifiers.characterText(character),
            label: character == " " ? "Space" : modifiers.characterText(character),
            isEnabled: isEnabled
        ) { send(.character(character)) }
    }

    private func key(_ key: AgentQuickKey, title: String? = nil, image: String? = nil) -> some View {
        TerminalKeyboardKeyCap(
            title: title ?? key.title ?? "", systemImage: image ?? key.systemImageName,
            label: key.accessibilityLabel, isEnabled: isEnabled
        ) { send(key) }
    }

    private func modifierKey(
        _ modifier: TerminalKeyModifiers, title: String, image: String? = nil, label: String
    ) -> some View {
        TerminalKeyboardKeyCap(
            title: title, systemImage: image, label: label, isEnabled: isEnabled,
            isSelected: modifiers.contains(modifier)
        ) { keyboardControl.toggleModifier(modifier) }
        .accessibilityValue(modifiers.contains(modifier) ? "Armed" : "Not armed")
        .accessibilityHint("Applies to the next remote key; tap again to cancel")
    }
}

private struct TerminalKeyboardKeyCap: View {
    let title: String
    var systemImage: String? = nil
    let label: String
    let isEnabled: Bool
    var isSelected: Bool? = nil
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
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
        .buttonStyle(TerminalKeyboardButtonStyle(isSelected: isSelected))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected == true ? .isSelected : [])
    }
}

/// Immediate press feedback with a short release, without changing layout or
/// installing a gesture that competes with the keyboard's horizontal pager.
struct TerminalKeyboardButtonStyle: ButtonStyle {
    /// A selection state identifies a toggle key, which keeps its color while held.
    /// Ordinary keys leave this nil to use momentary press feedback.
    var isSelected: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = isSelected == nil && configuration.isPressed
        return configuration.label
            .foregroundStyle(isSelected == true ? Color.white : .primary)
            .background(
                isPressed ? Color(uiColor: .systemGray3)
                    : (isSelected == true ? Color.accentColor : Color(uiColor: .secondarySystemFill)),
                in: .rect(cornerRadius: 7))
            .scaleEffect(isPressed && !reduceMotion ? 0.97 : 1)
            .animation(
                isSelected != nil || isPressed || reduceMotion ? nil : .easeOut(duration: 0.1),
                value: isPressed)
            .contentShape(.rect)
    }
}
