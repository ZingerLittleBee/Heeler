import Foundation
import Testing

@testable import Heeler

/// Chat's Agent controls: keys reach the Agent's program through
/// `agent.send_keys`, in the order pressed.
@MainActor
@Suite("Chat Agent keys")
struct ChatAgentKeysStoreTests {
    @Test func keysArriveInTheOrderPressed() async {
        let gate = ScriptedTransportCallGate()
        let recorder = KeyRecorder()
        let store = ChatAgentKeysStore { keys in
            recorder.calls += 1
            if recorder.calls == 1 { await gate.waitUntilOpen() }
            recorder.sent.append(keys)
        }

        store.press(.escape)
        let enter = store.press(.enter)
        await gate.waitForEntry()
        for _ in 0..<20 { await Task.yield() }
        #expect(recorder.calls == 1, "a key must wait for the one pressed before it")

        await gate.open()
        await enter?.value
        #expect(recorder.sent == [["esc"], ["enter"]])
    }

    @Test func aFailureShowsUntilAKeyArrives() async {
        let recorder = KeyRecorder()
        let store = ChatAgentKeysStore { keys in
            recorder.calls += 1
            if recorder.calls == 1 { throw TransportError.cancelled }
            recorder.sent.append(keys)
        }

        await store.press(.escape)?.value
        #expect(store.failure != nil)

        await store.press(.enter)?.value
        #expect(store.failure == nil)
        #expect(recorder.sent == [["enter"]])
    }

    /// The Composer's Stop: in line with the Agent page's keys, and told
    /// whether its Esc went.
    @Test func deliverQueuesLikeAPressAndSaysWhetherTheKeyWent() async {
        let gate = ScriptedTransportCallGate()
        let recorder = KeyRecorder()
        let store = ChatAgentKeysStore { keys in
            recorder.calls += 1
            if recorder.calls == 1 { await gate.waitUntilOpen() }
            if recorder.calls == 3 { throw TransportError.cancelled }
            recorder.sent.append(keys)
        }

        store.press(.enter)
        async let delivered = store.deliver(["esc"])
        await gate.waitForEntry()
        for _ in 0..<20 { await Task.yield() }
        #expect(recorder.calls == 1, "Stop's Esc waits for the key pressed before it")

        await gate.open()
        #expect(await delivered == .sent)
        #expect(recorder.sent == [["enter"], ["esc"]])

        #expect(await store.deliver(["esc"]) == .failed)
        #expect(store.failure != nil)
    }

    @Test func deliverSendsEveryKeyInOneRequest() async {
        let recorder = KeyRecorder()
        let store = ChatAgentKeysStore { keys in
            recorder.calls += 1
            recorder.sent.append(keys)
        }

        #expect(await store.deliver(["esc", "esc"]) == .sent)
        #expect(recorder.sent == [["esc", "esc"]])
    }

    @Test func deliverWithoutKeysSendsNothing() async {
        let recorder = KeyRecorder()
        let store = ChatAgentKeysStore { keys in
            recorder.calls += 1
            recorder.sent.append(keys)
        }

        #expect(await store.deliver([]) == .failed)
        #expect(recorder.calls == 0)
        #expect(store.failure == nil)
    }

    /// A Stop guard reads inside the queue, once the keys pressed before
    /// Stop have gone, so it sees their effect.
    @Test func aCheckRunsOnceEarlierKeysHaveGoneAndMayWithholdTheKeys() async {
        let gate = ScriptedTransportCallGate()
        let recorder = KeyRecorder()
        let store = ChatAgentKeysStore { keys in
            recorder.calls += 1
            if recorder.calls == 1 { await gate.waitUntilOpen() }
            recorder.sent.append(keys)
        }

        store.press(.up)
        async let withheld = store.deliver(["esc", "esc"], unless: {
            recorder.sentBeforeCheck = recorder.sent
            return "Not now."
        })
        await gate.waitForEntry()
        for _ in 0..<20 { await Task.yield() }
        #expect(recorder.sentBeforeCheck == nil, "the check waits for the key pressed before it")

        await gate.open()
        #expect(await withheld == .withheld("Not now."))
        #expect(recorder.sentBeforeCheck == [["up"]])
        #expect(recorder.sent == [["up"]], "a withheld delivery sends nothing")
        #expect(store.failure == nil)

        #expect(await store.deliver(["esc", "esc"], unless: { nil }) == .sent)
        #expect(recorder.sent == [["up"], ["esc", "esc"]])
    }
}

@MainActor
private final class KeyRecorder {
    var calls = 0
    var sent: [[String]] = []
    /// What had been sent when a delivery's check ran.
    var sentBeforeCheck: [[String]]?
}
