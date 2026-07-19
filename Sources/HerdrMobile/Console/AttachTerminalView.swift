import SwiftUI

/// The full-screen interactive Attach terminal (#11): SwiftTerm both ways —
/// PTY bytes feed the view; keystrokes from the soft keyboard, SwiftTerm's
/// accessory bar (Esc/Ctrl/Tab/arrows), and iPad hardware keyboards forward
/// to the remote. Geometry changes (rotation, split view, keyboard) ride SSH
/// window-change through the store.
///
/// Presented full-screen over the Agent detail screen, which owns the
/// handover: Observe stops before this appears and resumes after Detach —
/// the two surfaces share the Host's single terminal channel.
struct AttachTerminalView: View {
    let store: AttachTerminalStore
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TerminalScreenView(
                feed: store.feed,
                style: .attach,
                allowsInput: true,
                onSizeChanged: { cols, rows in store.viewDidResize(cols: cols, rows: rows) },
                onSend: { keystrokes in store.send(keystrokes) }
            )
            .overlay { statusOverlay }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Detach") {
                        // Stop before dismissing: the channel must be free
                        // by the time the detail screen resumes Observe.
                        Task {
                            await store.stop()
                            dismiss()
                        }
                    }
                }
            }
            .onDisappear {
                // Backstop for dismissals that bypass Detach (e.g. the
                // presenting screen being torn down takes the cover with it,
                // handler uninvoked): the attach channel must never outlive
                // this surface. Idempotent with the Detach path — a second
                // stop() is a no-op.
                Task { await store.stop() }
            }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch store.status {
        case .waitingForSize, .connecting:
            ProgressView()
        case .ended(let message):
            ContentUnavailableView {
                Label("Session Ended", systemImage: "cable.connector.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Reattach") { store.retry() }
                    .buttonStyle(.borderedProminent)
            }
        case .live, .stopped:
            EmptyView()
        }
    }
}
