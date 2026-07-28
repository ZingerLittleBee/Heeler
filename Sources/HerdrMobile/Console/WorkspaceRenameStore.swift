import Foundation
import Observation

/// The workspace rename form logic (#98). The new label lands in the Console
/// through the store's normal snapshot/delta machinery; this store only fires
/// the RPC and reports its outcome, and the sheet dismisses on `.renamed`.
///
/// Kept off the SSH types (standing repo rule): it talks to an injected
/// closure over the `ConsoleStore`, so it is testable against a scripted
/// transport.
@MainActor
@Observable
final class WorkspaceRenameStore {
    enum State: Equatable {
        /// Editing the form; no rename in flight.
        case editing
        /// A rename RPC is in flight.
        case renaming
        /// The last rename failed; the message is user-facing.
        case failed(String)
        /// The rename succeeded; the sheet dismisses.
        case renamed
    }

    /// The user's input, prefilled with the current label.
    var input: String

    private(set) var state: State = .editing

    private let rename: (String) async throws -> Void
    /// In-flight guard flipped synchronously before the first await, so a
    /// double-tap cannot fire the rename twice through the window before
    /// `state == .renaming` disables the button (mirrors #12/#13).
    private var isRenaming = false

    init(
        currentLabel: String,
        rename: @escaping (String) async throws -> Void
    ) {
        self.input = currentLabel
        self.rename = rename
    }

    /// What a submit sends: the trimmed input. Empty labels are withheld
    /// client-side because silently blanking the Console grouping label is
    /// only ever a mistake from a phone keyboard.
    var submittedValue: String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var canSubmit: Bool {
        state != .renaming && submittedValue != nil
    }

    /// Whether the sheet may be dismissed without abandoning an in-flight
    /// rename whose server-side outcome may already be committed.
    var canDismiss: Bool {
        state != .renaming
    }

    /// Fires the rename. Invalid forms are ignored; on success the state
    /// flips to `.renamed` for the sheet to dismiss.
    func submit() async {
        guard !isRenaming, canSubmit, let submittedValue else { return }
        isRenaming = true
        state = .renaming
        defer { isRenaming = false }
        do {
            try await rename(submittedValue)
            state = .renamed
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case TransportError.sshUnreachable:
            "The Host is not connected."
        case TransportError.timedOut:
            "The Host did not answer in time."
        case let apiError as HerdrAPIError:
            "herdr rejected the rename: \(apiError.message)"
        default:
            "The rename failed: \(error)"
        }
    }
}
