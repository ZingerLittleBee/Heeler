import SwiftUI

/// An iPhone's way back from a pushed Agent, which the edge swipe alone
/// never showed (#396). Separate glass pieces float over the terminal:
/// Back at the leading end, any trailing actions in one capsule, and at the
/// far end a fold button that stays put. The room between them is left to
/// the terminal, and folding leaves only that button, so the header can
/// cover almost no output.
///
/// Trailing actions are plain values rather than views, so a screen can
/// leave out the ones it cannot offer and the capsule goes with the last.
struct AgentDetailHeader: View {
    static let controlSize: CGFloat = 44
    /// How much of the glass shows, the rest letting output through.
    fileprivate static let glassOpacity: Double = 0.75
    /// Buttons sharing the actions capsule sit closer than standalone ones.
    private static let capsuleButtonWidth: CGFloat = 36
    private static let capsuleInset: CGFloat = (controlSize - capsuleButtonWidth) / 2

    let palette: TerminalThemePalette
    @Binding var isExpanded: Bool
    let onBack: () -> Void
    var actions: [AgentDetailHeaderAction] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if isExpanded {
                AgentDetailHeaderButton("Back", systemImage: "chevron.left", action: onBack)
                    .headerGlass(in: .circle)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            Spacer(minLength: 0)
            if isExpanded, !actions.isEmpty {
                HStack(spacing: 0) {
                    ForEach(actions) { action in
                        AgentDetailHeaderButton(
                            action.title, systemImage: action.systemImage,
                            width: Self.capsuleButtonWidth, action: action.perform)
                    }
                }
                .padding(.horizontal, Self.capsuleInset)
                .fixedSize()
                .headerGlass(in: .capsule)
                .transition(
                    .scale(scale: 0.6, anchor: .trailing).combined(with: .opacity))
            }
            foldButton
        }
        .foregroundStyle(palette.foreground)
    }

    /// Stays at the far end in both states.
    private var foldButton: some View {
        AgentDetailHeaderButton(
            isExpanded ? "Hide Header" : "Show Header",
            // A window's top bar, which is what this shows and hides: put
            // away while it is out, filled in while it is folded.
            systemImage: isExpanded
                ? "menubar.arrow.up.rectangle" : "inset.filled.topthird.rectangle"
        ) {
            withAnimation(reduceMotion ? nil : .snappy) {
                isExpanded.toggle()
            }
        }
        .headerGlass(in: .circle)
    }
}

/// One of `AgentDetailHeader`'s trailing buttons.
struct AgentDetailHeaderAction: Identifiable {
    let title: LocalizedStringKey
    let systemImage: String
    let perform: () -> Void

    var id: String { systemImage }
}

/// An icon button inside `AgentDetailHeader`. It has no surface of its own:
/// the header puts Back and the fold button on glass circles, and its
/// trailing actions together on one glass capsule.
struct AgentDetailHeaderButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let width: CGFloat
    let action: () -> Void

    init(
        _ title: LocalizedStringKey, systemImage: String,
        width: CGFloat = AgentDetailHeader.controlSize, action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.width = width
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: width, height: AgentDetailHeader.controlSize)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

extension View {
    /// Liquid Glass where the system has it, a blur before that. The glass
    /// sits behind the icons at part strength, so the output under the
    /// buttons still shows through while the icons stay solid.
    fileprivate func headerGlass(in shape: some Shape) -> some View {
        background {
            Group {
                if #available(iOS 26, *) {
                    Color.clear.glassEffect(.regular, in: shape)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
            .opacity(AgentDetailHeader.glassOpacity)
        }
        .contentShape(shape)
    }
}
