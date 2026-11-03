import SwiftUI
import UIKit

/// The shortcut row shared by Direct Input and the Shell Terminal: scrolling
/// keys with the presentation's trailing items pinned at the edge. Keys go
/// through `sendKey`; each surface supplies its own Paste and More controls
/// through `accessory`, since those act on surface-specific state.
struct InputShortcutStripRow<Accessory: View>: View {
    let strip: InputShortcutStripPresentation
    /// VoiceOver hint for every key cap, naming where the key goes.
    let keyAccessibilityHint: String
    let sendKey: (AgentQuickKey) -> Void
    /// Content for the strip's non-key items (`.paste`, `.more`).
    @ViewBuilder let accessory: (InputShortcutStripItem) -> Accessory
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        scrollingRow
            .frame(height: InputChromeLayout.shortcutRowHeight)
            .background(alignment: .top) {
                Rectangle()
                    .fill(Color(uiColor: .separator))
                    .frame(height: 1 / max(displayScale, 1))
            }
            .background(Color(uiColor: .secondarySystemBackground))
    }

    private var scrollingRow: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(strip.leadingItems, id: \.self) { @Sendable item in
                        MainActorContent { sizedItem(item) }
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 6)
            }

            HStack(spacing: 4) {
                ForEach(strip.trailingItems, id: \.self) { @Sendable item in
                    MainActorContent { sizedItem(item) }
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .background(Color(uiColor: .secondarySystemBackground))
            .overlay(alignment: .leading) {
                LinearGradient(
                    colors: [.clear, Color(uiColor: .separator).opacity(0.7)],
                    startPoint: .leading,
                    endPoint: .trailing)
                    .frame(width: InputChromeLayout.pinnedFadeWidth)
                    .offset(x: -InputChromeLayout.pinnedFadeWidth)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func sizedItem(_ item: InputShortcutStripItem) -> some View {
        itemView(item)
            .frame(
                width: InputChromeLayout.compactWidth(for: item),
                height: InputChromeLayout.shortcutRowHeight)
    }

    @ViewBuilder
    private func itemView(_ item: InputShortcutStripItem) -> some View {
        switch item {
        case .key(let key):
            keyButton(key)
        case .paste, .more:
            accessory(item)
        }
    }

    @ViewBuilder
    private func keyButton(_ key: AgentQuickKey) -> some View {
        if key == .backspace {
            TerminalBackspaceButton(isToolbar: true) { send(key) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Button {
                send(key)
            } label: {
                keyLabel(key).inputShortcutKeyCap()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .buttonStyle(TerminalKeyboardButtonStyle())
            .accessibilityLabel(key.accessibilityLabel)
            .accessibilityHint(keyAccessibilityHint)
        }
    }

    private func send(_ key: AgentQuickKey) {
        UIDevice.current.playInputClick()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        sendKey(key)
    }

    @ViewBuilder
    private func keyLabel(_ key: AgentQuickKey) -> some View {
        if let systemImageName = key.systemImageName {
            Image(systemName: systemImageName)
                .font(.system(size: 12, weight: .semibold))
        } else if let title = key.title {
            Text(title)
                .font(.caption.weight(.medium))
        }
    }
}

extension View {
    /// The shortcut row's key-cap frame, shared with accessories so they
    /// line up with the keys.
    func inputShortcutKeyCap() -> some View {
        frame(maxWidth: .infinity, minHeight: 30)
    }
}
