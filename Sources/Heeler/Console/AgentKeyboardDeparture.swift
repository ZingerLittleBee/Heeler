import SwiftUI

/// A terminal screen leaving for an Agent's screen with its keyboard up: a
/// Shell Terminal for an Agent its shell started or one picked in its
/// Workspace drawer, and an Agent's terminal for another Agent from its
/// switcher, its drawer or the new-agent sheet.
///
/// An Agent that opens on its terminal takes the keyboard over through the
/// handoff, as Back carries it. Chat may come up with nothing to type into (a
/// trust card, a conversation to choose or still to come), where a Composer
/// that took the keyboard would sit over the page's own buttons. So the
/// keyboard goes down first, on the screen being left, and Chat comes in
/// once UIKit has finished hiding it: a hide still running as the screens
/// change animates the arriving screen's input row, which can leave the
/// window mid-animation, and UIKit never reports that animation ended (UI
/// tests then wait on it until the screen is left). Chat's own switcher and
/// drawer carry the keyboard from one Composer to another and do not come
/// here.
///
/// The screen leaving sets `awaitingHide` before it hides its keyboard, and
/// only when UIKit animates the hide. The screen around it holds
/// `awaitingHide` and this modifier, which completes that departure once the
/// hide is reported done on `notificationCenter`, where the leaving screen's
/// keyboard inset hears the keyboard, or after `agentKeyboardHideLeash`.
/// The leaving screen can go first: the pane a shell starts its Agent in stops
/// being a terminal, and the terminal pool lets it go, often while the
/// keyboard is still going down (#644).
struct AgentKeyboardDeparture<Departure: Equatable>: ViewModifier {
    @Environment(\.agentKeyboardHideLeash) private var keyboardHideLeash
    @Binding var awaitingHide: Departure?
    let notificationCenter: NotificationCenter
    /// Routes as the screen now stands, which may have changed while the
    /// keyboard went down.
    let complete: @MainActor (Departure) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(
                notificationCenter.publisher(for: UIResponder.keyboardDidHideNotification)
            ) { _ in
                finish()
            }
            // A hide something cuts short (another responder taking the
            // keyboard) is never reported done; Chat comes in anyway.
            .task(id: awaitingHide) {
                guard awaitingHide != nil else { return }
                try? await Task.sleep(for: keyboardHideLeash)
                guard !Task.isCancelled else { return }
                finish()
            }
    }

    private func finish() {
        guard let departure = awaitingHide else { return }
        awaitingHide = nil
        complete(departure)
    }
}

extension EnvironmentValues {
    /// How long an Agent's Chat waits for UIKit to report the keyboard gone
    /// before it takes the screen anyway (`AgentKeyboardDeparture`). Tests
    /// lengthen it so only a reported hide brings Chat in.
    @Entry var agentKeyboardHideLeash: Duration = .seconds(1)
}

/// What a screen leaving for an Agent takes from the screen around it: which
/// Agents open on Chat, and where a departure for one of them waits for the
/// keyboard to go down (`AgentKeyboardDeparture`).
struct AgentChatDepartures<Departure: Equatable> {
    let opensOnChat: @MainActor (ConsoleAgent.ID) -> Bool
    let awaitingKeyboardHide: Binding<Departure?>
}
