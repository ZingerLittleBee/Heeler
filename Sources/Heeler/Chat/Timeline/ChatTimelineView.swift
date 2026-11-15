import SwiftUI
import UIKit

/// SwiftUI's handle on `ChatTimelineController`.
struct ChatTimelineView: UIViewControllerRepresentable {
    let state: ChatTimelineState
    /// Incremented by Jump to Latest (long-press `↓`).
    let jumpRequest: Int
    /// Incremented by Earlier Message (tap `↑`).
    var previousMessageRequest: Int = 0
    /// Incremented by Newer Message (tap `↓`).
    var nextMessageRequest: Int = 0
    /// Incremented by Jump to Top (long-press `↑`).
    var topJumpRequest: Int = 0
    /// Incremented after a send: follow the newest row again, unanimated.
    let followRequest: Int
    /// Incremented by the floating Collapse Steps button.
    var collapseRequest: Int = 0
    /// Height of the chrome floating over the list's top edge.
    var topObstruction: CGFloat = 0
    /// Where the chrome floating over the list's bottom edge begins. Through
    /// a relay, since it changes on every frame of the keyboard's motion.
    var bottomEdge = ChatTimelineBottomEdge()
    /// Height of the Collapse Steps button over the list's bottom edge.
    var collapseControlClearance: CGFloat = 0
    /// Height of the Earlier Message button at the end of the list.
    var jumpControlClearance: CGFloat = 0
    /// Room at the trailing edge rows end short of, for chrome floating
    /// over it; the list still runs to the edge.
    var trailingReserve: CGFloat = 0
    /// Chat's own text size; nil follows the system's.
    var textSize: DynamicTypeSize?
    var font: ChatFontOption = .system
    /// A placeholder covers the list. SwiftUI's `accessibilityHidden` on
    /// this view leaves the collection view's rows in the accessibility
    /// tree, rows the screen doesn't show. (A refused Send's "Sending…"
    /// that stayed in UI tests' tree under the placeholder was a cell UIKit
    /// kept for reuse: `ChatTimelineController` empties those.)
    var hidesFromAccessibility = false
    let actions: ChatTimelineActions

    func makeCoordinator() -> Coordinator {
        Coordinator(
            jumpRequest: jumpRequest, previousMessageRequest: previousMessageRequest,
            nextMessageRequest: nextMessageRequest, topJumpRequest: topJumpRequest,
            followRequest: followRequest, collapseRequest: collapseRequest)
    }

    func makeUIViewController(context: Context) -> ChatTimelineController {
        let controller = ChatTimelineController(actions: actions)
        controller.setTypography(size: textSize, font: font)
        controller.setTopObstruction(topObstruction)
        bottomEdge.controller = controller
        controller.setCollapseControlClearance(collapseControlClearance)
        controller.setJumpControlClearance(jumpControlClearance)
        controller.setTrailingReserve(trailingReserve)
        controller.view.accessibilityElementsHidden = hidesFromAccessibility
        controller.apply(state)
        return controller
    }

    func updateUIViewController(_ controller: ChatTimelineController, context: Context) {
        controller.actions = actions
        controller.setTypography(size: textSize, font: font)
        controller.setTopObstruction(topObstruction)
        bottomEdge.controller = controller
        controller.setCollapseControlClearance(collapseControlClearance)
        controller.setJumpControlClearance(jumpControlClearance)
        controller.setTrailingReserve(trailingReserve)
        controller.view.accessibilityElementsHidden = hidesFromAccessibility
        controller.apply(state)
        let coordinator = context.coordinator
        if coordinator.followRequest != followRequest {
            coordinator.followRequest = followRequest
            controller.followLatest()
        }
        if coordinator.jumpRequest != jumpRequest {
            coordinator.jumpRequest = jumpRequest
            controller.jumpToLatest()
        }
        if coordinator.topJumpRequest != topJumpRequest {
            coordinator.topJumpRequest = topJumpRequest
            controller.jumpToTop()
        }
        if coordinator.previousMessageRequest != previousMessageRequest {
            coordinator.previousMessageRequest = previousMessageRequest
            controller.jumpToPreviousUserMessage()
        }
        if coordinator.nextMessageRequest != nextMessageRequest {
            coordinator.nextMessageRequest = nextMessageRequest
            controller.jumpToNextUserMessage()
        }
        if coordinator.collapseRequest != collapseRequest {
            coordinator.collapseRequest = collapseRequest
            controller.collapseCurrentTrajectory()
        }
    }

