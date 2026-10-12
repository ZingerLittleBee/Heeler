import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Agent reference insertion", .timeLimit(.minutes(1)))
struct AgentReferenceInsertionTests {
    @Test(arguments: [false, true])
    func leavingAnAgentDiscardsHeldTextEvenWhenItsAttachIsRetained(retained: Bool) async throws {
        let transport = ScriptedTransport()
        let attach = AgentAttachStore(
            target: "w1:p1", paneTitle: "Claude", transportGeneration: 1,
            isOnStage: { true },
            runTerminal: { request, handler in
                let session = try await transport.attachTerminal(request)
                try await handler.runEndingSession(session)
            },
            closePane: {})
        attach.viewDidResize(cols: 80, rows: 24)
        try #require(await ChangesViewTests.eventually { attach.input.liveGeneration != nil })
        #expect(attach.terminalStatus == .connecting)
        attach.insertReference("discard.swift:3 ")

        if retained {
            attach.leaveInteractionsForRetention()
        } else {
            await attach.leave().value
            // A return can enqueue input before a channel owner permits rejoin.
            // Leaving again must discard it even though the pipeline is stopped.
            attach.insertReference("also-discard.swift ")
            await attach.leave().value
            attach.rejoin()
            try #require(await ChangesViewTests.eventually { attach.terminalStatus == .waitingForSize })
            attach.viewDidResize(cols: 80, rows: 24)
            try #require(await ChangesViewTests.eventually { attach.input.liveGeneration != nil })
        }
        #expect(await transport.emitAttachOutput(Data("live".utf8)))
        try #require(await ChangesViewTests.eventually { attach.terminalStatus == .live })
        attach.insertReference("keep.swift:4 ")
        await attach.leave().value
        let writes = await transport.attachInputs.compactMap { input -> Data? in
            if case .keystrokes(let data) = input { data } else { nil }
        }
        #expect(writes == [Data("keep.swift:4 ".utf8)])
        #expect(await transport.agentPromptParams.isEmpty)
    }
}
