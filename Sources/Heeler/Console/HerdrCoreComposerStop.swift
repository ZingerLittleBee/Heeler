import Foundation

/// The terminal Composer's Stop on a herdr-core Agent (ADR 0035): one
/// `terminal.interrupt`, in which the core presses the Terminal's own stop key,
/// then a read of the foreground, since the answer does not say whether the
/// program still runs. Heeler presses no key of its own.
@MainActor
struct HerdrCoreComposerStop {
    /// How long the core watches for an effect after pressing the key: up to the
    /// whole of it in a Terminal that never reports.
    static let interruptTimeout: Duration = .seconds(2)
    /// How much longer Stop waits for the core's answer, on a slow link or behind
    /// input the core holds. Past that it reads the foreground without the answer.
    static let answerMargin: Duration = .seconds(1)
    static let readTimeout: Duration = .seconds(5)

    static let notSent = "The Host is not connected, so Stop wasn't sent."
    static let outcomeUnknown =
        "The Host did not answer, so Stop may or may not have reached the Agent. Check the terminal."
    static let readFailed =
        "Stop went, but the Host did not say whether the Agent still runs. Check the terminal."

    let address: String
    let projection: @MainActor () -> HerdrCoreConsoleProjection?
    let clock: BlockedCardClock

    func perform() async -> AgentInterruptOutcome {
        guard let projection = projection() else { return .failed(Self.notSent) }
        let address = address
        do {
            try await AsyncDeadline.run(
                for: Self.interruptTimeout + Self.answerMargin, sleep: clock.sleep
            ) {
                try await projection.interruptTerminal(at: address, timeout: Self.interruptTimeout)
            }
        } catch AsyncDeadlineError.timedOut {
            // Expected, and the read below tells what the answer would not have.
        } catch TransportError.coreMutationOutcomeUnknown {
            // Inside the deadline only a link that ended says this.
            return .failed(Self.outcomeUnknown)
        } catch let refusal as HerdrAPIError {
            return .failed("The Host refused Stop: \(refusal.message)")
        } catch {
            return .failed(Self.notSent)
        }
        do {
            try await AsyncDeadline.run(for: Self.readTimeout, sleep: clock.sleep) {
                try await projection.readForeground(at: address)
            }
            return .sent
        } catch let refusal as HerdrAPIError where refusal.code == "not_found" {
            return .sent
        } catch {
            return .failed(Self.readFailed)
        }
    }
}
