import Foundation

extension ComposerDeliveryPolicy {
    /// Chat's delivery (ADR 0024). Text the rules refuse stays a draft.
    /// Otherwise the Agent's screen is read first, and the message goes only
    /// into an input box read as empty; a second read `DeliveryCheck.delay`
    /// after `agent.prompt` tells whether Enter took it. Both reads go
    /// through `agent.read`, on herdr-core an observing attach's paint, and a
    /// Blocked Agent refuses: nothing here touches the Attach PTY. `sendConcern` gets the text as sent and the
    /// screen the input box passed on, and may hold the message for what
    /// Chat knows beyond the box; nothing is awaited between them.
    /// `willReadScreen` runs just before the first read, once the Agent is
    /// not Blocked: Chat registers the send there, so a send witness's mark
    /// is on its way before `agent.read` rather than after it.
    ///
    /// `confirmSession`, for a program that can leave its conversation
    /// without herdr reporting it (`ChatProgram.confirmsSessionBeforeSend`),
    /// and for any on herdr-core (`AgentChatStore.confirmsSessionBeforeSend`),
    /// runs before `willReadScreen` and the screen read: why the message
    /// would land outside the conversation Chat shows, or nil to go on.
    /// A reported Working holds a program Chat never sends to during a turn
    /// (`ChatProgram.inputBoxWhileWorking`) before either, as Blocked does, and
    /// so does `heldSession`: the refusal Chat already knows `confirmSession`
    /// would give (`AgentChatStore.sessionRefusalBeforeCheck`).
    static func chat(
        rules: ChatSendRules,
        activity: @escaping @MainActor () -> ChatAgentActivity,
        readScreen: @escaping @MainActor () async throws -> ANSIScreen,
        confirmSession: (@MainActor () async -> String?)? = nil,
        heldSession: (@MainActor () -> String?)? = nil,
        sendConcern: @escaping @MainActor (_ outgoing: String, _ screen: ANSIScreen) -> String? = { _, _ in nil },
        willReadScreen: @escaping @MainActor () -> Void = {},
        conversation: (@MainActor () -> Int)? = nil,
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) -> ComposerDeliveryPolicy {
        let program = rules.program
        var policy = ComposerDeliveryPolicy(
            route: .chat,
            insertsIntoAttachWhenBlocked: false,
            outgoingText: { rules.outgoingText($0) },
            validate: { rules.validate($0) },
            preflight: { text in
                let reported = activity()
                if reported == .blocked { return .agentBlocked }
                // The screen would hold too, but on herdr-core the session
                // check's exec and the read's first paint come first, and
                // the echo showed Sending until they ended. Returning before
                // any await takes it back before it renders. A report that
                // lags the turn's end costs a hold the next status ends.
                if reported == .working, let working = program.inputBoxWhileWorking {
                    return .inputNotReady(working.holdReason(for: program))
                }
                // The same for a herdr-core Chat that can't tell, whose
                // Can't Tell page gave way to Sending through the exec.
                if let reason = heldSession?() { return .inputNotReady(reason) }
                if let confirmSession, let reason = await confirmSession() { return .inputNotReady(reason) }
                willReadScreen()
                let screen: ANSIScreen
                do {
                    screen = try await readScreen()
                } catch {
                    return .inputNotReady(Self.unreadableScreenReason(error))
                }
                switch PreSendGate.check(screen, program: program, activity: activity()) {
                case .send:
                    return sendConcern(rules.outgoingText(text), screen).map { .inputNotReady($0) }
                case .holdBlocked: return .agentBlocked
                case .hold(let state): return .inputNotReady(state.holdReason(for: program))
                }
            },
            verify: { sent in
                await pause(DeliveryCheck.delay)
                // A screen that cannot be read says nothing; the message
                // stays marked as sent.
                guard let screen = try? await readScreen() else { return true }
                if case .notDelivered = DeliveryCheck.verdict(
                    screen, program: program, activity: activity(), sent: sent)
                {
                    return false
                }
                return true
            })
        policy.conversation = conversation
        return policy
    }

    private static func unreadableScreenReason(_ error: any Error) -> String {
        guard let error = error as? TransportError else {
            return String(localized: "Heeler couldn't check the Agent's input box.")
        }
        // The explanation follows as each language joins sentences.
        return String(localized: "Heeler couldn't check the Agent's input box. \(error.presentation.explanation)")
    }
}

extension InputBoxState {
    /// Why Chat holds a message while the input box reads this way. Every
    /// case is one the terminal can resolve.
    func holdReason(for program: ChatProgram) -> String {
        switch self {
        case .empty:
            String(localized: "The Agent's input box is ready.")
        case .text:
            switch program {
            case .claude:
                String(localized: "The Agent's input box already has text. Send or clear it in the terminal first.")
            case .codex:
                // Codex 0.162.1's Esc puts follow-ups queued with Tab back
                // in the box.
                String(localized: "The Agent's input box already has text, such as a draft or a message Stop returned. Send or clear it in the terminal first.")
            case .pi, .omp:
                // Their Esc returns steers the turn has not taken to the
                // box, but the text may as well be a draft typed there.
                String(localized: "The Agent's input box already has text, such as a draft or a steer that Stop returned. Send or clear it in the terminal first.")
            case .grok:
                // Ctrl+C before the first output puts the turn's prompt back
                // in the box.
                String(localized: "Grok Build's input box already has text, such as a draft or a message Stop put back. Send or clear it in the terminal first.")
            case .opencode:
                // OpenCode's `/undo` puts the undone prompt back in the box,
                // and Up recalls an earlier one.
                String(localized: "The Agent's input box already has text, such as a draft, a prompt /undo put back, or one recalled with Up. Send or clear it in the terminal first.")
            case .agy:
                // Esc puts a message queued during the turn back in the box
                // (Antigravity CLI 1.5.3).
                String(localized: "Antigravity CLI's input box already has text, such as a draft or a queued message Stop put back. Send or clear it in the terminal first.")
            }
        case .shellMode:
            String(localized: "The Agent's input box is in shell mode. Leave it in the terminal first.")
        case .disabled(let explanation):
            String(localized: "The Agent isn't taking messages: \(explanation)")
        case .overlay:
            String(localized: "A menu is open over the Agent's input box. Close it in the terminal first.")
        case .dialog(let title):
            if program == .codex, title == CodexPlanPrompt.title {
                String(localized: "Codex is asking whether to implement the plan. Answer it in the terminal first.")
            } else {
                String(localized: "The Agent is showing a dialog. Answer it in the terminal first.")
            }
        case .noComposer(let reason):
            reason
        case .unknown:
            String(localized: "Heeler can't find the Agent's input box on screen.")
        }
    }
}
