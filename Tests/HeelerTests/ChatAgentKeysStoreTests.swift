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
        async let delivered = store.deliver(.escape)
        await gate.waitForEntry()
        for _ in 0..<20 { await Task.yield() }
        #expect(recorder.calls == 1, "Stop's Esc waits for the key pressed before it")

        await gate.open()
        #expect(await delivered)
        #expect(recorder.sent == [["enter"], ["esc"]])

        #expect(await store.deliver(.escape) == false)
        #expect(store.failure != nil)
    }
}

@MainActor
private final class KeyRecorder {
    var calls = 0
    var sent: [[String]] = []
}
