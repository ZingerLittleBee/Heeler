import SwiftUI
import UIKit

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
                        TerminalFullKeyboard(
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
                        Button {
                            // A cancelled swipe must never confirm a key press.
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            send(key)
                        } label: {
                            Group {
                                if let image = key.systemImageName {
                                    Image(systemName: image)
                                } else {
                                    Text(key.title ?? "")
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                }
                            }
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .buttonStyle(TerminalKeyboardButtonStyle())
                        .disabled(!isEnabled)
                        .opacity(isEnabled ? 1 : 0.45)
                        .accessibilityLabel(key.accessibilityLabel)
                        .accessibilityHint("Sends this key directly to the Agent")
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
