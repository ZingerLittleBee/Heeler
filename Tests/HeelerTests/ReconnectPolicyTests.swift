import Foundation
import Testing

@testable import Heeler

@Suite("Reconnect policy")
struct ReconnectPolicyTests {
    @Test func delaysGrowExponentiallyUntilTheCap() {
        let policy = ReconnectPolicy(
            initialDelay: .milliseconds(100), multiplier: 2, maxDelay: .milliseconds(450))

        #expect(policy.delay(beforeAttempt: 1) == .milliseconds(100))
        #expect(policy.delay(beforeAttempt: 2) == .milliseconds(200))
        #expect(policy.delay(beforeAttempt: 3) == .milliseconds(400))
        #expect(policy.delay(beforeAttempt: 4) == .milliseconds(450))
        #expect(policy.delay(beforeAttempt: 5) == .milliseconds(450))
    }

    @Test func hugeAttemptCountsStayAtTheCapWithoutOverflow() {
        // A Host can be gone for hours; attempt numbers keep climbing and the
        // delay must sit at the cap, not overflow or grow.
        #expect(
            ReconnectPolicy.default.delay(beforeAttempt: 10_000)
                == ReconnectPolicy.default.maxDelay)
    }

    @Test func firstAttemptAlwaysWaitsTheInitialDelay() {
        // Attempt numbers below 1 are a caller bug; degrade to the initial
        // delay instead of misbehaving.
        let policy = ReconnectPolicy(
            initialDelay: .milliseconds(100), multiplier: 2, maxDelay: .seconds(1))

        #expect(policy.delay(beforeAttempt: 0) == .milliseconds(100))
    }

    @Test func nonPositiveMultiplierNeverShrinksOrLoopsForever() {
        let policy = ReconnectPolicy(
            initialDelay: .milliseconds(100), multiplier: 0, maxDelay: .seconds(1))

        #expect(policy.delay(beforeAttempt: 50) == .milliseconds(100))
    }
}
