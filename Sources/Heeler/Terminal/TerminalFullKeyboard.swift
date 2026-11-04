import SwiftUI
import UIKit

/// A ten-column pitch keeps character keys consistent across staggered rows.
/// Width changes only horizontal geometry; the dock owns all vertical sizing.
struct TerminalFullKeyboardLayout {
    let contentWidth: CGFloat
    let horizontalInset: CGFloat
    let keySpacing: CGFloat
    let rowHeight: CGFloat

    static let rowSpacing: CGFloat = 4

    init(size: CGSize) {
        let expansion = min(1, max(0, (size.width - 600) / 400))
        horizontalInset = 6 + 6 * expansion
        keySpacing = 4 + 2 * expansion
        contentWidth = max(0, size.width - horizontalInset * 2)
        rowHeight = max(0, (size.height - 12 - 5 * Self.rowSpacing) / 6)
    }

    var characterWidth: CGFloat { max(0, (contentWidth - 9 * keySpacing) / 10) }
    var homeRowInset: CGFloat { (characterWidth + keySpacing) / 2 }
    var bottomKeyWidth: CGFloat { characterWidth * 0.875 }
    var spaceWidth: CGFloat { max(0, contentWidth - 9 * (bottomKeyWidth + keySpacing)) }

    func sideKeyWidth(characterCount: Int) -> CGFloat {
        max(0, (contentWidth - CGFloat(characterCount) * characterWidth
            - CGFloat(characterCount + 1) * keySpacing) / 2)
    }
}

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
            let layout = TerminalFullKeyboardLayout(size: geometry.size)
            VStack(spacing: TerminalFullKeyboardLayout.rowSpacing) {
                utilityRow(spacing: layout.keySpacing)
                    .frame(height: layout.rowHeight)
                numberRow(layout: layout)
                    .frame(height: layout.rowHeight)
                characterRow(showsSymbols ? "-/\\:;()$&@" : "qwertyuiop", layout: layout)
                    .frame(height: layout.rowHeight)
                characterRow(showsSymbols ? "[]=+#%^*{}" : "asdfghjkl", layout: layout)
                    .padding(.horizontal, showsSymbols ? 0 : layout.homeRowInset)
                    .frame(height: layout.rowHeight)
                HStack(spacing: layout.keySpacing) {
                    modifierKey(.shift, title: "Shift", image: "shift", label: "Shift modifier")
                        .frame(width: layout.sideKeyWidth(characterCount: showsSymbols ? 6 : 7))
                    ForEach(
                        Array(showsSymbols ? ".,?!'`" : "zxcvbnm"), id: \.self
                    ) { @Sendable character in
                        MainActorContent { characterKey(character) }
                            .frame(width: layout.characterWidth)
                    }
                    TerminalBackspaceButton(usesSymbol: true) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        send(.backspace)
                    }
                    .frame(width: layout.sideKeyWidth(characterCount: showsSymbols ? 6 : 7))
                    .frame(maxHeight: .infinity)
                    .disabled(!isEnabled)
                    .opacity(isEnabled ? 1 : 0.45)
                }
                .frame(height: layout.rowHeight)
                HStack(spacing: layout.keySpacing) {
                    modifierKey(.control, title: "Ctrl", label: "Control modifier")
                        .frame(width: layout.bottomKeyWidth)
                    modifierKey(.option, title: "Alt", label: "Option modifier")
                        .frame(width: layout.bottomKeyWidth)
                    TerminalKeyboardKeyCap(
                        title: "Fn", label: "Function key layer", isEnabled: isEnabled,
                        isSelected: showsFunctionKeys
                    ) { showsFunctionKeys.toggle() }
                    .frame(width: layout.bottomKeyWidth)
                    TerminalKeyboardKeyCap(
                        title: showsSymbols ? "ABC" : "#+=", label: "Symbol key layer",
                        isEnabled: isEnabled, isSelected: showsSymbols
                    ) { showsSymbols.toggle() }
                    .frame(width: layout.bottomKeyWidth)
                    characterKey(" ", title: "Space")
                        .frame(width: layout.spaceWidth)
                    key(.left)
                        .frame(width: layout.bottomKeyWidth)
                    key(.down)
                        .frame(width: layout.bottomKeyWidth)
                    key(.up)
                        .frame(width: layout.bottomKeyWidth)
                    key(.right)
                        .frame(width: layout.bottomKeyWidth)
                    key(.enter, image: "return")
                        .frame(width: layout.bottomKeyWidth)
                }
                .frame(height: layout.rowHeight)
            }
            .padding(.horizontal, layout.horizontalInset)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    private func utilityRow(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            key(.escape)
            if showsFunctionKeys {
                ForEach(
                    Array(TerminalFunctionKey.allCases.prefix(6)), id: \.self
                ) { @Sendable function in
                    MainActorContent { key(.function(function)) }
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
    private func numberRow(layout: TerminalFullKeyboardLayout) -> some View {
        if showsFunctionKeys {
            HStack(spacing: layout.keySpacing) {
                key(.tab)
                ForEach(
                    Array(TerminalFunctionKey.allCases.suffix(6)), id: \.self
                ) { @Sendable function in
                    MainActorContent { key(.function(function)) }
                }
            }
        } else {
            characterRow("1234567890", layout: layout)
        }
    }

    private func characterRow(_ characters: String, layout: TerminalFullKeyboardLayout) -> some View {
        HStack(spacing: layout.keySpacing) {
            ForEach(Array(characters), id: \.self) { @Sendable character in
                MainActorContent { characterKey(character) }
                    .frame(width: layout.characterWidth)
            }
        }
    }

    private func characterKey(_ character: Character, title: String? = nil) -> some View {
        TerminalKeyboardKeyCap(
            title: title ?? modifiers.characterText(character).uppercased(),
            label: character == " " ? "Space" : modifiers.characterText(character),
            isEnabled: isEnabled,
            fontSize: title == nil ? 15 : 13
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
    var fontSize: CGFloat = 13
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
            .font(.system(size: fontSize, weight: .medium))
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