    @MainActor
    final class Coordinator {
        var jumpRequest: Int
        var previousMessageRequest: Int
        var nextMessageRequest: Int
        var topJumpRequest: Int
        var followRequest: Int
        var collapseRequest: Int

        init(
            jumpRequest: Int, previousMessageRequest: Int, nextMessageRequest: Int,
            topJumpRequest: Int, followRequest: Int, collapseRequest: Int
        ) {
            self.jumpRequest = jumpRequest
            self.previousMessageRequest = previousMessageRequest
            self.nextMessageRequest = nextMessageRequest
            self.topJumpRequest = topJumpRequest
            self.followRequest = followRequest
            self.collapseRequest = collapseRequest
        }
    }
}

/// Stays reachable while the reader is deep inside expanded steps.
struct ChatCollapseTrajectoryButton: View {
    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Arrows closing on a line: the steps fold into the summary.
            ChatFloatingIcon(systemImage: "arrow.down.and.line.horizontal.and.arrow.up")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Collapse Current Trajectory")
        .accessibilityHint("Collapses this turn's reasoning and tool details and brings its summary into view.")
        .accessibilityIdentifier("chat.collapse-trajectory")
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .animation(.easeOut(duration: 0.15), value: isVisible)
    }
}

/// Adaptive vertical Liquid Glass capsule for stepping between user messages
/// (tap `↑` / `↓`) and jumping straight to the top or bottom (long-press `↑` / `↓`).
///
/// Shrinks to a single circle when only one direction applies, and stays
/// mounted when hidden so showing it never moves neighboring controls.
struct ChatMessageJumpControl: View {
    private struct StateSnapshot: Equatable {
        var showsPrevious: Bool
        var showsLatest: Bool
    }

    let showsPrevious: Bool
    let showsLatest: Bool
    let jumpPrevious: () -> Void
    let jumpTop: () -> Void
    let jumpNext: () -> Void
    let jumpLatest: () -> Void

    @State private var lastSingleIcon = "chevron.down"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isVisible: Bool { showsPrevious || showsLatest }
    private var showsBoth: Bool { showsPrevious && showsLatest }

    var body: some View {
        VStack(spacing: 0) {
            if showsPrevious {
                ChatJumpSegmentButton(
                    systemImage: "chevron.up",
                    topHitPadding: Self.hitInset,
                    bottomHitPadding: showsBoth ? 0 : Self.hitInset,
                    onTap: jumpPrevious,
                    onLongPress: jumpTop
                )
                .accessibilityLabel("Earlier message")
                .accessibilityHint("Scrolls the Agent to the previous message you sent")
                .accessibilityAction(named: "Jump to Top", jumpTop)
                .accessibilityIdentifier("chat.jump-to-previous-message")
            }
            if showsBoth {
                Rectangle()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: 16, height: 1)
                    .frame(width: AgentDetailHeader.controlSize, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if showsLatest {
                ChatJumpSegmentButton(
                    systemImage: "chevron.down",
                    topHitPadding: showsBoth ? 0 : Self.hitInset,
                    bottomHitPadding: Self.hitInset,
                    onTap: jumpNext,
                    onLongPress: jumpLatest
                )
                .accessibilityLabel("Newer message")
                .accessibilityHint("Scrolls the Agent to the next message you sent, then back to live output")
                .accessibilityAction(named: "Jump to Latest", jumpLatest)
                .accessibilityIdentifier("chat.jump-to-latest")
            }
            if !isVisible {
                Image(systemName: lastSingleIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: ChatFloatingIcon.diameter, height: ChatFloatingIcon.diameter)
                    .frame(width: AgentDetailHeader.controlSize, height: AgentDetailHeader.controlSize)
            }
        }
        .background {
            Color.clear
                .headerGlass(in: .capsule, opacity: ChatFloatingIcon.glassOpacity)
                .padding(Self.hitInset)
                .allowsHitTesting(false)
        }
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.2),
            value: StateSnapshot(showsPrevious: showsPrevious, showsLatest: showsLatest))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isVisible)
        .onChange(of: showsPrevious, initial: true) { _, isShown in
            if isShown, !showsLatest { lastSingleIcon = "chevron.up" }
        }
        .onChange(of: showsLatest, initial: true) { _, isShown in
            if isShown, !showsPrevious { lastSingleIcon = "chevron.down" }
        }
    }

    /// How far the touch target reaches past the visible glass capsule on
    /// each side.
    static var hitInset: CGFloat {
        max(0, (AgentDetailHeader.controlSize - ChatFloatingIcon.diameter) / 2)
    }
}

