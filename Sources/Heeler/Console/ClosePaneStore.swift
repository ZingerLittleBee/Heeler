import Foundation
import Observation

/// The Agent detail screen's close-pane action (#13, User Story 9): closing a
/// Pane is destructive — a Done agent must not be destroyed by a stray tap —
/// so the UI gates the RPC behind an explicit confirmation dialog and this
/// store fires the close only after the user confirms. The closed pane
/// disappears from the Console through its normal snapshot/delta machinery,
/// so this store only fires the RPC and reports its outcome; the screen
/// dismisses itself on `.closed`.
///
/// Kept off the SSH types (standing repo rule): it talks to an injected
/// closure over the `ConsoleStore`, so it is testable against a scripted
/// transport. The Console row's swipe-to-close is gated behind its own
/// confirmation as well.
@MainActor
@Observable
final class ClosePaneStore {
    enum State: Equatable {
        /// No close in flight; the pane is untouched (the cancel path stays
        /// here).
        case idle
        /// A close is in flight.
        case closing
        /// The last close failed; the message is user-facing. The pane is left
        /// untouched, unless the message says the Host did not confirm.
        case failed(String)
        /// The close succeeded; the screen dismisses.
        case closed
    }

    private(set) var state: State = .idle

    /// The Agent's display name, for the confirmation dialog's message so the
    /// user sees exactly which agent they are about to destroy.
    let paneTitle: String

    private let close: () async throws -> Void
    /// In-flight guard flipped synchronously before the first await, so a
    /// double-tap cannot fire the close twice through the window before
    /// `state == .closing` disables the button (mirrors #10/#12).
    private var isClosing = false
    /// Set while the screen is away, where a failure's alert would reach nobody.
    private var reportAfterLeaving: ((String) -> Void)?

    init(paneTitle: String, close: @escaping () async throws -> Void) {
        self.paneTitle = paneTitle
        self.close = close
    }

    /// Fires the close after the user confirms. On success the state flips
    /// to `.closed` for the screen to dismiss; on failure the error surfaces
    /// and nothing is sent again.
    func confirmClose() async {
        guard !isClosing else { return }
        isClosing = true
        state = .closing
        defer { isClosing = false }
        do {
            try await close()
            state = .closed
        } catch {
            state = .failed(Self.message(for: error))
            handOverFailure()
        }
    }

    /// The screen went away, perhaps with the link and with a failure on it. A
    /// failure from now on goes to `report`; with no `report` it stays here.
    func didLeaveScreen(reportingTo report: ((String) -> Void)?) {
        reportAfterLeaving = report
        handOverFailure()
    }

    func didReturnToScreen() {
        reportAfterLeaving = nil
    }

    /// The user read it.
    func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    private func handOverFailure() {
        guard let reportAfterLeaving, case .failed(let message) = state else { return }
        state = .idle
        reportAfterLeaving(message)
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected."
        case TransportError.timedOut:
            "The Host did not answer in time."
        case TransportError.coreMutationOutcomeUnknown:
            ConsoleStore.closeUnconfirmedMessage
        case let refusal as HerdrCoreCloseRefusal:
            "herdr-core rejected the close: \(refusal.message)"
        case let apiError as HerdrAPIError:
            "herdr rejected the close: \(apiError.message)"
        default:
            TransportError.herdrCoreLinkMessage(for: error)
                ?? "Closing the pane failed: \(error)"
        }
    }
}
