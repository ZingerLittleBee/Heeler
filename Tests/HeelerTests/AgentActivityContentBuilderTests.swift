import Foundation
import Testing

@testable import Heeler

@Suite("Agent activity content builder")
struct AgentActivityContentBuilderTests {
    private let hostID = UUID()
    private let key = Data(0..<32)

    @Test func countsCoverTheFullEligibleInventoryNotTheCap() throws {
        var agents: [ConsoleAgent] = [
            agent("w:p-block", .blocked),
            agent("w:p-done", .done),
        ]
        for index in 0..<6 {
            agents.append(agent("w:p-work-\(index)", .working))
        }

        let desire = try #require(
            AgentActivityContentBuilder.desire(from: agents, hostName: "mbp"))

        #expect(desire.counts == .init(working: 6, blocked: 1, done: 1))
        #expect(desire.agents.count == 5)
    }

    @Test func sortsBlockedThenDoneThenWorkingWithPaneByteTiebreak() throws {
        let agents = [
            agent("w:p9", .working, kind: "grok", title: "later"),
            agent("w:p2", .blocked, kind: "claude", title: "first blocked"),
            agent("w:p1", .done, kind: "droid", title: "done"),
            agent("w:p8", .blocked, kind: "codex", title: "second blocked"),
            agent("w:p3", .working, kind: "claude", title: "earlier working"),
        ]

        let desire = try #require(
            AgentActivityContentBuilder.desire(from: agents, hostName: "mbp"))

        #expect(desire.agents.map(\.paneID) == ["w:p2", "w:p8", "w:p1", "w:p3", "w:p9"])
        #expect(desire.agents.map(\.status) == [
            "blocked", "blocked", "done", "working", "working",
        ])
    }

    @Test func capsListedAgentsAtFiveAndKeepsCounts() throws {
        let agents = (0..<8).map { index in
            agent(String(format: "w:p%02d", index), .working)
        }

        let desire = try #require(
            AgentActivityContentBuilder.desire(from: agents, hostName: "studio"))

        #expect(desire.counts.working == 8)
        #expect(desire.agents.count == 5)
        #expect(desire.agents.map(\.paneID) == ["w:p00", "w:p01", "w:p02", "w:p03", "w:p04"])
    }

    @Test func trimsCJKTitlesAndHostNamesAtEightyGraphemes() throws {
        let cjk = String(repeating: "锁", count: 81)
        let agents = [agent("w:p1", .working, title: cjk)]

        let desire = try #require(
            AgentActivityContentBuilder.desire(from: agents, hostName: cjk))

        #expect(desire.hostName.count == 80)
        #expect(desire.hostName == String(repeating: "锁", count: 80))
        #expect(desire.agents.first?.title?.count == 80)
        #expect(desire.agents.first?.title == String(repeating: "锁", count: 80))
    }

    @Test func trimsEmojiGraphemesNotUTF8Bytes() throws {
        let family = "👨‍👩‍👧"
        #expect(family.count == 1)
        let over = String(repeating: family, count: 81)

        let desire = try #require(
            AgentActivityContentBuilder.desire(
                from: [agent("w:p1", .blocked, title: over)], hostName: "mbp"))

        #expect(desire.agents.first?.title?.count == 80)
        #expect(desire.agents.first?.title == String(repeating: family, count: 80))
    }

    @Test func excludesIdleAndUnknownFromCountsAndTheList() throws {
        let agents = [
            agent("w:p1", .idle, title: "idle"),
            agent("w:p2", .unknown, title: "unknown"),
            agent("w:p3", AgentStatus(rawValue: "mystery"), title: "future"),
            agent("w:p4", .working, title: "keep"),
        ]

        let desire = try #require(
            AgentActivityContentBuilder.desire(from: agents, hostName: "mbp"))

        #expect(desire.counts == .init(working: 1, blocked: 0, done: 0))
        #expect(desire.agents.map(\.paneID) == ["w:p4"])
    }

    @Test func returnsNilWhenNothingIsEligible() {
        let agents = [
            agent("w:p1", .idle),
            agent("w:p2", .unknown),
        ]

        #expect(AgentActivityContentBuilder.desire(from: agents, hostName: "mbp") == nil)
        #expect(
            AgentActivityContentBuilder.make(agents: agents, hostName: "mbp", key: key) == nil)
        #expect(AgentActivityContentBuilder.make(agents: [], hostName: "mbp", key: key) == nil)
    }

    @Test func carriesTheHerdrAgentNameAndOmitsItWhenUnnamed() throws {
        let agents = [
            agent("w:p1", .working, name: "la-demo"),
            agent("w:p2", .blocked),
        ]

        let desire = try #require(
            AgentActivityContentBuilder.desire(from: agents, hostName: "mbp"))

        let byPane = Dictionary(uniqueKeysWithValues: desire.agents.map { ($0.paneID, $0) })
        #expect(byPane["w:p1"]?.name == "la-demo")
        #expect(byPane["w:p2"]?.name == nil)
    }

    @Test func omitsEmptyTitlesAndFallsBackToUnknownKind() throws {
        let blankKind = Agent(
            terminalID: "t", kind: "", title: "", status: .done,
            workspaceID: "w", tabID: "t", paneID: "w:p1", cwd: "/", revision: 1)
        let agents = [
            ConsoleAgent(
                hostID: hostID, hostName: "mbp", agent: blankKind,
                workspaceLabel: nil, repoName: nil)
        ]

        let desire = try #require(
            AgentActivityContentBuilder.desire(from: agents, hostName: "mbp"))

        #expect(desire.agents == [
            AgentActivityDetails.AgentDetail(
                paneID: "w:p1", kind: "unknown", status: "done", title: nil)
        ])
    }

    @Test func degradesAnOversizeSealedTitleThenKeepsTheAgent() throws {
        // One grapheme, many UTF-8 bytes: 80 of these blow the ct budget
        // even after the 80-grapheme trim.
        let cluster = "e" + String(repeating: "\u{0301}", count: 50)
        let huge = String(repeating: cluster, count: 80)
        #expect(huge.count == 80)

        let state = try #require(
            AgentActivityContentBuilder.make(
                agents: [agent("w:p1", .working, title: huge)],
                hostName: "mbp",
                key: key))

        #expect(state.counts == .init(working: 1, blocked: 0, done: 0))
        let envelope = try #require(state.envelope)
        #expect(envelope.ct.count <= AgentActivityContentBuilder.maxCiphertextBytes)
        let details = try opened(state)
        #expect(details.agents.count == 1)
        #expect(details.agents.first?.title == nil)
        #expect(details.agents.first?.paneID == "w:p1")
        #expect(details.hostName == "mbp")
    }

    @Test func sealedContentOpensToTheDesiredDetails() throws {
        let agents = [agent("wV:p1", .working, title: "task")]
        let state = try #require(
            AgentActivityContentBuilder.make(agents: agents, hostName: "mbp", key: key))

        let details = try opened(state)
        #expect(details.hostName == "mbp")
        #expect(details.agents.first?.title == "task")
        #expect(details.agents.first?.status == "working")
    }

    private func opened(
        _ state: AgentActivityAttributes.ContentState
    ) throws -> AgentActivityDetails {
        let envelope = try #require(state.envelope)
        return try AgentActivityEnvelope.open(try JSONEncoder().encode(envelope), using: key)
    }

    private func agent(
        _ paneID: String, _ status: AgentStatus,
        kind: String = "claude", title: String = "Task", name: String? = nil
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID, hostName: "mbp",
            agent: Agent(
                .fixture(paneID: paneID, status: status, kind: kind, title: title, name: name)),
            workspaceLabel: nil, repoName: nil)
    }
}
