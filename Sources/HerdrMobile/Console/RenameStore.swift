import Foundation
import Observation

/// The Console rename actions' form logic (#98): one store per presented
/// rename sheet, covering both `agent.rename` and `workspace.rename`. The
/// new name lands in the Console through the store's normal snapshot/delta
/// machinery — this store only fires the RPC and reports its outcome; the
/// sheet dismisses itself on `.renamed`.
///
/// Kept off the SSH types (standing repo rule): it talks to an injected
/// closure over the `ConsoleStore`, so it is testable against a scripted
/// transport.
@MainActor
@Observable
final class RenameStore {
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

    /// What is being renamed; drives validation and the form copy. The rules
    /// mirror what the server enforces, verified live against herdr 0.7.5.
    enum Subject: Equatable {
        /// `agent.rename`: the server requires `^[a-z][a-z0-9_-]{0,31}$`
        /// (rejecting violations with `invalid_agent_name`) and treats an
        /// omitted name as "clear back to the detected kind" — so an empty
        /// input is a valid submit meaning "clear".
        case agent(detectedKind: String)
        /// `workspace.rename`: the server accepts any label, including an
        /// empty one. An empty submit is withheld client-side anyway: it
        /// would silently blank the Console's grouping label, which is only
        /// ever a mistake from a phone keyboard.
        case workspace
    }

    let subject: Subject
    /// The user's input, prefilled with the current name/label.
    var input: String

    private(set) var state: State = .editing

    private let rename: (String?) async throws -> Void
    /// In-flight guard flipped synchronously before the first await, so a
    /// double-tap cannot fire the rename twice through the window before
    /// `state == .renaming` disables the button (mirrors #12/#13).
    private var isRenaming = false

    init(
        subject: Subject,
        currentValue: String,
        rename: @escaping (String?) async throws -> Void
    ) {
        self.subject = subject
        self.input = currentValue
        self.rename = rename
    }

    /// What a submit sends: the trimmed input, with emptiness normalized to
    /// nil (the agent "clear" spelling; unsubmittable for workspaces).
    var submittedValue: String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The form-footer validation error; nil while the input is submittable.
    var validationMessage: String? {
        switch subject {
        case .agent:
            guard let value = submittedValue, !Self.isValidAgentName(value) else {
                return nil
            }
            return "Agent names are 1–32 characters: lowercase letters, "
                + "digits, - or _, starting with a letter."
        case .workspace:
            return nil
        }
    }

    /// The clear-semantics hint for the agent form; nil for workspaces.
    var clearHint: String? {
        guard case .agent(let detectedKind) = subject else { return nil }
        return "Leave empty to fall back to the detected kind (\(detectedKind))."
    }

    var canSubmit: Bool {
        guard state != .renaming, validationMessage == nil else { return false }
        switch subject {
        case .agent:
            return true
        case .workspace:
            return submittedValue != nil
        }
    }

    /// Whether the sheet may be dismissed without abandoning an in-flight
    /// rename whose server-side outcome may already be committed.
    var canDismiss: Bool {
        state != .renaming
    }

    /// Fires the rename. Invalid forms are ignored; on success the state
    /// flips to `.renamed` for the sheet to dismiss.
    func submit() async {
        guard !isRenaming, canSubmit else { return }
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

    /// A workspace rename store whose closure takes the label directly:
    /// `canSubmit` withholds empty workspace submits, so a nil
    /// `submittedValue` can only be a programmer error — surfaced as a
    /// failure here rather than encoded as a silent success by every caller.
    static func workspace(
        currentLabel: String,
        rename: @escaping (String) async throws -> Void
    ) -> RenameStore {
        RenameStore(subject: .workspace, currentValue: currentLabel) { value in
            guard let value else {
                assertionFailure("workspace rename submitted without a label")
                throw TransportError.cancelled
            }
            try await rename(value)
        }
    }

    /// The server's agent-name rule (`invalid_agent_name` otherwise),
    /// mirrored so the form can explain the rule before a round trip:
    /// `^[a-z][a-z0-9_-]{0,31}$`.
    static func isValidAgentName(_ name: String) -> Bool {
        guard name.count <= 32, let first = name.unicodeScalars.first else {
            return false
        }
        guard ("a"..."z").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
                || scalar == "-" || scalar == "_"
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
