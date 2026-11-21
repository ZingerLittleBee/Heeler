import Testing

@testable import Heeler

@MainActor
@Suite("Chat subagent presentation", .serialized)
struct ChatSubagentPresentationTests {
    @Test func historyPreservesLifecycleBoundariesAndCopyIncludesIdentity() {
        let presentation = ChatSubagentPresentation(activity: .init(
            agentPath: "/root/heeler_session_status",
            events: ["started", "interacted", "interacted", "completed", "interacted"]))
        #expect(presentation.name == "heeler_session_status")
        #expect(presentation.status == "Message exchanged")
        #expect(presentation.history.map(\.label) == [
            "Started", "Message exchanged ×2", "Completed", "Message exchanged",
        ])
        #expect(presentation.copyText.contains("/root/heeler_session_status"))
        #expect(presentation.copyText.contains("Message exchanged ×2"))
        #expect(ChatSubagentPresentation.symbol(for: "started") != "checkmark.circle")
        #expect(ChatSubagentPresentation.symbol(for: "interacted") != "checkmark.circle")
        #expect(ChatSubagentPresentation.symbol(for: "completed") == "checkmark.circle")
    }

    @Test func missingIdentityAndUnknownEventsHaveHonestLabels() {
        let presentation = ChatSubagentPresentation(activity: .init(agentPath: nil, events: ["future-event"]))
        #expect(presentation.name == "Unnamed subagent")
        #expect(presentation.status == "Activity recorded")
        #expect(presentation.eventCount == "1 event")
    }
}
