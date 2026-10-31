import SwiftUI

/// SwiftUI's handle on `ChatTimelineController`.
struct ChatTimelineView: UIViewControllerRepresentable {
    let state: ChatTimelineState
    /// Incremented by Jump to Latest.
    let jumpRequest: Int
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
    /// Chat's own text size; nil follows the system's.
    var textSize: DynamicTypeSize?
    var font: ChatFontOption = .system
    let actions: ChatTimelineActions

    func makeCoordinator() -> Coordinator {
        Coordinator(jumpRequest: jumpRequest, followRequest: followRequest, collapseRequest: collapseRequest)
    }

    func makeUIViewController(context: Context) -> ChatTimelineController {
        let controller = ChatTimelineController(actions: actions)
        controller.setTypography(size: textSize, font: font)
        controller.setTopObstruction(topObstruction)
        bottomEdge.controller = controller
        controller.setCollapseControlClearance(collapseControlClearance)
        controller.apply(state)
        return controller
    }

    func updateUIViewController(_ controller: ChatTimelineController, context: Context) {
        controller.actions = actions
        controller.setTypography(size: textSize, font: font)
        controller.setTopObstruction(topObstruction)
        bottomEdge.controller = controller
        controller.setCollapseControlClearance(collapseControlClearance)
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
        if coordinator.collapseRequest != collapseRequest {
            coordinator.collapseRequest = collapseRequest
            controller.collapseCurrentTrajectory()
        }
    }

    @MainActor
    final class Coordinator {
        var jumpRequest: Int
        var followRequest: Int
        var collapseRequest: Int

        init(jumpRequest: Int, followRequest: Int, collapseRequest: Int) {
            self.jumpRequest = jumpRequest
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

/// Back to the newest row, shown while the reader is scrolled away from it.
/// Always mounted so showing it never moves anything else.
struct ChatJumpToLatestButton: View {
    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChatFloatingIcon(systemImage: "chevron.down")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to Latest")
        .accessibilityIdentifier("chat.jump-to-latest")
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .animation(.easeOut(duration: 0.15), value: isVisible)
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
