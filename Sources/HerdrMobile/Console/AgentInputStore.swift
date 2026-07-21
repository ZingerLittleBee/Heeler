import Foundation
import Observation

/// A quick-key on the Agent detail input bar: a labeled shortcut mapped to
/// the `pane.send_keys` spelling herdr expects. The set covers answering a
/// Blocked agent without a full keyboard — submit, dismiss, interrupt,
/// navigate a menu, and the common yes/no prompt (#10).
///
/// The spellings were verified empirically against herdr 0.7.4: herdr's key
/// parser accepts `enter`, `esc`, `ctrl+c`, `up`/`down`/`left`/`right`, `y`,
/// `n`, and rejects near-misses like `ctrl-c` with an `invalid_key` error —
/// so these strings are load-bearing, not cosmetic.
enum QuickKey: String, CaseIterable, Identifiable, Sendable {
    case enter
    case escape
    case interrupt
    case up
    case down
    case left
    case right
    case yes
    case no

    var id: String { rawValue }

    /// The herdr `pane.send_keys` key sequence this shortcut sends.
    var keys: [String] {
        switch self {
        case .enter: ["enter"]
        case .escape: ["esc"]
        case .interrupt: ["ctrl+c"]
        case .up: ["up"]
        case .down: ["down"]
        case .left: ["left"]
        case .right: ["right"]
        case .yes: ["y"]
        case .no: ["n"]
        }
    }

    /// Short label for the button; nil when an SF Symbol carries it instead.
    var label: String? {
        switch self {
        case .enter: "Enter"
        case .escape: "Esc"
        case .interrupt: "Ctrl-C"
        case .up, .down, .left, .right: nil
        case .yes: "y"
        case .no: "n"
        }
    }

    /// SF Symbol for the arrow keys; nil when a text label carries it.
    var systemImage: String? {
        switch self {
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        default: nil
        }
    }
}

/// The Agent detail screen's input pipeline (#10): a message box that sends
/// typed replies and Enter atomically via `pane.send_input`, and a quick-key
/// bar that sends control keys via `pane.send_keys`. This is the User Story
/// 6 surface — answering a Blocked agent from native controls, never entering
/// Attach.
///
/// Kept separate from `ObserveTerminalStore`, which is deliberately read-only
/// (CONTEXT.md): Observe never sends input, so the send path lives here.
/// Sends are one-shot RPCs on the transport's bounded request queue; the
/// store only tracks the last outcome so the UI can surface a failure.
@MainActor
@Observable
final class AgentInputStore {
    enum SendState: Equatable {
        /// No send in flight; the last one (if any) succeeded.
        case idle
        /// An RPC is in flight.
        case sending
        /// The last send failed; the message is user-facing.
        case failed(String)
    }

    /// The message box's text, bound to the field.
    var draft: String = ""
    /// Caret position within `draft` as a character offset, mirrored from the
    /// message box's text selection so Dictation inserts at the cursor (#37).
    /// `nil` when the field isn't focused / the selection is unknown, which
    /// composes at the end.
    var cursorOffset: Int?
    private(set) var state: SendState = .idle

    /// Draft-send in-flight guard, flipped synchronously before the first
    /// await so a rapid double-tap cannot send the same reply twice: the
    /// button's `state == .sending` disable only latches after the transport
    /// hop, leaving a window the second tap slips through.
    private var isSendingDraft = false
    /// One FIFO for draft and quick-key RPCs. Separate fire-and-forget Tasks
    /// can otherwise overtake each other before the transport's request queue
    /// sees them, making rapid navigation keys arrive out of tap order.
    private var pendingSend: PendingSend?
    private var nextSendID: UInt64 = 0

    /// The Agent's pane id — the target for both `pane.send_input` and
    /// `pane.send_keys`.
    private let target: String
    /// The Host's current transport, re-queried per send: the events session
    /// underneath may have reconnected onto a fresh one (mirrors
    /// `ObserveTerminalStore`).
    private let transport: @Sendable () async -> (any Transport)?

    init(target: String, transport: @escaping @Sendable () async -> (any Transport)?) {
        self.target = target
        self.transport = transport
    }

    /// Whether the message box has anything worth sending.
    var canSendDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Writes the composed message and presses Enter in one RPC, clearing the
    /// box on success. Whitespace-only drafts are ignored.
    func sendDraft() async {
        _ = await queueDraft()?.value
    }

    /// Synchronous UI entry point: records the draft in the FIFO during the
    /// button callback, before a later tap can overtake a newly spawned Task.
    func submitDraft() {
        _ = queueDraft()
    }

    private func queueDraft() -> Task<Bool, Never>? {
        guard !isSendingDraft else { return nil }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        isSendingDraft = true
        return enqueue { [self] in
            defer { isSendingDraft = false }
            let sent = await run { transport in
                try await transport.sendInput(
                    PaneSendInputParams(paneID: target, keys: ["enter"], text: text))
            }
            // Do not erase a follow-up the user typed while this RPC was in
            // flight; only clear the exact draft that succeeded.
            if sent, draft.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                draft = ""
            }
            return sent
        }
    }

    /// Sends one quick-key's key sequence via `pane.send_keys`.
    func send(_ key: QuickKey) async {
        _ = await queue(key).value
    }

    /// Synchronous UI entry point preserving callback order exactly.
    func queue(_ key: QuickKey) -> Task<Bool, Never> {
        enqueue { [self] in
            await run { transport in
                try await transport.sendKeys(PaneSendKeysParams(keys: key.keys, paneID: target))
            }
        }
    }

    private func enqueue(
        _ action: @escaping @MainActor @Sendable () async -> Bool
    ) -> Task<Bool, Never> {
        let previous = pendingSend?.task
        nextSendID &+= 1
        let id = nextSendID
        let task = Task { @MainActor in
            _ = await previous?.value
            let result = await action()
            if pendingSend?.id == id {
                pendingSend = nil
            }
            return result
        }
        pendingSend = PendingSend(id: id, task: task)
        return task
    }

    /// Resolves the transport, runs one send under the `.sending` state, and
    /// maps failures onto a user-facing message. Returns whether it
    /// succeeded.
    private func run(_ action: (any Transport) async throws -> Void) async -> Bool {
        guard let transport = await transport() else {
            state = .failed("The Host is not connected.")
            return false
        }
        state = .sending
        do {
            try await action(transport)
            state = .idle
            return true
        } catch {
            state = .failed(Self.message(for: error))
            return false
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case TransportError.timedOut:
            "The Host did not answer in time."
        case let apiError as HerdrAPIError:
            "herdr rejected the input: \(apiError.message)"
        default:
            "Sending failed: \(error)"
        }
    }

    private struct PendingSend {
        let id: UInt64
        let task: Task<Bool, Never>
    }
}