private struct ChatJumpSegmentButton: View {
    private static let longPressDuration: TimeInterval = 0.35

    let systemImage: String
    let topHitPadding: CGFloat
    let bottomHitPadding: CGFloat
    let onTap: () -> Void
    let onLongPress: () -> Void

    @GestureState private var isHoldingLongPress = false
    @State private var suppressTapUntil: ContinuousClock.Instant?

    var body: some View {
        Button {
            if isHoldingLongPress { return }
            if let until = suppressTapUntil, ContinuousClock.now < until {
                suppressTapUntil = nil
                return
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onTap()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .buttonStyle(
            ChatJumpSegmentButtonStyle(
                topHitPadding: topHitPadding,
                bottomHitPadding: bottomHitPadding))
        .hoverEffect(.highlight)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: Self.longPressDuration)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .updating($isHoldingLongPress) { value, state, _ in
                    if case .second(true, _) = value { state = true }
                })
        .onChange(of: isHoldingLongPress) { wasHolding, isHolding in
            if !wasHolding, isHolding {
                suppressTapUntil = .now + .seconds(10)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onLongPress()
            } else if wasHolding, !isHolding {
                suppressTapUntil = .now + .milliseconds(250)
            }
        }
    }
}

private struct ChatJumpSegmentButtonStyle: ButtonStyle {
    let topHitPadding: CGFloat
    let bottomHitPadding: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: ChatFloatingIcon.diameter, height: ChatFloatingIcon.diameter)
            .background {
                Circle()
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0))
                    .padding(2)
            }
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .padding(.top, topHitPadding)
            .padding(.bottom, bottomHitPadding)
            .frame(width: AgentDetailHeader.controlSize)
            .contentShape(.rect)
    }
}

/// A glyph for Chat's floating buttons: a circle on the detail header's
/// glass, held a little more solid where it floats over the conversation's
/// text, and smaller than the header's controls so it hides less of it.
/// Taps still land anywhere in a control-sized square around it.
private struct ChatFloatingIcon: View {
    static let glassOpacity: Double = 0.9
    static let diameter: CGFloat = 36

    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: Self.diameter, height: Self.diameter)
            .headerGlass(in: .circle, opacity: Self.glassOpacity)
            .frame(width: AgentDetailHeader.controlSize, height: AgentDetailHeader.controlSize)
            .contentShape(.rect)
    }
}

/// Hands the list where the bottom chrome begins without invalidating any
/// view: the surface around the list would otherwise re-evaluate on every frame
/// of the keyboard's motion, which holds the motion to about 20Hz.
@MainActor
final class ChatTimelineBottomEdge {
    weak var controller: ChatTimelineController? {
        didSet { apply() }
    }
    private var edge: CGFloat?
    private var keyboardLift: CGFloat = 0
    private var keyboardIsFalling = false

    func update(edge: CGFloat?, keyboardLift: CGFloat, keyboardIsFalling: Bool) {
        self.edge = edge
        self.keyboardLift = keyboardLift
        self.keyboardIsFalling = keyboardIsFalling
        apply()
    }

    private func apply() {
        controller?.setBottomEdge(edge, keyboardLift: keyboardLift, keyboardIsFalling: keyboardIsFalling)
    }
}
