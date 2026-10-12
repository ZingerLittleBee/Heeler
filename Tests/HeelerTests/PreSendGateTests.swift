import Foundation
import Testing

@testable import Heeler

@Suite("Pre-send gate")
struct PreSendGateTests {
    @Test("An empty box passes unless the Agent is Blocked")
    func emptyBox() {
        #expect(PreSendGate.check(.empty(placeholder: nil), activity: .idle) == .send)
        #expect(PreSendGate.check(.empty(placeholder: "Ask Codex to do anything"), activity: .working) == .send)
        #expect(PreSendGate.check(.empty(placeholder: nil), activity: .unknown) == .send)
        #expect(PreSendGate.check(.empty(placeholder: nil), activity: .blocked) == .holdBlocked)
    }

    @Test(
        "Every other state holds the message",
        arguments: [
            InputBoxState.text("draft"), .shellMode("ls"), .shellMode(""), .disabled("Input disabled."),
            .overlay("/compact"), .dialog, .unknown("Claude's input box is not on screen."),
        ])
    func holds(state: InputBoxState) {
        #expect(PreSendGate.check(state, activity: .idle) == .hold(state))
        #expect(PreSendGate.check(state, activity: .blocked) == .holdBlocked)
    }

    @Test("Captured screens")
    func capturedScreens() throws {
        #expect(PreSendGate.check(try ScreenFixture.screen("claude-01-ready"), program: .claude, activity: .idle) == .send)
        #expect(PreSendGate.check(try ScreenFixture.screen("codex-00-ready"), program: .codex, activity: .idle) == .send)
        let bash = try ScreenFixture.screen("claude-02-c1-bash-blocked")
        #expect(PreSendGate.check(bash, program: .claude, activity: .blocked) == .holdBlocked)
        #expect(PreSendGate.check(bash, program: .claude, activity: .unknown) == .hold(.dialog))
        // The composer stays in view while asynchronous questions wait.
        let collapsed = try ScreenFixture.screen("codex-08-x4-async-collapsed")
        #expect(PreSendGate.check(collapsed, program: .codex, activity: .working) == .hold(.dialog))
    }
}

@Suite("Delivery check")
struct DeliveryCheckTests {
    @Test("The box emptied, or a dialog or Blocked took over: delivered")
    func delivered() {
        #expect(DeliveryCheck.verdict(.empty(placeholder: nil), activity: .working) == .delivered)
        #expect(DeliveryCheck.verdict(.dialog, activity: .unknown) == .delivered)
        #expect(DeliveryCheck.verdict(.unknown("why"), activity: .blocked) == .delivered)
    }

    @Test("Text left in the box: not delivered, with the text")
    func notDelivered() {
        #expect(DeliveryCheck.verdict(.text("fix the tests"), activity: .idle) == .notDelivered("fix the tests"))
        #expect(DeliveryCheck.verdict(.shellMode("ls"), activity: .working) == .notDelivered("ls"))
    }

    @Test(
        "Anything else leaves the message marked as sent",
        arguments: [
            InputBoxState.shellMode(""), .disabled("Input disabled."), .overlay("/compact"),
            .unknown("Codex's composer is not on screen."),
        ])
    func unconfirmed(state: InputBoxState) {
        #expect(DeliveryCheck.verdict(state, activity: .idle) == .unconfirmed)
    }

    @Test("Captured screens after sending")
    func capturedScreens() throws {
        #expect(
            DeliveryCheck.verdict(try ScreenFixture.screen("claude-29-c3-after-immediate"), program: .claude, activity: .idle)
                == .delivered)
        #expect(
            DeliveryCheck.verdict(try ScreenFixture.screen("claude-02-c1-bash-blocked"), program: .claude, activity: .unknown)
                == .delivered)
        #expect(
            DeliveryCheck.verdict(try ScreenFixture.screen("codex-03-x2-after-esc"), program: .codex, activity: .idle)
                == .delivered)
    }

    @Test("The re-read waits three seconds")
    func delay() {
        #expect(DeliveryCheck.delay == .seconds(3))
    }
}
