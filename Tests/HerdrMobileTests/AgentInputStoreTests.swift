import Foundation
import Testing

@testable import HerdrMobile

/// The detail screen's input store (#10) against a scripted transport: the
/// message box sends via `agent.send`, the quick-key bar via
/// `pane.send_keys`, failures surface, and success clears the box — protocol
/// level, no SSH, no UI.
@MainActor
@Suite("Agent input store")
struct AgentInputStoreTests {
    private func makeStore(
        transport: ScriptedTransport?, target: String = "w1:p1"
    ) -> AgentInputStore {
        AgentInputStore(target: target) { transport }
    }

    @Test func sendDraftDeliversViaAgentSendAndClearsTheBox() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        store.draft = "  yes, proceed  "

        await store.sendDraft()

        #expect(store.state == .idle)
        #expect(store.draft.isEmpty)
        // The draft is trimmed on the way out, targeted by pane id.
        #expect(
            await transport.agentSends == [
                AgentSendParams(target: "w1:p1", text: "yes, proceed")
            ])
    }

    @Test func blankDraftSendsNothing() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        store.draft = "   \n  "

        await store.sendDraft()

        #expect(await transport.agentSends.isEmpty)
        #expect(store.state == .idle)
    }

    @Test func quickKeysSendTheirHerdrSpellings() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)

        await store.send(.enter)
        await store.send(.escape)
        await store.send(.interrupt)
        await store.send(.up)
        await store.send(.yes)

        #expect(
            await transport.sentKeys == [
                PaneSendKeysParams(keys: ["enter"], paneID: "w1:p1"),
                PaneSendKeysParams(keys: ["esc"], paneID: "w1:p1"),
                PaneSendKeysParams(keys: ["ctrl+c"], paneID: "w1:p1"),
                PaneSendKeysParams(keys: ["up"], paneID: "w1:p1"),
                PaneSendKeysParams(keys: ["y"], paneID: "w1:p1"),
            ])
        #expect(store.state == .idle)
    }

    @Test func everyQuickKeyMapsToANonEmptySpelling() {
        // Guards the bar against shipping a key that sends nothing.
        for key in QuickKey.allCases {
            #expect(!key.keys.isEmpty)
            #expect(key.keys.allSatisfy { !$0.isEmpty })
            // Each button shows either a glyph or a label, never blank.
            #expect(key.label != nil || key.systemImage != nil)
        }
    }

    @Test func failedSendSurfacesAndKeepsTheDraft() async throws {
        let transport = ScriptedTransport()
        await transport.setSendFailure(.timedOut)
        let store = makeStore(transport: transport)
        store.draft = "important reply"

        await store.sendDraft()

        #expect(store.state == .failed("The Host did not answer in time."))
        // The draft survives so the user can retry rather than retype.
        #expect(store.draft == "important reply")
        #expect(await transport.agentSends.isEmpty)
    }

    @Test func serverRejectionSurfacesTheHerdrMessage() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)

        await transport.setSendFailure(nil)
        // A HerdrAPIError is not a TransportError; the store must still map it.
        let rejectingTransport = RejectingTransport(
            error: HerdrAPIError(code: "invalid_key", message: "unsupported key foo"))
        let rejectingStore = AgentInputStore(target: "w1:p1") { rejectingTransport }

        await rejectingStore.send(.enter)

        #expect(
            rejectingStore.state == .failed("herdr rejected the input: unsupported key foo"))
        _ = store
    }

    @Test func missingTransportFailsActionably() async throws {
        let store = makeStore(transport: nil)
        store.draft = "hello"

        await store.sendDraft()

        #expect(store.state == .failed("The Host is not connected."))
        #expect(store.draft == "hello")
    }

    @Test func successAfterFailureClearsTheError() async throws {
        let transport = ScriptedTransport()
        await transport.setSendFailure(.timedOut)
        let store = makeStore(transport: transport)

        await store.send(.enter)
        #expect(store.state == .failed("The Host did not answer in time."))

        await transport.setSendFailure(nil)
        await store.send(.enter)
        #expect(store.state == .idle)
    }
}

/// A `Transport` whose send methods always throw a fixed error: lets the
/// input store's error mapping be exercised for error types the scripted
/// transport does not model (e.g. a server-side `HerdrAPIError`).
private actor RejectingTransport: Transport {
    private let error: any Error

    init(error: any Error) {
        self.error = error
    }

    func sendToAgent(_ params: AgentSendParams) async throws { throw error }
    func sendKeys(_ params: PaneSendKeysParams) async throws { throw error }

    func ping() async throws -> ServerInfo { throw error }
    func listAgents() async throws -> [Agent] { throw error }
    func sessionSnapshot() async throws -> SessionSnapshot { throw error }
    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult { throw error }
    func subscribeToEvents(_ subscriptions: [EventSubscription]) async throws -> HerdrEventStream {
        throw error
    }
    func observeTerminal(_ request: TerminalObserveRequest) async throws -> TerminalFrameStream {
        throw error
    }
    var isConnected: Bool { true }
    func close() async throws {}
}
