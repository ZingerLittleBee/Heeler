import SwiftUI

/// SwiftUI's handle on `ChatTimelineController`.
struct ChatTimelineView: UIViewControllerRepresentable {
    let state: ChatTimelineState
    /// Incremented by Jump to Latest.
    let jumpRequest: Int
    /// Incremented after a send: follow the newest row again, unanimated.
    let followRequest: Int
    /// Height of the chrome floating over the list's top edge.
    var topObstruction: CGFloat = 0
    let actions: ChatTimelineActions

    func makeCoordinator() -> Coordinator {
        Coordinator(jumpRequest: jumpRequest, followRequest: followRequest)
    }

    func makeUIViewController(context: Context) -> ChatTimelineController {
        let controller = ChatTimelineController(actions: actions)
        controller.setTopObstruction(topObstruction)
        controller.apply(state)
        return controller
    }

    func updateUIViewController(_ controller: ChatTimelineController, context: Context) {
        controller.actions = actions
        controller.setTopObstruction(topObstruction)
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
    }

    @MainActor
    final class Coordinator {
        var jumpRequest: Int
        var followRequest: Int

        init(jumpRequest: Int, followRequest: Int) {
            self.jumpRequest = jumpRequest
            self.followRequest = followRequest
        }
    }
}

/// Back to the newest row, shown while the reader is scrolled away from it.
/// Always mounted so showing it never moves anything else.
struct ChatJumpToLatestButton: View {
    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(TerminalFloatingButtonStyle(highlight: .primary))
        .background(TerminalFloatingControlBackground(palette: .system))
        .accessibilityLabel("Jump to Latest")
        .accessibilityIdentifier("chat.jump-to-latest")
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .animation(.easeOut(duration: 0.15), value: isVisible)
    }
}
