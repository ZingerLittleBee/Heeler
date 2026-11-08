import Foundation

/// The terminal Composer's Stop on a herdr-core Agent (ADR 0035): one
/// `terminal.interrupt`, in which the core presses the Terminal's own stop key,
/// then a read of the foreground, since the answer does not say whether the
/// program still runs. Heeler presses no key of its own. `.sent` needs a sign that
/// the key left: the core's answer, or a read after it on the link's ordered writer.
@MainActor
struct HerdrCoreComposerStop {
    /// How long the core watches for an effect after pressing the key: up to the
    /// whole of it in a Terminal that never reports.
    static let interruptTimeout: Duration = .seconds(2)
    /// How much longer Stop waits for the core's answer, on a slow link or behind
    /// input the core holds. Past that it cancels the call, and if the call may have
    /// left, reads the foreground without the answer.
    static let answerMargin: Duration = .seconds(1)
    static let readTimeout: Duration = .seconds(5)
    /// How long a cancelled interrupt gets to say how far it went.
    static let cancelWait: Duration = .seconds(1)

    static let notSent = String(localized: "The Host is not connected, so Stop wasn't sent.")
    static let notTakenInTime = String(localized: "The Host did not take Stop in time, so it wasn't sent.")
    static let outcomeUnknown =
        String(localized: "The Host did not answer, so Stop may or may not have reached the Agent. Check the terminal.")
    static let coreGone = TransportError.herdrCoreTerminalGone.presentation.message
    static let readFailed =
        String(localized: "Stop went, but the Host did not say whether the Agent still runs. Check the terminal.")

    let address: String
    let projection: @MainActor () -> HerdrCoreConsoleProjection?
    /// The core the detail's Agent runs on: an address means another Agent on any other.
    let corePin: TerminalCorePin
    let clock: BlockedCardClock

    func perform() async -> AgentInterruptOutcome {
        guard let projection = projection() else { return .failed(Self.notSent) }
        let address = address
        let corePin = corePin
        let call = Task {
            guard projection.admits(corePin) else { throw TransportError.herdrCoreTerminalGone }
            try await projection.interruptTerminal(at: address, timeout: Self.interruptTimeout)
        }
        defer { call.cancel() }
        let wasAnswered: Bool
        switch await interrupt(call) {
        case .answered: wasAnswered = true
        case .unanswered: wasAnswered = false
        case .ended(let outcome): return outcome
        }
        do {
            try await AsyncDeadline.run(for: Self.readTimeout, sleep: clock.sleep) {
                try await projection.readForeground(at: address)
            }
            return .sent
        } catch let refusal as HerdrAPIError where refusal.code == "not_found" {
            return .sent
        } catch {
            // Without either answer, nothing says the key went or the link lasted.
            return .failed(wasAnswered ? Self.readFailed : Self.outcomeUnknown)
        }
    }

    private enum InterruptResult {
        case answered
        /// It may have left, and the deadline passed with no answer: expected, and
        /// the read tells what the answer would not have.
        case unanswered
        case ended(AgentInterruptOutcome)
    }

    /// Past the deadline a cancel settles how far the call went, so the key is never
    /// pressed late. A call with the link's writer or past it throws
    /// `.coreMutationOutcomeUnknown`, and the link stays up for the read. A call
    /// still queued is dropped, and one still waiting for a link, which a cancel does
    /// not end, can no longer write once it gets one.
    private func interrupt(_ call: Task<Void, any Error>) async -> InterruptResult {
        do {
            try await AsyncDeadline.run(
                for: Self.interruptTimeout + Self.answerMargin, sleep: clock.sleep
            ) { try await call.value }
            return .answered
        } catch AsyncDeadlineError.timedOut {
            call.cancel()
        } catch TransportError.coreMutationOutcomeUnknown {
            // Inside the deadline only a link that ended says this.
            return .ended(.failed(Self.outcomeUnknown))
        } catch TransportError.herdrCoreTerminalGone {
            return .ended(.failed(Self.coreGone))
        } catch let refusal as HerdrAPIError {
            return .ended(.failed(Self.refused(refusal)))
        } catch {
            return .ended(.failed(Self.notSent))
        }
        do {
            try await AsyncDeadline.run(for: Self.cancelWait, sleep: clock.sleep) { try await call.value }
            return .answered
        } catch TransportError.coreMutationOutcomeUnknown {
            return .unanswered
        } catch let refusal as HerdrAPIError {
            return .ended(.failed(Self.refused(refusal)))
        } catch {
            return .ended(.failed(Self.notTakenInTime))
        }
    }

    private static func refused(_ refusal: HerdrAPIError) -> String {
        String(localized: "The Host refused Stop: \(refusal.message)")
    }
}
