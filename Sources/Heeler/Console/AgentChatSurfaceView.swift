import SwiftUI

/// Agent detail's Chat surface (ADR 0020): the Agent's conversation, read
/// from the transcript its own program writes, in place of the terminal.
/// It never types into the Agent's PTY; the terminal stays retained per
/// ADR 0017 while Chat shows.
struct AgentChatSurfaceView: View {
    let agent: ConsoleAgent
    let program: ChatProgram
    /// Swaps the detail back to the Agent terminal.
    let selectSurface: (AgentDetailSurface) -> Void
    @Environment(\.detailCrossfade) private var detailCrossfade

    var body: some View {
        ContentUnavailableView {
            Label("Chat", systemImage: AgentDetailSurface.chat.showSystemImage)
        } actions: {
            Button(AgentDetailSurface.terminal.showTitle) { selectSurface(.terminal) }
        }
        .onAppear { detailCrossfade?.contentDidAppear() }
    }
}
