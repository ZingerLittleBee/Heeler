import SwiftUI
import Testing
import UIKit

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

    @Test func cardsRenderAtNarrowAndAccessibleSizes() throws {
        #expect(UIImage(named: "LucideBot") != nil)
        for accessible in [false, true] {
            for dark in [false, true] {
                let width: CGFloat = accessible ? 320 : 390
                let activity = ChatSubagentActivity(
                    agentPath: "/root/heeler_session_status",
                    events: ["started", "interacted", "interacted", "completed"])
                let tool = ChatToolActivity(
                    kind: .agent, name: "SubAgentActivity", title: "Subagent: heeler_session_status",
                    status: .succeeded, subagentActivity: activity)
                let row = ChatRow(
                    id: .entry(ChatEntryID("subagent")), content: .tool(tool), revision: 1, topSpacing: 0)
                let actions = ChatRowActions(
                    toggle: { _ in }, loadOlder: {}, copy: { _ in }, selectText: { _ in }, missingOutputText: "")
                var heights: [CGFloat] = []
                for expanded in [false, true] {
                    let renderer = ImageRenderer(content: ChatRowView(
                        row: row, isExpanded: expanded, actions: actions)
                        .padding(.vertical, 16)
                        .frame(width: width)
                        .background(Color(uiColor: .systemBackground))
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.dynamicTypeSize, accessible ? .accessibility3 : .large))
                    renderer.scale = 2
                    let image = try #require(renderer.uiImage)
                    #expect(image.size.width == width)
                    heights.append(image.size.height)
                    Attachment.record(image,
                        named: "subagent-accessible-\(accessible)-dark-\(dark)-expanded-\(expanded)", as: .png)
                }
                #expect(heights[1] > heights[0])
            }
        }
    }
}
