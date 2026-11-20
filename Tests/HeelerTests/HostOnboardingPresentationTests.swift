import Foundation
import Testing

@testable import Heeler

@Suite("Host onboarding follows the Console")
struct HostOnboardingPresentationTests {
    /// A Server's page has no Reconnect of its own, so checks that pass bring
    /// its Server back: a Console that stopped, or is backing off, retries
    /// once (ADR 0058).
    @Test func passingPreflightRetriesAConsoleThatStoppedOrIsBackingOff() {
        let key = HostKeyFingerprint(publicKeyBlob: Data("presented".utf8))
        let rejected = TransportError.hostKeyRejected(presented: key)
        let rows: [(Bool, EventsSessionStatus?, Bool, HostOnboardingConsoleRecovery.Action)] = [
            // The Console never prompts for trust, which onboarding now pinned.
            (true, .failed(rejected), false, .retry),
            (true, .failed(.jumpHostFailed(rejected)), false, .retry),
            // The Server was missing or stopped and now answers the checks.
            (true, .failed(.socketNotFound(path: "/tmp/herdr.sock")), false, .retry),
            (true, .failed(.authenticationFailed), false, .retry),
            // Nothing to wait out a backoff for.
            (true, .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut), false, .retry),
            // A manual Reconnect is already retrying: decide after it.
            (true, .failed(rejected), true, .wait),
            // The Console has not settled yet.
            (true, .connecting, false, .wait),
            // Any other settled state spends the proof without a retry.
            (true, .connected, false, .disarm),
            (true, .suspended, false, .disarm),
            (true, nil, false, .disarm),
            // No passing preflight to act on.
            (false, .failed(rejected), false, .wait),
        ]
        for (isArmed, status, inFlight, expected) in rows {
            let input = HostOnboardingConsoleRecovery.Input(
                isArmed: isArmed, status: status, isManualReconnectInFlight: inFlight)
            #expect(HostOnboardingConsoleRecovery.action(for: input) == expected)
        }
    }

    /// A Start that worked ends the wait of a Console backing off from a core it
    /// read as stopped. Anything else leaves the Console's connection alone.
    @Test func aStartThatPassedWakesOnlyAConsoleBackingOff() {
        let notRunning = EventsSessionStatus.reconnecting(
            attempt: 5, delay: .seconds(16),
            failure: .herdrCoreNotRunning(socketPath: "/s.sock", socketFilePresent: false))
        let started = CoreStartState.started(session: "work")
        let rows: [(CoreStartState, Bool, EventsSessionStatus?, HostOnboardingCoreFollow.Action)] = [
            (started, true, notRunning, .wakeConsole),
            (.alreadyRunning(session: "work"), true, notRunning, .wakeConsole),
            (
                started, true,
                .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut), .wakeConsole
            ),
            // The Console is on it, or has it.
            (started, true, .connected, .none),
            (started, true, .connecting, .none),
            // The checks did not pass: reconnecting would only read the same failure.
            (started, false, notRunning, .none),
            (.idle, true, notRunning, .none),
            (.running, true, notRunning, .none),
            (.failed(message: "no"), true, notRunning, .none),
        ]
        for (coreStart, passed, status, expected) in rows {
            #expect(
                HostOnboardingCoreFollow.action(
                    afterCoreStart: coreStart, reportPassed: passed, status: status) == expected,
                "\(coreStart) \(passed) \(String(describing: status))")
        }
    }

    @Test func theConsoleReadingACoreIsOnlyItsNotRunningAndItsConnected() {
        let notRunning = TransportError.herdrCoreNotRunning(socketPath: "/s.sock", socketFilePresent: true)
        let rows: [(EventsSessionStatus?, HostOnboardingCoreFollow.Reading)] = [
            (.reconnecting(attempt: 2, delay: .seconds(2), failure: notRunning), .notRunning),
            (.connected, .connected),
            (.reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut), .other),
            (.connecting, .other),
            (.suspended, .other),
            (.failed(notRunning), .other),
            (nil, .other),
        ]
        for (status, expected) in rows {
            #expect(HostOnboardingCoreFollow.reading(status) == expected, "\(String(describing: status))")
        }
    }

    /// The checks follow what the Console found out since they ran, in the two
    /// directions where they would otherwise disagree with the card above them.
    @Test func theChecksRunAgainWhenTheConsoleContradictsThem() {
        typealias Row = (
            reading: HostOnboardingCoreFollow.Reading, kind: ServerKind, phase: HostOnboardingStore.Phase,
            coreStart: CoreStartState, passed: Bool, offers: Bool, expected: HostOnboardingCoreFollow.Action
        )
        let rows: [Row] = [
            // The core stopped after passing checks, and Start is what is missing.
            (.notRunning, .herdrCore, .finished, .idle, true, false, .runChecks),
            // A Start's note goes too: it no longer describes this core.
            (.notRunning, .herdrCore, .finished, .started(session: "work"), true, false, .runChecks),
            // The checks already said so, or say something more exact after a Start.
            (.notRunning, .herdrCore, .finished, .idle, false, true, .none),
            (.notRunning, .herdrCore, .finished, .alreadyRunning(session: "work"), false, false, .none),
            // The core came back by itself, so Start would only say it runs.
            (.connected, .herdrCore, .finished, .idle, false, true, .runChecks),
            // Connecting after a Start leaves its note in place.
            (.connected, .herdrCore, .finished, .started(session: "work"), true, false, .none),
            (.connected, .herdrCore, .finished, .idle, false, false, .none),
            // Nothing to contradict yet, or a Start in hand.
            (.notRunning, .herdrCore, .running, .idle, true, false, .none),
            (.notRunning, .herdrCore, .idle, .idle, true, false, .none),
            (.notRunning, .herdrCore, .finished, .running, true, false, .none),
            (.connected, .herdrCore, .finished, .running, false, true, .none),
            (.other, .herdrCore, .finished, .idle, true, true, .none),
            // A Herdr TUI Host never reads this.
            (.notRunning, .herdrTUI, .finished, .idle, true, false, .none),
            (.connected, .herdrTUI, .finished, .idle, false, true, .none),
        ]
        for row in rows {
            #expect(
                HostOnboardingCoreFollow.action(
                    afterConsoleReads: row.reading, serverKind: row.kind, phase: row.phase,
                    coreStart: row.coreStart, reportPassed: row.passed, offersStart: row.offers)
                    == row.expected,
                "\(row)")
        }
    }

    /// The check prints the fingerprint of the host key file sshd serves for
    /// the presented key's algorithm.
    @Test func changedKeyCheckNamesTheHostKeyFileOfThePresentedAlgorithm() {
        let rows: [(algorithm: String, file: String)] = [
            ("ssh-ed25519", "ssh_host_ed25519_key.pub"),
            ("ecdsa-sha2-nistp256", "ssh_host_ecdsa_key.pub"),
            ("rsa-sha2-512", "ssh_host_rsa_key.pub"),
            ("ssh-rsa", "ssh_host_rsa_key.pub"),
            (HostKeyFingerprint.unknownAlgorithm, "ssh_host_ed25519_key.pub"),
        ]
        for (algorithm, file) in rows {
            let replacement = HostKeyReplacement(
                known: HostKeyFingerprint(digest: Data(repeating: 0, count: 32)),
                presented: HostKeyFingerprint(
                    digest: Data(repeating: 1, count: 32), algorithm: algorithm))
            #expect(replacement.fingerprintCommand == "ssh-keygen -lf /etc/ssh/\(file)")
        }
    }
}
